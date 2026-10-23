'use strict';

// 将搜索入口的 workerData/parentPort 映射到 Node IPC；直接导入原文件，无源码字符串替换。
const { EventEmitter } = require('node:events');
const { pathToFileURL } = require('node:url');
const { syncBuiltinESMExports } = require('node:module');
const workerThreads = require('node:worker_threads');
let closing = false;
let initialized = false;
const pending = [];
const port = new EventEmitter();

function send(packet) {
  if (!process.connected) return;
  process.send(packet, error => {
    if (error) process.exit(1);
  });
}
port.postMessage = value => send({ kind: 'message', value });
port.close = () => {
  closing = true;
  if (process.connected) process.disconnect();
};
port.ref = () => { process.channel?.ref(); return port; };
port.unref = () => { process.channel?.unref(); return port; };
port.start = () => {};

// 父服务即使被强杀，搜索进程也不能作为孤儿继续持有数据库锁。
process.on('disconnect', () => process.exit(closing ? 0 : 1));
process.on('message', async packet => {
  if (!packet || closing) return;
  if (packet.kind === 'message') {
    if (initialized) port.emit('message', packet.value);
    else pending.push(packet.value);
    return;
  }
  if (packet.kind !== 'init' || initialized) return;
  workerThreads.workerData = packet.value;
  workerThreads.parentPort = port;
  workerThreads.isMainThread = false;
  workerThreads.threadId = process.pid;
  syncBuiltinESMExports();
  try {
    await import(pathToFileURL(process.argv[2]).href);
    initialized = true;
    send({ kind: 'online' });
    for (const value of pending.splice(0)) port.emit('message', value);
  } catch (error) {
    if (process.connected) process.send({ kind: 'error', message: error.message, stack: error.stack }, () => process.exit(1));
    else process.exit(1);
  }
});
