#!/usr/bin/env bash
# 下载并校验第三方依赖到 vendor/（不入库）：
#   vendor/node/node-v<ver>-openharmony-arm64/   鸿蒙版 Node 运行时
#   vendor/git/git-<ver>-ohos-arm64/              鸿蒙版 Git
#   vendor/python/python-<ver>-ohos-arm64/        鸿蒙版 Python
#   vendor/tools/rg                                musl ARM64 ripgrep
#   vendor/kimi-code/package/                    kimi-code npm 包（dist/、dist-web/）
#   vendor/kimi-deps/node_modules/               kimi 的运行时依赖（ws、qrcode，按 runtime/kimi-deps 锁定）
# 已下载且校验通过的文件会被复用。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
VENDOR="$ROOT/vendor"
mkdir -p "$VENDOR/downloads"

log() { printf '\033[36m[fetch-deps]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[fetch-deps] %s\033[0m\n' "$*" >&2; exit 1; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- Node（鸿蒙版） ---------------------------------------------------------
node_archive="$VENDOR/downloads/$NODE_TARBALL"
if [[ ! -f "$node_archive" || "$(sha256_of "$node_archive")" != "$NODE_SHA256" ]]; then
  rm -f "$node_archive"
  for url in "$NODE_URL_GITHUB" "$NODE_URL_MIRROR"; do
    log "下载 $url"
    if curl -fsSL --retry 2 --connect-timeout 20 -o "$node_archive.part" "$url"; then
      mv "$node_archive.part" "$node_archive"
      break
    fi
    rm -f "$node_archive.part"
  done
  [[ -f "$node_archive" ]] || die "Node 下载失败"
fi
actual="$(sha256_of "$node_archive")"
[[ "$actual" == "$NODE_SHA256" ]] || die "Node sha256 不匹配：$actual != $NODE_SHA256"
log "Node $NODE_VERSION 校验通过"

node_dir="$VENDOR/node/node-v$NODE_VERSION-openharmony-arm64"
if [[ ! -x "$node_dir/bin/node" ]]; then
  rm -rf "$VENDOR/node" && mkdir -p "$VENDOR/node"
  tar -xJf "$node_archive" -C "$VENDOR/node"
fi
[[ -x "$node_dir/bin/node" ]] || die "解压后找不到 $node_dir/bin/node"

# --- git / ripgrep（鸿蒙预编译） --------------------------------------------
git_archive="$VENDOR/downloads/$GIT_TARBALL"
if [[ ! -f "$git_archive" || "$(sha256_of "$git_archive")" != "$GIT_SHA256" ]]; then
  rm -f "$git_archive"
  log "下载 $GIT_URL"
  curl -fsSL --retry 2 --connect-timeout 20 -o "$git_archive.part" "$GIT_URL"
  mv "$git_archive.part" "$git_archive"
fi
actual="$(sha256_of "$git_archive")"
[[ "$actual" == "$GIT_SHA256" ]] || die "git sha256 不匹配：$actual != $GIT_SHA256"
log "git $GIT_VERSION 校验通过"

git_dir="$VENDOR/git/git-$GIT_VERSION-ohos-arm64"
if [[ ! -x "$git_dir/bin/git" ]]; then
  rm -rf "$VENDOR/git" && mkdir -p "$VENDOR/git"
  tar -xzf "$git_archive" -C "$VENDOR/git"
fi
[[ -x "$git_dir/bin/git" ]] || die "解压后找不到 $git_dir/bin/git"

python_archive="$VENDOR/downloads/$PYTHON_TARBALL"
if [[ ! -f "$python_archive" || "$(sha256_of "$python_archive")" != "$PYTHON_SHA256" ]]; then
  rm -f "$python_archive"
  log "下载 $PYTHON_URL"
  curl -fsSL --retry 2 --connect-timeout 20 -o "$python_archive.part" "$PYTHON_URL"
  mv "$python_archive.part" "$python_archive"
fi
actual="$(sha256_of "$python_archive")"
[[ "$actual" == "$PYTHON_SHA256" ]] || die "Python sha256 不匹配：$actual != $PYTHON_SHA256"
log "Python $PYTHON_VERSION 校验通过"

python_dir="$VENDOR/python/python-$PYTHON_VERSION-ohos-arm64"
if [[ ! -x "$python_dir/bin/python3.14" ]]; then
  rm -rf "$VENDOR/python" && mkdir -p "$VENDOR/python"
  tar -xzf "$python_archive" -C "$VENDOR/python"
fi
[[ -x "$python_dir/bin/python3.14" ]] || die "解压后找不到 $python_dir/bin/python3.14"

rg_archive="$VENDOR/downloads/rg-$RG_BUILD"
if [[ ! -f "$rg_archive" || "$(sha256_of "$rg_archive")" != "$RG_SHA256" ]]; then
  rm -f "$rg_archive"
  log "下载 $RG_URL"
  curl -fsSL --retry 2 --connect-timeout 20 -o "$rg_archive.part" "$RG_URL"
  mv "$rg_archive.part" "$rg_archive"
fi
actual="$(sha256_of "$rg_archive")"
[[ "$actual" == "$RG_SHA256" ]] || die "ripgrep sha256 不匹配：$actual != $RG_SHA256"
mkdir -p "$VENDOR/tools"
install -m 0755 "$rg_archive" "$VENDOR/tools/rg"
log "ripgrep（${RG_BUILD}）校验通过"

# --- kimi-code npm 包 ------------------------------------------------------
kimi_archive="$VENDOR/downloads/moonshot-ai-kimi-code-$KIMI_CODE_VERSION.tgz"
integrity_of() { printf 'sha512-%s' "$(openssl dgst -sha512 -binary "$1" | openssl base64 -A)"; }
if [[ ! -f "$kimi_archive" || "$(integrity_of "$kimi_archive")" != "$KIMI_CODE_INTEGRITY" ]]; then
  rm -f "$kimi_archive"
  log "下载 @moonshot-ai/kimi-code@$KIMI_CODE_VERSION"
  (cd "$VENDOR/downloads" && npm pack "@moonshot-ai/kimi-code@$KIMI_CODE_VERSION" --silent >/dev/null)
fi
actual="$(integrity_of "$kimi_archive")"
[[ "$actual" == "$KIMI_CODE_INTEGRITY" ]] || die "kimi-code integrity 不匹配：$actual"
log "kimi-code $KIMI_CODE_VERSION 校验通过"

kimi_dir="$VENDOR/kimi-code"
stamp="$kimi_dir/.version"
if [[ ! -f "$stamp" || "$(cat "$stamp")" != "$KIMI_CODE_VERSION" ]]; then
  rm -rf "$kimi_dir" && mkdir -p "$kimi_dir"
  tar -xzf "$kimi_archive" -C "$kimi_dir"
  echo "$KIMI_CODE_VERSION" >"$stamp"
fi
[[ -f "$kimi_dir/package/dist/main.mjs" ]] || die "kimi-code 包结构异常：缺少 dist/main.mjs"

# --- kimi 运行时依赖（在我们自己的目录里按锁文件安装，不执行任何安装脚本） ---------
deps_dir="$VENDOR/kimi-deps"
if [[ ! -d "$deps_dir/node_modules/ws" || "$ROOT/runtime/kimi-deps/package-lock.json" -nt "$deps_dir/node_modules" ]]; then
  rm -rf "$deps_dir" && mkdir -p "$deps_dir"
  cp "$ROOT/runtime/kimi-deps/package.json" "$ROOT/runtime/kimi-deps/package-lock.json" "$deps_dir/"
  log "安装 kimi 运行时依赖（npm ci --omit=dev --ignore-scripts）"
  npm ci --prefix "$deps_dir" --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund --silent
fi
[[ -d "$deps_dir/node_modules/ws" && -d "$deps_dir/node_modules/qrcode" ]] || die "运行时依赖安装失败"

log "完成：$node_dir"
log "      $kimi_dir/package"
log "      $deps_dir/node_modules"
