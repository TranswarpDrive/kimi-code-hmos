#!/usr/bin/env bash
# 一键构建：下载依赖 → stage-runtime → hvigor 构建（InjectRuntime 注入 node + SignHap 签名）→ 复制到 dist/
# 用法：scripts/build.sh [debug|release]
# 总是产出未签名 HAP（分发用）；有 signing/*.local.json 时另产出已签名 HAP（自用）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-release}"
export DEVECO_CLI_CLT_PATH="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
export PATH="$DEVECO_CLI_CLT_PATH/bin:$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains:$PATH"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

log() { printf '\033[36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[build] %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$MODE" == debug || "$MODE" == release ]] || die "构建模式只能是 debug 或 release"
for tool in node npm python3 ohpm hvigorw zip unzip; do
  command -v "$tool" >/dev/null || die "缺少构建工具：$tool"
done

"$ROOT/scripts/fetch-deps.sh"
cd "$ROOT"
npm ci --ignore-scripts --no-audit --no-fund --prefer-offline
npm run check
KIMI_REQUIRE_UPSTREAM=1 npm test
"$ROOT/scripts/stage-runtime.sh"

cd "$ROOT"
ohpm install >/dev/null
# 不允许把上次签名产物误当成本次构建结果。
rm -f "$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
log "hvigor assembleHap（${MODE}）"
hvigorw assembleHap --mode module -p product=default -p buildMode="$MODE" --no-daemon

out="$ROOT/entry/build/default/outputs/default"
version="$(sed -n 's/.*"versionName": *"\([^"]*\)".*/\1/p' "$ROOT/AppScope/app.json5")"
name="KimiCode-hmos-$version-kimi$KIMI_CODE_VERSION-$MODE"
mkdir -p "$ROOT/dist"

check_hap() { # <hap>
  local flags=()
  [[ "$MODE" != release ]] || flags+=(--release)
  python3 "$ROOT/scripts/verify-hap.py" "$1" "${flags[@]}"
}

# 未签名包：发给别人用小白调试助手、HoKit 等工具以他们自己的华为账号重签安装
unsigned="$ROOT/dist/$name-unsigned.hap"
check_hap "$out/entry-default-unsigned.hap"
cp "$out/entry-default-unsigned.hap" "$unsigned"
shasum -a 256 "$unsigned" | awk '{print $1}' >"$unsigned.sha256"
log "未签名（分发用）：${unsigned}（$(du -h "$unsigned" | cut -f1)）"

# 已签名包：用本机签名配置签的，只能装到 Profile 里注册过的设备（scripts/install.sh 用它）
if [[ -f "$out/entry-default-signed.hap" ]]; then
  signed="$ROOT/dist/$name-signed.hap"
  check_hap "$out/entry-default-signed.hap"
  cp "$out/entry-default-signed.hap" "$signed"
  log "已签名（自用）：$signed"
else
  log "未配置签名，没有生成已签名 HAP（自用安装前先运行 scripts/setup-signing.sh）"
fi
