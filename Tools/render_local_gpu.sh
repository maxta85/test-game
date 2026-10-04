#!/usr/bin/env bash
# Render fixed camera presets on whatever GPU this box actually has.
#
#   Tools/render_local_gpu.sh <preset> [preset...]        -> shots/<preset>.png
#   Tools/render_local_gpu.sh --out <dir> <preset> [preset...]
#
# `./render.sh` asks for Vulkan. On a machine with no Vulkan loader that is not a
# driver error to work around, it is a missing library, and Godot reports it as
# `Could not initialize vulkan` at DisplayServerX11 followed by a Wayland
# failure and then a SIGSEGV during startup - which reads exactly like a broken
# project. So this script probes for the loader first and picks the renderer that
# can actually initialise, and says which one it picked.
#
# Two rules it will not let you skip:
#
#   1. The target PNG is deleted before the render, and the run fails if it did
#      not come back. A render that dies silently leaves the previous frame in
#      place, and a measurement loop over rendered output then reports one stale
#      image N times as if it were N data points.
#   2. The `[Shot] preset=... camera=...` line is printed. Whatever drives the
#      camera back there every frame ("print where the shot was actually taken
#      from") is the only evidence that the preset was honoured; a preset that
#      silently did nothing produces a plausible-looking chase shot.
#
# Same driver for a before/after pair, or the numbers mean nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-/home/coder/tools/godot}"
FRAMES="${FRAMES:-300}"
OUT="$ROOT/shots"

if [ "${1:-}" = "--out" ]; then
	OUT="$2"
	shift 2
fi
if [ "$#" -eq 0 ]; then
	echo "usage: $0 [--out <dir>] <preset> [preset...]" >&2
	exit 2
fi

# Probe, do not assume. libvulkan.so.1 is the loader; without it every Vulkan
# attempt above dies at startup whatever the ICD situation is.
if ldconfig -p 2>/dev/null | grep -q libvulkan.so.1 \
	|| ls /usr/lib/*/libvulkan.so.1 >/dev/null 2>&1; then
	DRIVER=vulkan
else
	DRIVER=opengl3
fi
echo "[render_local_gpu] driver=$DRIVER godot=$GODOT frames=$FRAMES out=$OUT"
if [ "$DRIVER" = opengl3 ]; then
	echo "[render_local_gpu] no Vulkan loader on this box (libvulkan.so.1 absent);" \
		"using the Compatibility renderer. Geometry is renderer-independent;" \
		"luminance and clipping are not - say which one a number came from."
fi

export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR" "$OUT"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

fail=0
for preset in "$@"; do
	target="$OUT/$preset.png"
	log="$OUT/$preset.log"
	rm -f "$target"
	timeout 1800 "$GODOT" --path "$ROOT" --rendering-driver "$DRIVER" \
		--audio-driver Dummy --resolution 1280x720 --quit-after "$FRAMES" \
		-- --shot "$target" "$preset" >"$log" 2>&1
	if ! grep -q "\[Shot\] wrote" "$log"; then
		echo "[render_local_gpu] FAIL $preset: no '[Shot] wrote' in $log" >&2
		grep -iE "error|vulkan|segmentation" "$log" | head -5 >&2
		fail=1
		continue
	fi
	grep -E "\[Shot\]" "$log"
	ls -la "$target"
done
exit "$fail"