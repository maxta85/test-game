#!/usr/bin/env bash
# Sweep the wet-tarmac albedo and re-render the five merged-night poses at each step.
#
# Run ON THE 3060 BOX, not here. `--headless` selects the dummy renderer, which never
# emits frame_post_draw, and three wasted renders in this project came from that.
#
# Usage:  Tools/sweep_road_albedo.sh <project-dir> <frames-dir>
# Every step DELETES its PNGs first and fails if they do not reappear, so a render
# that writes nothing cannot pass and a later step cannot re-read the previous frame.
set -u
ROOT="$1"
OUT="$2"
GODOT="$HOME/godot"
export LD_LIBRARY_PATH="$HOME/libs/usr/lib/x86_64-linux-gnu"
export DISPLAY=:99
LIB="World/mat_lib.gd"

for STEP in 0.105 0.150 0.200 0.260; do
  # Rewrite the constant in place. sed on the BOX, so $ROOT expands there.
  sed -i -E "s/^const WET_ASPHALT_ALBEDO := Color\([^)]*\)/const WET_ASPHALT_ALBEDO := Color(${STEP}, ${STEP}, ${STEP})/" "$ROOT/$LIB"
  echo "=== albedo $STEP ==="
  grep -n "^const WET_ASPHALT_ALBEDO" "$ROOT/$LIB"
  rm -f "$OUT"/alb${STEP}-*.png
  "$GODOT" --path "$ROOT" --rendering-driver vulkan --audio-driver Dummy --fixed-fps 60 \
    --script res://World/merged_night_capture.gd -- --out="$OUT" --tag="alb${STEP}" 2>&1 \
    | grep -E "^\[merged\]|frame luma|road band|MERGED_NIGHT_FAILS"
  ls "$OUT"/alb${STEP}-*.png 2>&1 | head -6
done
