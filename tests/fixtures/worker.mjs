import { workerData, parentPort, isMainThread } from 'node:worker_threads';
parentPort.postMessage({ type: 'ready', data: workerData, isMainThread, pid: process.pid });
parentPort.on('message', value => {
  if (value === 'crash') throw new Error('intentional worker test failure');
  if (value === 'block') { while (true) {} }
  if (value === 'close') { parentPort.close(); return; }
  parentPort.postMessage({ type: 'reply', value, data: workerData });
});
