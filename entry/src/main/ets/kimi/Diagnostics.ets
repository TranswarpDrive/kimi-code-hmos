import { FaultLogger } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Log';

const CHUNK: number = 800;
const MAX_CHARS: number = 8000;

/**
 * 把本应用 uid 下最近的 C++ 崩溃记录（含 node 子进程）输出到 hilog。
 * 沙箱外的 faultlog 目录 hdc 读不到，这是拿到崩溃原因（如 SIGSYS 的 syscall 号）和调用栈的唯一途径。
 */
export async function logRecentCrashes(sinceMs: number): Promise<void> {
  try {
    const logs = await FaultLogger.query(FaultLogger.FaultType.CPP_CRASH);
    // 时间戳单位因版本而异，这里不按时间过滤，直接取最新两条
    const recent = logs.sort((a: FaultLogger.FaultLogInfo, b: FaultLogger.FaultLogInfo) => b.timestamp - a.timestamp)
      .slice(0, 2);
    Log.info(`fault logs: ${logs.length} total, ${recent.length} since ${sinceMs}`);
    for (const item of recent) {
      Log.info(`crash pid=${item.pid} module=${item.module} reason=${item.reason} time=${item.timestamp}`);
      const text = item.fullLog !== undefined && item.fullLog.length > 0 ? item.fullLog : item.summary;
      for (let i = 0; i < Math.min(text.length, MAX_CHARS); i += CHUNK) {
        Log.info(`crash| ${text.substring(i, i + CHUNK)}`);
      }
    }
  } catch (err) {
    const e = err as BusinessError;
    Log.warn(`query fault logs failed (${e.code}): ${e.message}`);
  }
}
