import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x4B49;
const TAG: string = 'KimiShell';

/** 所有系统日志和界面日志共用，覆盖 URL、Authorization 和常见密钥字段。 */
export function redactSecrets(message: string): string {
  return message
    .replace(/([#?&](?:token|access_token|refresh_token|id_token|api_key|key|code|user_code|device_code)=)[^\s&#"'<>]+/gi, '$1***')
    .replace(/(\bBearer\s+)[A-Za-z0-9._~+\/-]+=*/gi, '$1***')
    .replace(/(["']?(?:token|api[_-]?key|access[_-]?token|refresh[_-]?token|password|client_secret)["']?\s*[:=]\s*["']?)[^\s,"';}]+/gi, '$1***');
}

/** 只转发完整行，避免 token 恰好跨读取边界时漏出后半段；超长行整行丢弃。 */
export class SafeLogLines {
  private pending: string = '';
  private discarding: boolean = false;

  reset(discardUntilNewline: boolean = false): void {
    this.pending = '';
    this.discarding = discardUntilNewline;
  }

  push(text: string): string[] {
    const result: string[] = [];
    const parts = text.split('\n');
    for (let i = 0; i < parts.length; i++) {
      const complete = i < parts.length - 1;
      if (!this.discarding) {
        this.pending += parts[i];
        if (this.pending.length > 64 * 1024) {
          this.pending = '';
          this.discarding = true;
        }
      }
      if (complete) {
        if (!this.discarding && this.pending.trimEnd() !== '') {
          result.push(redactSecrets(this.pending.trimEnd()).substring(0, 900));
        }
        this.reset();
      }
    }
    return result;
  }
}

/** hilog 封装：统一 domain/tag，便于 `hdc shell hilog -x | grep KimiShell` 过滤 */
export class Log {
  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', redactSecrets(message));
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', redactSecrets(message));
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', redactSecrets(message));
  }
}
