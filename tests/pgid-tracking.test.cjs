const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

test('preload records detached groups and removes a group only after it is empty', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kimi-pgid-'));
  const file = path.join(dir, 'groups');
  fs.writeFileSync(file, '999\n');
  try {
    execFileSync(process.execPath, ['--require', path.resolve(__dirname, '../runtime/ohos-preload.cjs'), '-e', `
      const assert = require('node:assert/strict');
      const fs = require('node:fs');
      const { once } = require('node:events');
      const { spawn } = require('node:child_process');
      const children = [];
      const file = process.env.KIMI_HMOS_PGID_FILE;
      const read = () => fs.readFileSync(file, 'utf8').trim().split('\\n');
      (async () => {
        try {
          for (const detached of [true, true, false]) {
            const child = spawn(process.execPath, ['-e', 'process.on("message", () => process.exit(0))'], {
              detached, stdio: ['ignore', 'ignore', 'ignore', 'ipc']
            });
            children.push(child);
            await once(child, 'spawn');
          }
          assert.deepEqual(read(), ['999', String(children[0].pid), String(children[1].pid)]);
          const failed = spawn('/kimi-missing-executable', { detached: true });
          await once(failed, 'error');
          assert.equal(read().length, 3);
          for (let i = 0; i < children.length; i++) {
            const child = children[i];
            const exit = once(child, 'exit');
            child.send('exit');
            await exit;
            assert.deepEqual(read(), i === 0 ? ['999', String(children[1].pid)] : ['999']);
          }
          assert.deepEqual(read(), ['999']);
          // 组长退出但 \`&\` 留下的后台任务仍在组内：保留登记，留给壳结束进程组。
          const background = spawn('/bin/sh', ['-c', 'sleep 30 &'], { detached: true, stdio: 'ignore' });
          await once(background, 'exit');
          assert.deepEqual(read(), ['999', String(background.pid)]);
          process.kill(-background.pid, 'SIGKILL');
        } finally {
          for (const child of children) child.kill('SIGKILL');
        }
      })().catch(error => { console.error(error); process.exitCode = 1; });
    `], { env: { ...process.env, KIMI_HMOS_PGID_FILE: file, KIMI_HMOS_DEBUG: '0' }, timeout: 10000, stdio: 'pipe' });
    // 被外部强杀的后台组不会再触发登记撤销，留给壳下次清理。
    assert.match(fs.readFileSync(file, 'utf8'), /^999\n\d+\n$/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
