'use strict';
// 鸿蒙应用沙箱兼容补丁：由壳以 `node --require <本文件> <kimi>/dist/main.mjs web ...` 先于 kimi 加载。
// 只修补确认会出问题的行为，其余保持 Node 原样。

const fs = require('node:fs');
const { syncBuiltinESMExports } = require('node:module');

const fsp = fs.promises;

// Kimi 用硬链接原子发布锁/元数据。不能用“创建空文件再复制”冒充原子发布：
// 其他进程会读到半写入数据。平台不支持时明确失败，让上游保留原始文件与错误。
const LINK_UNSUPPORTED_CODES = new Set(['EACCES', 'EPERM', 'ENOSYS', 'EXDEV', 'ENOTSUP', 'EOPNOTSUPP']);

const originalLink = fsp.link;
const originalLinkSync = fs.linkSync;

function annotateLinkError(error) {
  if (error && LINK_UNSUPPORTED_CODES.has(error.code)) {
    error.message += ' [kimi-hmos: atomic hard-link publication is unavailable; no partial destination was created]';
  }
  return error;
}

fsp.link = async function link(existingPath, newPath) {
  try {
    return await originalLink.call(fsp, existingPath, newPath);
  } catch (err) {
    throw annotateLinkError(err);
  }
};

fs.linkSync = function linkSync(existingPath, newPath) {
  try {
    return originalLinkSync.call(fs, existingPath, newPath);
  } catch (err) {
    throw annotateLinkError(err);
  }
};

fs.link = function link(existingPath, newPath, callback) {
  fsp.link(existingPath, newPath).then(() => callback(null), (err) => callback(err));
};

// worker 线程：kimi 创建搜索 worker 时显式传 `execArgv: []`，会丢掉 `--require` 预加载。
// 给显式 execArgv 补上本文件；搜索使用独立子进程，避免沙箱在线程创建阶段杀掉主服务。
const workerThreads = require('node:worker_threads');
const OriginalWorker = workerThreads.Worker;
const { ProcessWorker } = require('./process-worker.cjs');

workerThreads.Worker = class OhosWorker extends OriginalWorker {
  constructor(filename, options) {
    const isSearchWorker = String(filename).endsWith('search-worker.mjs');
    const mode = process.env.KIMI_HMOS_SEARCH_WORKER_MODE || 'process';
    if (process.env.KIMI_HMOS_DEBUG === '1') {
      fs.writeSync(2, `[trace] new Worker ${String(filename).slice(0, 200)} (${isSearchWorker ? mode : 'thread'})\n`);
    }
    if (isSearchWorker && mode === 'disabled') {
      throw new Error('search worker disabled by KIMI_HMOS_SEARCH_WORKER_MODE');
    }
    if (isSearchWorker && mode !== 'thread') {
      return new ProcessWorker(filename, options);
    }
    if (options && Array.isArray(options.execArgv) && !options.execArgv.includes(__filename)) {
      options = { ...options, execArgv: ['--require', __filename, ...options.execArgv] };
    }
    super(filename, options);
  }
};

// 让 `import { link } from 'node:fs/promises'`、`import { Worker } from 'node:worker_threads'` 等 ESM 具名导入也指向补丁后的实现
syncBuiltinESMExports();

if (process.env.KIMI_HMOS_DEBUG === '1') {
  const writeSync = fs.writeSync;
  const trace = (what, detail) => {
    try {
      writeSync(2, `[trace${workerThreads.isMainThread ? '' : ' worker'}] ${what} ${String(detail).slice(0, 160)}\n`);
    } catch {
      // stderr 不可写时忽略
    }
  };
  if (workerThreads.isMainThread) {
    trace('node', `${process.version} ${process.platform}-${process.arch} pid=${process.pid}`);
    // 确认 LD_PRELOAD / LD_LIBRARY_PATH 是否生效
    try {
      const libs = new Set();
      for (const line of fs.readFileSync('/proc/self/maps', 'utf8').split('\n')) {
        const mapped = line.split(/\s+/)[5];
        if (mapped && /lib(c\+\+_shared|kimicompat)\.so$/.test(mapped)) {
          libs.add(mapped);
        }
      }
      trace('mapped', [...libs].join(', ') || '(none)');
    } catch (err) {
      trace('read /proc/self/maps failed', err && err.message);
    }
  }
  // 记录可能触发沙箱限制的调用：主线程只记子进程与文件监听，worker 线程记录全部 fs/os/crypto/网络调用，
  // 进程被 seccomp 杀掉前的最后一条即可定位原因
  const describe = (args) => (typeof args[0] === 'string' || args[0] instanceof URL ? String(args[0]) : '');
  const traceAll = (label, mod, only) => {
    for (const key of Object.keys(mod)) {
      const desc = Object.getOwnPropertyDescriptor(mod, key);
      const original = desc && desc.value;
      if (typeof original !== 'function' || !desc.writable || /^[A-Z]/.test(key) || (only && !only.includes(key))) {
        continue;
      }
      mod[key] = function traced(...args) {
        trace(`${label}.${key}`, describe(args));
        return original.apply(this, args);
      };
    }
  };
  const childProcess = require('node:child_process');
  traceAll('child_process', childProcess);
  traceAll('fs', fs);
  traceAll('fs.promises', fsp);
  for (const name of ['os', 'crypto', 'net', 'dns']) {
    traceAll(name, require(`node:${name}`));
  }
  syncBuiltinESMExports();
}
