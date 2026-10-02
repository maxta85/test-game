#!/usr/bin/env bash
# Push this project to a remote build box over SSH. Real tooling, not a stub.
#
# The destination is this worker's own copy of the tree and never a shared one.
# Several agents push into this repository at the same time, so a push to a
# directory another agent also writes overwrites their work mid-build. Point
# WFOL_REMOTE_DIR somewhere else if you need to.
#
# The connection details are required parameters, not defaults. This repository
# is public, so nothing here names a host, a user, a port or a key file. All
# four must be set or the script refuses to run:
#
#   WFOL_SSH_HOST    required  hostname or IP of the build box
#   WFOL_SSH_USER    required  ssh user on that box
#   WFOL_SSH_PORT    required  ssh port
#   WFOL_SSH_KEY     required  private key to authenticate with
#   WFOL_REMOTE_DIR  optional  remote destination (default: ~/game-wfol)
#
#   WFOL_SSH_HOST=box WFOL_SSH_USER=you WFOL_SSH_PORT=22 \
#   WFOL_SSH_KEY=~/.ssh/id_ed25519 Tools/wfol_push.sh
#
# Tar + scp rather than rsync because the box has no rsync server side. .godot is
# excluded and rebuilt on the box, so it costs nothing to keep it out.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Tools/wfol_push.sh

  WFOL_SSH_HOST    required  hostname or IP of the build box
  WFOL_SSH_USER    required  ssh user on that box
  WFOL_SSH_PORT    required  ssh port
  WFOL_SSH_KEY     required  private key to authenticate with
  WFOL_REMOTE_DIR  optional  remote destination (default: ~/game-wfol)

Example:
  WFOL_SSH_HOST=box WFOL_SSH_USER=you WFOL_SSH_PORT=22 \
  WFOL_SSH_KEY=~/.ssh/id_ed25519 Tools/wfol_push.sh
USAGE
}

require() {
  [ -n "${!1:-}" ] || { printf 'wfol_push: %s is not set\n\n' "$1" >&2; usage; exit 2; }
}

require WFOL_SSH_HOST
require WFOL_SSH_USER
require WFOL_SSH_PORT
require WFOL_SSH_KEY

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT"
REMOTE_DIR="${WFOL_REMOTE_DIR:-~/game-wfol}"
REMOTE_TARBALL=/tmp/w3src.tgz
DEST="$WFOL_SSH_USER@$WFOL_SSH_HOST"
SSH=(ssh -i "$WFOL_SSH_KEY" -p "$WFOL_SSH_PORT" -o BatchMode=yes)
SCP=(scp -i "$WFOL_SSH_KEY" -P "$WFOL_SSH_PORT" -o BatchMode=yes)
TARBALL=$(mktemp /tmp/w3src.XXXXXX.tgz)
tar --exclude='.git' --exclude='.godot' --exclude='shots' --exclude='build' \
    --exclude='*.log' -C "$SRC" -czf "$TARBALL" .
"${SCP[@]}" -q "$TARBALL" "$DEST:$REMOTE_TARBALL"
"${SSH[@]}" "$DEST" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && tar xzf $REMOTE_TARBALL -C $REMOTE_DIR && rm -f $REMOTE_TARBALL && echo \"synced \$(du -sh $REMOTE_DIR | cut -f1)\""
rm -f "$TARBALL"
