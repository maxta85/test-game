# BRIEF 2 — Turn the placeholder racer into a real racing AI

You are the race agent. You shipped the race system (99 tests, 0 failures) and
your question about elevation was answered: **no fake elevation, keep selecting
routes by corner sharpness, the map is genuinely flat.** Carry on from there.

The brief calls for street-racing AI that:

> follows racing lines, overtakes, defends, brakes, makes mistakes, collides,
> recovers from crashes, takes shortcuts where appropriate, reacts to the
> player, and has different skill levels. **Do not make AI perfectly accurate.**
> Some opponents should be aggressive. Some cautious. Some should make mistakes
> under pressure.

Right now `AI/ai_racer.gd` is a 40-line placeholder I wrote: it steers at a
point 22 m up the road and slows for corners. It is not a racing AI. Replace it.

---

## 1. Ground rules (unchanged)

**Do NOT edit:**

```
World/**      Systems/vehicle/**   Systems/camera/**   Systems/player/**
Game/**       AI/traffic/**        Systems/traffic/**  Systems/race/race_def.gd
Tests/harness.gd  Tests/run_tests.gd  Tests/test_traffic.gd  project.godot
Tools/see.py     AGENT_BRIEF_TRAFFIC.md
```

**You now own:** `AI/ai_racer.gd`, and any new `AI/racer/**` files you want,
plus `Tests/test_ai.gd`.

`Systems/race/race_director.gd` is **yours** (you wrote it) — extend it if the
AI needs the route. But do not change its existing public behaviour: 99 tests
depend on it and they must all keep passing.

The other two agents are working concurrently. `git add` **explicit paths only**,
never `-A`.

```
Import:  /home/coder/tools/godot --headless --editor --quit --path .
Tests:   ./test.sh ai        and ./test.sh race
```

---

## 2. The contract you must not break

`Game/main.gd` already instantiates you. Keep this surface working:

```gdscript
var ai := AIRacer.new()
ai.car = rival_car       # CarBody
ai.graph = graph         # RoadGraph
ai.skill = 0.72          # 0..1
```

`_physics_process` drives the car. If you need more inputs, add them with
defaults — do not remove or rename the four above.

**No cheating.** Drive the same `throttle` / `brake` / `steer` / `handbrake`
surface the player uses. No teleporting, no setting `linear_velocity` directly,
no privileged grip. If the AI can do something the player cannot, it is wrong.

---

## 3. What to build

### 3.1 Expose the route (small, unblocks you)
`RaceDirector` already builds `_pts` / `_cp` / `_cum`. Add a public accessor so
the AI can follow the same checkpoint route the race is validated against:

```gdscript
func route_points() -> Array       # Array[Vector2] through the junctions
func route_length() -> float
func nearest_route_index(pos: Vector3) -> int   # where a car is on the route
func line_position() -> Vector3                 # the start/finish line
func line_direction() -> Vector2
```

Reusing the *same* route the race is scored on is the point — an AI that
follows a different line than the one being timed is a bug.

### 3.2 A real racing line
- Build a smoothed line through the route, not the raw junction-to-junction
  polyline. Raw polylines make an AI that hunts between apexes and looks awful.
- Brake before corners using the distance remaining and the corner's severity.
  An AI that brakes at the apex is unfun and reads as broken.
- Commit to a throttle target per segment rather than reacting frame to frame.

### 3.3 Overtaking and defending
- When a slower car is ahead and there is a usable lane, pick a side, commit,
  and go. Aborting halfway through a pass is the worst-looking AI behaviour there
  is.
- Defend the inside line on approach when leading.
- Do not sideswipe: if the gap is not there, back out.

### 3.4 Mistakes and recovery — **the part most easily skipped, and the part the
brief cares about most**
- Scale error rate with `skill`. A `skill = 0.95` driver should be near-clean; a
  `skill = 0.3` driver should lock up, run wide, and occasionally bin it.
- Aggression and caution should be separate axes from raw pace. A fast cautious
  driver and a slow aggressive one are both interesting.
- **Recovery is required**: spun, facing the wrong way, or off the line, the AI
  must reorient and rejoin rather than driving in circles forever. Test this
  explicitly by starting the car backwards at a known point on the route.

---

## 4. Tests — `Tests/test_ai.gd`

The placeholder has no tests, which is why it is a placeholder. Required:

- the AI completes a lap of the real circuit from the real start line
- it stays on the road surface for a full lap (max lateral offset asserted
  against road width — use `RoadGraph.nearest_road()`)
- it brakes before a corner, not at it (assert speed is already falling while
  still some distance from the apex)
- given a slower car ahead, it overtakes rather than driving through it
- given no gap, it does **not** attempt the pass
- **spun 180° at a known point, it recovers and rejoins** — assert it is moving
  the right way again within N seconds, and assert a bound so a broken AI that
  circles forever fails rather than hangs
- two AIs of different skill produce measurably different lap times
- a low-skill AI makes at least one avoidable-looking error over a long run
  (assert `errors > 0` for skill < 0.5, and `== 0` is acceptable for skill > 0.95)
- it never exceeds the speed limit by an absurd factor (catch an AI that is
  driving 200 km/h through a 50 km/h street)

Use the real `RoadGraph` and a real `CarBody` on a real `RoadCollision`-style
flat collider — this suite genuinely needs physics, so build a small world with
`t.new_root()`. Keep runs short enough that `./test.sh ai` stays under ~60s.

---

## 5. Definition of done

- [ ] `./test.sh race` still 99/99 — you did not break the race system
- [ ] `./test.sh ai` passes, zero failures
- [ ] Every item in section 4 is covered
- [ ] `Game/main.gd` still runs unchanged (I am integrating it; do not edit it)
- [ ] Committed with explicit `git add` paths
- [ ] No stubs. If something is not implemented, say so rather than shipping a lie.

## 6. Stuck?
`.agent_mailbox/questions.md`, then `./.agent_mailbox/check_mail.sh`. Ask if the
route accessors are not doing what this brief says, or if you believe a file you
do not own is wrong. Paste real error text.
