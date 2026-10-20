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

// worker 线程：kimi 创建搜索 worker 时显式传 `execArgv: []`，会丢掉 `--require` 预加载。
// 给显式 execArgv 补上本文件；搜索 worker 也可在主线程内联执行，避免沙箱在线程创建阶段杀掉进程。
const workerThreads = require('node:worker_threads');
const { EventEmitter } = require('node:events');
const OriginalWorker = workerThreads.Worker;

class InlineWorker extends EventEmitter {
  constructor(filename, options) {
    super();
    this.filename = filename;
    this.options = options || {};
    this.channel = null;
    this.unrefRequested = false;
    this.terminated = false;
  }

  async load() {
    if (this.terminated) {
      return;
    }
    const { port1, port2 } = new workerThreads.MessageChannel();
    this.channel = { port1, port2 };
    if (this.unrefRequested) {
      this.applyUnref();
    }
    port1.on('message', (event) => this.emit('message', event));
    port1.on('error', (error) => this.emit('error', error));
    const hadCustomData = Object.prototype.hasOwnProperty.call(globalThis, '__kimiHmosWorkerData');
    const previousCustomData = globalThis.__kimiHmosWorkerData;
    const hadParentPort = Object.prototype.hasOwnProperty.call(globalThis, '__kimiHmosParentPort');
    const previousParentPort = globalThis.__kimiHmosParentPort;
    globalThis.__kimiHmosParentPort = port2;
    globalThis.__kimiHmosWorkerData = this.options.workerData;
    try {
      const dataMarker = 'const data = workerData;';
      const portMarker = 'const port = parentPort;';
      const source = fs.readFileSync(String(this.filename).startsWith('file://') ?
        require('node:url').fileURLToPath(this.filename) : this.filename, 'utf8');
      if (!source.includes(dataMarker) || !source.includes(portMarker)) {
        throw new Error(`inline worker entry protocol markers not found: ${String(this.filename)}`);
      }
      const patched = source.replace(dataMarker, 'const data = globalThis.__kimiHmosWorkerData;')
        .replace(portMarker, 'const port = globalThis.__kimiHmosParentPort;');
      await import(`data:text/javascript;base64,${Buffer.from(patched).toString('base64')}`);
    } catch (error) {
      this.emit('error', error);
    } finally {
      if (hadCustomData) {
        globalThis.__kimiHmosWorkerData = previousCustomData;
      } else {
        delete globalThis.__kimiHmosWorkerData;
      }
      if (hadParentPort) {
        globalThis.__kimiHmosParentPort = previousParentPort;
      } else {
        delete globalThis.__kimiHmosParentPort;
      }
    }
  }

  postMessage(value) {
    if (this.channel === null) {
      throw new Error('inline worker channel is closed');
    }
    this.channel.port1.postMessage(value);
  }

  applyUnref() {
    if (this.channel === null) {
      return;
    }
    this.channel.port1.unref();
    this.channel.port2.unref();
  }

  unref() {
    this.unrefRequested = true;
    this.applyUnref();
    return this;
  }

  terminate() {
    this.terminated = true;
    if (this.channel !== null) {
      this.channel.port1.close();
      this.channel.port2.close();
    }
    setImmediate(() => this.emit('exit', 0));
    return Promise.resolve(0);
  }
}

let inlineLoadQueue = Promise.resolve();
function createInlineWorker(filename, options) {
  const worker = new InlineWorker(filename, options);
  worker.ready = inlineLoadQueue.then(() => worker.load(), () => worker.load());
  return worker;
}

workerThreads.Worker = class OhosWorker extends OriginalWorker {
  constructor(filename, options) {
    const isSearchWorker = String(filename).endsWith('search-worker.mjs');
    const mode = process.env.KIMI_HMOS_SEARCH_WORKER_MODE ||
      (process.env.KIMI_HMOS_NO_SEARCH_WORKER === '1' ? 'disabled' : 'inline');
    if (process.env.KIMI_HMOS_DEBUG === '1') {
      fs.writeSync(2, `[trace] new Worker ${String(filename).slice(0, 200)} (${isSearchWorker ? mode : 'thread'})\n`);
    }
    if (isSearchWorker && mode === 'disabled') {
      throw new Error('search worker disabled by KIMI_HMOS_SEARCH_WORKER_MODE');
    }
    if (isSearchWorker && mode === 'inline') {
      return createInlineWorker(filename, options);
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
