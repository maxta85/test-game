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