import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Log';

/** 用户授权类权限：让 kimi 能读写“文档”“下载”里的项目文件（子进程与应用共享沙箱视图） */
const USER_DIR_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
];

export async function requestUserDirPermissions(context: common.UIAbilityContext): Promise<void> {
  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, USER_DIR_PERMISSIONS);
    Log.info(`permission request result: ${JSON.stringify(result)}`);
  } catch (err) {
    const e = err as BusinessError;
    Log.warn(`requestPermissionsFromUser failed (${e.code}): ${e.message}`);
  }
}
