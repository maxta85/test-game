# HANDOVER — race agent

Written 2026-09-30 by the race agent, immediately before ownership was being
reassigned. Everything below is what a cold agent needs to pick this up. Ownership
is in flux — check `.agent_mailbox/` and the briefs before assuming any of it.

---

## 1. What I own (as of writing)

| Path | What it is |
|---|---|
| `Systems/race/race_def.gd` | Race definitions + circuit generation |
| `Systems/race/race_director.gd` | Race state machine: countdown, checkpoints, laps, results, rewards |
| `AI/ai_racer.gd` | The racing AI driver |
| `AI/racer/racing_line.gd` | Smoothed racing line + speed profile |
| `Tests/test_race.gd` | 99 assertions |
| `Tests/test_ai.gd` | 17 assertions |
| `Audio/**` | **6 files, 1047 lines — landed but owned by nobody** (see §6) |

## 2. What I committed

```
f348b29  Race system: director, race definitions and tests
5cd4a33  Racing AI: racing line, driver, and a real circuit to race on
976b747  Audio: procedural engine and cue system, with a self-check that can fail
```

`976b747` was **written by `claudelink/space-bunny-alpha`** as a delegated
session, then reviewed and independently re-run before landing. Provenance is in
the commit body.

## 3. Verification state — read this before trusting anything

| Suite | Last confirmed | Notes |
|---|---|---|
| `./test.sh race` | **99/99 green**, on the OSM map | re-ran after `208d23e` |
| `Audio/audio_check.gd` | **135/135, exit 0** | needs the import step first |
| `./test.sh ai` | ⚠️ **NOT CONFIRMED on the OSM map** | see below |

**The AI suite is unverified against the new map.** I started `./test.sh ai`
after the OSM change (`208d23e feat: the map is real OpenStreetMap streets`) and
stopped it partway to take this handover. Every assertion it had reached was
passing — including spin recovery (3.8 s), skill separation (828 m vs 687 m) and
mistake rates (25 errors at skill 0.3, 0 at skill 0.96) — but **it never printed
its summary line, so treat it as unknown, not green.** First thing to do:

    ./test.sh ai     # ~5–6 min. Expect it to fail or pass; either way it is the
                     # first thing that needs re-establishing.

The race suite re-run green on OSM is meaningful evidence that circuit generation
does not depend on the old authored grid being regular — the new roads are real
OSM geometry.

## 4. Landed but unused: the audio system

1047 lines in `Audio/` are committed and green, and **nothing calls them.**
`Game/main.gd` does not create an `AudioDirector`. It is a working library with no
consumer yet. Wiring it is the smallest high-value thing left in my old scope, but
`Game/main.gd` belongs to another agent — see §6.

`Systems/race/race_director.gd:38` already exposes `var lights: int` (3, 2, 1,
then 0) documented as "drives the revving audio". That is the intended hook and it
did not need changing.

## 5. Two known defects, both in files I do not own

**Player steering looks inverted.** Measured, not inferred: a `CarBody` at 0.35
throttle with `steer = +0.5` for 2 s yaws **+1.49 rad** and moves to
`(-11, 0, -11)` from a −Z heading. Positive steer is a **left** turn. But
`CarBody.steer` is documented *"-1 (full left) .. +1 (full right)"*, and
`PlayerController` computes `steer = steer_right - steer_left`. One of those two
is wrong. My AI matches the physics, not the comment.

**`find_loop` was fixed at source, so my workaround may now be redundant.**
`cf447e3 Fix find_loop returning a there-and-back instead of a circuit` landed by
another agent. I had independently worked around the same bug inside
`race_def.gd` (`_grow_circuit`, which grows a loop by detouring it around blocks
and rejects any candidate that does not turn corners and cover ground in both
axes). Both are now in place. `_grow_circuit` is ~120 lines that may be
retirable — **but that is a judgement call, not a cleanup**: it is tested, and the
race suite is green with it. Do not remove it without re-running `./test.sh race`.

Also in `race_def.gd`, another agent has uncommitted renames in `catalogue()`
(Gordon Street Sprint / Mulgrave Road Circuit). That is their work — do not
revert it.

## 6. Open decisions for whoever picks this up

1. **Who owns `Audio/`?** It is unassigned. If it is not claimed it will sit as
   1047 lines of dead code. Needs either an owner or a decision to wire it up.
2. **Can `Game/main.gd` be edited to wire audio?** That is the natural consumer
   and it belongs to another agent.
3. **Is `_grow_circuit` retired now that `find_loop` is fixed?** See §5.
4. **Ownership is being reassigned.** Confirm the new map before touching
   anything in §1.

## 7. External tooling — not in the repo, will not survive a fresh machine

`~/kilo-fleet/` holds a persistent fleet of Kilo ACP agents for delegating and
monitoring work. It is **outside the repo and undocumented anywhere in it.**

- `~/kilo-fleet/fleet2.py` — daemon + CLI
- `~/kilo-fleet/logs/*.jsonl` — every event per worker
- `~/kilo-fleet/briefs/` — task briefs given to delegated agents
- `~/kilo-fleet/wt/w1`, `wt/w2` — git worktrees of this repo on branches
  `fleet/w1` / `fleet/w2`

```
fleet2.py daemon 2 --repo <repo> --prepare "<import cmd>"   # start 2 workers
fleet2.py task <w> "<text>" --paths Audio/ --accept "<cmd>" --retries 2
fleet2.py status | verdict <w> | log <w> | cancel <w> | down
```

Workers run `kilo acp` on `claudelink/space-bunny-alpha`, one git worktree
each. **The audit model matters:** there is no sandbox on the Kilo backend, so
worktrees are directory isolation and a merge gate, not a jail. Safety comes from
a post-run `git status --porcelain` scope audit that fails the task if any touched
file is outside `--paths`. It detects violations; it cannot prevent them.

A daemon is currently running (pid 2562665, workers w1/w2 idle).

## 8. Gotchas that will cost you time otherwise

**Run the Godot import step before any test run.** `class_name` references do
not resolve until the editor has rescanned:

    /home/coder/tools/godot --headless --editor --quit --path .

This bit immediately after the audio merge — `Parse Error: Identifier "AudioCues"
not declared` — despite the code being verified green in a worktree.

**`./test.sh` runs headless with `--audio-driver Dummy`.** Nothing may assume a
real audio device exists.

**Do not race another agent's staging area.** During this session `git merge`
refused because a concurrent agent had 10 files staged mid-commit. The safe
landing is copy-the-files + `git commit -- <explicit paths>`, which cannot sweep
their work. Verified afterwards that their staged files were intact.

**A git worktree is not a jail** (see §7).

**Test cases that `await` must be `await`ed by their caller**, or every case runs
concurrently as an interleaved coroutine with its own world.

## 9. Mailbox

Outstanding questions posted by me, in `.agent_mailbox/questions.md`:
- **Q2** — the `find_loop` degenerate-route finding (now moot, see §5)
- **Q3** — the steer inversion finding (§5)

Unanswered at time of writing.

## 10. Project memory

Durable facts from this project are in `~/.agent-memory/projects/cairns-after-dark.md`
(ownership map, commands, and the measured gotchas behind §8), indexed in
`projects/INDEX.md`. **The fleet tooling in §7 is not yet written up there.**