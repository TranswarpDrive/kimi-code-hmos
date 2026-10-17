export interface SpawnOptions {
  /** 可执行文件绝对路径 */
  file: string;
  /** 完整 argv（含 argv[0]） */
  args: string[];
  /** "KEY=VALUE" 列表；不继承应用进程的环境变量 */
  env: string[];
  cwd?: string;
  /** 子进程 stdout/stderr 追加写入的文件 */
  logPath?: string;
  /** 子进程退出时回调；被信号结束时 code 为 -1、signal 为信号值 */
  onExit?: (pid: number, code: number, signal: number) => void;
}

/** fork + execve，返回 pid；失败抛出 Error */
export const spawn: (options: SpawnOptions) => number;

/** 向进程组（失败则向进程）发送信号 */
export const kill: (pid: number, signal: number) => boolean;

export const isAlive: (pid: number) => boolean;

/** libkimihost.so 所在目录（解压后的原生库目录，node 与 libkimicompat.so 也在这里） */
export const nativeLibDir: () => string;

/** 诊断：当前进程能否申请匿名可执行内存（V8 JIT 的前提） */
export const probeJit: () => string;
