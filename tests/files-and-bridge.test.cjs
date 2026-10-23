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
    '@kit.ArkWeb': { webview: {} }, './Log': { Log }
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

test('hardlink denial fails without creating a partial destination; EEXIST is preserved', async () => {
  const errors = ['EACCES', 'EPERM', 'ENOSYS', 'EEXIST'];
  for (const code of errors) {
    const failure = Object.assign(new Error('link failed'), { code });
    const mock = { promises: { link: async () => { throw failure; } }, linkSync: () => { throw failure; } };
    const modules = {
      'node:fs': mock, 'node:module': { syncBuiltinESMExports: noop },
      'node:worker_threads': { Worker: class {} }, './process-worker.cjs': { ProcessWorker: class {} }
    };
    vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../runtime/ohos-preload.cjs'), 'utf8'), {
      require: id => modules[id], process: { env: {} }, __filename: '/virtual/preload.cjs'
    });
    await assert.rejects(mock.promises.link('source', 'target'), error => error === failure && error.code === code);
    assert.throws(() => mock.linkSync('source', 'target'), error => error === failure);
  }
});
