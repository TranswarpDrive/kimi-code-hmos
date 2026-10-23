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
export const MAX_BLOB_BYTES: number = 32 * 1024 * 1024;
const WRITE_CHUNK_BYTES: number = 256 * 1024;

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
  const base = parts[parts.length - 1].trim().replace(/[\x00-\x1F\x7F]/g, '_');
  if (base === '' || base === '.' || base === '..') {
    return `download-${Date.now()}`;
  }
  // 预留防重名后缀空间；限制 UTF-8 文件名字节数，避免中文名称超过文件系统上限。
  let result = '';
  let bytes = 0;
  for (const character of base) {
    const length = encodeURIComponent(character).replace(/%[A-F\d]{2}/gi, '_').length;
    if (bytes + length > 180) {
      break;
    }
    result += character;
    bytes += length;
  }
  return result;
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
  private static blobBusy: boolean = false;
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

  static async saveBlobToDownloads(suggestedName: string, base64: string): Promise<string> {
    if (FileActions.blobBusy) {
      throw new Error('已有文件正在保存，请稍后重试');
    }
    if (base64.length > Math.ceil(MAX_BLOB_BYTES / 3) * 4) {
      throw new Error('此类文件下载最多支持 32 MiB，请减少导出范围后重试');
    }
    FileActions.blobBusy = true;
    let path = '';
    let file: fs.File | null = null;
    let complete = false;
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
      if (bytes.byteLength > MAX_BLOB_BYTES) {
        throw new Error('此类文件下载最多支持 32 MiB');
      }
      path = uniqueDownloadPath(suggestedName);
      file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let offset = 0;
      while (offset < bytes.byteLength) {
        const data = bytes.slice(offset, Math.min(offset + WRITE_CHUNK_BYTES, bytes.byteLength));
        const buffer = new ArrayBuffer(data.byteLength);
        new Uint8Array(buffer).set(data);
        const written = await fs.write(file.fd, buffer);
        if (written <= 0) {
          throw new Error('文件写入未完成，请检查剩余存储空间');
        }
        offset += written;
      }
      complete = true;
      Log.info(`blob download saved: ${path} (${bytes.byteLength} bytes)`);
      return path;
    } finally {
      FileActions.blobBusy = false;
      if (file !== null) {
        try {
          fs.closeSync(file);
        } finally {
          if (!complete) {
            try { fs.unlinkSync(path); } catch (err) { Log.warn('cannot remove unfinished download'); }
          }
        }
      }
    }
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
        notify(`无法开始下载：${String(err)}`);
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
      const unfinished = paths.get(item.getGuid());
      paths.delete(item.getGuid());
      if (unfinished !== undefined) {
        try { fs.unlinkSync(unfinished); } catch (err) { Log.warn('cannot remove unfinished web download'); }
      }
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
    await fileShare.activatePermission([{
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    }]);
    const path = new fileUri.FileUri(uri).path;
    if (!path.startsWith('/') || !pathExists(path) || !fs.statSync(path).isDirectory()) {
      throw new Error(`选择的路径不可用于内置 Node：${path}`);
    }
    const selection = new WorkspaceSelection();
    selection.uri = uri;
    selection.path = path;
    return selection;
  }
}
