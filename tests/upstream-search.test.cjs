const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
require('../runtime/ohos-preload.cjs');
const { Worker } = require('node:worker_threads');
const entry = path.resolve(__dirname, '../vendor/kimi-code/package/dist/search-worker.mjs');
const available = fs.existsSync(entry);
if (!available && process.env.KIMI_REQUIRE_UPSTREAM === '1') throw new Error('Fetch the pinned runtime before the upstream acceptance test');

test('pinned upstream search: index content, query, close, and reopen the same database', { skip: !available, timeout: 30000 }, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kimi-hmos-search-'));
  try {
    const session = path.join(directory, 'session');
    fs.mkdirSync(session);
    fs.writeFileSync(path.join(session, 'state.json'), JSON.stringify({ title: 'Acceptance session' }));
    fs.writeFileSync(path.join(session, 'wire.jsonl'), JSON.stringify({
      type: 'context.append_message', time: Date.now() / 1000,
      message: { role: 'user', content: [{ type: 'text', text: 'The cobalt lighthouse is a unique search fixture.' }] }
    }) + '\n');
    for (let pass = 0; pass < 3; pass++) {
      const worker = new Worker(entry, { execArgv: [], workerData: { dir: path.join(directory, 'index'), bootSalt: `acceptance-${pass}` } });
      try {
        worker.unref();
        const [ready] = await once(worker, 'message', { signal: AbortSignal.timeout(5000) });
        assert.equal(ready.type, 'ready');
        const request = (id, type, params) => new Promise((resolve, reject) => {
          const timer = setTimeout(() => { worker.off('message', listener); reject(new Error(`${type} timeout`)); }, 5000);
          function listener(event) {
            if (event.id !== id) return;
            clearTimeout(timer);
            worker.off('message', listener);
            if (event.type === 'error') reject(new Error(event.error.message));
            else resolve(event.result);
          }
          worker.on('message', listener);
          worker.postMessage({ v: 1, id, type, params });
        });
        const opened = await request(1, 'open');
        assert.equal(opened.readOnly, false);
        const synced = await request(2, 'sync', { sessions: [{
          id: 'acceptance', dir: session, workspaceId: 'test', title: 'Acceptance session', updatedAt: Date.now()
        }] });
        assert.equal(synced.failures, 0);
        let result;
        for (let attempt = 0; attempt < 30; attempt++) {
          result = await request(10 + attempt, 'search', {
            q: { query: 'cobalt', mode: 'text', op: 'AND', sort: 'score', pageSize: 10 },
            budgets: { maxTextHits: 100, literalCandidateCap: 100, postingsVisitBudget: 10000,
              queryDeadlineMs: 2000, queryTextBudgetChars: 100000 }
          });
          if (result.kind === 'page' && result.rows.length) break;
          await new Promise(resolve => setTimeout(resolve, 50));
        }
        assert.equal(result.kind, 'page');
        assert.equal(result.rows.length, 1);
        assert.match(result.rows[0].value.text, /cobalt lighthouse/);
        const closed = new Promise(resolve => worker.once('exit', resolve));
        await request(100, 'close');
        assert.equal(await closed, 0);
      } finally { await worker.terminate(); }
    }
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
