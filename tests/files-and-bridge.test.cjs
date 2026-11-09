const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const load = require('./load-ets.cjs');
const noop = () => {};
const Log = { info: noop, warn: noop, error: noop };

function fileActions(writer) {
  const files = new Map();
  const handles = new Map();
  let next = 1;
  const io = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    accessSync: name => name === '/Download' || files.has(name),
    openSync: name => { files.set(name, Buffer.alloc(0)); const file = { fd: next++ }; handles.set(file.fd, name); return file; },
    closeSync: file => handles.delete(file.fd),
    unlinkSync: name => files.delete(name),
    write: async (fd, data) => {
      const count = writer ? writer(data, files) : data.byteLength;
      const name = handles.get(fd);
      files.set(name, Buffer.concat([files.get(name), Buffer.from(data).subarray(0, count)]));
      return count;
    }
  };
  const modules = {
    '@kit.CoreFileKit': { fileIo: io, Environment: { getUserDownloadDir: () => '/Download' } },
    '@kit.ArkTS': { util: { Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } } } },
    '@kit.ArkWeb': { webview: { WebDownloadDelegate: class {
      onBeforeDownload(callback) { this.before = callback; }
      onDownloadFinish(callback) { this.finish = callback; }
      onDownloadFailed(callback) { this.failed = callback; }
    } } }, './Log': { Log }
  };
  return { ...load('kimi/FileActions.ets', modules), files };
}

test('blob writes handle short writes, remove path traversal, and preserve existing downloads', async () => {
  const h = fileActions(buffer => Math.min(5, buffer.byteLength));
  const payload = Buffer.from('完整文件内容0123456789');
  const first = await h.FileActions.saveBlobToDownloads('../../example.txt', payload.toString('base64'));
  const second = await h.FileActions.saveBlobToDownloads('example.txt', payload.toString('base64'));
  assert.equal(first, '/Download/example.txt');
  assert.equal(second, '/Download/example (1).txt');
  assert.deepEqual(h.files.get(first), payload);
  assert.deepEqual(h.files.get(second), payload);
});

test('failed writes clean up partial files and do not permanently lock downloads', async () => {
  let fail = true;
  const h = fileActions(buffer => { if (fail) throw new Error('disk full'); return buffer.byteLength; });
  await assert.rejects(h.FileActions.saveBlobToDownloads('partial.bin', 'YQ=='), /disk full/);
  assert.equal(h.files.size, 0);
  fail = false;
  await h.FileActions.saveBlobToDownloads('complete.bin', 'YQ==');
  assert.equal(h.files.size, 1);
});

test('concurrent web downloads reserve paths and release only their own files on termination', () => {
  const h = fileActions();
  const firstDelegate = h.FileActions.createDownloadDelegate(noop);
  const secondDelegate = h.FileActions.createDownloadDelegate(noop);
  function item(guid, delegate) {
    return {
      getGuid: () => guid,
      getUrl: () => 'https://example.org/report.txt',
      getSuggestedFileName: () => 'report.txt',
      getFullPath() { return this.path; },
      getLastErrorCode: () => 1,
      start(name) { this.path = name; },
      cancel() { delegate.failed(this); }
    };
  }
  const first = item('first', firstDelegate);
  const second = item('second', secondDelegate);
  firstDelegate.before(first);
  secondDelegate.before(second);
  assert.equal(h.files.size, 0);
  assert.equal(first.path, '/Download/report.txt');
  assert.equal(second.path, '/Download/report (1).txt');
  const payload = Buffer.from('second download');
  h.files.set(second.path, payload);
  h.files.set(first.path, Buffer.from('partial'));
  firstDelegate.failed(first);
  assert.equal(h.files.has(first.path), false);
  assert.deepEqual(h.files.get(second.path), payload);

  const cancelled = item('cancelled', firstDelegate);
  firstDelegate.before(cancelled);
  assert.equal(cancelled.path, first.path);
  cancelled.cancel();
  const replacement = item('replacement', firstDelegate);
  firstDelegate.before(replacement);
  assert.equal(replacement.path, first.path);
  h.files.set(replacement.path, payload);
  firstDelegate.failed(first);
  assert.deepEqual(h.files.get(replacement.path), payload);
  firstDelegate.finish(replacement);
  assert.deepEqual(h.files.get(replacement.path), payload);
  h.files.delete(replacement.path);
  const next = item('next', firstDelegate);
  firstDelegate.before(next);
  assert.equal(next.path, first.path);
  firstDelegate.finish(next);
  secondDelegate.finish(second);
});

test('oversized bridge payloads are rejected before allocation or file creation', async () => {
  const h = fileActions();
  await assert.rejects(h.FileActions.saveBlobToDownloads('too-large.bin', {
    length: Math.ceil(h.MAX_BLOB_BYTES / 3) * 4 + 4
  }), /32 MiB/);
  assert.equal(h.files.size, 0);
});

test('large accepted downloads use bounded writes', async () => {
  let largest = 0;
  const h = fileActions(buffer => { largest = Math.max(largest, buffer.byteLength); return buffer.byteLength; });
  const bytes = Buffer.alloc(1024 * 1024 + 1, 7);
  const name = await h.FileActions.saveBlobToDownloads('large.bin', bytes.toString('base64'));
  assert.ok(largest <= 256 * 1024);
  assert.deepEqual(h.files.get(name), bytes);
});

test('all log paths share credential redaction', () => {
  const calls = [];
  const { Log: logger, redactSecrets } = load('kimi/Log.ets', {
    '@kit.PerformanceAnalysisKit': { hilog: { info: (...args) => calls.push(args.at(-1)), warn: noop, error: noop } }
  });
  const samples = [
    'http://127.0.0.1/#token=secret-value',
    'https://example.org/login?user_code=secret-value&access_token=secret-value',
    'Authorization: Bearer secret-value',
    '{"api_key":"secret-value","refresh_token":"secret-value"}',
    'Token: secret-value'
  ];
  for (const sample of samples) {
    assert.ok(!redactSecrets(sample).includes('secret-value'));
    logger.info(sample);
  }
  assert.ok(calls.every(line => !line.includes('secret-value')));
});

test('log forwarding redacts credentials split across reads and discards oversized lines', () => {
  const { SafeLogLines } = load('kimi/Log.ets', {
    '@kit.PerformanceAnalysisKit': { hilog: {} }
  });
  const lines = new SafeLogLines();
  assert.equal(lines.push('Authorization: Bea').length, 0);
  assert.equal(lines.push('rer secret-').length, 0);
  assert.equal(lines.push('value\nnext\n').join('\n'), 'Authorization: Bearer ***\nnext');
  lines.push('x'.repeat(65537));
  assert.equal(lines.push('secret-tail\nsafe\n').join('\n'), 'safe');
  lines.push('unfinished token=secret');
  lines.reset();
  assert.equal(lines.push('new file\n').join('\n'), 'new file');
  lines.reset(true);
  assert.equal(lines.push('remaining-secret\nfirst complete line\n').join('\n'), 'first complete line');
});

test('bridge is limited to the current origin and injection ignores subframes', () => {
  const { bridgePermission, documentStartScript } = load('kimi/WebBridge.ets');
  const permission = JSON.parse(bridgePermission(58637)).javascriptProxyPermission;
  assert.deepEqual(permission.urlPermissionList, [{ scheme: 'http', host: '127.0.0.1', port: '58637', path: '' }]);
  for (const foreign of [true, false]) {
    const window = {};
    window.top = foreign ? window : {};
    vm.runInNewContext(documentStartScript('http://127.0.0.1:58637'), {
      window, location: { origin: foreign ? 'https://example.org' : 'http://127.0.0.1:58637' }
    });
    assert.equal(window.__kimiHmosShell, undefined);
  }
});

test('preview downloads retain the blob after the upstream URL expires at 60 seconds', async () => {
  const { documentStartScript } = load('kimi/WebBridge.ets');
  const payload = Buffer.from('预览文件内容');
  const blob = new Blob([payload], { type: 'text/plain' });
  const url = 'blob:http://127.0.0.1:58637/preview';
  const downloads = [];
  const errors = [];
  const fetched = [];
  let now = 0;
  let revoked = false;
  function element() {
    return {
      style: {}, children: [], listeners: {}, parentNode: null,
      setAttribute: noop,
      addEventListener(type, callback) { this.listeners[type] = callback; },
      appendChild(child) { this.children.push(child); child.parentNode = this; },
      removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
    };
  }
  const body = element();
  const document = {
    body, createElement: element, addEventListener: noop, removeEventListener: noop
  };
  const window = {
    open: noop,
    kimiHost: {
      downloadBlob: (name, base64) => downloads.push({ name, base64 }),
      downloadError: message => errors.push(message)
    }
  };
  window.top = window;
  vm.runInNewContext(documentStartScript('http://127.0.0.1:58637'), {
    window, document, URL, console,
    location: { origin: 'http://127.0.0.1:58637', href: 'http://127.0.0.1:58637/' },
    Date: class extends Date { static now() { return now; } },
    fetch: async href => {
      fetched.push(href);
      if (revoked) throw new Error('blob URL revoked');
      return { ok: true, blob: async () => blob };
    },
    FileReader: class {
      readAsDataURL(value) {
        assert.equal(value, blob);
        this.result = 'data:text/plain;base64,' + payload.toString('base64');
        this.onload();
      }
    }
  });
  window.open(url, '_blank');
  await new Promise(resolve => setImmediate(resolve));
  now = 61000;
  revoked = true;
  const overlay = body.children[0];
  const toolbar = overlay.children[0];
  toolbar.children[1].listeners.click();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(errors, []);
  assert.deepEqual(downloads, [{ name: 'preview-61000.txt', base64: payload.toString('base64') }]);
  assert.deepEqual(fetched, [url]);
  toolbar.children[2].listeners.click();
  assert.equal(body.children.length, 0);
});

test('hardlink denial fails without creating a partial destination; EEXIST is preserved', async () => {
  const errors = ['EACCES', 'EPERM', 'ENOSYS', 'EEXIST'];
  for (const code of errors) {
    const failure = Object.assign(new Error('link failed'), { code });
    const mock = { promises: { link: async () => { throw failure; } }, linkSync: () => { throw failure; } };
    const modules = {
      'node:fs': mock, 'node:module': { syncBuiltinESMExports: noop },
      'node:child_process': { spawn: noop }, 'node:worker_threads': { Worker: class {} },
      './process-worker.cjs': { ProcessWorker: class {} }
    };
    vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../runtime/ohos-preload.cjs'), 'utf8'), {
      require: id => modules[id], process: { env: {} }, __filename: '/virtual/preload.cjs'
    });
    await assert.rejects(mock.promises.link('source', 'target'), error => error === failure && error.code === code);
    assert.throws(() => mock.linkSync('source', 'target'), error => error === failure);
  }
});
