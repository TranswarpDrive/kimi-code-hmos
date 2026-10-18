#!/usr/bin/env bash
# 把 vendor/ 里的依赖放到构建需要的位置（均为生成物，不入库）：
#
#   entry/libs/arm64-v8a/node   鸿蒙版 Node（ohos-node）。在 module.json5 的 executableBinaryPaths 中声明，
#                               安装时随 libs 解压（compressNativeLibs=true）。它的 ELF .permission 节声明
#                               INHERIT_PARENT_PERMISSION，被应用拉起时继承应用的 JIT、联网等权限。
#   entry/src/main/resources/resfile/kimicode/
#                             → 安装后在 <context.resourceDir>/kimicode/（系统解压出的真实文件，只读）
#                                 package/                 kimi-code npm 包（dist/、dist-web/、node_modules/）
#                                 runtime/ohos-preload.cjs 沙箱兼容补丁
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
KIMI_OUT="$ROOT/entry/src/main/resources/resfile/kimicode"
NODE_SRC="$ROOT/vendor/node/node-v$NODE_VERSION-openharmony-arm64"
KIMI_SRC="$ROOT/vendor/kimi-code/package"
DEPS_SRC="$ROOT/vendor/kimi-deps/node_modules"

log() { printf '\033[36m[stage-runtime]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[stage-runtime] %s\033[0m\n' "$*" >&2; exit 1; }

for f in "$OBJCOPY" "$NODE_SRC/bin/node" "$KIMI_SRC/dist/main.mjs" "$DEPS_SRC/ws"; do
  [[ -e "$f" ]] || die "缺少 $f（先运行 scripts/fetch-deps.sh，或检查 DEVECO_CLI_CLT_PATH）"
done

# 清理旧产物（包括早期版本留下的 HNP 目录）
rm -rf "$LIBS_OUT" "$KIMI_OUT" "$ROOT/entry/hnp" "$ROOT/out/hnp-stage"
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
install -m 0755 "$NODE_SRC/bin/node" "$LIBS_OUT/node"
add_permission_section "$LIBS_OUT/node"
log "node $NODE_VERSION → entry/libs/arm64-v8a/node（含 .permission）  $(du -h "$LIBS_OUT/node" | cut -f1)"

# --- kimi-code → resources/resfile/kimicode/ ---------------------------------
mkdir -p "$KIMI_OUT/package" "$KIMI_OUT/runtime" "$KIMI_OUT/licenses"
# native/ 只是 SEA 自检用的 darwin/linux/win32 原生模块，鸿蒙上用不到
cp -R "$KIMI_SRC/dist" "$KIMI_SRC/dist-web" "$KIMI_SRC/package.json" "$KIMI_SRC/LICENSE" "$KIMI_OUT/package/"
cp -R "$DEPS_SRC" "$KIMI_OUT/package/node_modules"
cp "$ROOT/runtime/ohos-preload.cjs" "$KIMI_OUT/runtime/ohos-preload.cjs"
cp "$NODE_SRC/LICENSE" "$KIMI_OUT/licenses/node.LICENSE"
# hvigor 打包资源时会跳过点文件；这里先删掉，保证磁盘上的内容与 HAP 一致
find "$KIMI_OUT" -name '.*' -prune -exec rm -rf {} +
# 类型声明运行时用不到，而且 hvigor 会把它们当作“意外打包的源码文件”逐个告警
find "$KIMI_OUT" -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' \) -delete
find "$KIMI_OUT" -type d -exec chmod 0755 {} +
find "$KIMI_OUT" -type f -exec chmod 0644 {} +
log "kimi-code $KIMI_CODE_VERSION → resources/resfile/kimicode  $(du -sh "$KIMI_OUT" | cut -f1)（$(find "$KIMI_OUT" -type f | wc -l | tr -d ' ') 个文件）"

# --- ArkTS 侧的版本常量 ---------------------------------------------------------
cat >"$ROOT/entry/src/main/ets/kimi/RuntimeInfo.ets" <<EOF
// 由 scripts/stage-runtime.sh 生成，勿手改。
export const NODE_VERSION: string = '$NODE_VERSION';
export const KIMI_CODE_VERSION: string = '$KIMI_CODE_VERSION';
/** kimi-code 包在 resfile 中的目录名：运行时路径为 <context.resourceDir>/kimicode */
export const KIMI_RESFILE_DIR: string = 'kimicode';
EOF
log "RuntimeInfo.ets 已更新（node $NODE_VERSION / kimi-code $KIMI_CODE_VERSION）"
