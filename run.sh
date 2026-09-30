#!/usr/bin/env bash
# Launch CAIRNS AFTER DARK.
#   ./run.sh                       -> windowed game
#   ./run.sh res://Game/menu.tscn  -> run a specific scene
#   ./run.sh --shot boot           -> render 240 frames, save shots/boot.png, quit
#   ./run.sh --shot kerb --preset kerb   -> the same, from a fixed camera preset
#   FRAMES=600 ./run.sh --shot d1  -> longer warm-up before the capture
#
# Presets: absolute street views (start, street, downtown, kerb, carmeet, aerial,
# motorway) and car-relative ones (carhero, carfront, carhigh). See
# Systems/camera/shot_poser.gd. Without --preset you get the chase camera.
#
# Args after a bare `--` are readable in-game via OS.get_cmdline_user_args().
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="${GODOT:-/home/coder/tools/godot}"

# The Vulkan loader must be pinned to lavapipe. Without this the loader probes the
# non-functional virtio ICD and hangs forever at engine init. See ENGINE_DECISION.md.
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

SHOT=""
SCENE=""
PRESET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shot)    SHOT="$2"; shift 2 ;;
    --scene)   SCENE="$2"; shift 2 ;;
    --preset)  PRESET="$2"; shift 2 ;;
    res://*)   SCENE="$1"; shift ;;
    *)         shift ;;
  esac
done

mkdir -p "$ROOT/shots"
GODOT_ARGS=(--path "$ROOT" --rendering-driver vulkan --audio-driver Dummy)
[[ -n "$SHOT" ]] && GODOT_ARGS+=(--quit-after "${FRAMES:-240}")

if [[ -n "$SHOT" ]]; then
  # The preset is the third user arg: --shot takes the path, and main.gd reads
  # the preset after it. Dropping it silently rendered every "preset" shot from
  # the chase camera, which is how a broken camera looks like a broken preset.
  exec "$GODOT" "${GODOT_ARGS[@]}" ${SCENE:+"$SCENE"} -- \
    --shot "$ROOT/shots/$SHOT.png" ${PRESET:+"$PRESET"}
fi
exec "$GODOT" "${GODOT_ARGS[@]}" ${SCENE:+"$SCENE"} "$@"
