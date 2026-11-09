import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
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

interface ShellInfo {
  shell: string;
  kimi: string;
  node: string;
}

function shellInfo(version: string): string {
  const info: ShellInfo = { shell: 'kimi-code-hmos', kimi: version, node: NODE_VERSION };
  return JSON.stringify(info);
}

@Extend(Button)
function shellButton(primary: boolean = false, text: boolean = false) {
  .type(ButtonType.Normal)
  .height(32)
  .borderRadius(8)
  .fontSize(13)
  .fontColor(primary ? Color.White : $r('sys.color.font_primary'))
  .backgroundColor(primary ? $r('sys.color.brand') :
    (text ? Color.Transparent : $r('app.color.shell_hover')))
  .padding({ left: 12, right: 12 })
}

@Extend(Button)
function shellIconButton() {
  .type(ButtonType.Normal)
  .width(28)
  .height(28)
  .padding(0)
  .borderRadius(6)
  .stateStyles({
    normal: { .backgroundColor(Color.Transparent) },
    hovered: { .backgroundColor($r('app.color.shell_hover')) }
  })
}

@Extend(Text)
function shellLogText() {
  .fontFamily('monospace')
  .fontSize(11)
  .lineHeight(16)
  .fontColor($r('sys.color.font_secondary'))
  .copyOption(CopyOptions.LocalDevice)
  .width('100%')
}

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
  @State updateLogExpanded: boolean = false;
  @State updatePhase: UpdatePhase = UpdatePhase.IDLE;
  @State updateLatest: string = '';
  @State updateCandidate: string = '';
  @State updateActive: string = '';
  @State updateMessage: string = '';
  @State updateError: string = '';
  @State updateLogTail: string = '';
  @State updateAvailable: boolean = false;
  @StorageLink('shellTitleButtonWidth') titleButtonWidth: number = 0;
  private logScroller: Scroller = new Scroller();
  private updateLogScroller: Scroller = new Scroller();
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: KimiHostBridge = new KimiHostBridge((url: string) => {
    this.openOutside(url);
  }, (name: string, base64: string) => {
    this.saveBlob(name, base64);
  }, shellInfo(KIMI_CODE_VERSION), (message: string) => {
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
    this.logTimer = setInterval((): void => {
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
    this.bridge.setShellInfo(shellInfo(this.kimiVersion));
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
    try {
      await KimiServer.get().updates.restore();
      await this.restartUpdatedService();
    } catch (err) {
      this.notify(`恢复随包版本失败：${String(err)}`);
    }
  }

  private workspaceName(): string {
    if (this.workspace === `${this.context().filesDir}/workspace`) {
      return '默认工作区';
    }
    if (this.workspace === '/storage/Users/currentUser/Documents') {
      return '文档';
    }
    if (this.workspace === '/storage/Users/currentUser/Download') {
      return '下载';
    }
    if (this.workspace === '/storage/Users/currentUser/Desktop') {
      return '桌面';
    }
    return this.workspace.substring(this.workspace.lastIndexOf('/') + 1);
  }

  private isDefaultWorkspace(): boolean {
    return this.workspace === '/storage/Users/currentUser/Documents' ||
      this.workspace === `${this.context().filesDir}/workspace`;
  }

  private serviceActionsEnabled(): boolean {
    return this.updatePhase === UpdatePhase.IDLE && this.phase !== ServerPhase.STARTING &&
      this.phase !== ServerPhase.STOPPING;
  }

  private refreshLogs(): void {
    this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
    setTimeout((): void => this.logScroller.scrollEdge(Edge.Bottom), 0);
  }

  private toggleLogs(): void {
    this.logExpanded = !this.logExpanded;
    if (this.logExpanded) {
      this.refreshLogs();
    }
  }

  private confirmUpdate(restore: boolean): void {
    const cancel: AlertDialogButtonBaseOptions = {
      value: '取消', fontColor: $r('sys.color.font_primary'), defaultFocus: true, action: () => {}
    };
    const confirm: AlertDialogButtonBaseOptions = {
      value: restore ? '恢复并重启' : '更新并重启',
      fontColor: Color.White,
      backgroundColor: $r('sys.color.brand'),
      action: () => {
        if (restore) {
          this.restoreBundled();
        } else {
          this.performUpdate();
        }
      }
    };
    const options: AlertDialogParamWithButtons = {
      title: restore ? '恢复随包版本？' : '下载并更新？',
      message: restore ?
        '恢复随包版本并重启 Kimi 服务。项目文件、登录状态和已有会话不会被清除。' :
        '下载完成后将激活新版并重启 Kimi 服务。请先保存或完成正在执行的任务；项目文件、登录状态、已有会话和目录授权不会被清除。',
      primaryButton: cancel,
      secondaryButton: confirm
    };
    this.getUIContext().showAlertDialog(options);
  }

  private updateActionText(): string {
    if (this.updateCandidate !== '' && this.updateCandidate !== this.kimiVersion) {
      return '应用已下载版本';
    }
    if (this.updateAvailable && this.updateLatest !== '' && this.updateLatest !== this.kimiVersion) {
      return '下载并更新';
    }
    return '检查更新';
  }

  private updateAction(): void {
    if (this.updateCandidate !== '' && this.updateCandidate !== this.kimiVersion) {
      this.applyCandidate();
    } else if (this.updateAvailable && this.updateLatest !== '' && this.updateLatest !== this.kimiVersion) {
      this.confirmUpdate(false);
    } else {
      this.checkUpdates();
    }
  }

  build() {
    Stack() {
      Column() {
        this.ShellTitleBar()
        Stack() {
          Column() {
            if (this.warning !== '') {
              this.WarningBanner()
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
              }
            }
            .width('100%')
            .layoutWeight(1)
          }
          .width('100%')
          .height('100%')
          if (this.phase === ServerPhase.READY && this.logExpanded) {
            this.ReadyLogPanel()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .alignContent(Alignment.TopEnd)
      }
      .width('100%')
      .height('100%')
      .enabled(!this.updateExpanded)
      if (this.updateExpanded) {
        this.UpdatePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.shell_bg'))
    .onKeyEventDispatch((event: KeyEvent) => {
      if (this.updateExpanded && event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.updateExpanded = false;
        return true;
      }
      return false;
    })
  }

  @Builder
  ShellTitleBar() {
    Row() {
      Image($r('app.media.startIcon'))
        .width(16)
        .height(16)
        .margin({ right: 10 })
      Button() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(14)
            .fontColor([$r('sys.color.font_secondary')])
          Text(this.workspaceName())
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
        }
      }
      .type(ButtonType.Normal)
      .height(26)
      .constraintSize({ maxWidth: 320 })
      .flexShrink(1)
      .padding({ left: 8, right: 8 })
      .borderRadius(6)
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        hovered: { .backgroundColor($r('app.color.shell_hover')) }
      })
      .enabled(this.phase === ServerPhase.READY && this.serviceActionsEnabled())
      .onClick(() => this.chooseWorkspace())
      Blank()
      Stack({ alignContent: Alignment.TopEnd }) {
        Button() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .shellIconButton()
        .accessibilityText('更多')
        .bindMenu(this.ShellMenu(), { placement: Placement.BottomRight })
        if (this.updateAvailable) {
          Circle()
            .width(6)
            .height(6)
            .fill($r('sys.color.brand'))
            .hitTestBehavior(HitTestMode.None)
        }
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: this.titleButtonWidth + 12 })
    .backgroundColor($r('app.color.shell_bg'))
  }

  @Builder
  ShellMenu() {
    Menu() {
      MenuItemGroup() {
      MenuItem() {
        Text(this.workspace)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .ellipsisMode(EllipsisMode.CENTER)
          .padding({
            left: $r('sys.float.menu_item_hor_interval'), right: $r('sys.float.menu_item_hor_interval'),
            top: 8, bottom: 4
          })
      }
      .enabled(false)
      if (this.phase === ServerPhase.READY && this.serviceActionsEnabled()) {
        MenuItem({ content: '更换工作目录…' })
          .onClick(() => this.chooseWorkspace())
        MenuItem({ content: '恢复默认工作目录' })
          .enabled(!this.isDefaultWorkspace())
          .onClick(() => this.resetWorkspace())
      }
      }
      // 菜单组之间由系统自动绘制分隔线。
      MenuItemGroup() {
      MenuItem({ content: '运行时更新…', labelInfo: this.updateAvailable ? '有新版本' : '' })
        .labelFont({ size: 12 })
        .labelFontColor($r('sys.color.brand'))
        .onClick(() => this.openUpdates())
      if (this.serviceActionsEnabled()) {
        MenuItem({ content: '重启服务' })
          .onClick(() => this.restartService())
      }
      MenuItem({ content: '查看日志' })
        .onClick(() => {
          this.logExpanded = true;
          this.refreshLogs();
        })
      if (this.debugEnabled && this.serviceActionsEnabled()) {
        MenuItem({ content: '关闭调试日志' })
          .onClick(() => {
            KimiServer.get().setDebugEnabled(false);
            this.debugEnabled = false;
            this.restartService();
          })
      }
      }
    }
    .fontSize(13)
    .fontColor($r('sys.color.font_primary'))
    .backgroundColor($r('app.color.shell_surface'))
    .constraintSize({ maxWidth: 400 })
  }

  @Builder
  ServiceLog(maxHeight: number) {
    Scroll(this.logScroller) {
      Text(this.logTail === '' ? '（暂无日志）' : this.logTail)
        .shellLogText()
    }
    .width('100%')
    .constraintSize({ maxHeight: maxHeight })
    .padding(12)
    .onAppear(() => this.refreshLogs())
  }

  @Builder
  ReadyLogPanel() {
    Column() {
      Row({ space: 4 }) {
        Text('服务日志')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_primary')])
        }
        .shellIconButton()
        .accessibilityText('刷新日志')
        .onClick(() => this.refreshLogs())
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_primary')])
        }
        .shellIconButton()
        .accessibilityText('关闭日志')
        .onClick(() => { this.logExpanded = false; })
      }
      .height(44)
      .width('100%')
      .padding({ left: 16, right: 12 })
      Scroll(this.logScroller) {
        Text(this.logTail === '' ? '（暂无日志）' : this.logTail)
          .shellLogText()
      }
      .width('100%')
      .layoutWeight(1)
      .padding(12)
      .onAppear(() => this.refreshLogs())
      Text(KimiServer.get().logPath)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
        .copyOption(CopyOptions.LocalDevice)
        .width('100%')
        .padding(12)
    }
    .width('45%')
    .constraintSize({ maxWidth: 560 })
    .height('100%')
    .backgroundColor($r('app.color.shell_surface'))
    .border({ width: { left: '1px' }, color: $r('app.color.shell_border') })
  }

  @Builder
  WarningBackground() {
    Row() {}
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.warning'))
      .opacity(0.12)
  }

  @Builder
  WarningBanner() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(16)
        .fontColor([$r('sys.color.warning')])
      Text(this.warning)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
      Button('知道了')
        .shellButton(false, true)
        .onClick(() => { this.warning = ''; })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 4, bottom: 4 })
    .background(this.WarningBackground())
  }

  @Builder
  VersionRow(label: string, version: string) {
    Row() {
      Text(label)
        .width(72)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(version)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .copyOption(CopyOptions.LocalDevice)
        .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  UpdatePanel() {
    Stack() {
      Row() {}
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
      Column({ space: 16 }) {
        Row() {
          Text('运行时更新')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(16)
              .fontColor([$r('sys.color.font_primary')])
          }
          .shellIconButton()
          .id('runtimeUpdateClose')
          .defaultFocus(true)
          .accessibilityText('关闭运行时更新')
          .onClick(() => { this.updateExpanded = false; })
        }
        .width('100%')
        Column({ space: 8 }) {
          this.VersionRow('随包版本', KIMI_CODE_VERSION)
          this.VersionRow('当前运行', this.kimiVersion)
          this.VersionRow('官方最新', this.updateLatest === '' ? '尚未检查' : this.updateLatest)
        }
        Text('CLI 与 WebUI 来自同一个官方 npm 包。下载和校验期间当前服务继续运行；此功能不更新 HAP 外壳或 Node。')
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
        if (this.updateMessage !== '') {
          Text(this.updateMessage)
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
        }
        if (this.updatePhase !== UpdatePhase.IDLE) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('sys.color.font_secondary'))
            Text('请保持应用打开；关闭应用会取消未完成的更新，不会切换版本。')
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
              .layoutWeight(1)
          }
          .width('100%')
        }
        if (this.updateError !== '') {
          Text(this.updateError)
            .fontSize(13)
            .fontColor($r('sys.color.alert'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
        }
        if (this.updateLogExpanded || this.updateError !== '') {
          Scroll(this.updateLogScroller) {
            Text(this.updateLogTail === '' ? '（暂无更新日志）' : this.updateLogTail)
              .shellLogText()
          }
          .width('100%')
          .constraintSize({ maxHeight: 200 })
          .onAppear(() => {
            setTimeout((): void => this.updateLogScroller.scrollEdge(Edge.Bottom), 0);
          })
        }
        Flex({ justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center, wrap: FlexWrap.Wrap }) {
          Button('更新日志')
            .shellButton(false, true)
            .onClick(() => {
              this.updateLogExpanded = !this.updateLogExpanded;
              this.updateLogTail = KimiServer.get().updates.readLogTail(LOG_TAIL_BYTES);
            })
          Row({ space: 8 }) {
            if (this.updateActive !== '') {
              Button('恢复随包版本')
                .shellButton()
                .enabled(this.serviceActionsEnabled())
                .onClick(() => this.confirmUpdate(true))
            }
            Button(this.updateActionText())
              .shellButton(true)
              .enabled(this.serviceActionsEnabled())
              .onClick(() => this.updateAction())
          }
        }
        .width('100%')
      }
      .width('92%')
      .constraintSize({ maxWidth: 480 })
      .padding(24)
      .borderRadius(12)
      .backgroundColor($r('app.color.shell_surface'))
      .border({ width: '1px', color: $r('app.color.shell_border') })
      .shadow({ radius: 16, color: '#14000000', offsetY: 4 })
      .zIndex(1)
      .focusScopeId('runtimeUpdate', true)
      .onAppear(() => {
        this.getUIContext().getFocusController().requestFocus('runtimeUpdateClose');
      })
    }
    .width('100%')
    .height('calc(100% - 40vp)')
    .position({ x: 0, y: 40 })
    .zIndex(1)
    .onClick((): void => {})
  }

  @Builder
  StatusPanel() {
    Column() {
      Blank()
      Column() {
        Image($r('app.media.startIcon'))
          .width(48)
          .height(48)
          .margin({ bottom: 16 })
        Text('Kimi Code')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .margin({ bottom: 8 })
        Text(this.message === '' ? '准备中…' : this.message)
          .fontSize(14)
          .textAlign(TextAlign.Center)
          .fontColor(this.phase === ServerPhase.FAILED ? $r('sys.color.alert') : $r('sys.color.font_secondary'))
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
        if (this.phase === ServerPhase.STARTING || this.phase === ServerPhase.IDLE ||
          this.phase === ServerPhase.STOPPING) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color($r('sys.color.font_secondary'))
            .margin({ top: 16 })
        }
        if (this.phase === ServerPhase.FAILED || this.phase === ServerPhase.IDLE) {
          Flex({ justifyContent: FlexAlign.Center, wrap: FlexWrap.Wrap }) {
            Button('重新启动服务')
              .shellButton(true)
              .enabled(this.serviceActionsEnabled())
              .margin(4)
              .onClick(() => this.restartService())
            Button(this.debugEnabled ? '关闭调试日志并重启' : '开启调试日志并重启')
              .shellButton()
              .enabled(this.serviceActionsEnabled())
              .margin(4)
              .onClick(() => {
                this.debugEnabled = !this.debugEnabled;
                KimiServer.get().setDebugEnabled(this.debugEnabled);
                this.restartService();
              })
            Button('运行时更新')
              .shellButton()
              .margin(4)
              .onClick(() => this.openUpdates())
            Button(this.logExpanded ? '收起日志' : '查看日志')
              .shellButton()
              .margin(4)
              .onClick(() => this.toggleLogs())
          }
          .width('100%')
          .margin({ top: 16 })
        }
        if (this.logExpanded) {
          this.ServiceLog(280)
        }
      }
      .width('92%')
      .constraintSize({ maxWidth: 480 })
      Blank()
      Text(`HarmonyOS PC 外壳 · kimi-code ${this.kimiVersion} · node ${NODE_VERSION}`)
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .textAlign(TextAlign.Center)
        .margin({ top: 16, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.shell_bg'))
  }
}
