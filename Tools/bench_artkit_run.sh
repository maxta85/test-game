#!/usr/bin/env bash
# Run the scene bench on the render box for one or more presets.
#   .w3bench.sh street aerial carhero carfront
#
# Syncs ~/game-w3, imports (the sync deletes .godot, so the global class cache has
# to be rebuilt before a --script run can resolve class_names), then measures.
# Never touches ~/game - w1, w8 and w10 share it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH="ssh -i $HOME/.ssh/id_ed25519_renderbox -p 2225 -o BatchMode=yes"
PRESETS="${*:-street aerial carhero carfront}"
FRAMES="${FRAMES:-120}"
REPEAT="${REPEAT:-3}"
OFF="${OFF:-}"
PROP_STEP="${PROP_STEP:-}"

"$ROOT/Tools/w3push.sh" || exit 1

$SSH dev@apiserver "cd ~/game-w3 && export GODOT=\$HOME/godot && export LD_LIBRARY_PATH=\$HOME/libs/usr/lib/x86_64-linux-gnu && export XDG_RUNTIME_DIR=/tmp/xdg && mkdir -p \$XDG_RUNTIME_DIR && chmod 700 \$XDG_RUNTIME_DIR && \$GODOT --headless --path . --import >/dev/null 2>&1; for p in $PRESETS; do echo \"##### PRESET \$p\"; timeout 900 \$GODOT --path . --rendering-driver vulkan --resolution 1280x720 --script res://Tools/bench_artkit.gd -- --preset=\$p --frames=$FRAMES --repeat=$REPEAT ${OFF:+--off=$OFF} ${PROP_STEP:+--prop-step=$PROP_STEP} 2>&1 | grep -viE 'Fontconfig|unreferenced|alsa|libpulse|audio driver'; done"