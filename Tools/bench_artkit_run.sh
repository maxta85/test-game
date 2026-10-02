#!/usr/bin/env bash
# Run the art-kit bench on the remote build box for one or more presets.
#   Tools/bench_artkit_run.sh street aerial carhero carfront
#
# Pushes the tree to WFOL_REMOTE_DIR (see Tools/w3push.sh), imports (the sync
# deletes .godot, so the global class cache has to be rebuilt before a --script
# run can resolve class_names), then measures. It only ever writes to its own
# remote directory, never to one shared with another agent.
#
# This repository is public, so the connection details are required parameters
# rather than defaults - nothing here names a host, a user, a port or a key:
#
#   WFOL_SSH_HOST    required  hostname or IP of the build box
#   WFOL_SSH_USER    required  ssh user on that box
#   WFOL_SSH_PORT    required  ssh port
#   WFOL_SSH_KEY     required  private key to authenticate with
#   WFOL_REMOTE_DIR  optional  remote working directory (default: ~/game-w3)
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Tools/bench_artkit_run.sh [preset...]

  WFOL_SSH_HOST    required  hostname or IP of the build box
  WFOL_SSH_USER    required  ssh user on that box
  WFOL_SSH_PORT    required  ssh port
  WFOL_SSH_KEY     required  private key to authenticate with
  WFOL_REMOTE_DIR  optional  remote working directory (default: ~/game-w3)
  FRAMES           optional  frames per measurement (default: 120)
  REPEAT           optional  repeats per preset (default: 3)
USAGE
}

require() {
  [ -n "${!1:-}" ] || { printf 'bench_artkit_run: %s is not set\n\n' "$1" >&2; usage; exit 2; }
}

require WFOL_SSH_HOST
require WFOL_SSH_USER
require WFOL_SSH_PORT
require WFOL_SSH_KEY

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="${WFOL_REMOTE_DIR:-~/game-w3}"
DEST="$WFOL_SSH_USER@$WFOL_SSH_HOST"
SSH=(ssh -i "$WFOL_SSH_KEY" -p "$WFOL_SSH_PORT" -o BatchMode=yes)
PRESETS="${*:-street aerial carhero carfront}"
FRAMES="${FRAMES:-120}"
REPEAT="${REPEAT:-3}"
OFF="${OFF:-}"
PROP_STEP="${PROP_STEP:-}"

"$ROOT/Tools/w3push.sh" || exit 1

"${SSH[@]}" "$DEST" "cd $REMOTE_DIR && export GODOT=\$HOME/godot && export LD_LIBRARY_PATH=\$HOME/libs/usr/lib/x86_64-linux-gnu && export XDG_RUNTIME_DIR=/tmp/xdg && mkdir -p \$XDG_RUNTIME_DIR && chmod 700 \$XDG_RUNTIME_DIR && \$GODOT --headless --path . --import >/dev/null 2>&1; for p in $PRESETS; do echo \"##### PRESET \$p\"; timeout 900 \$GODOT --path . --rendering-driver vulkan --resolution 1280x720 --script res://Tools/bench_artkit.gd -- --preset=\$p --frames=$FRAMES --repeat=$REPEAT ${OFF:+--off=$OFF} ${PROP_STEP:+--prop-step=$PROP_STEP} 2>&1 | grep -viE 'Fontconfig|unreferenced|alsa|libpulse|audio driver'; done"