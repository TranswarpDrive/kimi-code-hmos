import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { isOpenableExternally, openExternal } from '../kimi/ExternalLink';
import { FileActions } from '../kimi/FileActions';
import { KimiServer, ServerPhase, ServerStatus } from '../kimi/KimiServer';
import { Log } from '../kimi/Log';
import { KIMI_CODE_VERSION, NODE_VERSION } from '../kimi/RuntimeInfo';
import { BRIDGE_METHODS, BRIDGE_NAME, bridgePermission, documentStartScript, KimiHostBridge } from '../kimi/WebBridge';

const LOG_TAIL_BYTES: number = 6000;

@Entry
@Component
struct Index {
  @State phase: ServerPhase = ServerPhase.IDLE;
  @State message: string = '';
  @State webUrl: string = '';
  @State logTail: string = '';
  @State logExpanded: boolean = false;
  @State warning: string = '';
  @State debugEnabled: boolean = false;
  @State workspace: string = '';
  @State proxyPermission: string = '';
  @State scripts: ScriptItem[] = [];
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: KimiHostBridge = new KimiHostBridge((url: string) => {
    this.openOutside(url);
  }, (name: string, base64: string) => {
    this.saveBlob(name, base64);
  }, JSON.stringify({ shell: 'kimi-code-hmos', kimi: KIMI_CODE_VERSION, node: NODE_VERSION }), (message: string) => {
    this.notify(message);
  });
  private origin: string = '';
  private unsubscribe: (() => void) | null = null;
  private logTimer: number = -1;
  private webReady: boolean = false;
  private webStale: boolean = false;

  aboutToAppear(): void {
    this.debugEnabled = KimiServer.get().isDebugEnabled();
    this.workspace = KimiServer.get().defaultWorkspace();
    this.unsubscribe = KimiServer.get().subscribe((status: ServerStatus) => {
      this.onStatus(status);
    });
    this.logTimer = setInterval(() => {
      if (this.phase !== ServerPhase.READY || this.logExpanded) {
        this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
    clearInterval(this.logTimer);
  }

  private onStatus(status: ServerStatus): void {
    this.phase = status.phase;
    this.message = status.message;
    this.warning = status.warning;
    if (status.phase !== ServerPhase.READY && this.webUrl !== '') {
      this.webStale = true;
    }
    if (status.phase === ServerPhase.FAILED) {
      this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
      this.logExpanded = true;
    }
    if (status.phase !== ServerPhase.READY || (status.url === this.webUrl && !this.webStale)) {
      return;
    }
    this.origin = `http://127.0.0.1:${status.port}`;
    this.proxyPermission = bridgePermission(status.port);
    this.scripts = [{ script: documentStartScript(this.origin), scriptRules: [this.origin] }];
    this.workspace = KimiServer.get().defaultWorkspace();
    const first = this.webUrl === '';
    this.webUrl = status.url;
    this.webStale = false;
    if (!first && this.webReady) {
      // 服务重启后即使端口和地址不变，也要丢弃旧的 WebSocket 连接并重新加载
      try {
        this.controller.loadUrl(status.url);
      } catch (err) {
        const e = err as BusinessError;
        Log.error(`loadUrl failed (${e.code}): ${e.message}`);
      }
    }
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private openOutside(url: string): void {
    openExternal(this.context(), url);
  }

  private notify(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 3000 });
  }

  private async saveBlob(name: string, base64: string): Promise<void> {
    try {
      this.notify('正在保存文件…');
      const path = await FileActions.saveBlobToDownloads(name, base64);
      this.notify(`下载完成：${path}`);
    } catch (err) {
      Log.warn(`save blob download failed: ${String(err)}`);
      this.notify(`下载失败：${String(err)}`);
    }
  }

  private async chooseWorkspace(): Promise<void> {
    try {
      const selection = await FileActions.selectWorkspace(this.context());
      await KimiServer.get().setWorkspace(selection.path, selection.uri);
      this.workspace = selection.path;
      this.logExpanded = false;
      this.notify(`工作目录：${selection.path}`);
    } catch (err) {
      const e = err as BusinessError;
      if (e.message === '未选择工作目录') {
        return;
      }
      Log.warn(`set workspace failed: ${String(err)}`);
      this.notify(`无法设置工作目录：${String(err)}`);
    }
  }

  private async resetWorkspace(): Promise<void> {
    try {
      await KimiServer.get().resetWorkspace();
      this.workspace = KimiServer.get().defaultWorkspace();
      this.logExpanded = false;
      this.notify(`已恢复默认工作目录：${this.workspace}`);
    } catch (err) {
      this.notify(`恢复默认工作目录失败：${String(err)}`);
    }
  }

  private restartService(): void {
    this.logExpanded = false;
    KimiServer.get().restart().catch((err: Error) => this.notify(`重启失败：${err.message}`));
  }

  build() {
    Column() {
      if (this.phase === ServerPhase.READY) {
        this.ShellToolbar()
        if (this.warning !== '') {
          this.WarningBanner()
        }
      }
      Stack() {
        if (this.webUrl !== '') {
          Web({ src: this.webUrl, controller: this.controller })
            .width('100%')
            .height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .databaseAccess(true)
            .fileAccess(false)
            .multiWindowAccess(false)
            .darkMode(WebDarkMode.Auto)
            .forceDarkAccess(false)
            .javaScriptOnDocumentStart(this.scripts)
            .javaScriptProxy({
              object: this.bridge,
              name: BRIDGE_NAME,
              methodList: BRIDGE_METHODS,
              controller: this.controller,
              permission: this.proxyPermission
            })
            .onControllerAttached(() => {
              this.webReady = true;
              try {
                this.controller.setDownloadDelegate(FileActions.createDownloadDelegate((message: string) => {
                  this.notify(message);
                }));
              } catch (err) {
                Log.warn(`setDownloadDelegate failed: ${String(err)}`);
              }
            })
            .onShowFileSelector((event: OnShowFileSelectorEvent) => {
              FileActions.selectWebFiles(this.context(), event.fileSelector, event.result);
              return true;
            })
            .onLoadIntercept((event: OnLoadInterceptEvent) => {
              const target = event.data.getRequestUrl();
              if (event.data.isMainFrame() && target !== this.origin && !target.startsWith(`${this.origin}/`)) {
                if (isOpenableExternally(target)) {
                  this.openOutside(target);
                }
                return true;
              }
              return false;
            })
            .onConsole((event: OnConsoleEvent) => {
              const level = event.message.getMessageLevel();
              if (level === MessageLevel.Error || level === MessageLevel.Warn) {
                Log.warn(`[web] ${event.message.getMessage()}`);
              }
              return false;
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              if (event.request.isMainFrame()) {
                Log.warn(`[web] load error ${event.error.getErrorCode()}: ${event.error.getErrorInfo()}`);
              }
            })
            .visibility(this.phase === ServerPhase.READY ? Visibility.Visible : Visibility.Hidden)
        }

        if (this.phase !== ServerPhase.READY) {
          this.StatusPanel()
        } else if (this.logExpanded) {
          this.ReadyLogPanel()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }

  @Builder
  ShellToolbar() {
    Row({ space: 8 }) {
      Text(this.workspace)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .copyOption(CopyOptions.LocalDevice)
      Button('选择目录')
        .fontSize(12)
        .height(28)
        .type(ButtonType.Normal)
        .borderRadius(6)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.chooseWorkspace();
        })
      Button('默认目录')
        .fontSize(12)
        .height(28)
        .type(ButtonType.Normal)
        .borderRadius(6)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.resetWorkspace();
        })
      Button('重启服务')
        .fontSize(12)
        .height(28)
        .type(ButtonType.Normal)
        .borderRadius(6)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.restartService();
        })
      Button(this.logExpanded ? '关闭日志' : '查看日志')
        .fontSize(12)
        .height(28)
        .type(ButtonType.Normal)
        .borderRadius(6)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.logExpanded = !this.logExpanded;
          this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
        })
      if (this.debugEnabled) {
        Button('关闭调试')
          .fontSize(12)
          .height(28)
          .onClick(() => {
            KimiServer.get().setDebugEnabled(false);
            this.debugEnabled = false;
            this.restartService();
          })
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor($r('app.color.start_window_background'))
  }

  @Builder
  ReadyLogPanel() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('服务日志')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button('刷新')
          .fontSize(13)
          .height(30)
          .onClick(() => {
            this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
          })
        Button('关闭')
          .fontSize(13)
          .height(30)
          .type(ButtonType.Normal)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.logExpanded = false;
          })
      }
      .width('100%')

      Scroll() {
        Text(this.logTail === '' ? '（暂无日志）' : this.logTail)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('sys.color.font_secondary'))
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .padding(12)
      .borderRadius(8)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .initialOffset({ yOffset: 1000000 })
      Text(`日志文件：${KimiServer.get().logPath}`)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor($r('app.color.start_window_background'))
  }

  @Builder
  WarningBanner() {
    Row({ space: 12 }) {
      Text(this.warning)
        .fontSize(13)
        .fontColor('#5C3B00')
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
      Button('知道了')
        .fontSize(13)
        .height(28)
        .backgroundColor('#E8B44A')
        .fontColor('#3A2600')
        .onClick(() => {
          this.warning = '';
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor('#FFE7A8')
  }

  @Builder
  StatusPanel() {
    Column({ space: 16 }) {
      Text('Kimi Code')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(`HarmonyOS PC 外壳 · kimi-code ${KIMI_CODE_VERSION} · node ${NODE_VERSION}`)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))

      if (this.phase === ServerPhase.STARTING || this.phase === ServerPhase.IDLE ||
        this.phase === ServerPhase.STOPPING) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color($r('sys.color.font_secondary'))
      }

      Text(this.message === '' ? '准备中…' : this.message)
        .fontSize(15)
        .textAlign(TextAlign.Center)
        .fontColor(this.phase === ServerPhase.FAILED ? Color.Red : $r('sys.color.font_primary'))
        .copyOption(CopyOptions.LocalDevice)
        .constraintSize({ maxWidth: 720 })

      Row({ space: 12 }) {
        if (this.phase === ServerPhase.FAILED || this.phase === ServerPhase.IDLE) {
          Button('重新启动服务')
            .onClick(() => {
              this.restartService();
            })
          Button(this.debugEnabled ? '关闭调试日志并重启' : '开启调试日志并重启')
            .type(ButtonType.Normal)
            .borderRadius(8)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .fontColor($r('sys.color.font_primary'))
            .onClick(() => {
              this.debugEnabled = !this.debugEnabled;
              KimiServer.get().setDebugEnabled(this.debugEnabled);
              this.restartService();
            })
        }
        Button(this.logExpanded ? '收起日志' : '查看日志')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.logExpanded = !this.logExpanded;
            this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
          })
      }

      if (this.logExpanded) {
        Scroll() {
          Text(this.logTail === '' ? '（暂无日志）' : this.logTail)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor($r('sys.color.font_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
        }
        .width('100%')
        .height(320)
        .padding(12)
        .borderRadius(8)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .constraintSize({ maxWidth: 900 })
        .initialOffset({ yOffset: 1000000 })
        Text(`日志文件：${KimiServer.get().logPath}`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .height('100%')
    .padding(32)
    .justifyContent(FlexAlign.Center)
  }
}
