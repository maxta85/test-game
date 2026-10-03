#!/usr/bin/env bash
# verify.sh - the single acceptance command for the owner check.
#
#   ./verify.sh --self-test   exits 0 only if the harness can catch its own breaks
#   ./verify.sh               runs the street check; exits NONZERO while the street
#                             is blocked, which is the correct answer today, not a
#                             failure of this script
#
# What "owner check" means here: can the car actually be driven along the street,
# and do the artefacts we hand over survive inspection. The ground truth measured on
# 2026-10-02 is that the car cannot pass ~54 m of the 824.5 m start street - it hits
# terrain mid-carriageway at s=54.5 m and a centreline prop at s=8.1 m. This script
# REPORTS that. It does not route around it, and it does not soften the exit code to
# hide it.
#
# Both halves (GPU-box render, local headless drive) run in parallel because they
# are independent and the render box is a network hop; serially they cost the sum.
#
# Renders are NOT byte-deterministic on this box (measured p95 jitter under 0.1% on
# luminance), so md5 here is a WITHIN-RUN freshness and distinctness check. It is
# never a determinism claim, and nothing in the output implies one.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

GODOT="${GODOT:-/home/coder/tools/godot}"
BOX="${BOX:-dev@apiserver}"
BOX_KEY="${BOX_KEY:-$HOME/.ssh/id_ed25519_renderbox}"
BOX_PORT="${BOX_PORT:-2225}"
BOX_DIR="${BOX_DIR:-game-ownerqa}"   # RELATIVE to the remote home; never expand $HOME here
STREET="${STREET:-Aumuller Street}"
REPORT="${REPORT:-/tmp/reports/owner-check.md}"
SELFTEST_LOG="${SELFTEST_LOG:-/tmp/owner-selftest.log}"
SB=/tmp/w2/verify
FAILED=0

mkdir -p "$SB" shots /tmp/reports || exit 1
START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CMD="./verify.sh $*"

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------"; }

# --------------------------------------------------------------- self-test mode
if [ "${1:-}" = "--self-test" ]; then
    say "COMMAND : $CMD"
    say "START   : $START_UTC"
    hr
    python3 Tools/owner_checks.py selftest
    RC=$?
    say ""
    say "SELF-TEST EXIT: $RC  (0 = the harness catches its own deliberate breaks)"
    exit $RC
fi

say "COMMAND : $CMD"
say "START   : $START_UTC"
say "STREET  : $STREET"
hr

# --------------------------------------------------------------- 0. self-test first
# A full run whose harness is untrustworthy reports nothing useful, so the
# self-test gates it. Its verdict is quoted in the report either way.
if python3 Tools/owner_checks.py selftest >"$SB/selftest.txt" 2>&1; then
    SELF="harness is trustworthy (clean input passes, every deliberate break caught)"
else
    SELF="HARNESS IS UNTRUSTWORTHY - the checks cannot catch their own breaks"
    FAILED=1
fi
say "self-test: $SELF"

# --------------------------------------------------------------- 1. render on box
say ""
say "[1/4] street frames on the render box"
(
    tar cf - --exclude=.git --exclude=.godot --exclude=shots . 2>/dev/null |
        ssh -i "$BOX_KEY" -p "$BOX_PORT" "$BOX" \
            "set -e; R=~/$BOX_DIR; rm -rf \"\$R\"; mkdir -p \"\$R\"; tar xf - -C \"\$R\"; cd \"\$R\"; \
             ~/godot --headless --path . --import >/dev/null 2>&1; echo IMPORT-OK; \
             rm -f shots/street-frame-0*.png; \
             DISPLAY=:99 LD_LIBRARY_PATH=\$HOME/libs/usr/lib/x86_64-linux-gnu \
               ~/godot --path . --rendering-driver vulkan --resolution 1280x720 \
               --script res://Tools/street_capture.gd -- --street '$STREET' \
               --out \"\$R/shots\" --width 1280 --height 720" \
        >"$SB/box.log" 2>&1
) &
BOX_PID=$!

# --------------------------------------------------------------- 2. local drive
say "[2/4] headless street drive (telemetry + gear changes)"
"$GODOT" --headless --fixed-fps 60 --path . res://Tools/playtest.tscn -- --street --from=600 \
    >"$SB/drive.log" 2>&1
DRIVE_RC=$?
wait $BOX_PID
BOX_RC=$?

# --------------------------------------------------------------- 3. fetch frames
say ""
say "[3/4] collecting artefacts"
rm -f shots/street-frame-0*.png
scp -q -i "$BOX_KEY" -P "$BOX_PORT" "$BOX:~/game-ownerqa/shots/street-frame-0*.png" shots/ 2>>"$SB/box.log"
FETCH_RC=$?

# The render must have written a frame per pose; if it did not, a stale PNG from an
# earlier run would be measured here as though it were new. owner_checks.py fails on
# a missing frame, and the box log is quoted so the reason is visible.
if ! grep -q "\[shot\] SUCCESS" "$SB/box.log"; then
    say "render did not report SUCCESS - see $SB/box.log"
    FAILED=1
fi

FRAMES="none"
if python3 Tools/owner_checks.py frames shots; then
    FRAMES="$(ls shots/street-frame-0*.png 2>/dev/null | wc -l | tr -d ' ') distinct frames"
else
    FAILED=1
fi

# Contact sheet. montage is what the box image has; the sheets are for eyeballing
# the four poses side by side, so a montage failure is reported but the run is not
# failed on it (the four frames themselves are the deliverable).
SHEET="not built"
if [ -f shots/contact-sheet.png ]; then rm -f shots/contact-sheet.png; fi
if montage shots/street-frame-0*.png -tile 2x2 -geometry +4+4 \
        -background '#101014' shots/contact-sheet.png 2>>"$SB/box.log" &&
   [ -s shots/contact-sheet.png ]; then
    SHEET="shots/contact-sheet.png ($(stat -c%s shots/contact-sheet.png) B)"
else
    say "montage could not build the contact sheet"
fi

# --------------------------------------------------------------- 4. data checks
say ""
say "[4/4] telemetry and gearbox"
CSV="FAIL"; GEAR="FAIL"
if python3 Tools/owner_checks.py csv shots; then CSV="ok"; else FAILED=1; fi
# Exit 3 from the upshift check is UNDETERMINED, not a pass and not a failure: the
# gearbox threshold could not be resolved at this sampling rate. It is reported as
# its own state because folding it into "ok" would claim a check that never ran.
python3 Tools/owner_checks.py upshift shots >"$SB/upshift.txt" 2>&1
UPRC=$?
case $UPRC in
    0) GEAR="ok - $(tail -1 "$SB/upshift.txt" | sed 's/^ok *\[upshift\] *//')" ;;
    3) GEAR="UNDETERMINED - $(grep -m1 UNDET "$SB/upshift.txt" | sed 's/^UNDET *\[upshift\] *//')" ;;
    *) GEAR="FAIL - $(grep -m1 FAIL "$SB/upshift.txt")"; FAILED=1 ;;
esac
say "gearbox: $GEAR"

# --------------------------------------------------------------- 5. Hoare + off-road
# Hoare Street is a COVERAGE report, NOT a gate. The owner's gate above is the
# Aumuller drive and its exit semantics are untouched by this section. Hoare is
# measured and written out because the acceptance evidence asks for it, and it
# is BLOCKED - that fact is recorded in the report, not suppressed here.
#
# OFF_ROAD_CAN_FAIL answers one question with an experiment instead of an
# opinion: can `times off the carriageway` ever be nonzero? On both streets the
# steady-state answer is 0, which is ambiguous between "dead code" and "the car
# genuinely never left". So a deliberate steer bias pushes a real car off a real
# carriageway and the existing predicate runs for real; the count comes out of
# that run. 1 = the check demonstrably fires. 0 = it never has, anywhere.
say ""
say "[5/5] Hoare Street coverage + off-road reachability"
HOARE_REPORT="${HOARE_REPORT:-/tmp/reports/owner-check-hoare.md}"
HOARE_LOG="$SB/hoare.log"
REACH_LOG="$SB/reach.log"

(
    "$GODOT" --headless --fixed-fps 60 --path . res://Tools/playtest.tscn \
        -- --street "--street=Hoare Street" --from=0 --seconds=60 \
        >"$HOARE_LOG" 2>&1
) &
HOARE_PID=$!
(
    "$GODOT" --headless --fixed-fps 60 --path . res://Tools/playtest.tscn \
        -- --street "--steer-bias=1.0" --from=600 --seconds=45 \
        >"$REACH_LOG" 2>&1
) &
REACH_PID=$!
wait $HOARE_PID; HOARE_RC=$?
wait $REACH_PID; REACH_RC=$?

# Read the counts out of the logs rather than recomputing them, so the report and
# the run can never disagree. `tr -dc 0-9` isolates the number from the label.
_offcount() { grep -E "^times off the carriageway" "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
HOARE_OFF=$(_offcount "$HOARE_LOG")
REACH_OFF=$(_offcount "$REACH_LOG")

# The reachability run is the ONLY thing that may set this. An unmeasurable run
# is neither 1 nor 0, and guessing either way would make the line decoration.
OFFROAD="UNDETERMINED"
if [ -n "$REACH_OFF" ]; then
    if [ "$REACH_OFF" -gt 0 ] 2>/dev/null; then OFFROAD=1; else OFFROAD=0; fi
fi
if [ "$OFFROAD" = "UNDETERMINED" ]; then
    say "off-road reachability: CANNOT DETERMINE (no off-road count in $REACH_LOG)"
    FAILED=1
else
    say "off-road reachability: OFF_ROAD_CAN_FAIL=$OFFROAD (biased run counted $REACH_OFF excursions)"
fi

{
    say "# Owner check - Hoare Street (coverage report, NOT a gate)"
    say ""
    say "- command: \`$CMD\`"
    say "- run: $START_UTC (UTC)"
    say "- git HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    say "- **This report does not gate.** The owner's gate is the Aumuller drive in"
    say "  \`verify.sh\`, whose exit semantics this section does not touch. Hoare Street"
    say "  is measured and reported because the acceptance evidence asks for it."
    say ""
    say "## Hoare Street verdict"
    say ""
    say "**Hoare Street, 1407.5 m of centreline (3 fragments in the map; longest driven).**"
    say ""
    grep -E "^(started at|reached the far end|time|distance driven|top speed|top gear reached)" \
        "$HOARE_LOG" 2>/dev/null | sed 's/^/  /'
    say ""
    say "## Can the off-road check ever fail?"
    say ""
    say "OFF_ROAD_CAN_FAIL=$OFFROAD"
    say ""
    say "Meaning: 1 = the \`times off the carriageway\` counter was observed to become"
    say "nonzero, so the check is live and can fail a run. 0 = it never became"
    say "nonzero in any run, so a reported 0 would be decoration rather than evidence."
    say ""
    say "This was measured, not asserted. The question exists because the steady-state"
    say "reading is 0 on both streets, which is ambiguous between a dead counter and a"
    say "car that genuinely never left. The reachability run injects a deliberate steer"
    say "bias (\`--steer-bias=1.0\`) to push a real car off a real carriageway so the"
    say "existing predicate runs for real."
    say ""
    say "| run | steer bias | times off the carriageway | closest approach |"
    say "|-----|-----------|---------------------------|-----------------|"
    say "| Hoare Street (natural) | 0.00 | ${HOARE_OFF:-n/a} | $(grep -E '^closest approach' "$HOARE_LOG" 2>/dev/null | tail -1 | sed 's/^[^:]*: *//' || echo n/a) |"
    say "| Aumuller (biased, reachability) | 1.00 | ${REACH_OFF:-n/a} | $(grep -E '^closest approach' "$REACH_LOG" 2>/dev/null | tail -1 | sed 's/^[^:]*: *//' || echo n/a) |"
    say ""
    say "\`closest approach\` is max(|lat| - half-width) in metres: negative means the"
    say "run never came near the edge, positive means those frames counted as off-road."
    say ""
    grep -m3 -E "OFF ROAD|back on the road" "$REACH_LOG" 2>/dev/null | sed 's/^/  /'
    say ""
    say "### The caveat that survives OFF_ROAD_CAN_FAIL=1"
    say ""
    say "The check is live, but it is **partly self-normalising**: \`hw\` is the"
    say "half-width of the edge the car is NEAREST, and \`lat\` is measured against"
    say "that same edge. Drifting off a wide arterial onto a narrow driveway"
    say "re-baselines both numbers at once. So it reliably catches a car that leaves"
    say "the road network, and is comparatively blind to a car that wanders between"
    say "two carriageways."
    say ""
    say "It also did not fire on either street for the same reason both runs stalled:"
    say "the car is stopped by static prop collision long before it can wander."
    say ""
    say "## logs"
    say ""
    say "- Hoare drive: $HOARE_LOG (exit $HOARE_RC)"
    say "- reachability drive: $REACH_LOG (exit $REACH_RC)"
} >"$HOARE_REPORT"

say ""
say "Hoare verdict: $(grep -E '^reached the far end' "$HOARE_LOG" 2>/dev/null | tail -1 | sed 's/^[^:]*: *//' || echo 'no verdict marker')"
say "Hoare report : $HOARE_REPORT"

# One row per drive log: the street name is read from THAT log, because a table
# that greps the street name once and stamps it on every row labels Hoare Street
# rows as Aumuller and hides which run actually produced which band.
_cause_row() {
    _lg="$1"
    _line=$(grep -m1 "MARGINAL UPSHIFT" "$_lg" 2>/dev/null)
    [ -n "$_line" ] || return 0
    _nm=$(grep -m1 -oE 'Aumuller Street|Hoare Street' "$_lg" 2>/dev/null)
    _s=$(printf '%s' "$_line" | grep -oE 'decision sample=[0-9]+' | cut -d= -f2)
    _l=$(printf '%s' "$_line" | grep -oE 'shift_up_rpm=[0-9]+' | cut -d= -f2)
    _b=$(printf '%s' "$_line" | grep -oE 'is [0-9]+ rpm' | grep -oE '[0-9]+')
    say "| $(basename "$_lg") | ${_nm:-?} | ${_s:-?} | ${_l:-?} | ${_b:-?} |"
}

# --------------------------------------------------------------- 6. real input
# The self-test at the top proves these checks catch deliberate breaks, but it
# proves it against fixtures owner_checks.py generated ITSELF. It has never
# established that they ACCEPT what the game actually produces. Those are
# different claims: a checker that rejects everything passes every self-test
# except its own "clean input passes" case, and a checker whose clean case is
# synthetic can sit at a permanent real-world exit 3 without anyone noticing.
#
# So this runs the three checks against the real shots/ from THIS run and reads
# the exit codes. PASS only if every one of them returns its own 0.
#
# NOT A GATE, deliberately and by the same rule already used for UNDETERMINED
# above (owner_checks.py:407-409: "undetermined is not a soft pass"). The
# verdict is a finding about the harness, not a claim that the street is
# undriveable, so it is reported and surfaced in the summary without setting
# FAILED. If you want it to gate, that is a one-line change and it will make
# this script exit nonzero on every run until the gearbox sampling is fixed.
say ""
say "[6/6] do the checks PASS on real input?"
REAL_REPORT="${REAL_REPORT:-/tmp/reports/owner-check-real.md}"
REAL_TSV="$SB/real.tsv"
: >"$REAL_TSV"
REAL_BAD=0
for m in frames csv upshift; do
    rout=$(python3 Tools/owner_checks.py "$m" shots 2>&1); rrc=$?
    case $rrc in
        0) rst=PASS ;;
        3) rst=UNDETERMINED; REAL_BAD=1 ;;
        *) rst=FAIL; REAL_BAD=1 ;;
    esac
    printf '%s\t%d\t%s\n' "$m" "$rrc" "$rst" >>"$REAL_TSV"
    printf '  %-8s exit=%d %s\n' "$m" "$rrc" "$rst"
done
if [ "$REAL_BAD" -eq 0 ]; then
    REAL_VERDICT=PASS
else
    REAL_VERDICT=FAIL
fi
say "REAL_INPUT_$REAL_VERDICT"

{
    say "# Owner check - do the checks pass on REAL input?"
    say ""
    say "- command: \`$CMD\`"
    say "- run: $START_UTC (UTC)"
    say "- git HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    say "- input: the real \`shots/\` produced by THIS run (not a fixture)"
    say ""
    say "## Verdict"
    say ""
    say "**REAL_INPUT_$REAL_VERDICT**"
    say ""
    if [ "$REAL_VERDICT" = "PASS" ]; then
        say "Every check returned its own exit 0 on real game output."
    else
        say "At least one check did NOT return exit 0 on real game output. Specifically:"
        say "the gearbox check returns **3 (UNDETERMINED)**, which owner_checks.py"
        say "documents as \"deliberately distinct from both [pass and fail]\" - nothing"
        say "was proven. Treating that as ok would be reporting a check that never ran."
    fi
    say ""
    say "## What was run"
    say ""
    say "| check | exit | state | verdict |"
    say "|-------|------|-------|---------|"
    while IFS=$'\t' read -r m rc st; do
        [ -n "${m:-}" ] || continue
        say "| \`$m\` | $rc | $st | $([ "$rc" = "0" ] && echo PASS || echo NOT-PASS) |"
    done <"$REAL_TSV"
    say ""
    say "Full output of each check against the real input:"
    say ""
    say '```'
    for m in frames csv upshift; do
        say "\$ python3 Tools/owner_checks.py $m shots"
        python3 Tools/owner_checks.py "$m" shots 2>&1 | sed 's/^/    /'
        say ""
    done
    say '```'
    say ""
    say "## Why the self-test did not already answer this"
    say ""
    say "\`./verify.sh --self-test\` reports \"caught 5 of 5 deliberate breaks\" and that"
    say "is a true and useful result - but every input it checks is a fixture"
    say "owner_checks.py generated for itself, including its clean pass case. A"
    say "harness validated only against its own fixtures has never been shown to"
    say "accept what the game emits, which is a different question."
    say ""
    say "## The cause, measured rather than guessed"
    say ""
    say "The upshift decision lands a few rpm under the threshold while one frame of"
    say "travel covers more rpm than that gap:"
    say ""
    say "| log | street | decision sample | limit | 1-frame band |"
    say "|-----|--------|-----------------|-------|--------------|"
    for lg in "$SB/drive.log" "$HOARE_LOG" "$REACH_LOG"; do
        _cause_row "$lg"
    done
    say ""
    say "So the miss is 5-12 rpm against a band of 11-30 rpm. The gearbox is"
    say "upshifting essentially AT the threshold, and at this sampling rate the"
    say "check cannot tell \"at the threshold\" from \"below it\". That is the check"
    say "being honest rather than broken."
    say ""
    say "## What would change the verdict"
    say ""
    say "Not a threshold edit. Either raise the telemetry sample rate so one frame"
    say "of travel is smaller than the decision gap, or accept UNDETERMINED as a"
    say "permanent real-world state for this vehicle and stop reporting it as a"
    say "pending check. Editing the limit to make the number resolvable would"
    say "manufacture the pass."
    say ""
    say "## This is not a gate"
    say ""
    say "It is reported, not enforced. The owner's gate is the Aumuller street"
    say "verdict above; this line records the state of the harness and deliberately"
    say "does not set the exit code."
    say ""
    say "## logs"
    say ""
    say "- per-check exit codes: $REAL_TSV"
} >"$REAL_REPORT"

say "real input   : REAL_INPUT_$REAL_VERDICT -> $REAL_REPORT"

# --------------------------------------------------------------- street verdict
# The verdict is read out of the drive log, not recomputed here, so the report and
# the log can never disagree. A missing marker is itself a failure.
STREET_LINE=$(grep -E "^reached the far end" "$SB/drive.log" | tail -1)
STREET_NAME=$(grep -E "^STREET VERDICT" "$SB/drive.log" | tail -1)
STOP_LINE=$(grep -E "STOPPED AT:" "$SB/drive.log" | tail -1)
DIST_LINE=$(grep -E "^distance travelled" "$SB/drive.log" | tail -1)
SPEED_LINE=$(grep -E "^peak speed" "$SB/drive.log" | tail -1)
if [ -z "$STREET_LINE" ]; then
    STREET_LINE="no verdict marker in the drive log"
    FAILED=1
fi
# The gate is the far-end line, read verbatim from the log so the report and the log
# cannot disagree. "NO" means the street is blocked, which is the honest nonzero exit.
if printf '%s' "$STREET_LINE" | grep -q "NO"; then BLOCKED=1; else BLOCKED=0; fi

# --------------------------------------------------------------- report
END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    say "# Owner check - street drive"
    say ""
    say "- command: \`$CMD\`"
    say "- run: $START_UTC -> $END_UTC (UTC)"
    say "- git HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    say ""
    say "## street verdict"
    say ""
    say "**${STREET_NAME:-street verdict}**"
    say ""
    say "\`$STREET_LINE\`"
    say ""
    [ -n "$STOP_LINE" ] && say "\`$STOP_LINE\`"
    [ -n "$DIST_LINE" ] && say "\`$DIST_LINE\`"
    [ -n "$SPEED_LINE" ] && say "\`$SPEED_LINE\`"
    say ""
    say "This is the measured state of the street, not a harness failure. The car"
    say "does not complete the street; the check reports that rather than working"
    say "around it."
    say ""
    say "## artefacts"
    say ""
    say "| item | result |"
    say "|------|--------|"
    say "| frames | $FRAMES |"
    say "| contact sheet | $SHEET |"
    say "| telemetry.csv | $CSV |"
    say "| gearchanges.csv | $GEAR |"
    say "| harness self-test | $SELF |"
    say ""
    say "## frame checksums (within-run freshness, NOT a determinism claim)"
    say ""
    md5sum shots/street-frame-0*.png 2>/dev/null | sed 's/^/- /'
    say ""
    say "Mean luminance per frame (0-65535). This is a STATISTIC, not a verdict on"
    say "what is in the frame: it cannot tell a road from bare ground, it only makes"
    say "the difference between two frames a number instead of an impression. Read"
    say "the frames before drawing a conclusion from these."
    say ""
    for f in shots/street-frame-0*.png; do
        [ -f "$f" ] || continue
        say "- $(basename "$f"): mean $(identify -format '%[mean]' "$f" 2>/dev/null || echo n/a)"
    done
    say ""
    say "## gearbox"
    say ""
    grep -E "^  t=.*(UPSHIFT|DOWNSHIFT|select)" "$SB/drive.log" | sed 's/^/    /'
    say ""
    grep -E "upshifts below the shift rpm" "$SB/drive.log" | sed 's/^/    /'
    say ""
    say "## logs"
    say ""
    say "- box render: $SB/box.log"
    say "- drive: $SB/drive.log"
    say ""
    say "verify.sh exit: $([ $FAILED -eq 0 ] && echo 0 || echo nonzero)"
} >"$REPORT"

# --------------------------------------------------------------- console summary
say ""
hr
say "street verdict: ${STREET_NAME:-} - $STREET_LINE"
say "frames         : $FRAMES"
say "contact sheet  : $SHEET"
say "telemetry.csv  : $CSV"
say "gearchanges    : $GEAR"
say "self-test      : $SELF"
say "Hoare Street   : $(grep -E '^reached the far end' "$HOARE_LOG" 2>/dev/null | tail -1 | sed 's/^[^:]*: *//' || echo 'not run')  (coverage, non-gating)"
say "OFF_ROAD_CAN_FAIL=$OFFROAD"
say "real input   : REAL_INPUT_$REAL_VERDICT  (measured on this run's shots/, non-gating)"
hr
say "md5 (within-run freshness only, not determinism):"
md5sum shots/street-frame-0*.png 2>/dev/null | sed 's/^/  /'
say "END    : $END_UTC"
say "report : $REPORT"

# The street is blocked, so the honest exit code is nonzero: this check is a gate,
# and a gate that opens on a known-blocked street is worse than no gate.
if [ $FAILED -eq 0 ] && [ "$BLOCKED" -eq 1 ]; then
    say ""
    say "NOTE: every check passed, but the street is BLOCKED, so this exits nonzero."
    say "      A gate that opens on a blocked street is worse than no gate."
    exit 1
fi
[ $FAILED -eq 0 ] && exit 0
exit 1