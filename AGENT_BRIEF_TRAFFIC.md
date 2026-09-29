# BRIEF — Build civilian traffic for CAIRNS AFTER DARK

You are one of **three** agents working in this Godot project. I am handling the
world, lighting, camera and driving feel. Another agent is building the race
system. **You own civilian traffic.** We never touch each other's files.

Traffic is explicitly on the first-milestone checklist, and the brief calls for
traffic that "makes racing through the city dangerous" — so it matters.

---

## 1. Ground rules

**Do NOT edit any of these. They belong to the other two agents and are being
actively changed right now:**

```
World/**                Systems/vehicle/**     Systems/camera/**
Systems/player/**       Systems/race/**        AI/ai_racer.gd
Game/main.gd  Game/main.tscn  Game/cfg.gd  Game/probe.gd
Tests/harness.gd        Tests/run_tests.gd     project.godot
Tools/see.py            AGENT_BRIEF_RACE.md
```

**You own:** `AI/traffic/**`, `Systems/traffic/**`, `Tests/test_traffic.gd`.
Nothing else.

**Registering your tests:** do nothing. The runner auto-discovers every
`Tests/test_*.gd` at startup. Creating `Tests/test_traffic.gd` is all it takes.
Do not edit another agent's `test_*.gd`.

**Tools:**
```
Engine:  /home/coder/tools/godot  (Godot 4.3, already installed)
Import:  /home/coder/tools/godot --headless --editor --quit --path .   # REQUIRED
Tests:   ./test.sh traffic
```

> The import step is **not optional**. Godot registers `class_name` globals in a
> cache built during import; a new `class_name TrafficCar` will fail with
> `Could not find type` until you run it.

**Git — we commit concurrently:**
```bash
git add AI/traffic Systems/traffic Tests/test_traffic.gd   # ALWAYS explicit
# NEVER `git add -A` / `git add .` — that stages other agents' in-progress work.
git -c user.email=agent@localhost -c user.name="Traffic Agent" commit -m "..."
```

**All content ORIGINAL.** No real car brands, no copied assets, no scraped map
data. Fictional marques only.

---

## 2. What already exists that you build on

### `RoadGraph` (`World/road_graph.gd`) — read it
The road network: 241 junctions, 312 edges, 27.4 km. Edges carry `class`,
`width`, `lanes`, `name`. The API:
```gdscript
g.nodes            # [{id, pos:Vector2, key, edges:Array[int], class}]
g.edges            # [{id, a:int, b:int, class, width, lanes, name, oneway}]
g.node_pos(i) -> Vector2
g.edge_length(id) -> float
g.point_on_edge(id, distance, from_a := true) -> Vector3
g.other_node(edge_id, node_id) -> int
g.nearest_road(pos) -> {edge, dist_along, point:Vector3, lateral}
g.speed_for(class) -> float          # m/s speed limit
g.width_for(class) -> float
RoadGraph.RoadClass.LANE / .STREET / .ARTERIAL / .HIGHWAY
```

### Test harness (`Tests/harness.gd`) — read it
No framework. Suites are `RefCounted` with an awaited `run(t: TestHarness)`.
```gdscript
t.ok(cond, "label")          t.eq(actual, expected, "label")
t.near(a, b, tol, "label")   t.between(a, lo, hi, "label")
t.gt(a, threshold, "label")  t.fails(cond, "label")   # asserts cond is FALSE
var world := t.new_root("Name")   # Node3D on the tree
await t.ticks(10)                # await 10 physics frames
await t.drop(world)
```
`t.fails(cond, …)` asserts `cond == false`. I have shipped two bugs by
misreading it, so re-read the harness before trusting a surprising result.

### Car specs (`Vehicles/car_db.gd`, `Vehicles/car_spec.gd`) — read only
`CarDB.get_spec(id)` returns a `CarSpec` (mass, length, width, dims). The
fictional civilian roster is **your job to add** — see below. Do not edit these
two files; add your civilian cars in your own module and read the spec data
from them.

---

## 3. What to build

### 3.1 Design constraint that shapes everything

**Traffic must be drivable and testable as pure logic, with no physics body.**

Do not spawn `CarBody` instances. Instead each traffic car is a small object
holding a *route* (a list of edge ids) and a scalar *distance along that route*,
advancing by `speed * delta`. Position is derived. This is how real traffic
systems work, it runs 200+ cars on a CPU, and it is unit-testable headlessly in
milliseconds.

A `TrafficCar` should be able to answer: "give me my world position", "am I
blocked?", "should I change lane?". That split is the whole architecture — keep
it.

### 3.2 `AI/traffic/traffic_car.gd`
- Holds a route (edge id list), a lateral offset from the centreline (so cars
  sit in the correct lane, on the correct side), current speed, and target speed.
- `position()` → world `Vector3`, derived from route progress + lateral offset.
- Speeds up, holds the speed limit, and **decelerates for whatever is in front**
  (other traffic, the player's car, a red light). Braking must be *predictable
  and early* — a car that brakes at the last moment looks like a bug and makes
  the street unplayable.
- Chooses the next edge at junctions. Never pick an illegal manoeuvre: no
  U-turns except where genuinely dead-ended, no driving the wrong way down a
  one-way.

### 3.3 `AI/traffic/traffic_manager.gd`
- Spawns and despawns to hit a target density, spread across the network
  (not all bunched in one place).
- Provides **forward queries for the player**: "is a car ahead of me within X
  metres in my lane?" This is what makes racing through the city dangerous, so
  the game will call it every frame. Design it to be cheap.
- Handles lane changes and bunching: if a car is stuck behind a slower one for
  too long on a multi-lane road, it should try to move over.

### 3.4 Traffic lights
- Intersections with ≥3 edges get lights, cycling green→amber→red.
- Cars must stop at red and go at green. **The brief says traffic must obey
  traffic lights most of the time** — so also add a small per-car "compliance"
  roll so a minority of drivers run a red. This is deliberate and is called for;
  do not make every car perfectly obedient, and do not make it random chaos
  either.

### 3.5 Parked cars and pedestrians
- Parked cars along the kerb — these are the obstacles a street race threads
  between, and they are the cheapest way to make a street feel inhabited.
- Pedestrians near the commercial strip. Simple bobbing capsules are fine; the
  point is that the shops have people outside them, not that they are
  simulated.

### 3.6 Civilian car roster
Add **6–8 fictional civilian vehicles** representing what actually drives in
Queensland: sedans, SUVs, utes (pickups), vans, hatchbacks, a small truck.
Put them in **your own file** (`AI/traffic/civilian_cars.gd`) with a lookup
function — do not edit `Vehicles/car_db.gd`. Give each a distinct silhouette
(length/width/height) and a distinct speed behaviour, because a stream of
identical cars is the classic giveaway of a fake city.

---

## 4. Tests — `Tests/test_traffic.gd`

Required cases (the brief forbids shipping anything unverified):
- a car advances along its route and stays on the road surface
- a car stays on the correct side of the centreline (right-hand traffic — this
  is Australia)
- a car slows for an obstacle ahead and does **not** collide with it
- braking is early enough to be survivable (assert a minimum gap is preserved)
- a car stops at a red light and proceeds on green
- the "non-compliant" minority does run reds, and it is a *minority*
- lane selection picks a valid edge at a junction and never goes the wrong way
  down a one-way
- density management: spawning N cars yields N cars, and despawning returns to
  target — and never spawns two cars on top of each other
- the forward "is there a car in front of me" query finds a car placed ahead and
  returns none when the road is clear
- parked cars are placed on the kerb, not in the driving lane
- every civilian car spec is sane (positive mass, plausible dimensions)

Use a real `RoadGraph` (pure computation and cheap) with **plain fake cars**, not
`CarBody`. Do not depend on vehicle physics — it keeps your tests fast and stops
us colliding.

---

## 5. Definition of done

- [ ] `./test.sh traffic` passes, zero failures
- [ ] Every item in section 4 is covered
- [ ] No file outside your ownership modified
- [ ] Committed with explicit `git add` paths
- [ ] **No stubs, no `pass`-only functions, no fake buttons.** If something is
      not implemented, say so in your summary rather than shipping a lie.
- [ ] It should be obvious to a reader how the game will plug you in: expose
      one obvious entry point (e.g. `TrafficManager.spawn(world, graph, count)`)
      so I can wire it into `Game/main.gd` without reading your whole module.

---

## 6. Stuck?

Do not guess for more than ~10 minutes. Append to `.agent_mailbox/questions.md`
(format in `.agent_mailbox/README.md`) and run `./.agent_mailbox/check_mail.sh`.

Ask if the interfaces above do not do what this brief says, a requirement is
genuinely ambiguous, or you believe a file you do not own is wrong. Do **not**
ask about anything you can answer by running a command — and paste the **real
error text**, not a paraphrase.
