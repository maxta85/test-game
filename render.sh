#!/usr/bin/env bash
# Render one or more fixed camera views. ./render.sh street aerial
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same override test.sh already uses, so the render box needs no /home/coder.
GODOT="${GODOT:-/home/coder/tools/godot}"
# No VK_ICD_FILENAMES override. It used to hardcode lavapipe, which pinned every
# render to software rasterisation on any machine - including one with a real GPU
# in it, where the file does not even exist and Vulkan falls back with nothing.
# The loader enumerates whatever is in the standard ICD dir: lavapipe on a CPU
# box, nvidia_icd.json on a GPU one. Set it by hand only to force a specific one.
export DISPLAY="${DISPLAY:-:99}"; export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"
mkdir -p "$ROOT/shots"
for preset in "$@"; do
  echo "--- rendering $preset ---"
  timeout 1800 "$GODOT" --path "$ROOT" --rendering-driver vulkan \
    --audio-driver Dummy --resolution 1280x720 --quit-after "${FRAMES:-260}" \
    -- --shot "$ROOT/shots/$preset.png" "$preset" 2>&1 \
    | grep -viE "unreferenced|at: unref|alsa|fontconfig" | grep -E "Shot|collider|ERROR" || true
done
ls -la "$ROOT/shots"/*.png
