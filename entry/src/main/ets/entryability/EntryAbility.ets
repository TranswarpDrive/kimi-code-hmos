import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BackgroundKeeper } from '../kimi/BackgroundKeeper';
import { KimiServer, ServerPhase, ServerStatus } from '../kimi/KimiServer';
import { Log } from '../kimi/Log';
import { requestUserDirPermissions } from '../kimi/Permissions';

export default class EntryAbility extends UIAbility {
  private keeper: BackgroundKeeper = new BackgroundKeeper();
  private unsubscribe: (() => void) | null = null;
  private mainWindow: window.Window | null = null;

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
    this.createShellWindow(windowStage);
    // 先申请“文档/下载”目录权限再启动服务：子进程启动时就能看到这些目录
    requestUserDirPermissions(this.context).finally(() => {
      KimiServer.get().start();
    });
  }

  private async createShellWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (err) {
      Log.warn(`getMainWindowSync failed: ${JSON.stringify(err)}`);
    }
    if (this.mainWindow !== null) {
      try {
        await this.mainWindow.setWindowLayoutFullScreen(true);
      } catch (err) {
        Log.warn(`setWindowLayoutFullScreen failed: ${JSON.stringify(err)}`);
      }
      this.setShellBackground();
    }
    try {
      await windowStage.loadContent('pages/Index');
    } catch (err) {
      Log.error(`loadContent failed: ${JSON.stringify(err)}`);
      return;
    }
    if (this.mainWindow === null) {
      return;
    }
    // 自由窗口须隐藏装饰标题才能让页面延伸到三键区下方。
    try {
      this.mainWindow.setWindowDecorVisible(false);
    } catch (err) {
      Log.warn(`setWindowDecorVisible failed: ${JSON.stringify(err)}`);
    }
    try {
      this.mainWindow.setWindowDecorHeight(40);
    } catch (err) {
      Log.warn(`setWindowDecorHeight failed: ${JSON.stringify(err)}`);
    }
    try {
      this.mainWindow.setWindowTitleMoveEnabled(true);
    } catch (err) {
      Log.warn(`setWindowTitleMoveEnabled failed: ${JSON.stringify(err)}`);
    }
    try {
      const rect: window.TitleButtonRect = this.mainWindow.getTitleButtonRect();
      AppStorage.setOrCreate<number>('shellTitleButtonWidth', rect.width + rect.right);
    } catch (err) {
      Log.warn(`getTitleButtonRect failed: ${JSON.stringify(err)}`);
    }
    try {
      this.mainWindow.on('windowTitleButtonRectChange', (rect: window.TitleButtonRect) => {
        AppStorage.setOrCreate<number>('shellTitleButtonWidth', rect.width + rect.right);
      });
    } catch (err) {
      Log.warn(`windowTitleButtonRectChange failed: ${JSON.stringify(err)}`);
    }
  }

  private setShellBackground(): void {
    if (this.mainWindow === null) {
      return;
    }
    try {
      const color: number = this.context.resourceManager.getColorByNameSync('shell_bg');
      this.mainWindow.setWindowBackgroundColor(`#${(color >>> 0).toString(16).padStart(8, '0')}`);
    } catch (err) {
      Log.warn(`setWindowBackgroundColor failed: ${JSON.stringify(err)}`);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.setShellBackground();
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
