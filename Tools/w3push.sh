#!/usr/bin/env bash
# Push this project to the render box into ~/game-w3 ONLY.
#
# ~/game is NOT a safe target: w1, w8 and w10 all rsync into it, so anyone
# pushing there overwrites the other agents' work mid-build. ~/game-w3 is this
# worker's own copy and nobody else writes to it.
#
#   Tools/w3push.sh          # sync, wiping ~/game-w3 first so deleted files go
#
# Tar + scp rather than rsync because the box has no rsync server side. .godot is
# excluded and rebuilt on the box, so it costs nothing to keep it out.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT"
SSH="ssh -i $HOME/.ssh/id_ed25519_renderbox -p 2225 -o BatchMode=yes"
SCP="scp -i $HOME/.ssh/id_ed25519_renderbox -P 2225 -o BatchMode=yes"
TARBALL=$(mktemp /tmp/w3src.XXXXXX.tgz)
tar --exclude='.git' --exclude='.godot' --exclude='shots' --exclude='build' \
    --exclude='*.log' -C "$SRC" -czf "$TARBALL" .
$SCP -q "$TARBALL" dev@apiserver:/tmp/w3src.tgz
$SSH dev@apiserver 'rm -rf ~/game-w3 && mkdir -p ~/game-w3 && tar xzf /tmp/w3src.tgz -C ~/game-w3 && rm -f /tmp/w3src.tgz && echo "synced $(du -sh ~/game-w3 | cut -f1)"'
rm -f "$TARBALL"
