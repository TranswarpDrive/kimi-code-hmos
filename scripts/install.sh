#!/usr/bin/env bash
# 通过 hdc 把已签名 HAP 装到已连接的鸿蒙PC 并启动。
# 用法：scripts/install.sh [path/to/xxx-signed.hap]   （默认取 dist/ 下最新的已签名 HAP）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="com.kimicodehmos.app"
HAP="${1:-$(ls -t "$ROOT"/dist/*-signed.hap 2>/dev/null | head -1 || true)}"

log() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "$HAP" && -f "$HAP" ]] || die "找不到已签名 HAP，先运行 scripts/setup-signing.sh 和 scripts/build.sh"
targets="$(hdc list targets 2>&1 || true)"
[[ -n "$targets" && "$targets" != *"[Empty]"* ]] || die "没有检测到设备（hdc list targets 为空）"

log "安装 $(basename "$HAP") → $(echo "$targets" | head -1)"
result="$(hdc install -r "$HAP" 2>&1)"
echo "$result"
[[ "$result" == *"successfully"* ]] || die "安装失败，见上方输出（签名/Profile 设备不匹配时请重新运行 scripts/setup-signing.sh）"

hdc shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
hdc shell aa start -a EntryAbility -b "$BUNDLE"
log "已启动。查看日志：hdc shell hilog -x | grep KimiShell"
