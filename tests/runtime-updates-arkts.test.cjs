const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./load-ets.cjs');
const noop = () => {};
const integrity = 'sha512-' + Buffer.alloc(64, 4).toString('base64');

function createUpdates() {
  const files = new Map();
  const directories = new Set();
  const processes = [];
  const terminated = [];
  const io = {
    accessSync: path => files.has(path) || directories.has(path),
    mkdirSync: path => directories.add(path),
    unlinkSync: path => files.delete(path),
    readTextSync: path => {
      if (!files.has(path)) throw new Error('missing file');
      return files.get(path);
    }
  };
  const host = {
    nativeLibDir: () => '/native',
    spawn: options => {
      const pid = 600 + processes.length;
      processes.push({ pid, options });
      return pid;
    },
    terminate: pid => terminated.push(pid)
  };
  const modules = {
    '@kit.AbilityKit': {},
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkTS': { util: {} },
    'libkimihost.so': { default: host },
    './Log': { Log: { info: noop, warn: noop, error: noop }, redactSecrets: text => text },
    './RuntimeInfo': { KIMI_CODE_VERSION: '2.2.0', KIMI_RESFILE_DIR: 'kimicode' }
  };
  const { RuntimeUpdates, UpdatePhase } = load('kimi/RuntimeUpdates.ets', modules);
  const updates = new RuntimeUpdates();
  updates.init({ filesDir: '/files', resourceDir: '/resources' });
  return { updates, UpdatePhase, files, processes, terminated };
}

function seedActive(files, version, pending = false) {
  const root = '/files/runtime-updates';
  files.set(`${root}/state.json`, JSON.stringify({
    schema: 1, activeVersion: version, previousVersion: '', pending
  }));
  files.set(`${root}/versions/${version}/.hmos-ready.json`, JSON.stringify({
    schema: 1, version, integrity
  }));
}

test('active runtime requires a safe version and a valid ready marker', () => {
  const h = createUpdates();
  assert.equal(h.updates.activeRuntime().version, '2.2.0');
  seedActive(h.files, '2.3.2', true);
  const active = h.updates.activeRuntime();
  assert.equal(active.version, '2.3.2');
  assert.equal(active.packageRoot, '/files/runtime-updates/versions/2.3.2/node_modules/@moonshot-ai/kimi-code');
  assert.equal(active.pending, true);

  h.files.set('/files/runtime-updates/versions/2.3.2/.hmos-ready.json', '{"schema":1}');
  assert.equal(h.updates.activeRuntime().version, '2.2.0');
  h.files.set('/files/runtime-updates/state.json', JSON.stringify({
    schema: 1, activeVersion: '../../project', previousVersion: '', pending: true
  }));
  assert.equal(h.updates.activeRuntime().updated, false);
});

test('check operations are serialized and consume structured official results', async () => {
  const h = createUpdates();
  const checking = h.updates.check();
  assert.equal(h.updates.getStatus().phase, h.UpdatePhase.CHECKING);
  await assert.rejects(h.updates.check(), /另一个更新操作/);
  assert.equal(h.processes.length, 1);
  const process = h.processes[0];
  assert.equal(process.options.cwd, '/files/runtime-updates');
  assert.ok(process.options.env.includes('HOME=/files/runtime-updates/npm-home'));
  assert.ok(process.options.args.includes('/files/runtime-updates/npm/bin/npm-cli.js'));
  assert.ok(process.options.args.includes('/resources/kimicode/npm.tar.gz'));
  assert.ok(process.options.args.includes('/resources/kimicode/npm-extract/node_modules/tar'));
  h.files.set('/files/runtime-updates/check.json', JSON.stringify({
    schema: 1, version: '2.3.2', updateAvailable: true
  }));
  h.files.set('/files/runtime-updates/result.json', JSON.stringify({
    schema: 1,
    command: 'check',
    ok: true,
    message: '发现官方新版本 2.3.2',
    latestVersion: '2.3.2',
    candidateVersion: '',
    updateAvailable: true
  }));
  process.options.onExit(process.pid, 0, 0);
  await checking;
  assert.equal(h.updates.getStatus().latestVersion, '2.3.2');
  assert.equal(h.updates.getStatus().updateAvailable, true);
  assert.equal(h.updates.getStatus().phase, h.UpdatePhase.IDLE);
});

test('failed helper operations preserve the active runtime and expose the error', async () => {
  const h = createUpdates();
  seedActive(h.files, '2.3.1');
  const checking = h.updates.check();
  const process = h.processes[0];
  h.files.set('/files/runtime-updates/result.json', JSON.stringify({
    schema: 1, command: 'check', ok: false, message: 'official registry unavailable'
  }));
  process.options.onExit(process.pid, 1, 0);
  await assert.rejects(checking, /official registry unavailable/);
  assert.equal(h.updates.getStatus().currentVersion, '2.3.1');
  assert.equal(h.updates.getStatus().activeVersion, '2.3.1');
  assert.equal(h.updates.getStatus().error, 'official registry unavailable');
});

test('closing the ability cancels the updater process group without activating downloads', async () => {
  const h = createUpdates();
  const installing = h.updates.install('2.3.2');
  const process = h.processes[0];
  h.updates.stopNow();
  await assert.rejects(installing, /更新已取消/);
  assert.deepEqual(h.terminated, [process.pid]);
  assert.equal(h.updates.activeRuntime().version, '2.2.0');
  process.options.onExit(process.pid, 1, 15);
  assert.equal(h.updates.activeRuntime().updated, false);
});
