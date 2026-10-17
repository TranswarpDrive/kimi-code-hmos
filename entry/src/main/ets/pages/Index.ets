import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { isOpenableExternally, openExternal } from '../kimi/ExternalLink';
import { KimiServer, ServerPhase, ServerStatus } from '../kimi/KimiServer';
import { Log } from '../kimi/Log';
import { KIMI_CODE_VERSION, NODE_VERSION } from '../kimi/RuntimeInfo';
import { BRIDGE_METHODS, BRIDGE_NAME, DOCUMENT_START_SCRIPT, KimiHostBridge } from '../kimi/WebBridge';

const LOG_TAIL_BYTES: number = 6000;

@Entry
@Component
struct Index {
  @State phase: ServerPhase = ServerPhase.IDLE;
  @State message: string = '';
  @State webUrl: string = '';
  @State logTail: string = '';
  @State logExpanded: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: KimiHostBridge = new KimiHostBridge((url: string) => {
    this.openOutside(url);
  }, JSON.stringify({ shell: 'kimi-code-hmos', kimi: KIMI_CODE_VERSION, node: NODE_VERSION }));
  private scripts: ScriptItem[] = [{ script: DOCUMENT_START_SCRIPT, scriptRules: ['*'] }];
  private origin: string = '';
  private unsubscribe: (() => void) | null = null;
  private logTimer: number = -1;
  private webReady: boolean = false;

  aboutToAppear(): void {
    this.unsubscribe = KimiServer.get().subscribe((status: ServerStatus) => {
      this.onStatus(status);
    });
    this.logTimer = setInterval(() => {
      if (this.phase !== ServerPhase.READY) {
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
    if (status.phase === ServerPhase.FAILED) {
      this.logTail = KimiServer.get().readLogTail(LOG_TAIL_BYTES);
      this.logExpanded = true;
    }
    if (status.phase !== ServerPhase.READY || status.url === this.webUrl) {
      return;
    }
    this.origin = `http://127.0.0.1:${status.port}`;
    const first = this.webUrl === '';
    this.webUrl = status.url;
    if (!first && this.webReady) {
      // 服务重启后端口/地址可能变化，Web 组件已存在时需要主动加载
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

  private isExternal(url: string): boolean {
    if (!isOpenableExternally(url)) {
      return false; // blob:、data:、about: 等留在 WebView 内
    }
    return this.origin === '' || !(url === this.origin || url.startsWith(`${this.origin}/`));
  }

  build() {
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
            controller: this.controller
          })
          .onControllerAttached(() => {
            this.webReady = true;
          })
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            const target = event.data.getRequestUrl();
            if (event.data.isMainFrame() && this.isExternal(target)) {
              this.openOutside(target);
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
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
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
              KimiServer.get().restart();
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
