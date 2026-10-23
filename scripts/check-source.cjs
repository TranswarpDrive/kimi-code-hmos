const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
for (const file of fs.readdirSync(__dirname).filter(name => name.endsWith('.sh'))) {
  execFileSync('bash', ['-n', path.join(__dirname, file)], { stdio: 'inherit' });
}
for (const directory of ['runtime', 'scripts', 'scripts/lib']) {
  for (const file of fs.readdirSync(path.join(root, directory)).filter(name => /\.(cjs|mjs)$/.test(name))) {
    execFileSync(process.execPath, ['--check', path.join(root, directory, file)], { stdio: 'inherit' });
  }
}
for (const file of fs.readdirSync(__dirname).filter(name => name.endsWith('.py'))) {
  execFileSync('python3', ['-c', 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())', path.join(__dirname, file)], { stdio: 'inherit' });
}
const app = JSON.parse(fs.readFileSync(path.join(root, 'AppScope/app.json5'))).app;
for (const file of ['package.json', 'entry/oh-package.json5']) {
  if (JSON.parse(fs.readFileSync(path.join(root, file))).version !== app.versionName) {
    throw new Error(`Version mismatch: ${file}`);
  }
}
console.log('Shell, JavaScript, Python syntax and version checks passed.');
