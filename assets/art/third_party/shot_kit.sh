#!/usr/bin/env bash
# Before/after contact sheet of the kit's props, on the GPU.
#
#   ./shot_kit.sh <out.png>
#
# `artkit/artkit_shot.gd` renders a fixed-camera sheet of the kit lit the way the
# game lights it at night. That is the only instrument here that can judge a
# texture change on a prop: from a street pose a 13 m palm is 40 px tall and a
# bark map is not measurable, so a street-only comparison proves reachability,
# not appearance.
#
# The camera, the lights and the exposure are constants inside artkit_shot.gd,
# which is what makes two renders comparable: they differ only by what changed in
# artkit/. Freshness is asserted the same way as capture_hoare.sh - delete the
# target first, and fail if no new frame appeared.
set -euo pipefail

ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
GODOT="${GODOT:-/home/coder/tools/godot}"
OUT="${1:?usage: shot_kit.sh <out.png>}"
PROPS="${PROPS:-palm_coco,palm_alexandrine,tree_rain_tree}"

export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

VKLIB="${VKLIB:-/tmp/vk/root/usr/lib/x86_64-linux-gnu}"
if [ ! -e "$VKLIB/libvulkan.so.1" ]; then
  for cand in /tmp/xroot/usr/lib/x86_64-linux-gnu /home/coder/pwlibs/usr/lib/x86_64-linux-gnu; do
    if [ -e "$cand/libvulkan.so.1" ]; then VKLIB="$cand"; break; fi
  done
fi
export LD_LIBRARY_PATH="$VKLIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -e /etc/vulkan/icd.d/nvidia_icd.json ] && export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json

rm -f "$OUT"
LOG="$OUT.log"
timeout 900 "$GODOT" --path "$ROOT" --rendering-driver vulkan --audio-driver Dummy \
  --resolution 1600x900 --script res://artkit/artkit_shot.gd -- \
  --out "$OUT" --props "$PROPS" > "$LOG" 2>&1 || {
    echo "[kit] FATAL godot exited nonzero:" >&2; tail -20 "$LOG" >&2; exit 1; }

grep -viE 'unreferenced|at: unref' "$LOG" | grep -E 'artkit_shot|Vulkan|Using Device|ERROR' || true
grep -q 'NVIDIA' "$LOG" || { echo "[kit] FATAL not a GPU frame" >&2; exit 1; }
[ -s "$OUT" ] || { echo "[kit] FATAL no frame written at $OUT" >&2; exit 1; }
echo "[kit] OK $(md5sum "$OUT")"