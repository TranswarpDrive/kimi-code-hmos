#!/usr/bin/env bash
# 通过 hdc 把已签名 HAP 装到已连接的鸿蒙PC 并启动。
# 用法：scripts/install.sh [path/to/xxx-signed.hap]   （默认取 dist/ 下最新的已签名 HAP）
# 同时连着模拟器时默认选真机（模拟器用 scripts/emulator.sh）；HDC_TARGET=<序列号或 IP:端口> 可指定设备。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="com.kimicodehmos.app"
HAP="${1:-$(ls -t "$ROOT"/dist/*-signed.hap 2>/dev/null | head -1 || true)}"

log() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "$HAP" && -f "$HAP" ]] || die "找不到已签名 HAP，先运行 scripts/setup-signing.sh 和 scripts/build.sh"
# 模拟器以 127.0.0.1:<端口> 出现，跳过它们
target="${HDC_TARGET:-$(hdc list targets 2>/dev/null | tr -d '\r' | grep -v -E '^(127\.0\.0\.1:|\[Empty\])' | grep -v '^$' | head -1 || true)}"
[[ -n "$target" ]] || die "没有检测到鸿蒙PC（hdc list targets 里没有真机）"

log "安装 $(basename "$HAP") → $target"
result="$(hdc -t "$target" install -r "$HAP" 2>&1)"
echo "$result"
[[ "$result" == *"successfully"* ]] || die "安装失败，见上方输出（签名/Profile 设备不匹配时请重新运行 scripts/setup-signing.sh）"

hdc -t "$target" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
hdc -t "$target" shell aa start -a EntryAbility -b "$BUNDLE"
log "已启动。查看日志：hdc -t $target shell \"hilog -T KimiShell\""
