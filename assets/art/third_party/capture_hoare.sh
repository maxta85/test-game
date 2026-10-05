#!/usr/bin/env bash
# Render the Hoare Street before/after frames on the local GPU.
#
#   ./capture_hoare.sh before|after   ->  /tmp/t194/$PHASE/
#
# ## Why this script exists
#
# Both lessons here were learned the hard way in this fleet and both are silent:
#
# 1. **A silent no-op looks exactly like a fresh render.** A run that produces no
#    frame leaves the previous run's PNG on disk, and every number read out of it
#    afterwards is stale while looking entirely new. So the target directory is
#    recreated from empty on every run, and the script fails loudly if no new
#    PNG exists at the end.
#
# 2. **The Vulkan ICD needs both the env var and the loader on the library path.**
#    `nvidia_icd.json` is present at /etc/vulkan/icd.d/ and `libGLX_nvidia.so.0`
#    is in ldconfig, but `libvulkan.so.1` is not on the default path in this
#    image, so Godot reports "Could not initialize vulkan" and then *exits 0*
#    having drawn nothing. Falling back to opengl3 silently substitutes
#    llvmpipe for the RTX 3060, which is not a GPU frame by any honest reading.
#    So: set VK_ICD_FILENAMES and LD_LIBRARY_PATH, and assert in the log that the
#    device really is the NVIDIA one.
set -euo pipefail

# The Godot *project* root, which is three directories above this script - not
# this script's own directory. Deriving it from BASH_SOURCE makes `--path` point
# at assets/art/third_party, Godot finds no project, and it fails with
# "Attempt to open script 'res://Tools/street_capture.gd' resulted in error
# 'File not found'" - a message that reads like a missing script and is actually
# a missing project.
ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [ ! -f "$ROOT/project.godot" ]; then
  echo "FATAL: $ROOT is not a Godot project root (no project.godot)" >&2
  exit 2
fi
GODOT="${GODOT:-/home/coder/tools/godot}"
PHASE="${1:?usage: capture_hoare.sh before|after}"
OUT="${OUT:-/tmp/t194/$PHASE}"
LOG="$OUT.log"

case "$PHASE" in
  before|after) ;;
  *) echo "phase must be 'before' or 'after', got '$PHASE'" >&2; exit 2 ;;
esac

export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

# The Vulkan loader lives outside the default search path in this image.
VKLIB="${VKLIB:-/tmp/vk/root/usr/lib/x86_64-linux-gnu}"
if [ ! -e "$VKLIB/libvulkan.so.1" ]; then
  for cand in /tmp/xroot/usr/lib/x86_64-linux-gnu /home/coder/pwlibs/usr/lib/x86_64-linux-gnu; do
    if [ -e "$cand/libvulkan.so.1" ]; then VKLIB="$cand"; break; fi
  done
fi
export LD_LIBRARY_PATH="$VKLIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ -e /etc/vulkan/icd.d/nvidia_icd.json ]; then
  export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
fi

# Fresh output directory. This is the guard against reading a stale frame.
rm -rf "$OUT"
mkdir -p "$OUT"

echo "[capture] phase=$PHASE out=$OUT"
timeout 1800 "$GODOT" --path "$ROOT" --rendering-driver vulkan \
  --audio-driver Dummy --resolution 1280x720 \
  --script res://Tools/street_capture.gd -- \
  --out "$OUT" --street "Hoare Street" > "$LOG" 2>&1 || {
    echo "[capture] FATAL godot exited nonzero; tail of log:" >&2
    tail -30 "$LOG" >&2
    exit 1
  }

grep -viE 'unreferenced|at: unref' "$LOG" | grep -E '\[shot\]|Vulkan|ERROR' || true

# Assert a real GPU frame. llvmpipe would satisfy every other check here.
if ! grep -q 'NVIDIA' "$LOG"; then
  echo "[capture] FATAL no NVIDIA device in the log - this is not a GPU frame" >&2
  grep -iE 'Using Device|OpenGL API' "$LOG" >&2 || true
  exit 1
fi

# Assert freshness: four non-empty PNGs, all distinct, all newly written.
n=$(find "$OUT" -name '*.png' -size +1k | wc -l)
if [ "$n" -ne 4 ]; then
  echo "[capture] FATAL expected 4 frames >1k in $OUT, found $n" >&2
  ls -la "$OUT" >&2
  exit 1
fi
u=$(md5sum "$OUT"/*.png | awk '{print $1}' | sort -u | wc -l)
if [ "$u" -ne 4 ]; then
  echo "[capture] FATAL frames are not distinct ($u unique of 4)" >&2
  exit 1
fi

echo "[capture] OK 4 distinct fresh frames"
ls -la "$OUT"/*.png
md5sum "$OUT"/*.png