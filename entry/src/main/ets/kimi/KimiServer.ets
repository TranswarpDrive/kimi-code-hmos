import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { process, util } from '@kit.ArkTS';
import kimihost from 'libkimihost.so';
import { logRecentCrashes } from './Diagnostics';
import { Log } from './Log';
import { KIMI_CODE_VERSION, KIMI_RESFILE_DIR, NODE_VERSION } from './RuntimeInfo';

export enum ServerPhase {
  IDLE = 'idle',
  STARTING = 'starting',
  READY = 'ready',
  STOPPING = 'stopping',
  FAILED = 'failed'
}

export class ServerStatus {
  phase: ServerPhase = ServerPhase.IDLE;
  /** 就绪后 Web UI 的完整地址（含 #token=） */
  url: string = '';
  port: number = 0;
  pid: number = 0;
  message: string = '';
  /** 降级运行时给用户的提示（如 jitless 模式），为空表示正常 */
  warning: string = '';
}

export type StatusListener = (status: ServerStatus) => void;

class ExitInfo {
  code: number = 0;
  signal: number = 0;
}

// SIGILL、SIGTRAP、SIGABRT、SIGBUS、SIGSEGV：V8 申请可执行内存失败时的典型死法
const JIT_CRASH_SIGNALS: number[] = [4, 5, 6, 7, 11];
const JITLESS_WARNING: string = '未获得 JIT 权限，Kimi Code 以 jitless 模式运行，联网功能可能不可用。' +
  '请确认签名 Profile 含 ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY 后重新安装。';
const LOG_FORWARD_INTERVAL_MS: number = 1000;
const LOG_FORWARD_MAX_BYTES: number = 64 * 1024;
const LOG_FORWARD_MAX_LINE: number = 900;

const PREFERRED_PORT: number = 58637; // 避开终端里 `kimi web` 的默认端口 58627
const PORT_ATTEMPTS: number = 20;
const READY_TIMEOUT_MS: number = 90000;
const READY_POLL_MS: number = 400;
const STOP_GRACE_MS: number = 4000;
const LOG_ROTATE_BYTES: number = 4 * 1024 * 1024;
const SIGTERM: number = 15;
const SIGKILL: number = 9;
const USER_DOCUMENTS: string = '/storage/Users/currentUser/Documents';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

function isDirectory(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (err) {
    return false;
  }
}

function ensureDir(path: string): void {
  try {
    if (!pathExists(path)) {
      fs.mkdirSync(path, true);
    }
  } catch (err) {
    const e = err as BusinessError;
    Log.error(`mkdir ${path} failed (${e.code}): ${e.message}`);
  }
}

function readText(path: string): string {
  return fs.readTextSync(path).trim();
}

function writeText(path: string, text: string, append: boolean): void {
  const mode = fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | (append ? fs.OpenMode.APPEND : fs.OpenMode.TRUNC);
  const file = fs.openSync(path, mode);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
}

/** GET 请求，返回 HTTP 状态码；连接失败返回 -1 */
async function httpStatus(url: string, timeoutMs: number): Promise<number> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs
    });
    return response.responseCode as number;
  } catch (err) {
    return -1;
  } finally {
    request.destroy();
  }
}

/**
 * 管理内置的 `kimi web` 子进程：选端口、拼环境变量、fork+execve（libkimihost.so）、
 * 轮询 /api/v1/healthz 就绪、读取 server.token 拼出 Web UI 地址，以及停止/重启。
 */
export class KimiServer {
  private static instance: KimiServer | null = null;

  private context: common.UIAbilityContext | null = null;
  private status: ServerStatus = new ServerStatus();
  private listeners: StatusListener[] = [];
  private startSeq: number = 0;

  homeDir: string = '';
  logPath: string = '';
  private pidPath: string = '';
  /** 本次启动是否已降级为 --jitless；每次 start() 都先尝试 JIT */
  private jitless: boolean = false;
  private lastExit: ExitInfo | null = null;
  /** 应用数据目录下存在 debug.flag 时，打开 kimi debug 日志与预加载脚本的调用追踪（很吵，仅排障用） */
  private debug: boolean = false;
  private debugFlagPath: string = '';
  private forwardOffset: number = 0;
  private forwardTimer: number = -1;
  /** 解压后的原生库目录：node（executableBinaryPaths）、libc++_shared.so、libkimicompat.so */
  private libDir: string = '';
  /** kimi-code 包目录：<context.resourceDir>/kimicode（resfile 安装时解压出的只读文件） */
  private kimiRoot: string = '';
  private workspacePathConfig: string = '';
  private workspaceUriConfig: string = '';
  private customWorkspace: string = '';

  static get(): KimiServer {
    if (KimiServer.instance === null) {
      KimiServer.instance = new KimiServer();
    }
    return KimiServer.instance;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
    this.homeDir = `${context.filesDir}/home`;
    const logDir = `${context.filesDir}/logs`;
    ensureDir(this.homeDir);
    ensureDir(logDir);
    ensureDir(`${context.filesDir}/workspace`);
    this.logPath = `${logDir}/kimi-server.log`;
    this.pidPath = `${logDir}/kimi-server.pid`;
    this.debugFlagPath = `${context.filesDir}/debug.flag`;
    this.workspacePathConfig = `${context.filesDir}/workspace.path`;
    this.workspaceUriConfig = `${context.filesDir}/workspace.uri`;
    try {
      const saved = readText(this.workspacePathConfig);
      if (isDirectory(saved)) {
        this.customWorkspace = saved;
      } else if (saved !== '') {
        Log.warn(`ignore unavailable workspace: ${saved}`);
      }
    } catch (err) {
      this.customWorkspace = '';
    }
    this.libDir = kimihost.nativeLibDir();
    this.kimiRoot = `${context.resourceDir}/${KIMI_RESFILE_DIR}`;
    Log.info(`native lib dir: ${this.libDir}, kimi root: ${this.kimiRoot}`);
    this.startLogForwarding();
  }

  getStatus(): ServerStatus {
    return this.status;
  }

  isDebugEnabled(): boolean {
    return pathExists(this.debugFlagPath);
  }

  /** 开关调试日志（files/debug.flag），下次启动服务时生效 */
  setDebugEnabled(enabled: boolean): void {
    try {
      if (enabled) {
        writeText(this.debugFlagPath, '1', false);
      } else if (pathExists(this.debugFlagPath)) {
        fs.unlinkSync(this.debugFlagPath);
      }
    } catch (err) {
      Log.warn(`toggle debug failed: ${String(err)}`);
    }
  }

  subscribe(listener: StatusListener): () => void {
    this.listeners.push(listener);
    listener(this.status);
    return () => {
      this.listeners = this.listeners.filter((item: StatusListener) => item !== listener);
    };
  }

  private update(phase: ServerPhase, message: string): void {
    const next = new ServerStatus();
    next.phase = phase;
    next.message = message;
    next.port = this.status.port;
    next.pid = this.status.pid;
    next.url = phase === ServerPhase.READY ? this.status.url : '';
    next.warning = phase === ServerPhase.READY && this.jitless ? JITLESS_WARNING : '';
    this.status = next;
    Log.info(`server ${phase}: ${message}`);
    for (const listener of this.listeners) {
      listener(next);
    }
  }

  get nodePath(): string {
    return `${this.libDir}/node`;
  }

  /** 默认工作目录：优先用户选择，其次“文档”，最后回退到应用沙箱 */
  defaultWorkspace(): string {
    if (this.customWorkspace !== '' && isDirectory(this.customWorkspace)) {
      return this.customWorkspace;
    }
    if (pathExists(USER_DOCUMENTS)) {
      return USER_DOCUMENTS;
    }
    return `${this.context?.filesDir}/workspace`;
  }

  async setWorkspace(path: string, uri: string): Promise<void> {
    if (!isDirectory(path)) {
      throw new Error(`工作目录不可用：${path}`);
    }
    const changed = this.customWorkspace !== path;
    writeText(this.workspaceUriConfig, uri, false);
    writeText(this.workspacePathConfig, path, false);
    this.customWorkspace = path;
    if (changed) {
      await this.restart();
    }
  }

  async resetWorkspace(): Promise<void> {
    const changed = this.customWorkspace !== '';
    this.customWorkspace = '';
    try {
      fs.unlinkSync(this.workspacePathConfig);
    } catch (err) {
      // 配置不存在即可
    }
    try {
      fs.unlinkSync(this.workspaceUriConfig);
    } catch (err) {
      // 配置不存在即可
    }
    if (changed) {
      await this.restart();
    }
  }

  async start(): Promise<void> {
    if (this.context === null) {
      throw new Error('KimiServer.init() not called');
    }
    if (this.status.phase === ServerPhase.STARTING || this.status.phase === ServerPhase.READY) {
      return;
    }
    const seq = ++this.startSeq;
    this.jitless = false;
    this.update(ServerPhase.STARTING, '正在检查内置运行时…');
    try {
      this.killStaleServer();
      this.rotateLog();
      this.assertRuntimeInstalled();
      this.debug = pathExists(this.debugFlagPath);
      try {
        await this.launch(seq);
      } catch (err) {
        if (seq !== this.startSeq || this.jitless || !this.exitLooksLikeJitFailure()) {
          throw err as Error;
        }
        // V8 JIT 需要可写可执行的匿名内存；应用没有 ALLOW_WRITABLE_CODE_MEMORY 时 node 会在启动阶段崩溃，
        // 降级 --jitless 重试（代价是没有 WebAssembly，Node 内置 fetch 依赖它）
        Log.warn('node crashed during startup, retrying with --jitless');
        this.jitless = true;
        await this.launch(seq);
      }
    } catch (err) {
      if (seq !== this.startSeq) {
        return;
      }
      const message = err instanceof Error ? err.message : String(err);
      this.stopProcess();
      this.update(ServerPhase.FAILED, message);
      // 崩溃记录由 faultloggerd 异步生成，稍等再查
      const since = Date.now() - 60000;
      setTimeout(() => {
        logRecentCrashes(since);
      }, 5000);
    }
  }

  /** 选端口 → 拉起进程 → 等待就绪；未就绪时抛错，被新的 start/stop 取消时直接返回 */
  private async launch(seq: number): Promise<void> {
    const port = await this.pickPort();
    if (seq !== this.startSeq) {
      return;
    }
    this.status.port = port;
    const mode = this.jitless ? '，jitless 模式' : '';
    this.update(ServerPhase.STARTING, `正在启动 Kimi Code 服务（127.0.0.1:${port}${mode}）…`);
    this.lastExit = null;
    const pid = this.spawnServer(port, seq);
    this.status.pid = pid;
    writeText(this.pidPath, String(pid), false);
    await this.waitReady(port, pid, seq);
    if (seq !== this.startSeq) {
      return;
    }
    const token = readText(`${this.homeDir}/.kimi-code/server.token`);
    this.status.url = `http://127.0.0.1:${port}/#token=${token}`;
    this.update(ServerPhase.READY, `已就绪（pid ${pid}${mode}）`);
  }

  private exitLooksLikeJitFailure(): boolean {
    const exit = this.lastExit;
    if (exit === null) {
      return false;
    }
    return JIT_CRASH_SIGNALS.indexOf(exit.signal) >= 0 || JIT_CRASH_SIGNALS.indexOf(exit.code - 128) >= 0;
  }

  private describeLastExit(): string {
    const exit = this.lastExit;
    if (exit === null) {
      return '原因未知';
    }
    return exit.signal > 0 ? `被信号 ${exit.signal} 结束` : `退出码 ${exit.code}`;
  }

  /**
   * 沙箱内的日志文件用 hdc 读不到，所以把 node 的输出同步转发到 hilog（tag KimiShell，前缀 [node]），
   * 便于 `hdc shell hilog -x -T KimiShell` 远程排障。token 会被打码。
   */
  private startLogForwarding(): void {
    try {
      this.forwardOffset = pathExists(this.logPath) ? fs.statSync(this.logPath).size : 0;
    } catch (err) {
      this.forwardOffset = 0;
    }
    if (this.forwardTimer < 0) {
      this.forwardTimer = setInterval(() => {
        this.forwardLog();
      }, this.isDebugEnabled() ? 50 : LOG_FORWARD_INTERVAL_MS);
    }
  }

  private forwardLog(): void {
    try {
      if (!pathExists(this.logPath)) {
        return;
      }
      const size = fs.statSync(this.logPath).size;
      if (size < this.forwardOffset) {
        this.forwardOffset = 0; // 日志被轮转
      }
      if (size === this.forwardOffset) {
        return;
      }
      const length = Math.min(size - this.forwardOffset, LOG_FORWARD_MAX_BYTES);
      const file = fs.openSync(this.logPath, fs.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(length);
      try {
        fs.readSync(file.fd, buffer, { offset: this.forwardOffset, length: length });
      } finally {
        fs.closeSync(file);
      }
      this.forwardOffset += length;
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const text = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      for (const line of text.split('\n')) {
        const trimmed = line.trimEnd();
        if (trimmed.length > 0) {
          const safe = trimmed.replace(/(#token=|Token:\s*)[A-Za-z0-9_-]+/g, '$1***');
          Log.info(`[node] ${safe.substring(0, LOG_FORWARD_MAX_LINE)}`);
        }
      }
    } catch (err) {
      // 转发只是辅助手段，失败不影响服务
    }
  }

  async restart(): Promise<void> {
    await this.stop();
    await this.start();
  }

  async stop(): Promise<void> {
    if (this.status.pid <= 0) {
      this.startSeq++;
      this.update(ServerPhase.IDLE, '已停止');
      return;
    }
    this.startSeq++;
    this.update(ServerPhase.STOPPING, '正在停止服务…');
    await this.stopProcessGracefully();
    this.update(ServerPhase.IDLE, '已停止');
  }

  /** 同步停止（Ability 销毁时用）：只发 SIGTERM，PDEATHSIG 兜底 */
  stopNow(): void {
    this.startSeq++;
    this.stopProcess();
    if (this.forwardTimer >= 0) {
      clearInterval(this.forwardTimer);
      this.forwardTimer = -1;
    }
  }

  private stopProcess(): void {
    const pid = this.status.pid;
    if (pid > 0) {
      kimihost.kill(pid, SIGTERM);
    }
    this.status.pid = 0;
    this.removePidFile();
  }

  private async stopProcessGracefully(): Promise<void> {
    const pid = this.status.pid;
    if (pid <= 0) {
      return;
    }
    kimihost.kill(pid, SIGTERM);
    const deadline = Date.now() + STOP_GRACE_MS;
    while (kimihost.isAlive(pid) && Date.now() < deadline) {
      await sleep(150);
    }
    if (kimihost.isAlive(pid)) {
      Log.warn(`pid ${pid} did not exit after SIGTERM, sending SIGKILL`);
      kimihost.kill(pid, SIGKILL);
    }
    this.status.pid = 0;
    this.removePidFile();
  }

  private removePidFile(): void {
    try {
      fs.unlinkSync(this.pidPath);
    } catch (err) {
      // 不存在即可
    }
  }

  /** 上次异常退出（应用被强杀）可能留下孤儿进程，先清掉 */
  private killStaleServer(): void {
    if (!pathExists(this.pidPath)) {
      return;
    }
    try {
      const stale = Number.parseInt(readText(this.pidPath), 10);
      if (stale > 0 && stale !== process.pid && kimihost.isAlive(stale)) {
        Log.warn(`killing stale server pid ${stale}`);
        kimihost.kill(stale, SIGKILL);
      }
    } catch (err) {
      Log.warn(`read stale pid failed: ${String(err)}`);
    }
    this.removePidFile();
  }

  private rotateLog(): void {
    try {
      if (pathExists(this.logPath) && fs.statSync(this.logPath).size > LOG_ROTATE_BYTES) {
        fs.renameSync(this.logPath, `${this.logPath}.1`);
      }
    } catch (err) {
      Log.warn(`rotate log failed: ${String(err)}`);
    }
  }

  private assertRuntimeInstalled(): void {
    const required: string[] = [
      this.nodePath,
      `${this.libDir}/libkimicompat.so`,
      `${this.kimiRoot}/package/dist/main.mjs`,
      `${this.kimiRoot}/runtime/ohos-preload.cjs`
    ];
    for (const path of required) {
      if (!pathExists(path)) {
        throw new Error(`内置运行时缺失：${path}\n请确认 HAP 包含 libs/arm64-v8a/node 与 resources/resfile/kimicode，并已完整安装。`);
      }
    }
  }

  private async pickPort(): Promise<number> {
    for (let i = 0; i < PORT_ATTEMPTS; i++) {
      const port = PREFERRED_PORT + i;
      const code = await httpStatus(`http://127.0.0.1:${port}/api/v1/healthz`, 600);
      if (code < 0) {
        return port;
      }
      Log.warn(`port ${port} is in use (HTTP ${code})`);
    }
    throw new Error(`端口 ${PREFERRED_PORT}-${PREFERRED_PORT + PORT_ATTEMPTS - 1} 都被占用`);
  }

  private buildEnv(): string[] {
    const ctx = this.context as common.UIAbilityContext;
    const path = [
      this.libDir,
      '/data/app/bin',
      '/data/service/hnp/bin',
      '/system/bin',
      '/bin'
    ].join(':');
    return [
      `HOME=${this.homeDir}`,
      `TMPDIR=${ctx.tempDir}`,
      `XDG_CACHE_HOME=${ctx.cacheDir}`,
      `PATH=${path}`,
      `GIT_EXEC_PATH=${this.libDir}`,
      `GIT_TEMPLATE_DIR=${this.kimiRoot}/git/share/git-core/templates`,
      `PYTHONHOME=${this.kimiRoot}/python`,
      `PYTHONPATH=${this.libDir}:${this.kimiRoot}/python/lib/python3.14:${this.kimiRoot}/python/lib/python3.14/site-packages`,
      `PYTHONPYCACHEPREFIX=${ctx.cacheDir}/python-pycache`,
      `TERMINFO=${this.kimiRoot}/python/share/terminfo`,
      // node 没有 RUNPATH，libc++_shared.so 与它同在解压后的 libs 目录
      `LD_LIBRARY_PATH=${this.libDir}`,
      `LD_PRELOAD=${this.libDir}/libkimicompat.so`,
      // libuv 会探测 io_uring_setup，应用沙箱的 seccomp 会拦截
      'UV_USE_IO_URING=0',
      'LANG=zh_CN.UTF-8',
      'TERM=xterm-256color',
      'NO_COLOR=1',
      'NODE_ENV=production',
      'KIMI_HMOS_SHELL=1',
      `KIMI_HMOS_DEBUG=${this.debug ? '1' : '0'}`,
      // 沙箱在线程创建阶段会杀掉 kimi 的搜索 worker；预加载脚本改为在主线程内联执行同样的协议和业务代码
      'KIMI_HMOS_SEARCH_WORKER_MODE=inline'
    ];
  }

  private spawnServer(port: number, seq: number): number {
    const main = `${this.kimiRoot}/package/dist/main.mjs`;
    const workspace = this.defaultWorkspace();
    Log.info(`workspace: ${workspace}`);
    const args: string[] = [this.nodePath];
    if (this.jitless) {
      args.push('--jitless');
    }
    args.push(
      '--require', `${this.kimiRoot}/runtime/ohos-preload.cjs`,
      main,
      'web',
      '--no-open',
      '--port', String(port),
      '--web-title', 'Kimi Code'
    );
    if (this.debug) {
      args.push('--log-level', 'debug');
    }
    const header = `\n===== ${new Date().toISOString()} start kimi-code ${KIMI_CODE_VERSION} on node ${NODE_VERSION}` +
      ` port ${port}${this.jitless ? ' (jitless)' : ''}\n`;
    writeText(this.logPath, header, true);
    return kimihost.spawn({
      file: this.nodePath,
      args: args,
      env: this.buildEnv(),
      cwd: workspace,
      logPath: this.logPath,
      onExit: (pid: number, code: number, signal: number) => {
        this.onChildExit(pid, code, signal, seq);
      }
    });
  }

  private onChildExit(pid: number, code: number, signal: number, seq: number): void {
    if (pid !== this.status.pid) {
      return;
    }
    const exit = new ExitInfo();
    exit.code = code;
    exit.signal = signal;
    this.lastExit = exit;
    this.status.pid = 0;
    this.removePidFile();
    // 启动阶段的退出由 waitReady/start 处理（可能触发 --jitless 重试）
    if (seq !== this.startSeq || this.status.phase !== ServerPhase.READY) {
      return;
    }
    this.update(ServerPhase.FAILED, `Kimi Code 服务意外退出（${this.describeLastExit()}），详见日志。`);
  }

  private async waitReady(port: number, pid: number, seq: number): Promise<void> {
    const deadline = Date.now() + READY_TIMEOUT_MS;
    const healthz = `http://127.0.0.1:${port}/api/v1/healthz`;
    const tokenPath = `${this.homeDir}/.kimi-code/server.token`;
    while (Date.now() < deadline) {
      if (seq !== this.startSeq) {
        return;
      }
      if (this.status.pid !== pid) {
        throw new Error(`Kimi Code 服务启动失败（${this.describeLastExit()}），详见日志。`);
      }
      if ((await httpStatus(healthz, 1500)) === 200 && pathExists(tokenPath)) {
        return;
      }
      await sleep(READY_POLL_MS);
    }
    throw new Error(`等待服务就绪超时（${READY_TIMEOUT_MS / 1000}s），详见日志。`);
  }

  /** 读取日志尾部，用于启动页/错误页展示；与 hilog 转发一样隐藏 token */
  readLogTail(maxBytes: number): string {
    try {
      if (!pathExists(this.logPath)) {
        return '';
      }
      const size = fs.statSync(this.logPath).size;
      const length = Math.min(size, maxBytes);
      const file = fs.openSync(this.logPath, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(length);
        fs.readSync(file.fd, buffer, { offset: size - length, length: length });
        const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        const text = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
        return text.replace(/(#token=|Token:\s*)[A-Za-z0-9_-]+/g, '$1***');
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      const e = err as BusinessError;
      return `读取日志失败：${e.message}`;
    }
  }
}
