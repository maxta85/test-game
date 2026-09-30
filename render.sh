#!/usr/bin/env bash
# Render one or more fixed camera views. ./render.sh street aerial
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export DISPLAY="${DISPLAY:-:99}"; export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"
mkdir -p "$ROOT/shots"
for preset in "$@"; do
  echo "--- rendering $preset ---"
  timeout 1800 /home/coder/tools/godot --path "$ROOT" --rendering-driver vulkan \
    --audio-driver Dummy --resolution 1280x720 --quit-after "${FRAMES:-260}" \
    -- --shot "$ROOT/shots/$preset.png" "$preset" 2>&1 \
    | grep -viE "unreferenced|at: unref|alsa|fontconfig" | grep -E "Shot|collider|ERROR" || true
done
ls -la "$ROOT/shots"/*.png
