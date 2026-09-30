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

# --fixed-fps disables real-time sync, so the loop runs flat out instead of
# sleeping to hit a 60 Hz wall clock. Measured on the vehicle suite: 80.3 s ->
# 3.3 s for an identical 129/0 result. The suite was never compute-bound, it
# was waiting on the clock - no GPU is involved (this is --headless, dummy
# renderer). It also makes runs deterministic: a fixed delta instead of the
# host's jittery real one.
exec "$GODOT" --headless --path "$ROOT" --audio-driver Dummy \
  --fixed-fps "${FIXED_FPS:-60}" \
  --script res://Tests/run_tests.gd -- ${1:-all}
