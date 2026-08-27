#!/bin/bash
# Dedicated Dria launcher for Apple M4 Max with 128 GB unified memory.

set -Eeuo pipefail

bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '0')"
gb=0
if [[ "$bytes" =~ ^[0-9]+$ ]]; then
  gb=$((bytes / 1024 / 1024 / 1024))
fi

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  printf '[错误] 这个脚本仅用于 Apple Silicon Mac。\n' >&2
  exit 1
fi

if [ "$gb" -lt 96 ]; then
  printf '[错误] 检测到约 %sGB 内存；这个脚本专门用于 M4 Max 128GB。\n' "$gb" >&2
  printf '普通 M4 16GB 请使用 deploy_dria.sh。\n' >&2
  exit 1
fi

printf '检测到 Apple Silicon，约 %sGB 内存。\n' "$gb"
printf 'M4 Max 模式：qwen3.5:9b + lfm2.5:1.2b，并发 2。\n\n'

export DRIA_MODEL="qwen3.5:9b,lfm2.5:1.2b"
export DRIA_MAX_CONCURRENT="2"
export DRIA_INSTALL_PROFILE="m4max"

bash <(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
  https://raw.githubusercontent.com/baibai131131/deploy_nodes/refs/heads/main/deploy_dria.sh)
