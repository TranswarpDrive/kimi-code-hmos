#!/usr/bin/env bash
# 通过 hdc 把已签名 HAP 装到已连接的鸿蒙PC 并启动。
# 用法：scripts/install.sh [path/to/xxx-signed.hap]   （默认取当前版本的 release 已签名 HAP）
# 同时连着模拟器时默认选真机（模拟器用 scripts/emulator.sh）；HDC_TARGET=<序列号或 IP:端口> 可指定设备。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="com.kimicodehmos.app"
export DEVECO_CLI_CLT_PATH="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
export PATH="$DEVECO_CLI_CLT_PATH/bin:$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains:$PATH"
source "$ROOT/scripts/versions.env"
version="$(sed -n 's/.*"versionName": *"\([^"]*\)".*/\1/p' "$ROOT/AppScope/app.json5")"
HAP="${1:-$ROOT/dist/KimiCode-hmos-$version-kimi$KIMI_CODE_VERSION-release-signed.hap}"

log() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "$HAP" && -f "$HAP" ]] || die "找不到已签名 HAP，先运行 scripts/setup-signing.sh 和 scripts/build.sh"
command -v hdc >/dev/null || die "缺少 hdc，请检查 DEVECO_CLI_CLT_PATH"
python3 "$ROOT/scripts/verify-hap.py" "$HAP" >/dev/null || die "HAP 校验失败，请重新构建"
# 模拟器以 127.0.0.1:<端口> 出现，跳过它们
target="${HDC_TARGET:-}"
if [[ -z "$target" ]]; then
  targets="$(hdc list targets 2>/dev/null | tr -d '\r' | grep -v -E '^(127\.0\.0\.1:|\[Empty\])' | grep -v '^$' || true)"
  [[ "$(printf '%s\n' "$targets" | grep -c . || true)" -le 1 ]] || die "连接了多台设备，请用 HDC_TARGET 指定安装目标"
  target="$targets"
fi
[[ -n "$target" ]] || die "没有检测到鸿蒙PC（hdc list targets 里没有真机）"
api="$(hdc -t "$target" shell param get const.ohos.apiversion | tr -d '\r\n ')"
[[ "$api" =~ ^[0-9]+$ ]] || die "无法读取设备 API 版本，请确认调试连接已授权"
[[ "$api" -ge 26 ]] || die "此分发包要求 API 26，设备当前为 API $api"

log "安装 $(basename "$HAP") → $target"
result="$(hdc -t "$target" install -r "$HAP" 2>&1)"
echo "$result"
[[ "$result" == *"successfully"* ]] || die "安装失败，见上方输出。请检查设备、Profile 与原证书；不要直接卸载，以免丢失会话。详见 docs/INSTALL.md"

hdc -t "$target" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
hdc -t "$target" shell aa start -a EntryAbility -b "$BUNDLE"
log "已启动。查看日志：hdc -t $target shell \"hilog -T KimiShell\""
