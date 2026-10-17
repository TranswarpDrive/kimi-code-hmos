'use strict';
// 鸿蒙应用沙箱兼容补丁：由壳以 `node --require <本文件> <kimi>/dist/main.mjs web ...` 先于 kimi 加载。
// 只修补确认会出问题的行为，其余保持 Node 原样。

const fs = require('node:fs');
const { syncBuiltinESMExports } = require('node:module');

const fsp = fs.promises;

// 沙箱可能拒绝硬链接（EACCES/EPERM）。kimi 用 `fs.promises.link(tmp, dst)` 做“原子独占创建”
// （锁文件、minidb 元数据），只吞 EEXIST。退化实现用 open(dst, 'wx') 独占创建，保留 EEXIST 语义。
const LINK_FALLBACK_CODES = new Set(['EACCES', 'EPERM', 'ENOSYS', 'EXDEV', 'ENOTSUP', 'EOPNOTSUPP']);

const originalLink = fsp.link;
const originalLinkSync = fs.linkSync;

async function exclusiveCopy(existingPath, newPath) {
  const data = await fsp.readFile(existingPath);
  const handle = await fsp.open(newPath, 'wx');
  try {
    await handle.writeFile(data);
  } finally {
    await handle.close();
  }
}

function exclusiveCopySync(existingPath, newPath) {
  const data = fs.readFileSync(existingPath);
  const fd = fs.openSync(newPath, 'wx');
  try {
    fs.writeFileSync(fd, data);
  } finally {
    fs.closeSync(fd);
  }
}

fsp.link = async function link(existingPath, newPath) {
  try {
    return await originalLink.call(fsp, existingPath, newPath);
  } catch (err) {
    if (!err || !LINK_FALLBACK_CODES.has(err.code)) {
      throw err;
    }
    return exclusiveCopy(existingPath, newPath);
  }
};

fs.linkSync = function linkSync(existingPath, newPath) {
  try {
    return originalLinkSync.call(fs, existingPath, newPath);
  } catch (err) {
    if (!err || !LINK_FALLBACK_CODES.has(err.code)) {
      throw err;
    }
    return exclusiveCopySync(existingPath, newPath);
  }
};

fs.link = function link(existingPath, newPath, callback) {
  fsp.link(existingPath, newPath).then(() => callback(null), (err) => callback(err));
};

// 让 `import { link } from 'node:fs/promises'` 等 ESM 具名导入也指向补丁后的实现
syncBuiltinESMExports();

if (process.env.KIMI_HMOS_DEBUG === '1') {
  process.stderr.write(`[ohos-preload] node ${process.version} ${process.platform}-${process.arch} pid=${process.pid}\n`);
}
