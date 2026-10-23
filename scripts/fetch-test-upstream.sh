#!/usr/bin/env bash
# CI 仅下载锁定的 Kimi 包，用真实搜索代码测试兼容层，无需鸿蒙 SDK 或签名。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/versions.env"
mkdir -p "$ROOT/vendor/downloads"
archive="$ROOT/vendor/downloads/moonshot-ai-kimi-code-$KIMI_CODE_VERSION.tgz"
if [[ ! -f "$archive" ]]; then
  (cd "$ROOT/vendor/downloads" && npm pack "@moonshot-ai/kimi-code@$KIMI_CODE_VERSION" --ignore-scripts --silent >/dev/null)
fi
actual="sha512-$(openssl dgst -sha512 -binary "$archive" | openssl base64 -A)"
[[ "$actual" == "$KIMI_CODE_INTEGRITY" ]] || { echo 'Kimi package integrity mismatch' >&2; exit 1; }
rm -rf "$ROOT/vendor/kimi-code"
mkdir -p "$ROOT/vendor/kimi-code"
tar -xzf "$archive" -C "$ROOT/vendor/kimi-code"
echo "Verified @moonshot-ai/kimi-code@$KIMI_CODE_VERSION"
