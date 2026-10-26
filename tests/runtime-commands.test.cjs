const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { COMMANDS, writeRuntimeCommands } = require('../scripts/runtime-commands.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kimi-runtime-commands-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const nativeDir = path.join(root, "native with 'quotes");
  const commandDir = path.join(root, 'commands');
  fs.mkdirSync(nativeDir);
  for (const name of COMMANDS) fs.symlinkSync(process.execPath, path.join(nativeDir, `${name}.bin`));
  writeRuntimeCommands(commandDir, '/bin/bash');
  return { nativeDir, commandDir, env: { PATH: commandDir, KIMI_HMOS_NATIVE_DIR: nativeDir } };
}

test('packaged launchers preserve standard command and Git helper names', t => {
  const { commandDir, env } = fixture(t);
  for (const name of COMMANDS) {
    assert.ok(fs.statSync(path.join(commandDir, name)).mode & 0o111);
    const result = spawnSync(name, ['-p', 'process.argv0'], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, `${name}: ${result.error || result.stderr}`);
    assert.equal(result.stdout.trim(), name);
  }
});

test('launchers preserve empty, quoted, spaced and shell-like arguments', t => {
  const { env } = fixture(t);
  const args = ['', 'two words', "a'b", '$(printf not-a-command)'];
  const result = spawnSync('node', ['-e', 'process.stdout.write(JSON.stringify(process.argv.slice(1)))', ...args], {
    env, encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), args);
});

test('missing native runtime fails explicitly instead of running a host command', t => {
  const { nativeDir, commandDir, env } = fixture(t);
  const noEnv = spawnSync('node', [], { env: { PATH: commandDir }, encoding: 'utf8' });
  assert.notEqual(noEnv.status, 0);
  assert.match(noEnv.stderr, /Missing bundled runtime path/);
  fs.unlinkSync(path.join(nativeDir, 'node.bin'));
  const noFile = spawnSync('node', [], { env, encoding: 'utf8' });
  assert.notEqual(noFile.status, 0);
});

test('packaged executable declarations match all generated command launchers', () => {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/module.json5'), 'utf8');
  const declared = [...source.matchAll(/"path":\s*"libs\/arm64-v8a\/([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(declared.sort(), COMMANDS.map(name => `${name}.bin`).sort());
});
