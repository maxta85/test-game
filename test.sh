#!/usr/bin/env bash
# Headless test runner. No test framework - the harness in Tests/harness.gd is
# deliberately tiny (asserts + counters) so there is nothing to install.
#   ./test.sh            run all suites
#   ./test.sh vehicle    run suites whose name contains "vehicle"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="${GODOT:-/home/coder/tools/godot}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

exec "$GODOT" --headless --path "$ROOT" --audio-driver Dummy \
  --script res://Tests/run_tests.gd -- ${1:-all}
