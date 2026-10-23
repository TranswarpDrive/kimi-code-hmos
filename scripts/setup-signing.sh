#!/usr/bin/env bash
# 首次配置调试签名（调试证书 + 调试 Profile，绑定当前连接设备的 UDID）。前提：
#   1. 鸿蒙PC 已开启开发者模式，并通过 USB 或无线调试连到本机（hdc list targets 能看到）
#   2. 华为开发者账号（未登录时会执行 devecocli auth login，在浏览器里完成登录）
#
# devecocli signature generate 会改写 build-profile.json5（并丢掉注释），这里先备份，
# 生成后把签名配置提取到 signing/<product>.local.json（不入库），再还原 build-profile.json5。
# 根目录 hvigorfile.ts 在构建时自动注入该文件。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVECO_CLI_CLT_PATH="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
export PATH="$DEVECO_CLI_CLT_PATH/bin:$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains:$PATH"
JSON5_DIR="$DEVECO_CLI_CLT_PATH/hvigor/hvigor-ohos-plugin/node_modules/json5"
PRODUCT="${1:-default}"
OUT="$ROOT/signing/$PRODUCT.local.json"

log() { printf '\033[36m[setup-signing]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[setup-signing] %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$PRODUCT" == default || "$PRODUCT" == emulator ]] || die "产品只能是 default 或 emulator"
if [[ -f "$OUT" && " $* " != *" --force "* ]]; then
  log "已存在签名配置，日常升级直接运行 scripts/build.sh 和 scripts/install.sh。需要续期/变更 Profile 时先备份原证书，再显式使用 --force。"
  exit 0
fi
command -v devecocli >/dev/null || die "找不到 devecocli（npm i -g @deveco/deveco-cli）"
command -v hdc >/dev/null || die "找不到 hdc（检查 CLT 的 toolchains 是否在 PATH）"

targets="$(hdc list targets 2>&1 || true)"
if [[ -z "$targets" || "$targets" == *"[Empty]"* ]]; then
  die "没有检测到设备。请在鸿蒙PC 上打开 设置 > 系统 > 开发者选项（USB 调试或无线调试），连接后重试。"
fi
log "设备：$(echo "$targets" | tr '\n' ' ')"

if devecocli auth status 2>&1 | grep -qi 'not logged in'; then
  log "需要登录华为开发者账号，即将打开浏览器…"
  devecocli auth login
fi
log "华为账号登录状态已检查"

backup="$(mktemp "${TMPDIR:-/tmp}/build-profile.XXXXXX")"
cp "$ROOT/build-profile.json5" "$backup"
trap 'cp "$backup" "$ROOT/build-profile.json5"; rm -f "$backup"' EXIT

log "生成签名材料（调试证书 + 调试 Profile）…"
(cd "$ROOT" && devecocli signature generate --product "$PRODUCT" "${@:2}")

node "$ROOT/scripts/lib/extract-signing.mjs" "$ROOT/build-profile.json5" "$PRODUCT" "$OUT" "$JSON5_DIR"
log "完成。之后直接运行 scripts/build.sh 即可产出已签名 HAP。"
