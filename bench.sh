#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export DISPLAY="${DISPLAY:-:99}"; export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"
exec /home/coder/tools/godot --path "$ROOT" --rendering-driver vulkan --audio-driver Dummy \
  --script res://Tests/bench_render.gd -- "${1:-2000}" "${2:-120}"
