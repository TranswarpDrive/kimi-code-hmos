#!/usr/bin/env bash
# 把 vendor/ 里的依赖放到构建需要的位置（均为生成物，不入库）：
#
#   entry/libs/arm64-v8a/       鸿蒙版 Node、ripgrep、git、python3 与 Python 原生库。
#                               可执行文件在 module.json5 的 executableBinaryPaths 中声明并带 .permission 节；
#                               Python 原生文件同时写入 entry/libs/python-native-files.txt 供 InjectRuntime 读取。
#   entry/src/main/resources/resfile/kimicode/
#                             → 安装后在 <context.resourceDir>/kimicode/（系统解压出的真实文件，只读）
#                                 package/                 kimi-code npm 包（dist/、dist-web/、node_modules/）
#                                 runtime/ohos-preload.cjs 沙箱兼容补丁
#                                 git/share/               git 模板与本地化资源
#                                 python/                  Python 纯 Python 标准库与 terminfo
#                                 licenses/                随包二进制的许可证
#
# 不用 HNP：小白调试助手等重签工具对带 HNP 的 HAP 支持不稳定，而 resfile 是标准资源目录。
# libkimicompat.so、libkimihost.so 由 entry 的 CMake 构建；libc++_shared.so 由 hvigor 自动带上。
# 同时生成 entry/src/main/ets/kimi/RuntimeInfo.ets。所有 ELF 由 hap-sign-tool 在 HAP 签名时统一做代码签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
CLT="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
OBJCOPY="$CLT/sdk/default/openharmony/native/llvm/bin/llvm-objcopy"
READELF="$CLT/sdk/default/openharmony/native/llvm/bin/llvm-readelf"

LIBS_OUT="$ROOT/entry/libs/arm64-v8a"
PY_NATIVE_MANIFEST="$ROOT/entry/libs/python-native-files.txt"
KIMI_OUT="$ROOT/entry/src/main/resources/resfile/kimicode"
NODE_SRC="$ROOT/vendor/node/node-v$NODE_VERSION-openharmony-arm64"
KIMI_SRC="$ROOT/vendor/kimi-code/package"
DEPS_SRC="$ROOT/vendor/kimi-deps/node_modules"
GIT_SRC="$ROOT/vendor/git/git-$GIT_VERSION-ohos-arm64"
RG_SRC="$ROOT/vendor/tools/rg"
PY_SRC="$ROOT/vendor/python/python-$PYTHON_VERSION-ohos-arm64"

log() { printf '\033[36m[stage-runtime]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[stage-runtime] %s\033[0m\n' "$*" >&2; exit 1; }

for f in "$OBJCOPY" "$NODE_SRC/bin/node" "$KIMI_SRC/dist/main.mjs" "$DEPS_SRC/ws" "$RG_SRC" \
  "$GIT_SRC/bin/git" "$PY_SRC/bin/python3.14" "$PY_SRC/share/terminfo"; do
  [[ -e "$f" ]] || die "缺少 ${f}（先运行 scripts/fetch-deps.sh，或检查 DEVECO_CLI_CLT_PATH）"
done

# 清理旧产物（包括早期版本留下的 HNP 目录）
rm -rf "$LIBS_OUT" "$KIMI_OUT" "$ROOT/entry/hnp" "$ROOT/out/hnp-stage"
rm -f "$PY_NATIVE_MANIFEST"
mkdir -p "$LIBS_OUT" "$KIMI_OUT"

# 给随包可执行文件加上 .permission 节（见官方“应用程序包集成bin文件（PC/2in1）”）：
# 声明 INHERIT_PARENT_PERMISSION 后，bin 被本应用拉起时继承应用的全部 system_grant 权限
# （ALLOW_WRITABLE_CODE_MEMORY → V8 JIT，INTERNET → 联网）。不能再 strip，否则该节会被删掉。
add_permission_section() { # <elf>
  "$OBJCOPY" --add-section ".permission=$ROOT/runtime/bin-permission.json" "$1" "$1.tmp"
  mv "$1.tmp" "$1"
  chmod 0755 "$1"
  [[ "$("$READELF" -S "$1")" == *".permission"* ]] || die "$1 缺少 .permission 节"
}

# --- node → entry/libs/arm64-v8a/ ---------------------------------------------
# 旧版 C++ hap 签名器先检查路径中是否有点号，无扩展名会被静默漏签。
# .bin 只改变包内文件名；运行时用标准命令名的 shell 脚本启动原始已签名文件。
install -m 0755 "$NODE_SRC/bin/node" "$LIBS_OUT/node.bin"
add_permission_section "$LIBS_OUT/node.bin"
log "node $NODE_VERSION → entry/libs/arm64-v8a/node.bin（含 .permission）  $(du -h "$LIBS_OUT/node.bin" | cut -f1)"

# --- rg / git → entry/libs/arm64-v8a/，git 数据与许可证 → resfile ------------
install -m 0755 "$RG_SRC" "$LIBS_OUT/rg.bin"
add_permission_section "$LIBS_OUT/rg.bin"
GIT_BIN_NAMES=(git git-upload-pack git-receive-pack git-upload-archive git-shell)
for name in "${GIT_BIN_NAMES[@]}"; do
  install -m 0755 "$GIT_SRC/bin/$name" "$LIBS_OUT/$name.bin"
  add_permission_section "$LIBS_OUT/$name.bin"
done
install -m 0755 "$GIT_SRC/libexec/git-core/git-remote-https" "$LIBS_OUT/git-remote-https.bin"
add_permission_section "$LIBS_OUT/git-remote-https.bin"
mkdir -p "$KIMI_OUT/git" "$KIMI_OUT/licenses/ripgrep"
cp -R "$GIT_SRC/share" "$KIMI_OUT/git/"
cp "$GIT_SRC/licenses.txt" "$KIMI_OUT/licenses/git.licenses.txt"
cp "$ROOT/runtime/licenses/ripgrep/LICENSE-MIT" "$ROOT/runtime/licenses/ripgrep/UNLICENSE" \
  "$KIMI_OUT/licenses/ripgrep/"
log "rg $(du -h "$LIBS_OUT/rg.bin" | cut -f1) + git ${GIT_VERSION}（含 remote-https、share、许可证）已加入随包 bin"

# --- Python：ELF 平铺进 libs 签名，纯 Python 标准库放 resfile -------------------
PY_LIB_NAMES=(
  libbz2.so.1.0 libcrypto.so.3 libffi.so.8 libgdbm.so.6 libgdbm_compat.so.4
  libintl.so.8 liblzma.so.5 libncursesw.so.6 libpanelw.so.6 libreadline.so.8
  libsqlite3.so libssl.so.3 libuuid.so.1 libz.so.1 libzstd.so.1
)
python_native_files=(python3.bin)
install -m 0755 "$PY_SRC/bin/python3.14" "$LIBS_OUT/python3.bin"
add_permission_section "$LIBS_OUT/python3.bin"
for name in "${PY_LIB_NAMES[@]}"; do
  install -m 0755 "$PY_SRC/lib/$name" "$LIBS_OUT/$name"
  python_native_files+=("$name")
done
for module in "$PY_SRC/lib/python3.14/lib-dynload/"*.so; do
  name="$(basename "$module")"
  install -m 0755 "$module" "$LIBS_OUT/$name"
  python_native_files+=("$name")
done
printf 'libs/arm64-v8a/%s\n' "${python_native_files[@]}" >"$PY_NATIVE_MANIFEST"
mkdir -p "$KIMI_OUT/python/lib" "$KIMI_OUT/python/share"
cp -R "$PY_SRC/lib/python3.14" "$KIMI_OUT/python/lib/"
rm -rf "$KIMI_OUT/python/lib/python3.14/test" \
  "$KIMI_OUT/python/lib/python3.14/config-3.14-aarch64-linux-musl" \
  "$KIMI_OUT/python/lib/python3.14/idlelib" \
  "$KIMI_OUT/python/lib/python3.14/tkinter" \
  "$KIMI_OUT/python/lib/python3.14/turtledemo" \
  "$KIMI_OUT/python/lib/python3.14/lib-dynload"
find "$KIMI_OUT/python/lib/python3.14" -type d -name __pycache__ -prune -exec rm -rf {} +
cp -R "$PY_SRC/share/terminfo" "$KIMI_OUT/python/share/"
cp "$PY_SRC/licenses.txt" "$KIMI_OUT/licenses/python.licenses.txt"
log "Python ${PYTHON_VERSION}（${#python_native_files[@]} 个原生文件，stdlib $(du -sh "$KIMI_OUT/python" | cut -f1)）已加入运行时"

# --- kimi-code → resources/resfile/kimicode/ ---------------------------------
mkdir -p "$KIMI_OUT/package" "$KIMI_OUT/runtime" "$KIMI_OUT/licenses"
# native/ 只是 SEA 自检用的 darwin/linux/win32 原生模块，鸿蒙上用不到
cp -R "$KIMI_SRC/dist" "$KIMI_SRC/dist-web" "$KIMI_SRC/package.json" "$KIMI_SRC/LICENSE" "$KIMI_OUT/package/"
cp -R "$DEPS_SRC" "$KIMI_OUT/package/node_modules"
# npm 作为单个归档携带，避免 HAP 增加数千资源条目；首次更新时由随包 tar 模块解压。
NPM_SRC="$NODE_SRC/lib/node_modules/npm"
mkdir -p "$KIMI_OUT/npm-extract/node_modules/@isaacs"
for name in tar chownr minipass minizlib yallist; do
  cp -cR "$NPM_SRC/node_modules/$name" "$KIMI_OUT/npm-extract/node_modules/"
done
cp -cR "$NPM_SRC/node_modules/@isaacs/fs-minipass" "$KIMI_OUT/npm-extract/node_modules/@isaacs/"
COPYFILE_DISABLE=1 tar -czf "$KIMI_OUT/npm.tar.gz" \
  --exclude='._*' --exclude='*/._*' \
  --exclude='npm/docs' --exclude='npm/man' --exclude='*/.*' \
  --exclude='*.d.ts' --exclude='*.d.mts' --exclude='*.d.cts' \
  -C "$NODE_SRC/lib/node_modules" npm
cp "$ROOT"/runtime/*.cjs "$KIMI_OUT/runtime/"
cp "$NODE_SRC/LICENSE" "$KIMI_OUT/licenses/node.LICENSE"
# hvigor 打包资源时会跳过点文件；这里先删掉，保证磁盘上的内容与 HAP 一致
find "$KIMI_OUT" -name '.*' -prune -exec rm -rf {} +
# 类型声明运行时用不到，而且 hvigor 会把它们当作“意外打包的源码文件”逐个告警
find "$KIMI_OUT" -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' \) -delete
find "$KIMI_OUT" -type d -exec chmod 0755 {} +
find "$KIMI_OUT" -type f -exec chmod 0644 {} +
# 启动脚本必须随包安装到只读目录，并在 ZIP 中保留可执行位；不能在可写 filesDir 中临时生成。
node "$ROOT/scripts/runtime-commands.cjs" "$KIMI_OUT/bin"
log "kimi-code $KIMI_CODE_VERSION → resources/resfile/kimicode  $(du -sh "$KIMI_OUT" | cut -f1)（$(find "$KIMI_OUT" -type f | wc -l | tr -d ' ') 个文件）"

# --- ArkTS 侧的版本常量 ---------------------------------------------------------
cat >"$ROOT/entry/src/main/ets/kimi/RuntimeInfo.ets" <<EOF
// 由 scripts/stage-runtime.sh 生成，勿手改。
export const NODE_VERSION: string = '$NODE_VERSION';
export const KIMI_CODE_VERSION: string = '$KIMI_CODE_VERSION';
/** kimi-code 包在 resfile 中的目录名：运行时路径为 <context.resourceDir>/kimicode */
export const KIMI_RESFILE_DIR: string = 'kimicode';
EOF
log "RuntimeInfo.ets 已更新（node $NODE_VERSION / kimi-code ${KIMI_CODE_VERSION}）"
node "$ROOT/scripts/runtime-manifest.cjs"
