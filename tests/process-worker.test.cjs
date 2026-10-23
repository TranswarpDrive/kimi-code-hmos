const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const path = require('node:path');
const { ProcessWorker } = require('../runtime/process-worker.cjs');
const entry = path.join(__dirname, 'fixtures/worker.mjs');
const message = worker => once(worker, 'message', { signal: AbortSignal.timeout(5000) }).then(([value]) => value);

test('worker can be rebuilt repeatedly with independent data and ESM imports', { timeout: 20000 }, async t => {
  // 模拟实际宿主的 HTTP 服务；unref 后不能依赖测试框架替我们保活（Node 22 会提前结束）。
  const hostHandle = setInterval(() => {}, 1000);
  t.after(() => clearInterval(hostHandle));
  for (let i = 0; i < 3; i++) {
    const worker = new ProcessWorker(entry, { execArgv: [], workerData: { id: i } });
    try {
      worker.unref();
      const ready = await message(worker);
      assert.equal(ready.type, 'ready');
      assert.equal(ready.data.id, i);
      assert.equal(ready.isMainThread, false);
      assert.notEqual(ready.pid, process.pid);
      const reply = message(worker);
      worker.postMessage(new Map([['value', 42n]]));
      assert.equal((await reply).value.get('value'), 42n);
    } finally { await worker.terminate(); }
    assert.equal(worker.threadId, -1);
  }
});

test('concurrent workers do not overwrite each others initialization', async () => {
  const workers = [1, 2, 3].map(id => new ProcessWorker(entry, { execArgv: [], workerData: id }));
  try {
    const ready = await Promise.all(workers.map(message));
    assert.deepEqual(ready.map(item => item.data), [1, 2, 3]);
    assert.equal(new Set(ready.map(item => item.pid)).size, 3);
  } finally { await Promise.all(workers.map(worker => worker.terminate())); }
});

test('messages sent immediately after construction are delivered after initialization', async () => {
  const worker = new ProcessWorker(entry, { execArgv: [], workerData: 'queued' });
  try {
    const reply = new Promise(resolve => worker.on('message', value => { if (value.type === 'reply') resolve(value); }));
    worker.postMessage('early');
    assert.equal((await Promise.race([reply, new Promise((_, reject) => setTimeout(() => reject(new Error('message timeout')), 5000).unref())])).value, 'early');
  } finally { await worker.terminate(); }
});

test('termination really stops blocked work and is idempotent', async () => {
  const worker = new ProcessWorker(entry, { execArgv: [], workerData: null });
  const ready = await message(worker);
  worker.postMessage('block');
  const exit = once(worker, 'exit', { signal: AbortSignal.timeout(5000) });
  await worker.terminate();
  await exit;
  await worker.terminate();
  assert.throws(() => process.kill(ready.pid, 0), { code: 'ESRCH' });
});

test('missing entry reports an error and exits', async () => {
  const worker = new ProcessWorker(path.join(__dirname, 'missing.mjs'), { execArgv: [] });
  const error = once(worker, 'error');
  const exit = new Promise(resolve => worker.once('exit', resolve));
  assert.match((await error)[0].message, /Cannot find module/);
  assert.equal(await exit, 1);
});
