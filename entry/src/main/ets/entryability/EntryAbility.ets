import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { BackgroundKeeper } from '../kimi/BackgroundKeeper';
import { KimiServer, ServerPhase, ServerStatus } from '../kimi/KimiServer';
import { Log } from '../kimi/Log';
import { requestUserDirPermissions } from '../kimi/Permissions';

export default class EntryAbility extends UIAbility {
  private keeper: BackgroundKeeper = new BackgroundKeeper();
  private unsubscribe: (() => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      Log.warn(`setColorMode failed: ${JSON.stringify(err)}`);
    }
    const server = KimiServer.get();
    server.init(this.context);
    this.unsubscribe = server.subscribe((status: ServerStatus) => {
      if (status.phase === ServerPhase.READY) {
        this.keeper.start(this.context);
      } else if (status.phase === ServerPhase.FAILED || status.phase === ServerPhase.IDLE) {
        this.keeper.stop(this.context);
      }
    });
    Log.info(`onCreate, launch reason ${launchParam.launchReason}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Log.error(`loadContent failed: ${JSON.stringify(err)}`);
      }
    });
    // 先申请“文档/下载”目录权限再启动服务：子进程启动时就能看到这些目录
    requestUserDirPermissions(this.context).finally(() => {
      KimiServer.get().start();
    });
  }

  onDestroy(): void {
    Log.info('onDestroy, stopping kimi server');
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
    KimiServer.get().stopNow();
    this.keeper.stop(this.context);
  }
}
