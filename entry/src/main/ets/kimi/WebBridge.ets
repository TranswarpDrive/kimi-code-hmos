/**
 * ArkWeb 与 kimi Web UI 之间的桥：
 *  - KimiHostBridge 以 `window.kimiHost` 暴露外链与 blob 下载方法（javaScriptProxy）
 *  - DOCUMENT_START_SCRIPT 接管 window.open、外链点击、blob 下载与 blob 文件预览
 *
 * kimi Web 打开外链有两种写法：window.open(url, '_blank', 'noopener')；
 * 以及先 window.open('', '_blank') 拿到窗口、稍后再设置 location.href（防弹窗拦截）。
 * 注入脚本返回一个“假窗口”：外链交给系统浏览器，blob 地址在当前文档显示预览层。
 */

export const BRIDGE_NAME: string = 'kimiHost';
export const BRIDGE_METHODS: string[] = ['openExternal', 'downloadBlob', 'shellInfo'];

export type BlobDownloadHandler = (name: string, base64: string) => void;

export class KimiHostBridge {
  private onOpenExternal: (url: string) => void;
  private onDownloadBlob: BlobDownloadHandler;
  private info: string;

  constructor(onOpenExternal: (url: string) => void, onDownloadBlob: BlobDownloadHandler, info: string) {
    this.onOpenExternal = onOpenExternal;
    this.onDownloadBlob = onDownloadBlob;
    this.info = info;
  }

  openExternal(url: string): void {
    this.onOpenExternal(String(url));
  }

  downloadBlob(name: string, base64: string): void {
    this.onDownloadBlob(String(name), String(base64));
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
  function isBlob(url) {
    var u = resolve(url);
    return !!u && u.protocol === 'blob:';
  }
  function blobExtension(type) {
    var mime = String(type || '').split(';')[0].toLowerCase();
    var extensions = {
      'application/pdf': 'pdf',
      'application/zip': 'zip',
      'application/json': 'json',
      'text/markdown': 'md',
      'text/plain': 'txt'
    };
    if (extensions[mime]) { return extensions[mime]; }
    if (mime.indexOf('image/') === 0) {
      return mime.substring(6).replace('svg+xml', 'svg').replace('jpeg', 'jpg');
    }
    return '';
  }
  function downloadBlob(url, name) {
    var host = window.${BRIDGE_NAME};
    if (!host || typeof host.downloadBlob !== 'function') {
      console.warn('[kimi-hmos] bridge not ready, cannot download blob');
      return;
    }
    var suggested = String(name || '').trim() || ('download-' + Date.now());
    fetch(url).then(function (response) {
      if (!response.ok) { throw new Error('HTTP ' + response.status); }
      return response.blob();
    }).then(function (blob) {
      if (suggested.lastIndexOf('.') < 0) {
        var extension = blobExtension(blob.type);
        if (extension) { suggested += '.' + extension; }
      }
      var reader = new FileReader();
      reader.onload = function () {
        var dataUrl = String(reader.result || '');
        var comma = dataUrl.indexOf(',');
        if (comma < 0) {
          console.warn('[kimi-hmos] invalid blob data URL');
          return;
        }
        host.downloadBlob(suggested, dataUrl.substring(comma + 1));
      };
      reader.onerror = function () { console.warn('[kimi-hmos] cannot read blob'); };
      reader.readAsDataURL(blob);
    }).catch(function (err) {
      console.warn('[kimi-hmos] blob download failed: ' + String(err));
    });
  }
  function openPreview(url) {
    var overlay = document.createElement('div');
    overlay.setAttribute('data-kimi-hmos-preview', '');
    overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#111;display:flex;flex-direction:column;';
    var toolbar = document.createElement('div');
    toolbar.style.cssText = 'height:48px;flex:0 0 48px;display:flex;align-items:center;gap:8px;padding:0 16px;box-sizing:border-box;background:#252525;color:#fff;font:14px sans-serif;';
    var title = document.createElement('span');
    title.textContent = '文件预览';
    title.style.cssText = 'flex:1 1 auto;';
    var downloadButton = document.createElement('button');
    downloadButton.textContent = '下载';
    downloadButton.style.cssText = 'border:0;border-radius:6px;padding:6px 18px;background:#444;color:#fff;cursor:pointer;';
    var closeButton = document.createElement('button');
    closeButton.textContent = '关闭';
    closeButton.style.cssText = downloadButton.style.cssText;
    var frame = document.createElement('iframe');
    frame.src = url;
    frame.style.cssText = 'flex:1 1 auto;width:100%;height:calc(100% - 48px);border:0;background:#fff;';
    function closePreview() {
      if (!overlay.parentNode) { return; }
      document.removeEventListener('keydown', onKey, true);
      overlay.parentNode.removeChild(overlay);
    }
    function onKey(event) {
      if (event.key === 'Escape') {
        event.preventDefault();
        closePreview();
      }
    }
    downloadButton.addEventListener('click', function () {
      downloadBlob(url, 'preview-' + Date.now());
    });
    closeButton.addEventListener('click', closePreview);
    document.addEventListener('keydown', onKey, true);
    toolbar.appendChild(title);
    toolbar.appendChild(downloadButton);
    toolbar.appendChild(closeButton);
    overlay.appendChild(toolbar);
    overlay.appendChild(frame);
    (document.body || document.documentElement).appendChild(overlay);
    return closePreview;
  }
  function fakeWindow() {
    var opened = false;
    var current = 'about:blank';
    var closePreview = null;
    function go(url) {
      if (opened || url === undefined || url === null || url === '' || url === 'about:blank') { return; }
      current = String(url);
      if (isExternal(url)) {
        opened = true;
        openExternal(url);
      } else if (isBlob(url)) {
        opened = true;
        closePreview = openPreview(resolve(url).href);
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
      close: function () {
        if (closePreview) { closePreview(); }
        closePreview = null;
        win.closed = true;
      },
      document: { write: function () {}, writeln: function () {}, open: function () {}, close: function () {} }
    };
    Object.defineProperty(win, 'location', { get: function () { return loc; }, set: go });
    return { win: win, go: go };
  }

  var nativeOpen = window.open;
  window.open = function (url, target, features) {
    var href = (url === undefined || url === null) ? '' : String(url);
    if (href === '' || href === 'about:blank' || isExternal(href) || isBlob(href)) {
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
    if (!anchor) { return; }
    if (anchor.hasAttribute('download')) {
      if (isBlob(anchor.href)) {
        event.preventDefault();
        event.stopPropagation();
        downloadBlob(anchor.href, anchor.getAttribute('download'));
      }
      return;
    }
    if (isExternal(anchor.href)) {
      event.preventDefault();
      event.stopPropagation();
      openExternal(anchor.href);
    }
  }, true);
})();
`;
