#!/usr/bin/env bash
# 把 vendor/ 里的依赖放到构建需要的位置：
#
#   entry/libs/arm64-v8a/node   鸿蒙版 Node（ohos-node）。在 module.json5 的 executableBinaryPaths 中声明，
#                               安装时随 libs 解压（compressNativeLibs=true），并获得应用的内核权限
#                               （ALLOW_WRITABLE_CODE_MEMORY → V8 JIT）。放在 HNP 里的二进制拿不到该权限。
#   entry/hnp/arm64-v8a/kimicode.hnp
#                             → 沙箱 /data/app/kimicode.org/kimicode_<KIMI_CODE_VERSION>/
#                                 package/                 kimi-code npm 包（dist/、dist-web/、node_modules/）
#                                 runtime/ohos-preload.cjs 沙箱兼容补丁
#                                 licenses/                随包二进制的许可证
#
# libkimicompat.so、libkimihost.so 由 entry 的 CMake 构建；libc++_shared.so 由 hvigor 自动带上。
# 同时生成 entry/src/main/ets/kimi/RuntimeInfo.ets。所有 ELF 由 hap-sign-tool 在 HAP 签名时统一做代码签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
CLT="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
HNPCLI="$CLT/sdk/default/openharmony/toolchains/hnpcli"
CC="$CLT/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang"
OBJCOPY="$CLT/sdk/default/openharmony/native/llvm/bin/llvm-objcopy"
READELF="$CLT/sdk/default/openharmony/native/llvm/bin/llvm-readelf"

STAGE="$ROOT/out/hnp-stage"
LIBS_OUT="$ROOT/entry/libs/arm64-v8a"
HNP_OUT="$ROOT/entry/hnp/arm64-v8a"
NODE_SRC="$ROOT/vendor/node/node-v$NODE_VERSION-openharmony-arm64"
KIMI_SRC="$ROOT/vendor/kimi-code/package"
DEPS_SRC="$ROOT/vendor/kimi-deps/node_modules"

log() { printf '\033[36m[stage-runtime]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[stage-runtime] %s\033[0m\n' "$*" >&2; exit 1; }

for f in "$HNPCLI" "$NODE_SRC/bin/node" "$KIMI_SRC/dist/main.mjs" "$DEPS_SRC/ws"; do
  [[ -e "$f" ]] || die "缺少 $f（先运行 scripts/fetch-deps.sh，或检查 DEVECO_CLI_CLT_PATH）"
done

rm -rf "$STAGE" "$HNP_OUT" "$LIBS_OUT"
mkdir -p "$STAGE" "$HNP_OUT" "$LIBS_OUT"

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
# 诊断工具：检查被拉起的二进制能否获得 JIT 所需的可执行内存
"$CC" -O2 -Wall -o "$LIBS_OUT/jitprobe" "$ROOT/entry/src/main/cpp/tools/jitprobe.c"
add_permission_section "$LIBS_OUT/jitprobe"

# --- kimicode.hnp -----------------------------------------------------------
kimi_stage="$STAGE/kimicode"
mkdir -p "$kimi_stage/package" "$kimi_stage/runtime" "$kimi_stage/licenses"
# native/ 只是 SEA 自检用的 darwin/linux/win32 原生模块，鸿蒙上用不到
cp -R "$KIMI_SRC/dist" "$KIMI_SRC/dist-web" "$KIMI_SRC/package.json" "$KIMI_SRC/LICENSE" "$kimi_stage/package/"
cp -R "$DEPS_SRC" "$kimi_stage/package/node_modules"
rm -f "$kimi_stage/package/node_modules/.package-lock.json"
cp "$ROOT/runtime/ohos-preload.cjs" "$kimi_stage/runtime/ohos-preload.cjs"
cp "$NODE_SRC/LICENSE" "$kimi_stage/licenses/node.LICENSE"
# 安装后文件沿用这里的 UGO 权限：统一成目录 755、文件 644
find "$kimi_stage" -type d -exec chmod 0755 {} +
find "$kimi_stage" -type f -exec chmod 0644 {} +
cat >"$kimi_stage/hnp.json" <<EOF
{
  "type": "hnp-config",
  "name": "kimicode",
  "version": "$KIMI_CODE_VERSION",
  "install": {
    "links": []
  }
}
EOF
"$HNPCLI" pack -i "$kimi_stage" -o "$HNP_OUT" >/dev/null
[[ -f "$HNP_OUT/kimicode.hnp" ]] || die "hnpcli 未生成 kimicode.hnp（实际：$(ls "$HNP_OUT")）"
log "kimicode.hnp  $(du -h "$HNP_OUT/kimicode.hnp" | cut -f1)"

# --- ArkTS 侧的版本与路径常量 -----------------------------------------------------
cat >"$ROOT/entry/src/main/ets/kimi/RuntimeInfo.ets" <<EOF
// 由 scripts/stage-runtime.sh 生成，勿手改。私有 HNP 安装后的沙箱路径：/data/app/<name>.org/<name>_<version>/
export const NODE_VERSION: string = '$NODE_VERSION';
export const KIMI_CODE_VERSION: string = '$KIMI_CODE_VERSION';
export const KIMI_HNP_ROOT: string = '/data/app/kimicode.org/kimicode_$KIMI_CODE_VERSION';
EOF
log "RuntimeInfo.ets 已更新（node $NODE_VERSION / kimi-code $KIMI_CODE_VERSION）"
