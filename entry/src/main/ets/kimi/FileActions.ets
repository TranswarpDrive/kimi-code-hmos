import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Environment, fileIo as fs, fileShare, fileUri, picker } from '@kit.CoreFileKit';
import { Log } from './Log';

export class WorkspaceSelection {
  uri: string = '';
  path: string = '';
}

export type FileActionNotice = (message: string) => void;

function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

function downloadsDirectory(): string {
  const path = Environment.getUserDownloadDir();
  if (!pathExists(path)) {
    fs.mkdirSync(path, true);
  }
  return path;
}

function safeFileName(suggested: string): string {
  const normalized = suggested.replace(/\\/g, '/');
  const parts = normalized.split('/');
  const base = parts[parts.length - 1].trim().replace(/[\x00-\x1F]/g, '_');
  if (base === '' || base === '.' || base === '..') {
    return `download-${Date.now()}`;
  }
  return base;
}

function uniqueDownloadPath(suggested: string): string {
  const directory = downloadsDirectory();
  const name = safeFileName(suggested);
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.substring(0, dot) : name;
  const suffix = dot > 0 ? name.substring(dot) : '';
  for (let index = 0; index < 1000; index++) {
    const candidateName = index === 0 ? name : `${stem} (${index})${suffix}`;
    const candidate = `${directory}/${candidateName}`;
    if (!pathExists(candidate)) {
      return candidate;
    }
  }
  throw new Error(`无法为 ${name} 生成不重复的文件名`);
}

export class FileActions {
  static selectWebFiles(context: common.UIAbilityContext, params: FileSelectorParam,
    result: FileSelectorResult): void {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = params.getMode() === FileSelectorMode.FileOpenMultipleMode ? 500 : 1;
    options.selectMode = params.getMode() === FileSelectorMode.FileOpenFolderMode ?
      picker.DocumentSelectMode.FOLDER : picker.DocumentSelectMode.FILE;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(options)
      .then((uris: string[]) => {
        result.handleFileList(uris);
      })
      .catch((err: BusinessError) => {
        Log.warn(`file selector cancelled or failed (${err.code}): ${err.message}`);
        result.handleFileList([]);
      });
  }

  static saveBlobToDownloads(suggestedName: string, base64: string): string {
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
    const path = uniqueDownloadPath(suggestedName);
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const data = new ArrayBuffer(bytes.byteLength);
      new Uint8Array(data).set(bytes);
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
    Log.info(`blob download saved: ${path} (${bytes.byteLength} bytes)`);
    return path;
  }

  static createDownloadDelegate(notify: FileActionNotice): webview.WebDownloadDelegate {
    const delegate = new webview.WebDownloadDelegate();
    const paths = new Map<string, string>();
    const blobDownloads = new Set<string>();
    delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      if (item.getUrl().startsWith('blob:')) {
        blobDownloads.add(item.getGuid());
        item.cancel();
        notify('请使用文件预览顶部的“下载”按钮保存 blob 文件');
        return;
      }
      try {
        const path = uniqueDownloadPath(item.getSuggestedFileName());
        paths.set(item.getGuid(), path);
        item.start(path);
        Log.info(`web download started: ${item.getUrl()} -> ${path}`);
      } catch (err) {
        Log.warn(`start web download failed: ${String(err)}`);
        item.cancel();
      }
    });
    delegate.onDownloadFinish((item: webview.WebDownloadItem) => {
      const path = paths.get(item.getGuid()) ?? item.getFullPath();
      paths.delete(item.getGuid());
      Log.info(`web download finished: ${path}`);
      notify(`下载完成：${path}`);
    });
    delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      paths.delete(item.getGuid());
      if (blobDownloads.delete(item.getGuid())) {
        return;
      }
      const message = `下载失败：${item.getSuggestedFileName()}（${item.getLastErrorCode()}）`;
      Log.warn(`${message}, url ${item.getUrl()}`);
      notify(message);
    });
    return delegate;
  }

  static async selectWorkspace(context: common.UIAbilityContext): Promise<WorkspaceSelection> {
    const options = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    options.maxSelectNumber = 1;
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.select(options);
    if (uris.length !== 1) {
      throw new Error('未选择工作目录');
    }
    const uri = uris[0];
    await fileShare.persistPermission([{
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    }]);
    const path = decodeURIComponent(new fileUri.FileUri(uri).path);
    if (!path.startsWith('/') || !pathExists(path) || !fs.statSync(path).isDirectory()) {
      throw new Error(`选择的路径不可用于内置 Node：${path}`);
    }
    const selection = new WorkspaceSelection();
    selection.uri = uri;
    selection.path = path;
    return selection;
  }
}
