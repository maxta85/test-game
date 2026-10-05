#!/usr/bin/env bash
# A Godot that can actually open Vulkan on this box, for `Tools/render_local_gpu.sh`.
#
# THE PROBLEM, and why this file exists at all
#
# `Tools/render_local_gpu.sh` picks its driver by asking whether a *Vulkan loader
# library* is present, because without one Godot dies at startup in a way that reads
# like a broken project. That probe is `ldconfig -p | grep libvulkan.so.1`, and the
# loader here is not installed system-wide - so the honest answer is "no Vulkan" and
# the script falls back to the Compatibility (OpenGL) renderer. Compatibility has no
# SDFGI, no SSAO and a weaker SSR path, so every night-look number taken through it
# would be a number about a renderer the game does not ship with. `project.godot` says
# `forward_plus`; the numbers have to come from forward_plus or they are not the
# game's numbers.
#
# So this wrapper does two things and nothing else:
#   1. finds a Vulkan loader (`libvulkan.so.1`) that exists on this machine but is not
#      on the loader cache, and puts its directory on LD_LIBRARY_PATH. It never
#      installs anything and never writes outside this worktree.
#   2. rewrites the `--rendering-driver` argument `render_local_gpu.sh` computed to
#      `vulkan`, because the script computes that argument from a probe which cannot
#      see the loader this wrapper just found. Passing the flag twice is not an
#      option worth guessing about, so the pair is filtered out and one explicit flag
#      is put back.
#
# USE
#   GODOT="$PWD/World/render_forward_plus.sh" Tools/render_local_gpu.sh street
#
# IT SAYS WHICH RENDERER IT GOT. If no loader is found, this wrapper does not
# pretend: it prints `[render_forward_plus] no Vulkan loader found; running the
# Compatibility renderer - SDFGI/SSAO numbers from that run are NOT the game's` and
# leaves the driver alone, so a number always arrives with the renderer that
# produced it attached.
set -uo pipefail

REAL_GODOT="${NIGHT_PASS_REAL_GODOT:-/home/coder/tools/godot}"

find_loader_dir() {
	local candidate
	# A real installed loader first: if the box ever gets one, this finds it and the
	# rest of the list is irrelevant.
	for candidate in \
		/usr/lib/*/libvulkan.so.1 \
		/usr/local/lib/libvulkan.so.1 \
		/usr/local/lib/*/libvulkan.so.1 \
		"$HOME"/.local/lib/*/libvulkan.so.1; do
		[ -e "$candidate" ] && { dirname "$candidate"; return 0; }
	done
	# Otherwise a loader someone already unpacked on this machine. Read-only use.
	for candidate in \
		/tmp/vk/root/usr/lib/*/libvulkan.so.1 \
		/tmp/*/vk/lib/libvulkan.so.1 \
		"$HOME"/pwlibs/usr/lib/*/libvulkan.so.1; do
		[ -e "$candidate" ] && { dirname "$candidate"; return 0; }
	done
	return 1
}

loader_dir="$(find_loader_dir)"
if [ -z "$loader_dir" ]; then
	echo "[render_forward_plus] no Vulkan loader found; running the Compatibility renderer" \
		"- SDFGI/SSAO numbers from that run are NOT the game's" >&2
	exec "$REAL_GODOT" "$@"
fi
export LD_LIBRARY_PATH="$loader_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Filter out the caller's `--rendering-driver <x>` pair, then put ours back.
#
# OURS GOES FIRST, NOT LAST, and that ordering is the whole point of this edit.
# Godot splits its command line at the bare `--`: everything before it is an engine
# argument, everything after it is handed to the script as user args and IGNORED.
# `Tools/render_local_gpu.sh` builds its command line as
#     godot --path ROOT --rendering-driver DRIVER ... --quit-after N -- --shot ...
# so its bare `--` is the LAST argument. This wrapper used to append its own
# `--rendering-driver vulkan` after everything it was given, which put it on the
# wrong side of that `--` for every documented invocation: the flag was silently
# dropped and the run fell back to whatever the project defaulted to. The wrapper
# reported `driver=vulkan` on stderr the whole time, so the number carried a
# Forward+ label it had not earned - which is precisely the failure this file
# exists to prevent. Leading position is engine-flag space unconditionally.
argv=()
skip=0
for a in "$@"; do
	if [ "$skip" = 1 ]; then skip=0; continue; fi
	if [ "$a" = "--rendering-driver" ]; then skip=1; continue; fi
	argv+=("$a")
done
echo "[render_forward_plus] driver=vulkan (leading) loader=$loader_dir" >&2
exec "$REAL_GODOT" --rendering-driver vulkan "${argv[@]}"