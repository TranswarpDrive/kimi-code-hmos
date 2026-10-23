const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./load-ets.cjs');
const noop = () => {};
const Log = { info: noop, warn: noop, error: noop };
const tick = () => new Promise(setImmediate);

function createServer() {
  const alive = new Set([100]);
  const timers = [];
  const host = {
    kill: (pid, signal) => { if (signal === 9) alive.delete(pid); return true; },
    terminate: pid => alive.delete(pid),
    isAlive: pid => alive.has(pid), isGroupAlive: pid => alive.has(pid)
  };
  const { KimiServer, ServerPhase } = load('kimi/KimiServer.ets', {
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, unlinkSync: noop }, fileShare: {} },
    '@kit.NetworkKit': { http: {} }, '@kit.ArkTS': { util: {} },
    'libkimihost.so': { default: host }, './Log': { Log, redactSecrets: text => text, SafeLogLines: class {} },
    './Diagnostics': { logRecentCrashes: noop }, './RuntimeInfo': {}
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
  return { server, alive, timers, phases: ServerPhase, launches: () => launches };
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
