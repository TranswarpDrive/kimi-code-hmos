const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  PACKAGE, REGISTRY, execute, officialTarball, readState, validateMetadata, atomicWriteJson
} = require('../runtime/runtime-updater.cjs');

const integrity = 'sha512-' + Buffer.alloc(64, 7).toString('base64');

function compare(left, right) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let index = 0; index < 3; index++) {
    if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
  }
  return 0;
}

const semver = {
  valid: version => /^\d+\.\d+\.\d+$/.test(version) ? version : null,
  gt: (left, right) => compare(left, right) > 0,
  satisfies: (version, range) => {
    const match = /^>=(\d+\.\d+\.\d+)$/.exec(range);
    return !match || compare(version, match[1]) >= 0;
  }
};

function writeInstalledPackage(directory, version, engines = '>=22.19.0') {
  const root = path.join(directory, 'node_modules', '@moonshot-ai', 'kimi-code');
  fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
  fs.mkdirSync(path.join(root, 'dist-web'), { recursive: true });
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({
    name: PACKAGE, version, engines: { node: engines }
  }));
  fs.writeFileSync(path.join(root, 'LICENSE'), 'MIT');
  for (const relative of ['dist/main.mjs', 'dist/search-worker.mjs', 'dist-web/index.html']) {
    fs.writeFileSync(path.join(root, relative), `fixture ${version}`);
  }
  fs.writeFileSync(path.join(directory, 'package-lock.json'), JSON.stringify({
    lockfileVersion: 3,
    packages: {
      [`node_modules/${PACKAGE}`]: { version, resolved: officialTarball(version), integrity }
    }
  }));
}

function snapshot(directory) {
  const result = {};
  function visit(relative) {
    const file = path.join(directory, relative);
    for (const entry of fs.readdirSync(file, { withFileTypes: true })) {
      const name = path.join(relative, entry.name);
      if (entry.isDirectory()) visit(name);
      else result[name] = fs.readFileSync(path.join(directory, name), 'utf8');
    }
  }
  visit('.');
  return result;
}

function harness(t) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kimi-runtime-updater-'));
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));
  const root = path.join(temporary, 'runtime-updates');
  const project = path.join(temporary, 'project');
  fs.mkdirSync(path.join(project, 'node_modules', 'keep'), { recursive: true });
  fs.writeFileSync(path.join(project, 'package.json'), '{"name":"existing-project"}');
  fs.writeFileSync(path.join(project, 'package-lock.json'), '{"lockfileVersion":3}');
  fs.writeFileSync(path.join(project, 'node_modules', 'keep', 'index.js'), 'module.exports = 1;');
  const before = snapshot(project);
  const options = {
    root,
    npmCli: '/unused/npm-cli.js',
    nodeBinary: process.execPath,
    preload: '/unused/preload.cjs',
    builtIn: '2.2.0'
  };
  const state = {
    latest: '2.3.2',
    urls: [],
    installs: 0,
    smokes: 0,
    stagingDirectories: []
  };
  const adapters = {
    semver,
    fetchMetadata: async url => {
      state.urls.push(url);
      return {
        name: PACKAGE,
        version: state.latest,
        dist: { tarball: officialTarball(state.latest), integrity }
      };
    },
    npmInstall: async (context, directory) => {
      state.installs++;
      state.stagingDirectories.push(directory);
      assert.ok(directory.startsWith(path.join(root, 'versions') + path.sep));
      assert.ok(path.basename(directory).startsWith('.staging-'));
      writeInstalledPackage(directory, state.latest);
    },
    smokeTest: (context, directory, version) => {
      state.smokes++;
      assert.equal(version, state.latest);
      assert.ok(fs.existsSync(path.join(directory, 'node_modules')));
    }
  };
  return {
    root, project, before, options, adapters, state,
    run(command, version) {
      return execute(command, { ...options, version }, adapters);
    },
    seedActive(version, pending = false) {
      const directory = path.join(root, 'versions', version);
      writeInstalledPackage(directory, version);
      atomicWriteJson(path.join(directory, '.hmos-ready.json'), { schema: 1, version, integrity });
      atomicWriteJson(path.join(root, 'state.json'), {
        schema: 1, activeVersion: version, previousVersion: '', pending
      });
    }
  };
}

test('official check uses the pinned registry and records a newer CLI/WebUI version', async t => {
  const h = harness(t);
  const result = await h.run('check');
  assert.deepEqual(h.state.urls, [`${REGISTRY}/${encodeURIComponent(PACKAGE)}/latest`]);
  assert.equal(result.latestVersion, '2.3.2');
  assert.equal(result.currentVersion, '2.2.0');
  assert.equal(result.updateAvailable, true);
  assert.equal(JSON.parse(fs.readFileSync(path.join(h.root, 'check.json'))).updateAvailable, true);
  assert.deepEqual(snapshot(h.project), h.before);
});

test('metadata rejects unofficial tarballs, invalid integrity and unsafe versions', () => {
  const valid = {
    name: PACKAGE,
    version: '2.3.2',
    dist: { tarball: officialTarball('2.3.2'), integrity }
  };
  assert.equal(validateMetadata({ semver }, valid).version, '2.3.2');
  for (const mutate of [
    value => { value.dist.tarball = 'https://example.org/kimi.tgz'; },
    value => { value.dist.integrity = 'sha1-untrusted'; },
    value => { value.version = '../../project'; },
    value => { value.name = 'other-package'; }
  ]) {
    const value = structuredClone(valid);
    mutate(value);
    assert.throws(() => validateMetadata({ semver }, value));
  }
});

test('install is staged, activation is atomic, commit marks health and restore keeps projects intact', async t => {
  const h = harness(t);
  const installed = await h.run('install', '2.3.2');
  assert.equal(installed.candidateVersion, '2.3.2');
  assert.equal(readState(h.root).activeVersion, '');
  assert.equal(h.state.installs, 1);
  assert.equal(h.state.smokes, 1);
  assert.ok(h.state.stagingDirectories.every(directory => !fs.existsSync(directory)));

  const activated = await h.run('activate', '2.3.2');
  assert.equal(activated.currentVersion, '2.3.2');
  assert.equal(activated.pending, true);
  assert.equal(fs.existsSync(path.join(h.root, 'candidate.json')), false);
  await h.run('commit');
  assert.equal(readState(h.root).pending, false);
  const restored = await h.run('restore');
  assert.equal(restored.currentVersion, '2.2.0');
  assert.equal(readState(h.root).activeVersion, '');
  assert.deepEqual(snapshot(h.project), h.before);
});

test('rollback returns to the previous updated runtime instead of deleting it', async t => {
  const h = harness(t);
  h.seedActive('2.3.1');
  await h.run('install', '2.3.2');
  await h.run('activate', '2.3.2');
  assert.deepEqual(readState(h.root), {
    schema: 1, activeVersion: '2.3.2', previousVersion: '2.3.1', pending: true
  });
  const restored = await h.run('rollback');
  assert.equal(restored.currentVersion, '2.3.1');
  assert.equal(readState(h.root).pending, false);
  assert.ok(fs.existsSync(path.join(h.root, 'versions', '2.3.1', 'package-lock.json')));
  assert.deepEqual(snapshot(h.project), h.before);
});

test('npm and smoke failures never publish a candidate or change the active runtime', async t => {
  const h = harness(t);
  h.seedActive('2.3.1');
  const original = readState(h.root);
  h.adapters.npmInstall = async () => { throw new Error('network failed'); };
  await assert.rejects(h.run('install', '2.3.2'), /network failed/);
  assert.deepEqual(readState(h.root), original);
  assert.equal(fs.existsSync(path.join(h.root, 'candidate.json')), false);
  assert.deepEqual(snapshot(h.project), h.before);

  h.adapters.npmInstall = async (context, directory) => writeInstalledPackage(directory, h.state.latest);
  h.adapters.smokeTest = () => { throw new Error('incompatible CLI'); };
  await assert.rejects(h.run('install', '2.3.2'), /incompatible CLI/);
  assert.deepEqual(readState(h.root), original);
  assert.equal(fs.existsSync(path.join(h.root, 'candidate.json')), false);
  assert.equal(fs.existsSync(path.join(h.root, 'versions', '2.3.2')), false);
});

test('corrupt installed packages cannot activate and an in-use directory is never overwritten', async t => {
  const h = harness(t);
  h.seedActive('2.3.1');
  await h.run('install', '2.3.2');
  const main = path.join(h.root, 'versions', '2.3.2', 'node_modules', '@moonshot-ai', 'kimi-code', 'dist', 'main.mjs');
  fs.rmSync(main);
  await assert.rejects(h.run('activate', '2.3.2'), /缺少|missing/);
  assert.equal(readState(h.root).activeVersion, '2.3.1');

  h.state.latest = '2.3.1';
  await assert.rejects(h.run('install', '2.3.1'), /不高于/);
  assert.ok(fs.existsSync(path.join(h.root, 'versions', '2.3.1', 'package-lock.json')));
});

test('unsupported engines, downgrades and traversal inputs are rejected before activation', async t => {
  const h = harness(t);
  h.adapters.npmInstall = async (context, directory) => writeInstalledPackage(directory, h.state.latest, '>=99.0.0');
  await assert.rejects(h.run('install', '2.3.2'), /不支持当前 Node/);
  assert.equal(readState(h.root).activeVersion, '');

  h.seedActive('2.3.2');
  h.state.latest = '2.3.1';
  await assert.rejects(h.run('install', '2.3.1'), /不高于/);
  await assert.rejects(h.run('install', '../../project'), /版本号格式无效/);
  assert.equal(readState(h.root).activeVersion, '2.3.2');
  await assert.rejects(execute('check', { ...h.options, root: h.project }, h.adapters), /独立/);
  assert.deepEqual(snapshot(h.project), h.before);
});

test('restore repairs corrupt state without depending on the npm archive', async t => {
  const h = harness(t);
  fs.mkdirSync(h.root, { recursive: true });
  fs.writeFileSync(path.join(h.root, 'state.json'), '{broken');
  fs.writeFileSync(path.join(h.root, 'check.json'), '{also broken');
  const result = await execute('restore', h.options);
  assert.equal(result.currentVersion, '2.2.0');
  assert.equal(readState(h.root).activeVersion, '');
  assert.deepEqual(snapshot(h.project), h.before);
});
