#!/usr/bin/env bash
# t183 - prove the assertions added to Tests/test_water.gd are wired to the thing
# they claim to check. Every mutation must change the result away from the
# control summary. A mutation that does not is either decoration or an equivalent
# mutant, and both have to be named as such rather than quietly dropped.
#
# ONLY Tests/test_water.gd is ever written, and it is restored from the saved good
# copy after every step. Production code is never touched - which also means no
# mutant here can prove the PRODUCTION behaviour is load-bearing, only that the
# assertion reads the measurement it names.
#
# VERDICT RULE, and why it is not just "count the [FAIL] lines": a suite that
# throws part way through run() cannot print its own failures, and a parse error
# prints none either, so a mutant that CRASHES the suite reads as "0 failed" and
# looks like a survivor. One of the mutants below does exactly that. So the
# verdict is "did the summary change away from the control", nothing else.
set -uo pipefail

# WT is DERIVED from this script's own location, never hardcoded. Two reasons,
# and the second is the dangerous one:
#   1. a verbatim copy would measure the wrong worktree's tests;
#   2. `restore()` writes back to "$WT/Tests/test_water.gd", so running a copy
#      that pointed at wt/w3 would MUTATE AND RESTORE ANOTHER AGENT'S WORKTREE.
WT="${T183_WT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${T183_OUT:-/tmp/t183}"
mkdir -p "$OUT"
SRC="$WT/Tests/test_water.gd"
GOOD="$OUT/test_water.gd.fixed"
LOG="$OUT/mutation.log"
CTL_SUMMARY=""

if [ ! -f "$SRC" ]; then
  echo "FATAL: no $SRC under derived worktree '$WT'" >&2
  exit 2
fi

# Bootstrap the pristine copy from the file as committed, so the script is
# self-contained. t183's first run needed a hand-made $GOOD; without it every
# `restore` is a silent no-op (`cp` of a missing file, `set -e` not on) and the
# mutants COMPOUND, leaving the worktree's test_water.gd mutated on exit.
cp "$SRC" "$GOOD"
: > "$LOG"

# A restore that does not restore is the one failure mode that would silently
# corrupt the deliverable this whole script exists to protect. Make it loud.
restore() {
  cp "$GOOD" "$SRC" || { echo "FATAL: restore failed" >&2; exit 3; }
  cmp -s "$GOOD" "$SRC" || { echo "FATAL: restore did not take" >&2; exit 3; }
}

summary_of() { grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1; }

run_case() { # $1 label, $2 python body
  restore
  if ! python3 - "$SRC" "$GOOD" <<PY
import sys
p, good = sys.argv[1], sys.argv[2]
s = open(p).read()
before = s
$2
assert s != before, "pattern not found / no change"
open(p, 'w').write(s)
PY
  then printf 'MUT %-30s REJECTED (pattern not found)\n' "$1" | tee -a "$LOG"; restore; return; fi
  out=$(cd "$WT" && ./test.sh water 2>&1)
  summary=$(printf '%s' "$out" | summary_of)
  if [ "$summary" = "$CTL_SUMMARY" ]; then
    verdict="SURVIVED - decoration or equivalent mutant"
  else
    verdict="KILLED"
  fi
  first=$(printf '%s' "$out" | grep -m2 -E '^\s+(FAILED|UNPARSEABLE)' | sed 's/^ *//' | cut -c1-140 | tr '\n' ';')
  printf 'MUT %-30s %-46s %-22s %s\n' "$1" "$verdict" "$summary" "$first" | tee -a "$LOG"
  restore
}

echo "=== t183 mutation matrix for Tests/test_water.gd ===" | tee -a "$LOG"
echo "=== control first, so 'KILLED' means 'differs from a green control' ===" | tee -a "$LOG"

restore
out=$(cd "$WT" && ./test.sh water 2>&1)
CTL_SUMMARY=$(printf '%s' "$out" | summary_of)
printf 'CTL unmutated                         GREEN                                %-22s\n' "$CTL_SUMMARY" | tee -a "$LOG"

# M1 - pretend every ring is clear. The two drop-rule assertions are the whole
# point of the fix, so they must notice.
run_case M1_all_rings_clear "
s = s.replace('var sampled_clear: bool = body_tightest - body_hw - WaterClearance.KERB_SETBACK >= 0.0',
              'var sampled_clear: bool = true')
"

# M2 - drop the kerb setback from the source-ring rule. On THIS map no ring sits
# in the 0..0.5 m kerb band (the offender is 0.2648 m inside the TARMAC, not the
# kerb), so this is an equivalent mutant here. Recorded, not hidden.
run_case M2_ignore_kerb_setback "
s = s.replace('var sampled_clear: bool = body_tightest - body_hw - WaterClearance.KERB_SETBACK >= 0.0',
              'var sampled_clear: bool = body_tightest - body_hw >= 0.0')
"

# M2b - the same seam, pushed far enough to actually move a decision.
run_case M2b_kerb_setback_6m "
s = s.replace('var sampled_clear: bool = body_tightest - body_hw - WaterClearance.KERB_SETBACK >= 0.0',
              'var sampled_clear: bool = body_tightest - body_hw - 6.0 >= 0.0')
"

# M3 - never increment the disagreement counter. A counter-backed '== 0' check
# cannot catch this by construction; the mitigation is M3b.
run_case M3_disagree_never_counted "
s = s.replace('if sampled_clear != bool(ex[\"clear\"]):', 'if false:')
"

# M3b - break the SAMPLED index geometry instead. The positive margin comparison
# is what catches this, which is why it exists.
run_case M3b_sampled_index_wrong "
s = s.replace('best = {\"d\": d, \"hw\": float(s[\"hw\"]), \"name\": String(s[\"name\"])}',
              'best = {\"d\": d * 9.0, \"hw\": float(s[\"hw\"]), \"name\": String(s[\"name\"])}')
"

# M4 - the kept-ring kerb margin, checked against a widened setback.
run_case M4_kerb_margin_widened "
s = s.replace('var km := body_tightest - body_hw - WaterClearance.KERB_SETBACK',
              'var km := body_tightest - body_hw - WaterClearance.KERB_SETBACK - 2.0')
"

# M5 - on-ring check that never matches: a displaced surface must be caught.
run_case M5_on_a_kept_ring_false "
s = s.replace('func _on_a_kept_ring(p: Vector2) -> bool:',
              'func _on_a_kept_ring(p: Vector2) -> bool:\n\treturn false')
"

# M6 - the built-mesh clearance band, widened past every vertex.
run_case M6_built_band_widened "
s = s.replace('if d < hw + WaterClearance.KERB_SETBACK:', 'if d < hw + 40.0:')
"

# M7 - the stub guard, by hanging an empty mesh off the node. Proves the guard
# reads the built children rather than the plan's own count. NOTE: this one
# CRASHES the rest of the suite, so it prints no [FAIL] line at all - it is only
# visible because the summary is compared rather than the failure count.
run_case M7_stub_guard_reads_children "
s = s.replace('\tvar stubs := 0',
              '\tvar _stubmesh := MeshInstance3D.new()\n\t_stubmesh.mesh = ArrayMesh.new()\n\t_node.add_child(_stubmesh)\n\tvar stubs := 0')
"

# M8 - the kept-area reference widened past what was built.
run_case M8_area_reference_widened "
s = s.replace('t.between(built_area, _kept_area * 0.98, _kept_area * 1.02,',
              't.between(built_area, _kept_area * 1.5, _kept_area * 2.0,')
"

# M9 - the sampling step coarsened, so the sampled margin drifts off the exact one.
run_case M9_sampling_step_coarse "
s = s.replace('for p in _sample_ring(ring, SAMPLE_STEP):', 'for p in _sample_ring(ring, 90.0):')
"

# M11 - REGRESSION WITNESS, not expected to be killed. Reinstating the bug the
# mutation matrix found: comparing the SQUARED distance from _nearest() against a
# half width in metres, which is what this suite shipped for its whole life. It
# passes, and that is exactly why it survived - the suite reported "no built water
# vertex is inside a carriageway" while only proving 2.74 m of a 7.0 m arterial.
run_case M11_squared_distance_reintroduced "
s = s.replace('if d < hw + WaterClearance.KERB_SETBACK:', 'if d * d < hw + WaterClearance.KERB_SETBACK:')
"""


# M10 - the built "clears the widest carriageway" floor, made unreachable.
run_case M10_widest_carriageway_floor "
s = s.replace('t.gt(worst - 7.0, 0.0,', 't.gt(worst - 40.0, 0.0,')
"

# CONTROL - three unmutated runs, so "KILLED" rests on a stable green.
for i in 1 2 3; do
  restore
  out=$(cd "$WT" && ./test.sh water 2>&1)
  s2=$(printf '%s' "$out" | summary_of)
  printf 'CTL unmutated run %d                   %-46s %-22s\n' "$i" \
    "$([ "$s2" = "$CTL_SUMMARY" ] && echo GREEN || echo "DRIFT vs $CTL_SUMMARY")" "$s2" | tee -a "$LOG"
done

restore
if diff -q "$SRC" "$GOOD" >/dev/null; then
  echo "RESTORED: Tests/test_water.gd byte-identical to the good copy" | tee -a "$LOG"
else
  echo "RESTORE FAILED - Tests/test_water.gd differs from the good copy" | tee -a "$LOG"
fi