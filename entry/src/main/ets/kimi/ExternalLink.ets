import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Log';

const EXTERNAL_SCHEMES: string[] = ['http:', 'https:', 'mailto:'];

/** 只把 http(s)/mailto 交给系统，避免页面借桥接拉起任意 scheme */
export function isOpenableExternally(url: string): boolean {
  const lower = url.trim().toLowerCase();
  for (const scheme of EXTERNAL_SCHEMES) {
    if (lower.startsWith(scheme)) {
      return true;
    }
  }
  return false;
}

/**
 * 用系统默认浏览器打开链接（kimi 登录走 OAuth 设备码流程，授权页在浏览器里完成，无需回跳应用）。
 * openLink 失败时退回隐式 Want（viewData + browsable）。
 */
export function openExternal(context: common.UIAbilityContext, url: string): void {
  if (!isOpenableExternally(url)) {
    Log.warn(`refuse to open non-web url: ${url}`);
    return;
  }
  Log.info(`open external: ${url}`);
  context.openLink(url, { appLinkingOnly: false }).catch((err: BusinessError) => {
    Log.warn(`openLink failed (${err.code}): ${err.message}, fallback to startAbility`);
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((err2: BusinessError) => {
      Log.error(`startAbility viewData failed (${err2.code}): ${err2.message}`);
    });
  });
}
