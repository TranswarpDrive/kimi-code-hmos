'use strict';

const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const { randomUUID, createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { createRequire } = require('node:module');

const PACKAGE = '@moonshot-ai/kimi-code';
const REGISTRY = 'https://registry.npmjs.org';
const SCHEMA = 1;
const MAX_JSON_BYTES = 2 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 30000;
const NPM_TIMEOUT_MS = 10 * 60 * 1000;
const SMOKE_TIMEOUT_MS = 30000;

function officialTarball(version) {
  return `${REGISTRY}/${PACKAGE}/-/kimi-code-${version}.tgz`;
}

function readJson(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.size > MAX_JSON_BYTES) throw new Error(`状态文件无效：${path.basename(file)}`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function fsyncDirectory(directory) {
  const fd = fs.openSync(directory, 'r');
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function atomicWriteText(file, text) {
  const directory = path.dirname(file);
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${randomUUID()}.tmp`);
  let fd;
  try {
    fd = fs.openSync(temporary, 'wx', 0o600);
    fs.writeFileSync(fd, text);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temporary, file);
    fsyncDirectory(directory);
  } catch (error) {
    if (fd !== undefined) fs.closeSync(fd);
    fs.rmSync(temporary, { force: true });
    throw error;
  }
}

function atomicWriteJson(file, value) {
  atomicWriteText(file, JSON.stringify(value, null, 2) + '\n');
}

function defaultState() {
  return { schema: SCHEMA, activeVersion: '', previousVersion: '', pending: false };
}

function readState(root) {
  try {
    const state = readJson(path.join(root, 'state.json'));
    if (state.schema !== SCHEMA || typeof state.activeVersion !== 'string' ||
      typeof state.previousVersion !== 'string' || typeof state.pending !== 'boolean') {
      throw new Error('运行时状态格式无效');
    }
    return state;
  } catch (error) {
    if (error.code === 'ENOENT') return defaultState();
    throw error;
  }
}

function writeState(context, state) {
  atomicWriteJson(path.join(context.root, 'state.json'), state);
}

function readOptionalJson(file) {
  try {
    return readJson(file);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function assertVersion(semver, version) {
  if (typeof version !== 'string' || semver.valid(version) !== version) {
    throw new Error('官方版本号格式无效');
  }
  return version;
}

function versionDirectory(context, version) {
  assertVersion(context.semver, version);
  return path.join(context.root, 'versions', version);
}

function packageDirectory(directory) {
  return path.join(directory, 'node_modules', '@moonshot-ai', 'kimi-code');
}

function readyMarker(directory) {
  return path.join(directory, '.hmos-ready.json');
}

function readReady(context, directory) {
  const marker = readOptionalJson(readyMarker(directory));
  if (!marker || marker.schema !== SCHEMA) return null;
  assertVersion(context.semver, marker.version);
  if (path.basename(directory) !== marker.version || typeof marker.integrity !== 'string') {
    throw new Error('候选运行时标记与目录不一致');
  }
  return marker;
}

function validatePackage(context, directory, metadata) {
  const root = packageDirectory(directory);
  const stat = fs.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Kimi Code 包目录无效');
  const pkg = readJson(path.join(root, 'package.json'));
  if (pkg.name !== PACKAGE || pkg.version !== metadata.version) {
    throw new Error('下载包名或版本与官方元数据不一致');
  }
  if (!pkg.engines || typeof pkg.engines.node !== 'string' ||
    !context.semver.satisfies(process.versions.node, pkg.engines.node)) {
    throw new Error(`该版本不支持当前 Node ${process.versions.node}`);
  }
  for (const relative of ['dist/main.mjs', 'dist/search-worker.mjs', 'dist-web/index.html', 'LICENSE']) {
    const file = path.join(root, relative);
    let valid = false;
    try {
      valid = fs.lstatSync(file).isFile();
    } catch (error) {
      valid = false;
    }
    if (!valid) throw new Error(`Kimi Code 包缺少 ${relative}`);
  }
  const lock = readJson(path.join(directory, 'package-lock.json'));
  const locked = lock.packages && lock.packages[`node_modules/${PACKAGE}`];
  if (!locked || locked.version !== metadata.version || locked.resolved !== officialTarball(metadata.version) ||
    locked.integrity !== metadata.integrity) {
    throw new Error('npm 锁文件未确认官方归档及完整性值');
  }
  return root;
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, {
      headers: {
        Accept: 'application/json',
        'Accept-Encoding': 'identity',
        'User-Agent': 'kimi-code-hmos-updater/1'
      },
      timeout: REQUEST_TIMEOUT_MS
    }, response => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`官方更新服务返回 HTTP ${response.statusCode}`));
        return;
      }
      const chunks = [];
      let length = 0;
      response.on('data', chunk => {
        length += chunk.length;
        if (length > MAX_JSON_BYTES) {
          request.destroy(new Error('官方元数据超过大小限制'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (error) {
          reject(new Error('官方元数据不是有效 JSON'));
        }
      });
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('连接官方更新服务超时')));
    request.on('error', reject);
  });
}

function validateMetadata(context, metadata, expectedVersion) {
  if (!metadata || metadata.name !== PACKAGE) throw new Error('官方元数据的包名不正确');
  const version = assertVersion(context.semver, metadata.version);
  if (expectedVersion !== undefined && version !== expectedVersion) {
    throw new Error('官方最新版本已变化，请重新检查更新');
  }
  if (!metadata.dist || metadata.dist.tarball !== officialTarball(version) ||
    !/^sha512-[A-Za-z0-9+/]{86}==$/.test(metadata.dist.integrity || '')) {
    throw new Error('官方元数据缺少受支持的 tarball 或 SHA-512 完整性值');
  }
  return { name: PACKAGE, version, integrity: metadata.dist.integrity };
}

async function latestMetadata(context) {
  const encoded = encodeURIComponent(PACKAGE);
  const metadata = await context.fetchMetadata(`${REGISTRY}/${encoded}/latest`);
  return validateMetadata(context, metadata);
}

function readDisplayJson(file) {
  try {
    return readJson(file);
  } catch (error) {
    return null;
  }
}

function result(context, command, message, extra = {}) {
  const state = readState(context.root);
  const check = readDisplayJson(path.join(context.root, 'check.json'));
  const candidate = readDisplayJson(path.join(context.root, 'candidate.json'));
  return {
    schema: SCHEMA,
    command,
    ok: true,
    message,
    bundledVersion: context.builtIn,
    currentVersion: state.activeVersion || context.builtIn,
    activeVersion: state.activeVersion,
    previousVersion: state.previousVersion,
    pending: state.pending,
    latestVersion: check && check.version ? check.version : '',
    candidateVersion: candidate && candidate.version ? candidate.version : '',
    ...extra
  };
}

function childEnvironment(context, home) {
  const environment = {
    HOME: home,
    TMPDIR: context.tempDir,
    XDG_CACHE_HOME: path.join(context.root, 'xdg-cache'),
    PATH: process.env.PATH || '/system/bin:/bin',
    NODE_ENV: 'production',
    UV_USE_IO_URING: '0',
    KIMI_HMOS_DEBUG: '0',
    NPM_CONFIG_REGISTRY: REGISTRY,
    NPM_CONFIG_USERCONFIG: context.npmrc,
    NPM_CONFIG_GLOBALCONFIG: `${context.npmrc}.global`,
    NPM_CONFIG_CACHE: path.join(context.root, 'npm-cache'),
    NPM_CONFIG_WORKSPACES: 'false',
    NPM_CONFIG_UPDATE_NOTIFIER: 'false'
  };
  for (const name of ['LD_LIBRARY_PATH', 'LD_PRELOAD', 'LANG', 'TERM', 'KIMI_HMOS_NATIVE_DIR']) {
    if (process.env[name]) environment[name] = process.env[name];
  }
  return environment;
}

function npmInstall(context, directory) {
  const completed = spawnSync(context.nodeBinary, [
    context.npmCli, 'install',
    '--prefix', directory,
    '--ignore-scripts',
    '--omit=dev',
    '--omit=optional',
    '--no-audit',
    '--no-fund',
    '--engine-strict=true',
    '--workspaces=false',
    '--install-strategy=hoisted',
    '--save-exact=true',
    `--registry=${REGISTRY}`,
    `--userconfig=${context.npmrc}`,
    `--globalconfig=${context.npmrc}.global`,
    `--cache=${path.join(context.root, 'npm-cache')}`
  ], {
    cwd: directory,
    env: childEnvironment(context, context.home),
    stdio: 'inherit',
    timeout: NPM_TIMEOUT_MS,
    windowsHide: true
  });
  if (completed.error || completed.status !== 0) {
    const reason = completed.error && completed.error.code === 'ETIMEDOUT' ? '超时' : `退出码 ${completed.status}`;
    throw new Error(`npm 安装失败（${reason}），请查看更新日志`);
  }
}

function smokeTest(context, directory, version) {
  const home = path.join(context.root, 'smoke-home');
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  const main = path.join(packageDirectory(directory), 'dist', 'main.mjs');
  const completed = spawnSync(context.nodeBinary, ['--require', context.preload, main, '--version'], {
    cwd: home,
    env: childEnvironment(context, home),
    encoding: 'utf8',
    timeout: SMOKE_TIMEOUT_MS,
    maxBuffer: 1024 * 1024,
    windowsHide: true
  });
  if (completed.error || completed.status !== 0 || !completed.stdout.trim().split(/\r?\n/).includes(version)) {
    throw new Error('新版 CLI 冒烟检查失败，未切换运行时');
  }
}

function removeCandidate(context) {
  fs.rmSync(path.join(context.root, 'candidate.json'), { force: true });
}

function pruneVersions(context, candidateVersion) {
  const state = readState(context.root);
  const keep = new Set([state.activeVersion, state.previousVersion, candidateVersion].filter(Boolean));
  const directory = path.join(context.root, 'versions');
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name.startsWith('.staging-')) {
      fs.rmSync(path.join(directory, entry.name), { recursive: true, force: true });
    } else if (entry.isDirectory() && context.semver.valid(entry.name) === entry.name && !keep.has(entry.name)) {
      fs.rmSync(path.join(directory, entry.name), { recursive: true, force: true });
    }
  }
  fsyncDirectory(directory);
}

async function checkForUpdates(context) {
  const metadata = await latestMetadata(context);
  const state = readState(context.root);
  const current = state.activeVersion || context.builtIn;
  const available = context.semver.gt(metadata.version, current);
  atomicWriteJson(path.join(context.root, 'check.json'), {
    schema: SCHEMA,
    version: metadata.version,
    integrity: metadata.integrity,
    checkedAt: new Date().toISOString(),
    updateAvailable: available
  });
  return result(context, 'check', available ? `发现官方新版本 ${metadata.version}` : '当前已是最新版本', {
    latestVersion: metadata.version,
    updateAvailable: available
  });
}

async function installUpdate(context, requestedVersion) {
  const version = assertVersion(context.semver, requestedVersion);
  const metadata = await latestMetadata(context);
  if (metadata.version !== version) throw new Error('官方最新版本已变化，请重新检查更新');
  const state = readState(context.root);
  const current = state.activeVersion || context.builtIn;
  if (!context.semver.gt(version, current)) throw new Error('目标版本不高于当前版本，已停止安装');

  const finalDirectory = versionDirectory(context, version);
  const existing = fs.existsSync(finalDirectory) ? readReady(context, finalDirectory) : null;
  if (fs.existsSync(finalDirectory) && [state.activeVersion, state.previousVersion].includes(version) &&
    (!existing || existing.integrity !== metadata.integrity)) {
    throw new Error('历史运行时目录异常，请先恢复随包版本再重试');
  }

  const versions = path.join(context.root, 'versions');
  fs.mkdirSync(versions, { recursive: true, mode: 0o700 });
  pruneVersions(context, version);
  let directory = finalDirectory;
  if (!existing || existing.integrity !== metadata.integrity) {
    if (fs.existsSync(finalDirectory)) fs.rmSync(finalDirectory, { recursive: true, force: true });
    const staging = path.join(versions, `.staging-${process.pid}-${randomUUID()}`);
    directory = staging;
    fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
    try {
      atomicWriteJson(path.join(staging, 'package.json'), {
        name: 'kimi-code-hmos-updated-runtime',
        version: '0.0.0',
        private: true,
        dependencies: { [PACKAGE]: version }
      });
      await context.npmInstall(context, staging);
      validatePackage(context, staging, metadata);
      context.smokeTest(context, staging, version);
      atomicWriteJson(readyMarker(staging), {
        schema: SCHEMA,
        version,
        integrity: metadata.integrity,
        package: `node_modules/${PACKAGE}`
      });
      fs.renameSync(staging, finalDirectory);
      fsyncDirectory(versions);
      directory = finalDirectory;
    } finally {
      fs.rmSync(staging, { recursive: true, force: true });
    }
  }

  validatePackage(context, finalDirectory, metadata);
  atomicWriteJson(path.join(context.root, 'candidate.json'), {
    schema: SCHEMA,
    version,
    integrity: metadata.integrity
  });
  pruneVersions(context, version);
  return result(context, 'install', `Kimi Code ${version} 已下载并校验，重启后生效`, {
    latestVersion: version,
    candidateVersion: version,
    updateAvailable: true
  });
}

function activateUpdate(context, requestedVersion) {
  const candidate = readOptionalJson(path.join(context.root, 'candidate.json'));
  if (!candidate || candidate.schema !== SCHEMA || candidate.version !== requestedVersion) {
    throw new Error('没有可激活的已校验版本');
  }
  assertVersion(context.semver, candidate.version);
  const metadata = {
    version: candidate.version,
    integrity: candidate.integrity
  };
  const directory = versionDirectory(context, candidate.version);
  const ready = readReady(context, directory);
  if (!ready || ready.integrity !== candidate.integrity) throw new Error('候选运行时标记或完整性值无效');
  validatePackage(context, directory, metadata);

  const state = readState(context.root);
  if (state.activeVersion === candidate.version) {
    removeCandidate(context);
    return result(context, 'activate', `Kimi Code ${candidate.version} 已在运行`, { updateAvailable: false });
  }
  writeState(context, {
    schema: SCHEMA,
    activeVersion: candidate.version,
    previousVersion: state.activeVersion,
    pending: true
  });
  removeCandidate(context);
  return result(context, 'activate', `已准备切换到 Kimi Code ${candidate.version}`, {
    currentVersion: candidate.version,
    activeVersion: candidate.version,
    previousVersion: state.activeVersion,
    pending: true,
    candidateVersion: '',
    updateAvailable: false
  });
}

function commitUpdate(context) {
  const state = readState(context.root);
  if (state.activeVersion && !readReady(context, versionDirectory(context, state.activeVersion))) {
    throw new Error('活动运行时缺少有效标记');
  }
  if (state.pending) writeState(context, { ...state, pending: false });
  return result(context, 'commit', '新版运行时已通过首次启动检查');
}

function restoreRuntime(context, command, usePrevious) {
  const state = usePrevious ? readState(context.root) : defaultState();
  let restored = usePrevious ? state.previousVersion : '';
  if (restored) {
    try {
      const ready = readReady(context, versionDirectory(context, restored));
      if (!ready) restored = '';
    } catch (error) {
      restored = '';
    }
  }
  writeState(context, { schema: SCHEMA, activeVersion: restored, previousVersion: '', pending: false });
  removeCandidate(context);
  return result(context, command, restored ? `已恢复 Kimi Code ${restored}` : '已恢复随包 Kimi Code', {
    currentVersion: restored || context.builtIn,
    activeVersion: restored,
    previousVersion: '',
    pending: false,
    candidateVersion: '',
    updateAvailable: false
  });
}

function ensureNpm(options) {
  const root = path.resolve(options.root);
  const expectedCli = path.join(root, 'npm', 'bin', 'npm-cli.js');
  if (!path.isAbsolute(options.npmCli) || path.resolve(options.npmCli) !== expectedCli) {
    throw new Error('npm 必须从更新目录中的随包归档准备');
  }
  if (!path.isAbsolute(options.npmArchive) || !path.isAbsolute(options.tarModule)) {
    throw new Error('npm 归档和解压模块必须使用绝对路径');
  }
  const required = ['bin/npm-cli.js', 'lib/cli.js', 'node_modules/semver/package.json', 'LICENSE'];
  const complete = directory => required.every(relative => {
    try {
      return fs.lstatSync(path.join(directory, relative)).isFile();
    } catch (error) {
      return false;
    }
  });
  const archiveHash = createHash('sha256').update(fs.readFileSync(options.npmArchive)).digest('hex');
  const markerPath = path.join(root, '.npm-archive.json');
  let marker = null;
  try {
    marker = readJson(markerPath);
  } catch (error) {
    marker = null;
  }
  if (marker && marker.sha256 === archiveHash && complete(path.join(root, 'npm'))) {
    return;
  }

  const staging = path.join(root, `.npm-extract-${process.pid}-${randomUUID()}`);
  fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
  try {
    const tar = require(options.tarModule);
    tar.x({ file: options.npmArchive, cwd: staging, sync: true, strict: true, preservePaths: false });
    const extracted = path.join(staging, 'npm');
    const pkg = readJson(path.join(extracted, 'package.json'));
    if (pkg.name !== 'npm' || typeof pkg.version !== 'string' || !complete(extracted)) {
      throw new Error('随包 npm 归档结构无效');
    }
    fs.rmSync(path.join(root, 'npm'), { recursive: true, force: true });
    fs.renameSync(extracted, path.join(root, 'npm'));
    atomicWriteJson(markerPath, { schema: SCHEMA, sha256: archiveHash, version: pkg.version });
    fsyncDirectory(root);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

async function execute(command, options, adapters = {}) {
  if (!['check', 'install', 'activate', 'commit', 'rollback', 'restore'].includes(command)) {
    throw new Error(`未知更新命令：${command}`);
  }
  if (!path.isAbsolute(options.root) || path.basename(options.root) !== 'runtime-updates') {
    throw new Error('更新目录必须是独立的 runtime-updates 目录');
  }
  const root = path.resolve(options.root);
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  if (!fs.lstatSync(root).isDirectory() || fs.lstatSync(root).isSymbolicLink()) {
    throw new Error('更新目录不能是符号链接或普通文件');
  }
  const needsNpm = command === 'check' || command === 'install';
  if (needsNpm && !adapters.semver) ensureNpm(options);
  const stateSemver = {
    valid: version => typeof version === 'string' && version.length <= 80 &&
      /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version) ? version : null
  };
  const semver = adapters.semver || (needsNpm ? createRequire(options.npmCli)('semver') : stateSemver);
  const builtIn = assertVersion(semver, options.builtIn);
  const context = {
    root,
    builtIn,
    nodeBinary: options.nodeBinary,
    npmCli: options.npmCli,
    preload: options.preload,
    home: path.join(root, 'npm-home'),
    tempDir: path.join(root, 'tmp'),
    npmrc: path.join(root, 'isolated-npmrc'),
    semver,
    fetchMetadata: adapters.fetchMetadata || fetchJson,
    npmInstall: adapters.npmInstall || npmInstall,
    smokeTest: adapters.smokeTest || smokeTest
  };
  for (const directory of [context.home, context.tempDir, path.join(root, 'npm-cache'), path.join(root, 'xdg-cache')]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  const npmrc = `registry=${REGISTRY}\nignore-scripts=true\naudit=false\nfund=false\n`;
  atomicWriteText(context.npmrc, npmrc);
  atomicWriteText(`${context.npmrc}.global`, npmrc);

  switch (command) {
    case 'check': return checkForUpdates(context);
    case 'install': return installUpdate(context, options.version);
    case 'activate': return activateUpdate(context, options.version);
    case 'commit': return commitUpdate(context);
    case 'rollback': return restoreRuntime(context, 'rollback', true);
    case 'restore': return restoreRuntime(context, 'restore', false);
    default: throw new Error(' unreachable ');
  }
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key.startsWith('--') || value === undefined) throw new Error('更新命令参数不完整');
    options[key.slice(2)] = value;
  }
  for (const key of ['root', 'npm-cli', 'npm-archive', 'tar-module', 'node-binary', 'preload', 'built-in', 'result']) {
    if (!options[key]) throw new Error(`缺少参数 --${key}`);
  }
  return {
    root: options.root,
    npmCli: options['npm-cli'],
    npmArchive: options['npm-archive'],
    tarModule: options['tar-module'],
    nodeBinary: options['node-binary'],
    preload: options.preload,
    builtIn: options['built-in'],
    version: options.version,
    result: options.result
  };
}

async function main() {
  const command = process.argv[2];
  const options = parseArguments(process.argv.slice(3));
  try {
    const value = await execute(command, options);
    atomicWriteJson(options.result, value);
  } catch (error) {
    const message = error && error.message ? String(error.message).slice(0, 1200) : String(error);
    atomicWriteJson(options.result, { schema: SCHEMA, command, ok: false, message });
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`runtime updater failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  PACKAGE,
  REGISTRY,
  execute,
  officialTarball,
  readState,
  validateMetadata,
  atomicWriteJson
};
