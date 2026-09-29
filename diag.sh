#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"
exec /home/coder/tools/godot --headless --path "$ROOT" --audio-driver Dummy \
  --script res://Tests/diag_vehicle.gd -- "${1:-kairo_s13}" "${2:-120}"
