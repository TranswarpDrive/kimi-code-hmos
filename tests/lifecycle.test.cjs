const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./load-ets.cjs');
const noop = () => {};
const Log = { info: noop, warn: noop, error: noop };
const tick = () => new Promise(setImmediate);

function createServer() {
  const alive = new Set([100]);
  const timers = [];
  const runtime = {
    active: { version: '2.2.0', packageRoot: '/bundled', updated: false, pending: false },
    rollbacks: 0
  };
  class RuntimeUpdates {
    activeRuntime() { return { ...runtime.active }; }
    async rollback() {
      runtime.rollbacks++;
      runtime.active = { version: '2.2.0', packageRoot: '/bundled', updated: false, pending: false };
    }
    async commit() { runtime.active.pending = false; }
    stopNow() {}
    init() {}
  }
  const host = {
    kill: (pid, signal) => { if (signal === 9) alive.delete(pid); return true; },
    terminate: pid => alive.delete(pid),
    isAlive: pid => alive.has(pid), isGroupAlive: pid => alive.has(pid)
  };
  const { KimiServer, ServerPhase } = load('kimi/KimiServer.ets', {
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, unlinkSync: noop }, fileShare: {} },
    '@kit.NetworkKit': { http: {} }, '@kit.ArkTS': { util: {} },
    'libkimihost.so': { default: host }, './Log': { Log, redactSecrets: text => text, SafeLogLines: class {} },
    './Diagnostics': { logRecentCrashes: noop },
    './RuntimeInfo': { KIMI_CODE_VERSION: '2.2.0', KIMI_RESFILE_DIR: 'kimicode', NODE_VERSION: '24.21.0' },
    './RuntimeUpdates': { RuntimeUpdates }
  }, { setTimeout: resolve => { timers.push(resolve); return timers.length; } });
  const server = new KimiServer();
  server.context = { filesDir: '/virtual' };
  server.status.phase = ServerPhase.READY;
  server.status.pid = 100;
  server.processGroupPid = 100;
  server.rotateLog = noop;
  server.assertRuntimeInstalled = noop;
  let launches = 0;
  server.launch = async function () {
    this.status.pid = 200 + launches++;
    this.processGroupPid = this.status.pid;
    alive.add(this.status.pid);
    this.update(ServerPhase.READY, 'mock process started');
  };
  return { server, alive, timers, phases: ServerPhase, launches: () => launches, runtime };
}

test('overlapping restarts are serialized and superseded requests do not spawn', async () => {
  const h = createServer();
  const first = h.server.restart();
  await tick();
  const second = h.server.restart();
  h.alive.delete(100);
  h.timers.shift()();
  await Promise.all([first, second]);
  assert.equal(h.launches(), 1);
  assert.deepEqual([...h.alive], [200]);
  assert.equal(h.server.status.pid, 200);
});

test('destroy during restart cancels queued launches and clears status', async () => {
  const h = createServer();
  const first = h.server.restart();
  await tick();
  const second = h.server.restart();
  h.server.stopNow();
  h.timers.shift()();
  await Promise.all([first, second]);
  assert.equal(h.launches(), 0);
  assert.equal(h.alive.size, 0);
  assert.equal(h.server.status.phase, h.phases.IDLE);
});

test('stop after the group leader exits still waits for descendants', async () => {
  const h = createServer();
  h.server.status.pid = 0;
  const stopping = h.server.stop();
  await tick();
  assert.equal(h.timers.length, 1);
  h.alive.delete(100);
  h.timers.shift()();
  await stopping;
  assert.equal(h.server.processGroupPid, 0);
});

test('a newly activated runtime rolls back once when its first launch fails', async () => {
  const h = createServer();
  h.server.status.phase = h.phases.IDLE;
  h.server.status.pid = 0;
  h.server.processGroupPid = 0;
  h.alive.clear();
  h.runtime.active = { version: '2.3.2', packageRoot: '/updated', updated: true, pending: true };
  let attempts = 0;
  h.server.launch = async function () {
    attempts++;
    if (attempts === 1) throw new Error('new WebUI failed');
    this.update(h.phases.READY, 'bundled runtime ready');
  };
  await h.server.start();
  assert.equal(attempts, 2);
  assert.equal(h.runtime.rollbacks, 1);
  assert.equal(h.server.currentKimiVersion(), '2.2.0');
  assert.equal(h.server.status.phase, h.phases.READY);
  assert.match(h.server.status.warning, /2\.3\.2.*恢复/);
});

test('a stable updated runtime is not rolled back by an unrelated later failure', async () => {
  const h = createServer();
  h.server.status.phase = h.phases.IDLE;
  h.server.status.pid = 0;
  h.server.processGroupPid = 0;
  h.runtime.active = { version: '2.3.2', packageRoot: '/updated', updated: true, pending: false };
  h.server.launch = async () => { throw new Error('port unavailable'); };
  await h.server.start();
  assert.equal(h.runtime.rollbacks, 0);
  assert.equal(h.runtime.active.version, '2.3.2');
  assert.equal(h.server.status.phase, h.phases.FAILED);
});

test('stop while background startup is pending prevents a late background task', async () => {
  let release;
  let starts = 0;
  let stops = 0;
  const { BackgroundKeeper } = load('kimi/BackgroundKeeper.ets', {
    '@kit.AbilityKit': { wantAgent: {
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: () => new Promise(resolve => { release = resolve; })
    } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      BackgroundMode: { TASK_KEEPING: 1 },
      startBackgroundRunning: async () => { starts++; }, stopBackgroundRunning: async () => { stops++; }
    } }, './Log': { Log }
  });
  const keeper = new BackgroundKeeper();
  const context = { abilityInfo: { bundleName: 'test', name: 'test' } };
  const starting = keeper.start(context);
  await tick();
  const stopping = keeper.stop(context);
  release({});
  await Promise.all([starting, stopping]);
  assert.equal(starts, 0);
  assert.equal(stops, 0);
  assert.equal(keeper.running, false);
});
