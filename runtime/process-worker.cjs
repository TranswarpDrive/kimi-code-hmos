'use strict';

// 只用于已知的 Kimi 搜索入口：进程隔离保留退出/重建语义，不创建受沙箱限制的 Worker 线程。
const { fork } = require('node:child_process');
const { EventEmitter } = require('node:events');
const { fileURLToPath } = require('node:url');
const path = require('node:path');

class ProcessWorker extends EventEmitter {
  constructor(filename, options = {}) {
    super();
    const entry = filename instanceof URL ? fileURLToPath(filename) : String(filename);
    if (!path.isAbsolute(entry)) throw new TypeError('search worker entry must be absolute');
    const execArgv = [...(options.execArgv || process.execArgv)];
    const preload = path.join(__dirname, 'ohos-preload.cjs');
    if (!execArgv.includes(preload)) execArgv.push('--require', preload);
    if (process.execArgv.includes('--jitless') && !execArgv.includes('--jitless')) execArgv.push('--jitless');
    const maxHeap = options.resourceLimits?.maxOldGenerationSizeMb;
    if (Number.isFinite(maxHeap) && maxHeap > 0) execArgv.push(`--max-old-space-size=${Math.ceil(maxHeap)}`);
    this.exited = false;
    this.child = fork(path.join(__dirname, 'worker-child.cjs'), [entry], {
      execArgv,
      env: options.env || process.env,
      serialization: 'advanced',
      stdio: ['ignore', 'inherit', 'inherit', 'ipc']
    });
    this.threadId = this.child.pid;
    this.exitPromise = new Promise(resolve => { this.resolveExit = resolve; });
    this.child.on('message', packet => {
      if (!packet || this.exited) return;
      if (packet.kind === 'message') this.emit('message', packet.value);
      if (packet.kind === 'online') this.emit('online');
      if (packet.kind === 'error') {
        const error = new Error(packet.message);
        if (packet.stack) error.stack = packet.stack;
        this.emit('error', error);
      }
    });
    this.child.on('error', error => this.emit('error', error));
    this.child.once('exit', (code, signal) => {
      this.exited = true;
      this.threadId = -1;
      const result = code ?? (signal ? 1 : 0);
      this.resolveExit(result);
      this.emit('exit', result);
    });
    this.send({ kind: 'init', value: options.workerData });
  }

  send(packet) {
    if (this.exited || !this.child.connected) throw new Error('search worker channel is closed');
    this.child.send(packet, error => {
      if (error && !this.exited && !this.terminating) this.emit('error', error);
    });
  }

  postMessage(value, transferList) {
    if (transferList?.length) throw new TypeError('search process worker does not support transferable handles');
    this.send({ kind: 'message', value });
  }

  unref() {
    this.child.unref();
    this.child.channel?.unref();
    return this;
  }

  ref() {
    this.child.ref();
    this.child.channel?.ref();
    return this;
  }

  terminate() {
    if (!this.exited && !this.terminating) {
      this.terminating = true;
      this.child.kill('SIGKILL');
    }
    return this.exitPromise;
  }
}

module.exports = { ProcessWorker };
