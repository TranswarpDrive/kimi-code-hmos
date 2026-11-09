const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const load = require('./load-ets.cjs');
const noop = () => {};
const Log = { info: noop, warn: noop, error: noop };
const tick = () => new Promise(setImmediate);

function createServer(network = { http: {} }, files = new Map()) {
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
  let openedPath;
  const { KimiServer, ServerPhase } = load('kimi/KimiServer.ets', {
    '@kit.CoreFileKit': { fileIo: {
      accessSync: path => files.has(path) || path.endsWith('/server.token'),
      unlinkSync: path => { files.delete(path); },
      OpenMode: { WRITE_ONLY: 1, CREATE: 2, APPEND: 4, TRUNC: 8 },
      openSync: path => { openedPath = path; return { fd: 1 }; },
      writeSync: (fd, text) => { files.set(openedPath, text); }, closeSync: noop,
      readTextSync: path => files.has(path) ? files.get(path) : 'test-token'
    }, fileShare: {} },
    '@kit.NetworkKit': network, '@kit.ArkTS': { util: {} },
    'libkimihost.so': { default: host }, './Log': { Log, redactSecrets: text => text, SafeLogLines: class {} },
    './Diagnostics': { logRecentCrashes: noop },
    './RuntimeInfo': { KIMI_CODE_VERSION: '2.2.0', KIMI_RESFILE_DIR: 'kimicode', NODE_VERSION: '24.21.0' },
    './RuntimeUpdates': { RuntimeUpdates }
  }, { setTimeout: resolve => { timers.push(resolve); return timers.length; } });
  const server = new KimiServer();
  server.context = { filesDir: '/virtual' };
  server.pgidPath = '/virtual/kimi-shell.pgids';
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
  return { server, alive, timers, phases: ServerPhase, launches: () => launches, runtime, host };
}

test('detached shell groups are killed and cleared before spawn and after normal or forced stop; crashes are left to the native exit thread', async () => {
  const pgidPath = '/virtual/kimi-shell.pgids';
  for (const scenario of ['spawn', 'stop', 'force', 'crash']) {
    const files = new Map([[pgidPath, '301\n302\n']]);
    const h = createServer(undefined, files);
    const killed = [];
    h.host.kill = (pid, signal) => {
      killed.push([pid, signal]);
      if (signal === 9 || (scenario === 'stop' && pid === 100)) h.alive.delete(pid);
      return true;
    };
    if (scenario === 'spawn') {
      h.host.spawn = options => {
        assert.equal(files.get(pgidPath), '');
        assert.ok(options.env.includes(`KIMI_HMOS_PGID_FILE=${pgidPath}`));
        return 200;
      };
      h.server.spawnServer(58637, 0);
    } else if (scenario === 'crash') {
      h.alive.delete(100);
      h.server.onChildExit(100, 1, 0, 0);
    } else {
      if (scenario === 'force') {
        let checks = 0;
        h.host.isGroupAlive = () => ++checks > 1;
      }
      await h.server.stop();
    }
    if (scenario === 'crash') {
      // 旧服务的退出回调可能晚于新服务启动，ArkTS 不能在这里清理，否则会误杀新服务登记的进程组。
      assert.deepEqual(killed, [], scenario);
      assert.equal(files.get(pgidPath), '301\n302\n', scenario);
      continue;
    }
    assert.deepEqual(killed.filter(item => item[0] !== 100), [[301, 9], [302, 9]], scenario);
    if (scenario === 'force') assert.ok(killed.some(item => item[0] === 100 && item[1] === 9));
    assert.equal(files.get(pgidPath), '', scenario);
  }
});

test('native log drain redacts split tokens, bounded long lines and the final partial line before writing', () => {
  const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/cpp/kimihost.cpp'), 'utf8');
  const native = source.slice(source.indexOf('constexpr off_t kLogLimit'), source.indexOf('bool GroupAlive'));
  const dir = fs.mkdtempSync('/tmp/kimi-log-');
  try {
    fs.writeFileSync(path.join(dir, 'test.cpp'), `
      #include <cassert>
      #include <cerrno>
      #include <cstdio>
      #include <fcntl.h>
      #include <fstream>
      #include <iterator>
      #include <regex>
      #include <string>
      #include <sys/stat.h>
      #include <thread>
      #include <unistd.h>
      #include <utility>
      ${native}
      int main(int argc, char **argv) {
        assert(argc == 2);
        int fds[2];
        assert(pipe(fds) == 0);
        const std::string padding(16381, 'x');
        const std::string longLine(65540, 'y');
        const std::string secrets = "  Token:     abc123\\nAuthorization: Bearer xyz\\n"
          "?access_token=secret&x=1\\n\\\"api_key\\\": \\\"k\\\"\\n";
        const std::string input = secrets + padding + "#token=Abc._~-09&ok=1\\n" + longLine +
          " token=" + std::string(80000, 'A') + "!\\nfinal token=Last.secret";
        const std::string expected = "  Token:     ***\\nAuthorization: Bearer ***\\n"
          "?access_token=***\\n\\\"api_key\\\": \\\"***\\\"\\n" + padding + "#token=***\\n" + longLine +
          " token=***\\nfinal token=***";
        LogRedactionState state;
        std::string splitOutput;
        for (char c : input) {
          state = RedactLogChunk(std::move(state), std::string(1, c), false);
          splitOutput += state.output;
        }
        state = RedactLogChunk(std::move(state), "", true);
        splitOutput += state.output;
        assert(splitOutput == expected);
        std::thread writer([&]() {
          size_t offset = 0;
          while (offset < input.size()) {
            ssize_t n = write(fds[1], input.data() + offset, input.size() - offset);
            if (n < 0 && errno == EINTR) continue;
            assert(n > 0);
            offset += n;
          }
          close(fds[1]);
        });
        const int logFd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0600);
        assert(logFd >= 0);
        DrainLog(fds[0], logFd, argv[1]);
        writer.join();
        std::ifstream file(argv[1]);
        const std::string actual((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        assert(actual == expected);
        puts("native log regression passed");
      }
    `);
    execFileSync('c++', ['-std=c++17', '-pthread', path.join(dir, 'test.cpp'), '-o', path.join(dir, 'test')]);
    assert.match(execFileSync(path.join(dir, 'test'), [path.join(dir, 'server.log')], { encoding: 'utf8' }), /passed/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

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

test('exit around the first-start commit rolls back without publishing the dead runtime as ready', async () => {
  for (const timing of ['during', 'before']) {
    for (const notify of [true, false]) {
      const h = createServer();
      h.server.status.phase = h.phases.IDLE;
      h.server.status.pid = 0;
      h.server.processGroupPid = 0;
      h.alive.clear();
      h.runtime.active = { version: '2.3.2', packageRoot: '/updated', updated: true, pending: true };
      delete h.server.launch;
      h.server.pickPort = async () => 58637;
      let attempts = 0;
      let seq;
      let commits = 0;
      let release;
      const readyVersions = [];
      h.server.subscribe(status => {
        if (status.phase === h.phases.READY) readyVersions.push(h.server.currentKimiVersion());
      });
      const exit = () => {
        h.alive.delete(200);
        if (notify) h.server.onChildExit(200, 1, 0, seq);
      };
      h.server.spawnServer = (port, startSeq) => {
        seq = startSeq;
        const pid = 200 + attempts++;
        h.alive.add(pid);
        return pid;
      };
      h.server.waitReady = async () => {
        if (attempts === 1 && timing === 'before') exit();
      };
      h.server.updates.commit = async () => {
        commits++;
        await new Promise(resolve => { release = resolve; });
        h.runtime.active.pending = false;
      };
      const starting = h.server.start();
      await tick();
      if (release) {
        if (timing === 'during') exit();
        release();
      }
      await starting;
      assert.equal(h.runtime.rollbacks, 1, `${timing}, notify=${notify}`);
      assert.equal(commits, timing === 'during' ? 1 : 0);
      assert.equal(attempts, 2);
      assert.deepEqual(readyVersions, ['2.2.0']);
      assert.equal(h.server.status.pid, 201);
      assert.equal(h.server.status.phase, h.phases.READY);
      assert.match(h.server.status.warning, /2\.3\.2.*恢复/);
    }
  }
});

test('port selection skips a non-HTTP TCP listener and uses the free port for startup', async () => {
  const connected = [];
  const closed = [];
  const healthChecks = [];
  const h = createServer({
    socket: {
      constructTCPSocketInstance: () => {
        let port;
        return {
          connect: async options => {
            port = options.address.port;
            assert.equal(options.address.address, '127.0.0.1');
            connected.push(port);
            if (port !== 58637) throw new Error('ECONNREFUSED');
          },
          close: async () => { closed.push(port); }
        };
      }
    },
    http: {
      RequestMethod: { GET: 'GET' },
      createHttp: () => ({
        request: async url => {
          healthChecks.push(url);
          if (url.includes(':58637/')) throw new Error('invalid HTTP response');
          return { responseCode: 200 };
        },
        destroy: noop
      })
    }
  });
  h.server.status.phase = h.phases.IDLE;
  h.server.status.pid = 0;
  h.server.processGroupPid = 0;
  h.alive.clear();
  delete h.server.launch;
  let spawnedPort;
  h.server.spawnServer = port => {
    spawnedPort = port;
    h.alive.add(200);
    return 200;
  };
  const starting = h.server.start();
  await tick();
  assert.equal(spawnedPort, 58638);
  await starting;
  assert.deepEqual(connected, [58637, 58638]);
  assert.deepEqual(closed, connected);
  assert.deepEqual(healthChecks, ['http://127.0.0.1:58638/api/v1/healthz']);
  assert.equal(h.server.status.phase, h.phases.READY);
  assert.equal(h.server.status.port, 58638);
  assert.equal(h.server.status.url, 'http://127.0.0.1:58638/#token=test-token');
  assert.equal(h.runtime.rollbacks, 0);
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
