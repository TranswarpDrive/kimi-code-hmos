import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x4B49;
const TAG: string = 'KimiShell';

/** hilog 封装：统一 domain/tag，便于 `hdc shell hilog -x | grep KimiShell` 过滤 */
export class Log {
  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }
}
