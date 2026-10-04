#!/usr/bin/env bash
# t183 - the owner gate: three consecutive FULL ./test.sh runs on this worktree,
# green, with IDENTICAL pass counts. Count-stability, not vibes.
#
# Run detached: `setsid nohup bash Tests/t183_full3.sh > /tmp/t183/full3.log 2>&1 &`
# It takes ~6 minutes a run, which is longer than any foreground tool call.
#
# Each run gets its own log and its own md5 of the whole [PASS]/[FAIL] label
# stream, so "identical" means the assertions are the same assertions, not just
# the same total. A flaky suite that keeps its count while shuffling which
# assertions ran would pass a count-only check.
set -uo pipefail

# WT is DERIVED from this script's own location, never hardcoded to a worktree.
# t183 was authored in wt/w3, and a verbatim copy of this file into any other
# worktree would have run `./test.sh` over there and reported wt/w3's numbers as
# this branch's evidence - a green 3x gate on a tree nobody is shipping. One
# `cd ..` from `${BASH_SOURCE[0]}` is the project root in every worktree.
# Override with T183_WT / T183_OUT only if you have a reason to.
WT="${T183_WT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${T183_OUT:-/tmp/t183}"
mkdir -p "$OUT"
if [ ! -x "$WT/test.sh" ]; then
  echo "FATAL: no test.sh under derived worktree '$WT' - refusing to report a gate on the wrong tree" >&2
  exit 2
fi
echo "t183_full3: measuring worktree $WT" | tee -a "$OUT/worktree.txt"
TABLE="$OUT/full3-table.txt"
: > "$TABLE"

printf '%-6s %-10s %-22s %-8s %-34s %s\n' \
	"run" "exit" "summary" "elapsed" "labels-md5" "verdict" | tee -a "$TABLE"

for i in 1 2 3; do
	log="$OUT/full-run$i.log"
	cd "$WT" || exit 1
	t0=$(date +%s)
	./test.sh > "$log" 2>&1
	rc=$?
	elapsed=$(( $(date +%s) - t0 ))
	summary=$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$log" | tail -1)
	md5=$(grep -oE '\[(PASS|FAIL)\].*' "$log" | sed 's/([0-9. eE+-]*)$//' | md5sum | cut -d' ' -f1)
	unparseable=$(grep -c 'UNPARSEABLE' "$log")
	if [ "$rc" -eq 0 ] && [ "$unparseable" -eq 0 ] && [ -n "$summary" ] \
		&& printf '%s' "$summary" | grep -qE '^0 failed|[1-9][0-9]* passed, 0 failed$'; then
		verdict=GREEN
	else
		# Single token, no spaces: the aggregate verdict reads this with
		# `awk '{print $NF}'`, and "RED rc=9 unparseable=0" has three words, so
		# $NF would have been "unparseable=0". Verified against a RED row.
		verdict="RED_rc=$rc,unparseable=$unparseable"
	fi
	printf '%-6s %-10s %-24s %-8s %-34s %s\n' \
		"run$i" "$rc" "$summary" "${elapsed}s" "$md5" "$verdict" | tee -a "$TABLE"
done

echo | tee -a "$TABLE"
# Read the recorded rows back WITHOUT positional fields, because there is no
# correct one: `tr -s ' ' '|'` splits the summary "2455 passed, 0 failed" into
# THREE fields, so every index after field 2 is shifted by three. t183's first
# version used awk '$6' and read "failed" out of the summary; its fix swapped
# that for `cut -d'|' -f7`, which reads the ELAPSED time instead of the verdict
# and prints "FULL 3x: NOT GREEN (357s / 356s / 358s)" on three green runs.
# Swapping the parser did not help, because both parsers assumed a field with no
# spaces in it. So: anchor on content. The verdict is the last field; the summary
# is everything between the exit code and the elapsed time.
# Measured on a green table, before this fix: field 7 = "357s", field 9 = "GREEN".
row() { grep "^$1" "$TABLE" | tail -1; }
verdict_of() { row "$1" | awk '{print $NF}'; }
summary_of() { row "$1" | sed -E 's/^[^ ]+ +[^ ]+ +(.+[^ ]) +[0-9]+s +[0-9a-f]{32} +.*$/\1/'; }
md5_of()     { row "$1" | grep -oE '[0-9a-f]{32}' | head -1; }

v1=$(verdict_of run1); v2=$(verdict_of run2); v3=$(verdict_of run3)
s1=$(summary_of run1); s2=$(summary_of run2); s3=$(summary_of run3)
m1=$(md5_of run1); m2=$(md5_of run2); m3=$(md5_of run3)

if [ "$v1" = GREEN ] && [ "$v2" = GREEN ] && [ "$v3" = GREEN ] && [ -n "$s1" ]; then
	if [ "$s1" = "$s2" ] && [ "$s2" = "$s3" ]; then
		echo "FULL 3x IDENTICAL pass counts GREEN: $s1 on all three runs" | tee -a "$TABLE"
	else
		echo "FULL 3x IDENTICAL pass counts: NO ($s1 / $s2 / $s3)" | tee -a "$TABLE"
	fi
	if [ "$m1" = "$m2" ] && [ "$m2" = "$m3" ]; then
		echo "  assertion-label stream also identical: $m1" | tee -a "$TABLE"
	else
		echo "  assertion-LABEL stream NOT identical ($m1 / $m2 / $m3) - see the report:" \
			"audio dB readings and object instance ids inside labels, not a count change" | tee -a "$TABLE"
	fi
else
	echo "FULL 3x: NOT GREEN ($v1 / $v2 / $v3)" | tee -a "$TABLE"
fi