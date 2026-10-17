#!/usr/bin/env bash
# 把 vendor/ 里的依赖组装成两个私有 HNP，输出到 entry/hnp/arm64-v8a/：
#
#   node.hnp      → 沙箱 /data/app/node.org/node_<NODE_VERSION>/
#                     bin/node                 鸿蒙版 Node（ohos-node）
#                     lib/libc++_shared.so     SDK 自带 C++ 运行时（node 无 RUNPATH，经 LD_LIBRARY_PATH 加载）
#                     lib/libkimicompat.so     SIGSYS 兼容层（LD_PRELOAD）
#   kimicode.hnp  → 沙箱 /data/app/kimicode.org/kimicode_<KIMI_CODE_VERSION>/
#                     package/                 kimi-code npm 包（dist/、dist-web/、node_modules/）
#                     runtime/ohos-preload.cjs 沙箱兼容补丁
#
# 同时生成 entry/src/main/ets/kimi/RuntimeInfo.ets，让 ArkTS 侧知道安装路径。
# HNP 内的 ELF 由 hap-sign-tool 在 HAP 签名时统一做代码签名，这里不单独签。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"
CLT="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
SDK="$CLT/sdk/default/openharmony"
HNPCLI="$SDK/toolchains/hnpcli"
LLVM="$SDK/native/llvm"
CC="$LLVM/bin/aarch64-unknown-linux-ohos-clang"
STRIP="$LLVM/bin/llvm-strip"
READELF="$LLVM/bin/llvm-readelf"

STAGE="$ROOT/out/hnp-stage"
HNP_OUT="$ROOT/entry/hnp/arm64-v8a"
NODE_SRC="$ROOT/vendor/node/node-v$NODE_VERSION-openharmony-arm64"
KIMI_SRC="$ROOT/vendor/kimi-code/package"
DEPS_SRC="$ROOT/vendor/kimi-deps/node_modules"

log() { printf '\033[36m[build-hnp]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[build-hnp] %s\033[0m\n' "$*" >&2; exit 1; }

for f in "$HNPCLI" "$CC" "$NODE_SRC/bin/node" "$KIMI_SRC/dist/main.mjs" "$DEPS_SRC/ws"; do
  [[ -e "$f" ]] || die "缺少 $f（先运行 scripts/fetch-deps.sh，或检查 DEVECO_CLI_CLT_PATH）"
done

rm -rf "$STAGE" "$HNP_OUT"
mkdir -p "$STAGE" "$HNP_OUT"

write_hnp_json() { # <dir> <name> <version> <links-json>
  cat >"$1/hnp.json" <<EOF
{
  "type": "hnp-config",
  "name": "$2",
  "version": "$3",
  "install": {
    "links": $4
  }
}
EOF
}

pack() { # <stage dir> <expected hnp file name>
  "$HNPCLI" pack -i "$1" -o "$HNP_OUT" >/dev/null
  [[ -f "$HNP_OUT/$2" ]] || die "hnpcli 未生成 $HNP_OUT/$2（实际：$(ls "$HNP_OUT")）"
  log "$2  $(du -h "$HNP_OUT/$2" | cut -f1)"
}

# --- node.hnp ---------------------------------------------------------------
node_stage="$STAGE/node"
mkdir -p "$node_stage/bin" "$node_stage/lib"
install -m 0755 "$NODE_SRC/bin/node" "$node_stage/bin/node"
install -m 0755 "$LLVM/lib/aarch64-linux-ohos/libc++_shared.so" "$node_stage/lib/libc++_shared.so"
"$CC" -shared -fPIC -O2 -Wall -Wextra -Werror -o "$node_stage/lib/libkimicompat.so" "$ROOT/runtime/compat/ohos_compat.c"
"$STRIP" --strip-unneeded "$node_stage/lib/libkimicompat.so"
chmod 0755 "$node_stage/lib/libkimicompat.so"
install -m 0644 "$NODE_SRC/LICENSE" "$node_stage/LICENSE"
[[ "$("$READELF" -h "$node_stage/lib/libkimicompat.so")" == *AArch64* ]] || die "libkimicompat.so 不是 AArch64"
write_hnp_json "$node_stage" node "$NODE_VERSION" '[{ "source": "/bin/node", "target": "node" }]'
pack "$node_stage" node.hnp

# --- kimicode.hnp -----------------------------------------------------------
kimi_stage="$STAGE/kimicode"
mkdir -p "$kimi_stage/package" "$kimi_stage/runtime"
# native/ 只是 SEA 自检用的 darwin/linux/win32 原生模块，鸿蒙上用不到
cp -R "$KIMI_SRC/dist" "$KIMI_SRC/dist-web" "$KIMI_SRC/package.json" "$KIMI_SRC/LICENSE" "$kimi_stage/package/"
cp -R "$DEPS_SRC" "$kimi_stage/package/node_modules"
rm -rf "$kimi_stage/package/node_modules/.package-lock.json"
install -m 0644 "$ROOT/runtime/ohos-preload.cjs" "$kimi_stage/runtime/ohos-preload.cjs"
# 安装后文件沿用这里的 UGO 权限：统一成目录 755、文件 644
find "$kimi_stage" -type d -exec chmod 0755 {} +
find "$kimi_stage" -type f -exec chmod 0644 {} +
write_hnp_json "$kimi_stage" kimicode "$KIMI_CODE_VERSION" '[]'
pack "$kimi_stage" kimicode.hnp

# --- ArkTS 侧的路径常量 ---------------------------------------------------------
cat >"$ROOT/entry/src/main/ets/kimi/RuntimeInfo.ets" <<EOF
// 由 scripts/build-hnp.sh 生成，勿手改。私有 HNP 安装后的沙箱路径：/data/app/<name>.org/<name>_<version>/
export const NODE_VERSION: string = '$NODE_VERSION';
export const KIMI_CODE_VERSION: string = '$KIMI_CODE_VERSION';
export const NODE_HNP_ROOT: string = '/data/app/node.org/node_$NODE_VERSION';
export const KIMI_HNP_ROOT: string = '/data/app/kimicode.org/kimicode_$KIMI_CODE_VERSION';
EOF
log "RuntimeInfo.ets 已更新（node $NODE_VERSION / kimi-code $KIMI_CODE_VERSION）"
