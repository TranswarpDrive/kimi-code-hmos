import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Log';

/**
 * 用户授权类权限：
 *  - 读写“文档”“下载”里的项目文件（子进程与应用共享沙箱视图）
 *  - 读剪贴板：ArkWeb 粘贴以应用身份读取，未授权时 Ctrl+V 粘贴不进其他应用复制的图片和文字
 */
const USER_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_PASTEBOARD'
];

export async function requestUserPermissions(context: common.UIAbilityContext): Promise<void> {
  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, USER_PERMISSIONS);
    Log.info(`permission request result: ${JSON.stringify(result)}`);
  } catch (err) {
    const e = err as BusinessError;
    Log.warn(`requestPermissionsFromUser failed (${e.code}): ${e.message}`);
  }
}
