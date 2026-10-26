'use strict';
// 生成随包安装到只读 resfile/bin 的启动脚本；鸿蒙不允许运行可写沙箱中的脚本或创建软链接。
const fs = require('node:fs');
const path = require('node:path');

const COMMANDS = Object.freeze([
  'node', 'python3', 'rg', 'git', 'git-upload-pack', 'git-receive-pack',
  'git-upload-archive', 'git-shell', 'git-remote-https'
]);

function writeRuntimeCommands(directory, shell = '/system/bin/sh') {
  if (!path.isAbsolute(shell) || /[\r\n]/.test(shell)) throw new Error('Invalid runtime shell');
  fs.mkdirSync(directory, { recursive: true });
  for (const name of COMMANDS) {
    // exec -a 保持 Git multicall/helper 的原始命令名；双引号原样保留空参数、空格和引号。
    const content = `#!${shell}\n# Kimi Code bundled command\nexec -a ${name} "\${KIMI_HMOS_NATIVE_DIR:?Missing bundled runtime path}/${name}.bin" "$@"\n`;
    const file = path.join(directory, name);
    fs.writeFileSync(file, content, { mode: 0o755 });
    fs.chmodSync(file, 0o755);
  }
}

if (require.main === module) {
  if (!process.argv[2]) throw new Error('Usage: node scripts/runtime-commands.cjs <output-directory>');
  writeRuntimeCommands(process.argv[2]);
}

module.exports = { COMMANDS, writeRuntimeCommands };
