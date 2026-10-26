import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import kimihost from 'libkimihost.so';
import { Log, redactSecrets } from './Log';
import { KIMI_CODE_VERSION, KIMI_RESFILE_DIR } from './RuntimeInfo';

export enum UpdatePhase {
  IDLE = 'idle',
  CHECKING = 'checking',
  INSTALLING = 'installing',
  ACTIVATING = 'activating',
  RESTORING = 'restoring'
}

export class UpdateStatus {
  phase: UpdatePhase = UpdatePhase.IDLE;
  bundledVersion: string = KIMI_CODE_VERSION;
  currentVersion: string = KIMI_CODE_VERSION;
  activeVersion: string = '';
  latestVersion: string = '';
  candidateVersion: string = '';
  pending: boolean = false;
  updateAvailable: boolean = false;
  message: string = '';
  error: string = '';
}

export class ActiveRuntime {
  version: string = KIMI_CODE_VERSION;
  packageRoot: string = '';
  updated: boolean = false;
  pending: boolean = false;
}

interface UpdateStateData {
  schema: number;
  activeVersion: string;
  previousVersion: string;
  pending: boolean;
}

interface UpdateResultData {
  schema: number;
  command: string;
  ok: boolean;
  message: string;
  currentVersion: string;
  activeVersion: string;
  previousVersion: string;
  latestVersion: string;
  candidateVersion: string;
  pending: boolean;
  updateAvailable: boolean;
}

interface CheckData {
  schema: number;
  version: string;
  updateAvailable: boolean;
}

interface CandidateData {
  schema: number;
  version: string;
  integrity: string;
}

interface ReadyData {
  schema: number;
  version: string;
  integrity: string;
}

export type UpdateListener = (status: UpdateStatus) => void;

function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

function ensureDir(path: string): void {
  if (!pathExists(path)) {
    fs.mkdirSync(path, true);
  }
}

function safeVersion(version: string): boolean {
  return version.length <= 80 && /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version);
}

export class RuntimeUpdates {
  private context: common.UIAbilityContext | null = null;
  private status: UpdateStatus = new UpdateStatus();
  private listeners: UpdateListener[] = [];
  private root: string = '';
  private logPath: string = '';
  private resultPath: string = '';
  private scriptPath: string = '';
  private npmCli: string = '';
  private npmArchive: string = '';
  private tarModule: string = '';
  private preload: string = '';
  private nodeBinary: string = '';
  private libDir: string = '';
  private commandDir: string = '';
  private pid: number = 0;
  private operationSeq: number = 0;
  private disposed: boolean = false;
  private operationReject: ((error: Error) => void) | null = null;

  init(context: common.UIAbilityContext): void {
    this.disposed = false;
    this.context = context;
    this.root = `${context.filesDir}/runtime-updates`;
    ensureDir(this.root);
    ensureDir(`${context.filesDir}/logs`);
    this.logPath = `${context.filesDir}/logs/kimi-update.log`;
    this.resultPath = `${this.root}/result.json`;
    const resource = `${context.resourceDir}/${KIMI_RESFILE_DIR}`;
    this.scriptPath = `${resource}/runtime/runtime-updater.cjs`;
    this.preload = `${resource}/runtime/ohos-preload.cjs`;
    this.npmCli = `${this.root}/npm/bin/npm-cli.js`;
    this.npmArchive = `${resource}/npm.tar.gz`;
    this.tarModule = `${resource}/npm-extract/node_modules/tar`;
    this.commandDir = `${resource}/bin`;
    this.libDir = kimihost.nativeLibDir();
    this.nodeBinary = `${this.libDir}/node.bin`;
    this.refreshFromDisk();
  }

  getStatus(): UpdateStatus {
    return this.status;
  }

  isBusy(): boolean {
    return this.pid > 0;
  }

  subscribe(listener: UpdateListener): () => void {
    this.listeners.push(listener);
    listener(this.status);
    return () => {
      this.listeners = this.listeners.filter((item: UpdateListener) => item !== listener);
    };
  }

  private emit(): void {
    for (const listener of this.listeners) {
      listener(this.status);
    }
  }

  private readJson(path: string): Object | null {
    try {
      return JSON.parse(fs.readTextSync(path)) as Object;
    } catch (err) {
      return null;
    }
  }

  private state(): UpdateStateData {
    const data = this.readJson(`${this.root}/state.json`) as UpdateStateData | null;
    if (data !== null && data.schema === 1 && typeof data.activeVersion === 'string' &&
      typeof data.previousVersion === 'string' && typeof data.pending === 'boolean') {
      return data;
    }
    const fallback: UpdateStateData = { schema: 1, activeVersion: '', previousVersion: '', pending: false };
    return fallback;
  }

  activeRuntime(): ActiveRuntime {
    const active = new ActiveRuntime();
    const state = this.state();
    active.pending = state.pending;
    if (!safeVersion(state.activeVersion)) {
      return active;
    }
    const directory = `${this.root}/versions/${state.activeVersion}`;
    const marker = this.readJson(`${directory}/.hmos-ready.json`) as ReadyData | null;
    if (marker === null || marker.schema !== 1 || marker.version !== state.activeVersion ||
      !/^sha512-[A-Za-z0-9+/]{86}==$/.test(marker.integrity)) {
      Log.warn(`updated runtime ${state.activeVersion} has no valid ready marker; using bundled runtime`);
      active.pending = false;
      return active;
    }
    active.version = state.activeVersion;
    active.packageRoot = `${directory}/node_modules/@moonshot-ai/kimi-code`;
    active.updated = true;
    return active;
  }

  currentVersion(): string {
    return this.activeRuntime().version;
  }

  private refreshFromDisk(): void {
    const active = this.activeRuntime();
    const check = this.readJson(`${this.root}/check.json`) as CheckData | null;
    const candidate = this.readJson(`${this.root}/candidate.json`) as CandidateData | null;
    const result = this.readJson(this.resultPath) as UpdateResultData | null;
    const next = new UpdateStatus();
    next.currentVersion = active.version;
    next.activeVersion = active.updated ? active.version : '';
    next.pending = active.pending;
    if (check !== null && safeVersion(check.version)) {
      next.latestVersion = check.version;
      next.updateAvailable = check.updateAvailable === true && check.version !== active.version;
    }
    if (candidate !== null && safeVersion(candidate.version)) {
      next.candidateVersion = candidate.version;
      next.updateAvailable = true;
    }
    if (result !== null && result.ok) {
      if (typeof result.latestVersion === 'string') {
        next.latestVersion = result.latestVersion;
      }
      if (typeof result.candidateVersion === 'string') {
        next.candidateVersion = result.candidateVersion;
      }
      next.updateAvailable = result.updateAvailable === true || next.candidateVersion !== '';
      next.message = result.message;
    } else if (next.candidateVersion !== '') {
      next.message = `Kimi Code ${next.candidateVersion} 已下载，重启后生效`;
    } else if (active.updated) {
      next.message = `正在使用官方更新版 ${active.version}`;
    } else {
      next.message = '可从官方 npm 检查并更新 CLI 与 WebUI';
    }
    this.status = next;
  }

  private phaseFor(command: string): UpdatePhase {
    if (command === 'check') {
      return UpdatePhase.CHECKING;
    }
    if (command === 'install') {
      return UpdatePhase.INSTALLING;
    }
    if (command === 'rollback' || command === 'restore') {
      return UpdatePhase.RESTORING;
    }
    return UpdatePhase.ACTIVATING;
  }

  private messageFor(command: string, version: string): string {
    if (command === 'check') {
      return '正在连接官方 npm 检查更新…';
    }
    if (command === 'install') {
      return `正在从官方 npm 下载并校验 Kimi Code ${version}…`;
    }
    if (command === 'activate') {
      return `正在准备切换到 Kimi Code ${version}…`;
    }
    if (command === 'commit') {
      return '正在确认新版首次启动…';
    }
    return '正在恢复可用运行时…';
  }

  private buildEnv(): string[] {
    return [
      `HOME=${this.root}/npm-home`,
      `TMPDIR=${this.root}/tmp`,
      `XDG_CACHE_HOME=${this.root}/xdg-cache`,
      `PATH=${this.commandDir}:/system/bin:/bin`,
      `KIMI_HMOS_NATIVE_DIR=${this.libDir}`,
      `LD_LIBRARY_PATH=${this.libDir}`,
      `LD_PRELOAD=${this.libDir}/libkimicompat.so`,
      'UV_USE_IO_URING=0',
      'LANG=zh_CN.UTF-8',
      'NODE_ENV=production',
      'KIMI_HMOS_DEBUG=0'
    ];
  }

  private run(command: string, version: string = ''): Promise<void> {
    if (this.disposed || this.context === null) {
      return Promise.reject(new Error('更新器尚未初始化'));
    }
    if (this.pid > 0) {
      return Promise.reject(new Error('另一个更新操作仍在进行'));
    }
    const seq = ++this.operationSeq;
    this.status.phase = this.phaseFor(command);
    this.status.error = '';
    this.status.message = this.messageFor(command, version);
    this.emit();
    try {
      fs.unlinkSync(this.resultPath);
    } catch (err) {
      // 不存在即可
    }
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      this.operationReject = reject;
      const args: string[] = [
        this.nodeBinary, this.scriptPath, command,
        '--root', this.root,
        '--npm-cli', this.npmCli,
        '--npm-archive', this.npmArchive,
        '--tar-module', this.tarModule,
        '--node-binary', this.nodeBinary,
        '--preload', this.preload,
        '--built-in', KIMI_CODE_VERSION,
        '--result', this.resultPath
      ];
      if (version !== '') {
        args.push('--version', version);
      }
      try {
        this.pid = kimihost.spawn({
          file: this.nodeBinary,
          args: args,
          env: this.buildEnv(),
          cwd: this.root,
          logPath: this.logPath,
          onExit: (pid: number, code: number, signal: number) => {
            this.onExit(seq, pid, code, signal, command, resolve, reject);
          }
        });
        Log.info(`runtime update ${command} started, pid ${this.pid}`);
      } catch (err) {
        this.operationReject = null;
        this.pid = 0;
        const message = err instanceof Error ? err.message : String(err);
        this.status.phase = UpdatePhase.IDLE;
        this.status.error = message;
        this.status.message = '无法启动更新进程';
        this.emit();
        reject(err instanceof Error ? err : new Error(message));
      }
    });
  }

  private onExit(seq: number, pid: number, code: number, signal: number, command: string,
    resolve: () => void, reject: (error: Error) => void): void {
    if (seq !== this.operationSeq || pid !== this.pid) {
      return;
    }
    this.pid = 0;
    this.operationReject = null;
    this.refreshFromDisk();
    const result = this.readJson(this.resultPath) as UpdateResultData | null;
    this.status.phase = UpdatePhase.IDLE;
    if (code === 0 && result !== null && result.ok && result.command === command) {
      this.status.message = result.message;
      this.status.updateAvailable = result.updateAvailable === true || this.status.candidateVersion !== '';
      Log.info(`runtime update ${command}: ${result.message}`);
      this.emit();
      resolve();
      return;
    }
    const message = result !== null && typeof result.message === 'string' && result.message !== '' ?
      result.message : `更新进程异常退出（code ${code}, signal ${signal}）`;
    this.status.error = message;
    this.status.message = '更新失败，当前运行时未被替换';
    Log.warn(`runtime update ${command} failed: ${redactSecrets(message)}`);
    this.emit();
    reject(new Error(message));
  }

  check(): Promise<void> {
    return this.run('check');
  }

  install(version: string): Promise<void> {
    if (!safeVersion(version)) {
      return Promise.reject(new Error('更新版本号无效'));
    }
    return this.run('install', version);
  }

  activate(version: string): Promise<void> {
    if (!safeVersion(version)) {
      return Promise.reject(new Error('更新版本号无效'));
    }
    return this.run('activate', version);
  }

  commit(): Promise<void> {
    return this.run('commit');
  }

  rollback(): Promise<void> {
    return this.run('rollback');
  }

  restore(): Promise<void> {
    return this.run('restore');
  }

  stopNow(): void {
    this.disposed = true;
    this.operationSeq++;
    if (this.pid > 0) {
      kimihost.terminate(this.pid, 2000);
      this.pid = 0;
    }
    if (this.operationReject !== null) {
      const reject = this.operationReject;
      this.operationReject = null;
      reject(new Error('更新已取消'));
    }
  }

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
        const bytesRead = fs.readSync(file.fd, buffer, { offset: size - length, length: length });
        const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        let text = decoder.decodeToString(new Uint8Array(buffer, 0, bytesRead), { stream: false });
        const newline = text.indexOf('\n');
        text = newline >= 0 ? text.substring(newline + 1) : '';
        return redactSecrets(text);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      return `读取更新日志失败：${String(err)}`;
    }
  }
}
