# BRIEF — Build the race system for CAIRNS AFTER DARK

You are one of two agents working in this Godot project. I am handling the
world, lighting and driving feel. **You own the race system.** We never touch
each other's files.

---

## 1. Ground rules (read these first)

**Do NOT edit any of these — they belong to the other agent and are being
actively changed right now. Editing them will cause real conflicts:**

```
World/**              Systems/vehicle/**      Systems/camera/**
Systems/player/**     Game/main.gd  Game/main.tscn  Game/cfg.gd
Game/probe.gd         Tests/harness.gd  Tests/run_tests.gd
project.godot         Tools/see.py
```

**You own:** `Systems/race/**`, `Tests/test_race.gd`. Nothing else.

**Registering your test suite:** do nothing. The runner now auto-discovers every
`Tests/test_*.gd` at startup, so simply creating `Tests/test_race.gd` is enough.
Do not edit `Tests/run_tests.gd` (and do not edit another agent's `test_*.gd` -
a second agent is working here concurrently).

**Tools:**
```
Engine:  /home/coder/tools/godot  (Godot 4.3, already installed)
Import:  /home/coder/tools/godot --headless --editor --quit --path .   # REQUIRED first
Tests:   ./test.sh race         (headless; no display needed)
```

> **The import step is not optional.** Godot registers `class_name` globals in a
> cache built during import. A new file with `class_name RaceDirector` will fail
> with `Could not find type "RaceDirector"` until you run the import command.
> If you see that error, you forgot this step.

**Git — important, we are committing concurrently:**
```bash
git add Systems/race Tests/test_race.gd      # ALWAYS explicit paths
# NEVER `git add -A` or `git add .` — that will stage the other agent's
# uncommitted work-in-progress into your commit and break their build.
git -c user.email=agent@localhost -c user.name="Race Agent" commit -m "..."
```

**All content must be ORIGINAL.** No real car brands, no copyrighted names, no
textures or assets from anywhere. This is a fictionalised Cairns.

---

## 2. What exists already that you build on

### `RoadGraph` (`World/road_graph.gd`) — read this file
A real road network: junctions as nodes, road segments as edges, built from
authored street corridors. It currently has 241 junctions, 312 edges, 27.4 km.

The API you need:
```gdscript
var g := RoadGraph.new()
g.build(ManundaLayout.corridors())

g.nodes            # [{id, pos:Vector2, key, edges:Array[int], class}]
g.edges            # [{id, a:int, b:int, class, width, lanes, name, oneway}]
g.node_pos(i) -> Vector2
g.edge_length(id) -> float
g.point_on_edge(id, distance, from_a := true) -> Vector3
g.other_node(edge_id, node_id) -> int
g.nearest_road(pos: Vector3) -> {edge:int, dist_along:float, point:Vector3, lateral:float}
g.find_loop(start_node:int, target_len_m:float) -> Array   # closed circuit of node ids
g.speed_for(class) -> float      # speed limit, m/s
g.width_for(class) -> float

RoadGraph.RoadClass.LANE / .STREET / .ARTERIAL / .HIGHWAY
```

**`find_loop` is your friend.** It already works and returns a closed racing
circuit through real streets — `find_loop(0, 700.0)` currently returns a
**2283 m, 30-junction lap**. Use it to generate a real street circuit rather
than inventing an oval.

### Test harness (`Tests/harness.gd`) — read this file
No test framework. A `RefCounted` harness with counters. Suites are
`RefCounted` with a `run(t: TestHarness)` method that is awaited.

```gdscript
extends RefCounted
func run(t: TestHarness) -> void:
    t.suite("race")                      # optional, runner already does it
    t.ok(cond, "label")
    t.eq(actual, expected, "label")
    t.near(actual, expected, tolerance, "label")
    t.between(actual, lo, hi, "label")
    t.gt(actual, threshold, "label")
    t.fails(cond, "label")               # asserts cond is FALSE
    var world := t.new_root("RaceWorld") # a Node3D added to the tree
    await t.ticks(10)                    # await 10 physics frames
    await t.drop(world)                  # free it
```

Note `t.fails(cond, "x")` asserts `cond == false`. I have shipped two bugs of my
own by misreading that helper, so if a result looks inverted, re-read the
harness before you trust it.

### Money / progression (`Game/cfg.gd`) — **read only, do not edit**
A `Cfg` autoload you may call: `Cfg.money`, `Cfg.add_money(int)`,
`Cfg.record_race(race_id, best_time, best_lap)`, `Cfg.save_game()`.

---

## 3. What to build

A `RaceDirector` that runs a race from a start grid to a finish, plus race
definitions. Pure logic driven by car positions, so it is fast and testable
headlessly with no rendering.

### 3.1 `Systems/race/race_def.gd`
A race definition: id, display name, type, node path / checkpoint list, lap
count, number of opponents, entry fee, payout, and a difficulty rating.

Required race types, per the design brief:
- **Sprint** — point A to point B, no laps.
- **Circuit** — 3-5 laps of a closed loop.
- **Time attack** — solo, minimal traffic, best lap matters most.
- **Pursuit** — opponents/police apply pressure. (Start simple: opponents only.
  Do not implement helicopters. Leave escalation levels as data, not systems.)
- **Touge-style run** — technical, uses elevation, tight corners, narrow streets.

### 3.2 `Systems/race/race_director.gd`
States: `IDLE -> COUNTDOWN -> RACING -> FINISHED -> (back to IDLE)`

Responsibilities:
- **Starting grid.** Assign grid slots, place cars, hold them until lights out.
- **Countdown.** 3-2-1-GO, with engine revving. Cars cannot move before GO.
- **Checkpoints.** Ordered list. Must be passed **in order** — skipping a
  checkpoint must not be allowed to count. This is the single most important
  correctness property; test it explicitly.
- **Lap counting.** Increment only when crossing the start/finish line in the
  correct direction.
- **Wrong-way detection.** Car facing against the track direction.
- **Finish detection.** Required laps completed AND all checkpoints passed.
- **Timing.** Per-lap and total times, best lap, and results ordered by finish.
- **Rewards.** Payout to the finishers, scaled by position, minus entry fee.

### 3.3 `Tests/test_race.gd`
**This is the deliverable that proves it works.** The brief is explicit that
nothing ships unverified. Required cases:
- countdown blocks input before GO
- checkpoints must be taken in order (skipping one does not progress)
- lap increments on a valid line crossing
- lap does **not** increment crossing backwards
- finish fires only after the required laps
- results are ordered by finish time
- payout is correct for each finishing position
- insufficient funds cannot enter a race
- wrong-way is detected and cleared

Use a real `RoadGraph` (it is pure computation, cheap) but a **fake car** — a
plain object with a `position` you move around — not `CarBody`. You do not
depend on vehicle physics, which keeps your tests fast and keeps us from
colliding.

---

## 4. Definition of done

- [ ] `./test.sh race` passes with **zero** failures
- [ ] Every item in section 3.3 is covered
- [ ] No file outside your ownership is modified
- [ ] Committed with explicit `git add` paths
- [ ] No stubs, no `pass`-only functions, no fake buttons. If something is not
      implemented, say so in your summary rather than shipping a lie.

---

## 5. Stuck?

Do not guess for more than ~10 minutes. Append a question to
`.agent_mailbox/questions.md` (format in `.agent_mailbox/README.md`) and run
`./.agent_mailbox/check_mail.sh` to check for an answer.

Ask if: the interfaces above are not doing what this brief says, a requirement
is genuinely ambiguous, or you believe a file you do not own is wrong.
Do not ask about anything you can answer by running a command — and paste the
**real error text**, not a paraphrase of it.
