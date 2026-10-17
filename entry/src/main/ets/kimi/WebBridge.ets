/**
 * ArkWeb 与 kimi Web UI 之间的桥：
 *  - KimiHostBridge 以 `window.kimiHost` 暴露给页面（javaScriptProxy）
 *  - DOCUMENT_START_SCRIPT 在每个文档开始时注入，接管 window.open 与外链点击
 *
 * kimi Web 打开外链有两种写法：window.open(url, '_blank', 'noopener')；
 * 以及先 window.open('', '_blank') 拿到窗口、稍后再设置 location.href（防弹窗拦截）。
 * 注入脚本返回一个“假窗口”，在拿到真实 URL 时转交 kimiHost.openExternal → 系统浏览器。
 */

export const BRIDGE_NAME: string = 'kimiHost';
export const BRIDGE_METHODS: string[] = ['openExternal', 'shellInfo'];

export class KimiHostBridge {
  private onOpenExternal: (url: string) => void;
  private info: string;

  constructor(onOpenExternal: (url: string) => void, info: string) {
    this.onOpenExternal = onOpenExternal;
    this.info = info;
  }

  openExternal(url: string): void {
    this.onOpenExternal(String(url));
  }

  shellInfo(): string {
    return this.info;
  }
}

export const DOCUMENT_START_SCRIPT: string = `
(function () {
  if (window.__kimiHmosShell) { return; }
  window.__kimiHmosShell = true;
  var ORIGIN = location.origin;

  function resolve(url) {
    try { return new URL(String(url), location.href); } catch (e) { return null; }
  }
  function isExternal(url) {
    var u = resolve(url);
    if (!u) { return false; }
    if (u.protocol === 'mailto:') { return true; }
    return (u.protocol === 'http:' || u.protocol === 'https:') && u.origin !== ORIGIN;
  }
  function openExternal(url) {
    var u = resolve(url);
    if (!u) { return false; }
    var host = window.${BRIDGE_NAME};
    if (host && typeof host.openExternal === 'function') {
      host.openExternal(u.href);
      return true;
    }
    console.warn('[kimi-hmos] bridge not ready, cannot open ' + u.href);
    return false;
  }
  function fakeWindow() {
    var opened = false;
    var current = 'about:blank';
    function go(url) {
      if (opened || url === undefined || url === null || url === '' || url === 'about:blank') { return; }
      current = String(url);
      if (isExternal(url)) {
        opened = true;
        openExternal(url);
      } else {
        console.warn('[kimi-hmos] new window for in-app url is not supported: ' + url);
      }
    }
    var loc = {
      assign: go,
      replace: go,
      reload: function () {},
      toString: function () { return current; }
    };
    Object.defineProperty(loc, 'href', { get: function () { return current; }, set: go });
    var win = {
      closed: false,
      opener: null,
      name: '',
      focus: function () {},
      blur: function () {},
      postMessage: function () {},
      close: function () { win.closed = true; },
      document: { write: function () {}, writeln: function () {}, open: function () {}, close: function () {} }
    };
    Object.defineProperty(win, 'location', { get: function () { return loc; }, set: go });
    return { win: win, go: go };
  }

  var nativeOpen = window.open;
  window.open = function (url, target, features) {
    var href = (url === undefined || url === null) ? '' : String(url);
    if (href === '' || href === 'about:blank' || isExternal(href)) {
      var fake = fakeWindow();
      fake.go(href);
      return fake.win;
    }
    return nativeOpen.call(window, url, target, features);
  };

  document.addEventListener('click', function (event) {
    if (event.defaultPrevented || event.button !== 0) { return; }
    var node = event.target;
    var anchor = node && node.closest ? node.closest('a[href]') : null;
    if (!anchor || anchor.hasAttribute('download')) { return; }
    if (isExternal(anchor.href)) {
      event.preventDefault();
      event.stopPropagation();
      openExternal(anchor.href);
    }
  }, true);
})();
`;
