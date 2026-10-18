#!/usr/bin/env bash
# 真机不在手边时，在本机 2in1 模拟器上自测：构建 emulator 产品（兼容 API 24）→ 安装 → 启动。
# 用法：scripts/emulator.sh [debug|release]
#
# 模拟器镜像目前最高 HarmonyOS 6.1.1(24)，没有 API 26，所以用 build-profile.json5 里单独的 emulator 产品；
# 对外分发的仍是 scripts/build.sh 产出的 default 产品（只支持 API 26）。模拟器不校验调试 Profile 里的设备列表，
# 直接用 scripts/setup-signing.sh 生成的签名即可，不用（也不要）为它重新生成证书。
# 首次需要创建模拟器（镜像可用 `devecocli emulator image list` 查看）：
#   devecocli emulator create --device-type 2in1 --os-version="HarmonyOS 6.1.1(24)" KimiPC_API24
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-debug}"
EMULATOR="${KIMI_EMULATOR:-KimiPC_API24}"
BUNDLE="com.kimicodehmos.app"
export DEVECO_CLI_CLT_PATH="${DEVECO_CLI_CLT_PATH:-$HOME/DevTools/command-line-tools-26/command-line-tools}"
export PATH="$DEVECO_CLI_CLT_PATH/bin:$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains:$PATH"

log() { printf '\033[36m[emulator]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[emulator] %s\033[0m\n' "$*" >&2; exit 1; }

# 模拟器以 127.0.0.1:<端口> 出现在 hdc 里；真机是 USB 序列号或局域网地址
emulator_target() { hdc list targets 2>/dev/null | tr -d '\r' | grep -E '^127\.0\.0\.1:[0-9]+$' | head -1 || true; }

"$ROOT/scripts/fetch-deps.sh"
"$ROOT/scripts/stage-runtime.sh"
cd "$ROOT"
ohpm install >/dev/null
log "hvigor assembleHap（product=emulator，$MODE）"
hvigorw assembleHap --mode module -p product=emulator -p buildMode="$MODE" --no-daemon
hap="$ROOT/entry/build/emulator/outputs/default/entry-default-signed.hap"
[[ -f "$hap" ]] || die "没有生成已签名 HAP（先运行 scripts/setup-signing.sh）"

target="$(emulator_target)"
if [[ -z "$target" ]]; then
  command -v devecocli >/dev/null || die "没有运行中的模拟器，且找不到 devecocli 来启动 $EMULATOR"
  log "启动模拟器 $EMULATOR"
  devecocli emulator start "$EMULATOR" || die "启动失败；先按脚本开头的命令创建模拟器，或用 KIMI_EMULATOR 指定名称"
  for _ in $(seq 1 60); do
    target="$(emulator_target)"
    if [[ -n "$target" && "$(hdc -t "$target" shell param get bootevent.boot.completed 2>/dev/null)" == *true* ]]; then
      break
    fi
    target=""
    sleep 3
  done
  [[ -n "$target" ]] || die "等待模拟器开机超时"
fi

log "安装 $(basename "$hap") → $target"
result="$(hdc -t "$target" install -r "$hap" 2>&1)"
echo "$result"
[[ "$result" == *"successfully"* ]] || die "安装失败，见上方输出（证书变了要先 hdc -t $target uninstall $BUNDLE）"
hdc -t "$target" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
hdc -t "$target" shell aa start -a EntryAbility -b "$BUNDLE"
log "已启动。日志：hdc -t $target shell \"hilog -T KimiShell\"；截图：hdc -t $target shell snapshot_display -f /data/local/tmp/s.jpeg"
