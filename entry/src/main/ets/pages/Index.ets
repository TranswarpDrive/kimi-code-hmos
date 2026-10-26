import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { isOpenableExternally, openExternal } from '../kimi/ExternalLink';
import { FileActions } from '../kimi/FileActions';
import { KimiServer, ServerPhase, ServerStatus } from '../kimi/KimiServer';
import { Log } from '../kimi/Log';
import { KIMI_CODE_VERSION, NODE_VERSION } from '../kimi/RuntimeInfo';
import { UpdatePhase, UpdateStatus } from '../kimi/RuntimeUpdates';
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
  @State kimiVersion: string = KIMI_CODE_VERSION;
  @State updateExpanded: boolean = false;
  @State updateConfirm: boolean = false;
  @State restoreConfirm: boolean = false;
  @State updateLogExpanded: boolean = false;
  @State updatePhase: UpdatePhase = UpdatePhase.IDLE;
  @State updateLatest: string = '';
  @State updateCandidate: string = '';
  @State updateActive: string = '';
  @State updateMessage: string = '';
  @State updateError: string = '';
  @State updateLogTail: string = '';
  @State updateAvailable: boolean = false;
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
  private unsubscribeUpdates: (() => void) | null = null;
  private logTimer: number = -1;
  private webReady: boolean = false;
  private webStale: boolean = false;

  aboutToAppear(): void {
    this.debugEnabled = KimiServer.get().isDebugEnabled();
    this.workspace = KimiServer.get().defaultWorkspace();
    this.kimiVersion = KimiServer.get().currentKimiVersion();
    this.unsubscribe = KimiServer.get().subscribe((status: ServerStatus) => {
      this.onStatus(status);
    });
    this.unsubscribeUpdates = KimiServer.get().updates.subscribe((status: UpdateStatus) => {
      this.onUpdateStatus(status);
    });
    this.logTimer = setInterval(() => {
      if (this.phase !== ServerPhase.READY || this.logExpanded) {
        this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
      }
      if (this.updateExpanded && (this.updatePhase !== UpdatePhase.IDLE || this.updateLogExpanded)) {
        this.updateLogTail = KimiServer.get().updates.readLogTail(LOG_TAIL_BYTES);
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
    if (this.unsubscribeUpdates !== null) {
      this.unsubscribeUpdates();
      this.unsubscribeUpdates = null;
    }
    clearInterval(this.logTimer);
  }

  private onStatus(status: ServerStatus): void {
    this.phase = status.phase;
    this.message = status.message;
    this.warning = status.warning;
    this.kimiVersion = KimiServer.get().currentKimiVersion();
    this.bridge.setShellInfo(JSON.stringify({ shell: 'kimi-code-hmos', kimi: this.kimiVersion, node: NODE_VERSION }));
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

  private onUpdateStatus(status: UpdateStatus): void {
    this.updatePhase = status.phase;
    this.updateLatest = status.latestVersion;
    this.updateCandidate = status.candidateVersion;
    this.updateActive = status.activeVersion;
    this.updateMessage = status.message;
    this.updateError = status.error;
    this.updateAvailable = status.updateAvailable;
    if (this.updateExpanded && (status.phase !== UpdatePhase.IDLE || status.error !== '')) {
      this.updateLogTail = KimiServer.get().updates.readLogTail(LOG_TAIL_BYTES);
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

  private openUpdates(): void {
    this.updateConfirm = false;
    this.restoreConfirm = false;
    this.updateLogTail = KimiServer.get().updates.readLogTail(LOG_TAIL_BYTES);
    this.updateExpanded = true;
  }

  private async checkUpdates(): Promise<void> {
    try {
      await KimiServer.get().updates.check();
    } catch (err) {
      Log.warn(`check updates failed: ${String(err)}`);
    }
  }

  private async restartUpdatedService(): Promise<void> {
    const server = KimiServer.get();
    await server.restart();
    this.kimiVersion = server.currentKimiVersion();
    if (server.getStatus().phase === ServerPhase.READY) {
      this.notify(`正在运行 Kimi Code ${this.kimiVersion}`);
    } else {
      this.notify(server.getStatus().message);
    }
  }

  private async performUpdate(): Promise<void> {
    const version = this.updateLatest;
    this.updateConfirm = false;
    try {
      await KimiServer.get().updates.install(version);
      await KimiServer.get().updates.activate(version);
      await this.restartUpdatedService();
    } catch (err) {
      Log.warn(`install update failed: ${String(err)}`);
      this.notify(`更新未完成：${String(err)}`);
    }
  }

  private async applyCandidate(): Promise<void> {
    const version = this.updateCandidate;
    try {
      await KimiServer.get().updates.activate(version);
      await this.restartUpdatedService();
    } catch (err) {
      this.notify(`无法应用已下载版本：${String(err)}`);
    }
  }

  private async restoreBundled(): Promise<void> {
    this.restoreConfirm = false;
    try {
      await KimiServer.get().updates.restore();
      await this.restartUpdatedService();
    } catch (err) {
      this.notify(`恢复随包版本失败：${String(err)}`);
    }
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
        if (this.updateExpanded) {
          this.UpdatePanel()
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
      Button(this.updateAvailable ? '有更新' : '更新')
        .fontSize(12)
        .height(28)
        .type(ButtonType.Normal)
        .borderRadius(6)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.openUpdates();
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
  UpdatePanel() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Text('Kimi Code 运行时更新')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button('关闭')
          .height(30)
          .type(ButtonType.Normal)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.updateConfirm = false;
            this.restoreConfirm = false;
            this.updateExpanded = false;
          })
      }
      .width('100%')

      Text(`随包版本 ${KIMI_CODE_VERSION} · 当前运行 ${this.kimiVersion} · 官方最新 ${this.updateLatest || '尚未检查'}`)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .copyOption(CopyOptions.LocalDevice)
      Text('CLI 与 WebUI 来自同一个官方 npm 包。下载和校验期间当前服务继续运行；此功能不更新 HAP 外壳或 Node。')
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(this.updateMessage)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .copyOption(CopyOptions.LocalDevice)

      if (this.updatePhase !== UpdatePhase.IDLE) {
        Row({ space: 12 }) {
          LoadingProgress()
            .width(24)
            .height(24)
          Text('请保持应用打开；关闭应用会取消未完成的更新，不会切换版本。')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      if (this.updateError !== '') {
        Text(this.updateError)
          .fontSize(13)
          .fontColor(Color.Red)
          .copyOption(CopyOptions.LocalDevice)
      }
      if (this.updateConfirm) {
        Text('再次点击确认：下载完成后将激活新版并重启 Kimi 服务。请先保存或完成正在执行的任务；项目文件、登录状态、已有会话和目录授权不会被清除。')
          .fontSize(14)
          .fontColor('#5C3B00')
          .padding(12)
          .borderRadius(8)
          .backgroundColor('#FFE7A8')
      }
      if (this.restoreConfirm) {
        Text('再次点击确认：恢复随包版本并重启 Kimi 服务。项目文件、登录状态和已有会话不会被清除。')
          .fontSize(14)
          .fontColor('#5C3B00')
          .padding(12)
          .borderRadius(8)
          .backgroundColor('#FFE7A8')
      }

      Row({ space: 12 }) {
        Button('检查更新')
          .enabled(this.updatePhase === UpdatePhase.IDLE && this.phase !== ServerPhase.STARTING &&
            this.phase !== ServerPhase.STOPPING)
          .onClick(() => {
            this.updateConfirm = false;
            this.checkUpdates();
          })
        if (this.updateAvailable && this.updateLatest !== '' && this.updateLatest !== this.kimiVersion) {
          Button(this.updateConfirm ? '确认下载并重启' : '下载并更新')
            .enabled(this.updatePhase === UpdatePhase.IDLE && this.phase !== ServerPhase.STARTING &&
              this.phase !== ServerPhase.STOPPING)
            .onClick(() => {
              if (this.updateConfirm) {
                this.performUpdate();
              } else {
                this.updateConfirm = true;
              }
            })
        }
        if (this.updateCandidate !== '' && this.updateCandidate !== this.kimiVersion) {
          Button('应用已下载版本')
            .enabled(this.updatePhase === UpdatePhase.IDLE && this.phase !== ServerPhase.STARTING &&
              this.phase !== ServerPhase.STOPPING)
            .onClick(() => {
              this.applyCandidate();
            })
        }
        if (this.updateActive !== '') {
          Button(this.restoreConfirm ? '确认恢复随包' : '恢复随包版本')
            .enabled(this.updatePhase === UpdatePhase.IDLE && this.phase !== ServerPhase.STARTING &&
              this.phase !== ServerPhase.STOPPING)
            .type(ButtonType.Normal)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .fontColor($r('sys.color.font_primary'))
            .onClick(() => {
              if (this.restoreConfirm) {
                this.restoreBundled();
              } else {
                this.restoreConfirm = true;
              }
            })
        }
      }

      Button(this.updateLogExpanded ? '收起更新日志' : '查看更新日志')
        .type(ButtonType.Normal)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.updateLogExpanded = !this.updateLogExpanded;
          this.updateLogTail = KimiServer.get().updates.readLogTail(LOG_TAIL_BYTES);
        })
      if (this.updateLogExpanded || this.updateError !== '') {
        Scroll() {
          Text(this.updateLogTail === '' ? '（暂无更新日志）' : this.updateLogTail)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor($r('sys.color.font_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
        }
        .width('100%')
        .height(220)
        .padding(12)
        .borderRadius(8)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .initialOffset({ yOffset: 1000000 })
      }
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .backgroundColor($r('app.color.start_window_background'))
  }

  @Builder
  StatusPanel() {
    Column({ space: 16 }) {
      Text('Kimi Code')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(`HarmonyOS PC 外壳 · kimi-code ${this.kimiVersion} · node ${NODE_VERSION}`)
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
        Button('运行时更新')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.openUpdates();
          })
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
