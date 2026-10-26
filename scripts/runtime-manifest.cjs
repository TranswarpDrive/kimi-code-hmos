// 由 staging 调用，把随包运行时的版本和摘要放进 HAP，供独立发布检查使用。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { COMMANDS } = require('./runtime-commands.cjs');
const root = path.resolve(__dirname, '..');
const resource = 'resources/resfile/kimicode';
const staged = path.join(root, 'entry/src/main', resource);
const versions = {};
for (const line of fs.readFileSync(path.join(root, 'scripts/versions.env'), 'utf8').split('\n')) {
  const match = /^([A-Z_]*(?:VERSION|BUILD))=([^\s#]+)$/.exec(line);
  if (match) versions[match[1]] = match[2];
}
const files = [];
function add(file, name) {
  files.push({ path: name, sha256: crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') });
}
const libs = path.join(root, 'entry/libs/arm64-v8a');
for (const file of fs.readdirSync(libs).sort()) add(path.join(libs, file), `libs/arm64-v8a/${file}`);
const required = [
  'package/dist/main.mjs', 'package/dist/search-worker.mjs', 'package/package.json',
  'package/node_modules/ws/package.json', 'package/node_modules/qrcode/package.json', 'npm.tar.gz',
  'python/lib/python3.14/os.py', 'python/lib/python3.14/ssl.py',
  ...COMMANDS.map(name => `bin/${name}`),
  ...fs.readdirSync(path.join(staged, 'runtime')).map(file => `runtime/${file}`)
];
for (const file of required) add(path.join(staged, file), `${resource}/${file}`);
function addTree(directory, prefix) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) addTree(file, `${prefix}/${entry.name}`);
    else add(file, `${prefix}/${entry.name}`);
  }
}
addTree(path.join(staged, 'npm-extract'), `${resource}/npm-extract`);
fs.writeFileSync(path.join(staged, 'runtime-manifest.json'), JSON.stringify({ schema: 1, versions, files }, null, 2) + '\n');
console.log(`Runtime manifest: ${files.length} files`);
