#!/usr/bin/env bash
# 一键构建：下载依赖 → 打 HNP → hvigor 构建（InjectHnp 注入 + SignHap 签名）→ 复制到 dist/
# 用法：scripts/build.sh [debug|release]
# 没有 signing/*.local.json 时只产出未签名 HAP（可用于检查结构，不能安装）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-debug}"
export DEVECO_CLI_CLT_PATH="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
export PATH="$DEVECO_CLI_CLT_PATH/bin:$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains:$PATH"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

log() { printf '\033[36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[build] %s\033[0m\n' "$*" >&2; exit 1; }

"$ROOT/scripts/fetch-deps.sh"
"$ROOT/scripts/build-hnp.sh"

cd "$ROOT"
ohpm install >/dev/null
log "hvigor assembleHap（$MODE）"
hvigorw assembleHap --mode module -p product=default -p buildMode="$MODE" --no-daemon

out="$ROOT/entry/build/default/outputs/default"
version="$(sed -n 's/.*"versionName": *"\([^"]*\)".*/\1/p' "$ROOT/AppScope/app.json5")"
name="KimiCode-hmos-$version-kimi$KIMI_CODE_VERSION-$MODE"
mkdir -p "$ROOT/dist"

if [[ -f "$out/entry-default-signed.hap" ]]; then
  hap="$ROOT/dist/$name-signed.hap"
  cp "$out/entry-default-signed.hap" "$hap"
else
  hap="$ROOT/dist/$name-unsigned.hap"
  cp "$out/entry-default-unsigned.hap" "$hap"
  log "未配置签名，只生成了未签名 HAP；先运行 scripts/setup-signing.sh"
fi

listing="$(unzip -l "$hap")"
for entry in hnp/arm64-v8a/node.hnp hnp/arm64-v8a/kimicode.hnp libs/arm64-v8a/libkimihost.so module.json; do
  [[ "$listing" == *"$entry"* ]] || die "HAP 缺少 $entry"
done
log "产物：$hap（$(du -h "$hap" | cut -f1)）"
