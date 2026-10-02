# Render performance - BEFORE baseline, and the cost artkit will add

All numbers measured on the render box (RTX 3060, 12 GB, named by WFOL_SSH_HOST),
Vulkan forward+, **1280x720**, against `main` at `443010b`. 3 agents share that
machine, which is the single most important caveat below.

## How to reproduce

The bench scripts take the box's connection details as required environment
variables (WFOL_SSH_HOST, WFOL_SSH_USER, WFOL_SSH_PORT, WFOL_SSH_KEY) so that
nothing about the machine is written down here. Each writes only to its own
WFOL_REMOTE_DIR, never to a directory another agent shares.

```bash
Tools/w3push.sh                       # sync this project to $WFOL_REMOTE_DIR
Tools/bench_run.sh street aerial carhero carfront
OFF=lights Tools/bench_run.sh aerial   # ablations
Tools/bench_artkit_run.sh street      # artkit cost, one boot
```

Two benches, and why there are two:

- **`Tools/bench_scene.gd`** loads `res://Game/main.tscn` and drives it exactly the
  way `render.sh` does - same presets, same auto-started race, same hidden menus -
  and only adds measurement. This is the number that matters, because it includes
  the reflection probe, the player car, the chase camera, the HUD and the race
  director.
- **`Tools/bench_artkit.gd`** boots once and measures, adds `ArtKitScatter`, and
  measures again in the same process. See "Why one boot" below - subtracting two
  separate runs is not valid on this box.

`Tools/bench_render.gd` (pre-existing) stays what it was: a deterministic
scene-graph budget gate that runs on a CPU box. It is the wrong tool for frame
time, and its header already says so.

## Read this before reading any number: the box is shared

Several agents run on the render box at the same time. Between two measurement
sessions an hour apart, with the same project and the same preset, the `street`
preset measured **9.7 ms** and then **8.3 ms**. Nothing changed. p95 frame times
swing by 10 ms between repeats on their own.

So:

- **Deltas measured within one session are trustworthy.** Every ablation and
  every artkit delta below is back-to-back in one process, and those are the
  numbers to act on.
- **Absolute baselines are a range, not a point.** Quoted as the spread across
  repeats within a session.
- Frame time is reported as **median and p95, never mean**. A single contended
  frame moves a mean a long way and a median not at all.

## BEFORE baseline (current main, no artkit)

Frozen world: the tree is paused before sampling, so the car and the AI traffic
hold still. Without that, a car-relative preset drifts out of frame mid-run and
the draw-call count falls 874 -> 651 inside a single run - that is the scene
changing, not the frame rate. It is not a repeatable measurement without it.

| preset | frame time (median) | fps | draw calls | primitives |
|---|---|---|---|---|
| `street` | 9.6 - 9.7 ms | ~103 | 413 | 4,382,846 |
| `aerial` | 20.2 - 20.6 ms | ~49 | 422 | 4,382,918 |
| `carhero` | 10.9 - 11.1 ms | ~91 | 874 | 4,823,896 |
| `carfront` | 18.8 - 23.3 ms | ~43-53 | 834 | 4,814,375 |

Scene: 1,756 nodes, 353 mesh nodes, 68 multimesh nodes, **1,327 lights, 0 of them
shadow-casting**, 4.38M primitives at the street shot.

**The spread between presets is the real finding.** `street` and `carhero` are
comfortably over 90 fps. `aerial` and `carfront` are already under 60 fps *before
artkit exists*. `carfront` is a ground-level shot - it is slow for the same
reason `aerial` is: it sits in the middle of the suburb with 834 draw calls and
nothing culling, rather than in a street canyon where a 413-call view down the
road lets frustum culling do its job. Where the player is matters more than what
is on screen.

## What artkit will cost

One boot, `ArtKitScatter` attached between the two measurements, so the only
thing separating them is the scatter node.

Fed in: the **real 2,198 OSM footprints** from `OSMBuildings.plan()` (storeys and
lit fraction passed through, so they wrap as houses rather than shoeboxes) plus
**1,555 props** placed the way `WorldBuilder` places them - along street-class
edges, alternating kerbs, every 18 m.

| preset | before | after | delta | fps before -> after | draw calls |
|---|---|---|---|---|---|
| `street` | 9.62 ms | 12.42 ms | **+2.80 ms (x1.29)** | 104 -> 80 | 413 -> 808 (+395) |
| `aerial` | 23.06 ms | 27.84 ms | **+4.78 ms (x1.21)** | 43.4 -> 35.9 | 422 -> 822 (+400) |
| `carfront` | 23.34 ms | 28.14 ms | **+4.80 ms (x1.21)** | 42.8 -> 35.5 | 834 -> 1234 (+400) |

### The kit's own draw-call claims hold

`ArtKitScatter.stats` in the real scene, with the real lights:

```
nodes 84 | prop_nodes 69 | building_nodes 15 | instances 14651
triangles 1378110 | props 1555 | buildings 2198 | skipped 0
```

- **"400 unique wrapped footprints -> 15 draw calls": confirmed.** 2,198
  footprints produced exactly **15** building nodes. Baking works as advertised.
- **"1650 placements -> 126 draw calls": holds.** 1,555 placements produced 69
  prop nodes, well under the claimed ceiling.

Nothing about the artkit's batching is broken, and it should not be touched.

### The cost is not draw calls. It is primitives.

Draw calls are the cheap axis on a modern GPU and the kit already spent them
well. The expensive one is primitive count:

```
street: 4,382,846 -> 11,231,476 primitives   (+6,848,630, x2.6)
```

The scatter reports 1,378,110 triangles but adds **6.85M** primitives - a 5x
multiplier. That is MultiMesh: **14,651 instances**, each drawn per instance
regardless of how few draw calls they cost. A palm is 14 triangles in the batch
stats and several hundred rendered primitives per placement. The kit optimises
the thing it measures (calls) and the thing that actually bites here (vertices)
is untouched.

### The ceiling, stated honestly

At `street`, artkit costs 2.8 ms on a 9.6 ms frame and still lands at **80 fps**.
At the wide views, which were **already below 60 fps before artkit**, it costs
another 4.8 ms and lands at **~36 fps**.

So the ceiling is not "artkit is affordable" or "artkit is unaffordable". It is:

> **Artkit is affordable in a street canyon and unaffordable in the open suburb,
> and the open suburb is already failing before artkit is wired in.**

The binding constraint is the pre-existing 43 fps at `aerial`/`carfront`, not the
artkit delta. Fixing the wide-view cost first buys artkit ~2x more headroom than
optimising artkit would.

### One more number: the build

`ArtKitScatter` build is a **one-off at load**: **18.5 s / 27.1 s / 36.4 s** across
the three runs. That range is contention, not a stable measurement - treat it as
"tens of seconds", not as three numbers. It is the same order as the existing
23.6 s world build, so wiring artkit in roughly doubles time-to-first-frame.
Anyone measuring boot time after this lands should expect it to have moved.

## Render settings: measured, and the answer is leave them alone

The brief asked for tuning proposals with measurements. The sweep says there is
no free win here, so **no `project.godot` change is proposed.** Back-to-back in
one session:

**`soft_shadow_filter_quality` (directional), currently 2**

| value | `street` | `aerial` |
|---|---|---|
| 0 | 9.50 / 9.46 ms | 18.45 / 18.48 ms |
| 1 | 8.25 / 8.27 ms | 18.43 / 18.34 ms |
| 2 (current) | 8.33 / 8.34 ms | 18.34 / 18.35 ms |

1 and 2 are indistinguishable - within noise in both directions. **Dropping to 0
is measurably *worse*** (street 9.5 vs 8.3), which is not what a naive
"lowest quality is fastest" expectation predicts. There is nothing to win.

**`msaa_3d`, currently 1 (2x)**

| value | `street` | `aerial` |
|---|---|---|
| 0 | 8.00 / 8.10 ms | 18.07 / 18.10 ms |
| 1 (current) | 8.24 / 8.32 ms | 18.38 / 18.38 ms |

Turning MSAA off saves **0.2 - 0.3 ms, about 2-3%**. That is a real but small win
with a real visual cost on a game whose whole look is wet reflective asphalt, and
2-3% does not pay for it. Not proposed.

**`positional_shadow/soft_shadow_filter_quality`, currently 2** - every omni in
the scene has `shadow_enabled = false`, so this setting currently governs
nothing. Changing it is a no-op, not a saving.

### Shadows: do not turn them on, and here is the number

The obvious temptation on a 1,278-streetlight night scene is to let some of them
cast shadows. Measured - all 1,327 omnis given shadows, directional shadow off:

| preset | before | with omni shadows | draw calls |
|---|---|---|---|
| `street` | 9.7 ms | 6.75 ms | 413 -> 197 |
| `aerial` | 22.7 ms | **41.4 ms (x1.82)** | 422 -> **2,723** |

`aerial` nearly doubles. `WorldBuilder._streetlights()` says "hundreds of
shadow-casting lights would melt a CPU raster"; on a real GPU 3060 it is still
+19 ms and +2,300 draw calls. **Do not enable omni shadows.** The `street` number
looks like a win but it is not one - it is the directional shadow being removed
(413 -> 197 calls) with only a handful of nearby omnis inside a street canyon
ever becoming relevant, and it is not a configuration worth having.

## Where the time actually goes

Ablations, one session, back-to-back (`--off=<what>` in `bench_scene.gd`):

| preset | baseline | lights off | fog/glow/ssao/ssil off | both off |
|---|---|---|---|---|
| `street` | 9.67 / 9.73 | 9.62 / 9.56 | 9.48 / 9.52 | - |
| `aerial` | 22.76 / 22.72 | **17.12 / 17.25** | **18.04 / 18.07** | 16.80 / 17.00 |
| `carfront` | 18.75 / 18.78 | 17.40 / 19.72 | 18.53 / 18.59 | 17.14 / 17.27 |

- At `aerial` the 1,327 streetlights cost **~5.5 ms (24%)** and the post stack
  **~4.7 ms (21%)**.
- The savings do **not** add up (5.5 + 4.7 = 10.2, but both-off only saves 5.9),
  so the two overlap heavily - they are not independent budgets.
- At `street` neither matters: together they are ~0.35 ms of a 9.7 ms frame.
  The ground-level cost is spread thin across everything, with no single target.
- The reflection probe is **not** a cost here. Freezing it, and separately
  removing the node outright, moved frame time by less than the session noise
  (< 0.5 ms) at every preset.

## What I would do next, in order

1. **Cull omni lights by distance** before the artkit lands. 1,327 shadowless
   omnis is a third of the wide-view frame. Godot's clustered forward+ already
   limits per-pixel work, so the win is in the per-cluster cull, not the lights
   themselves - measure before assuming.
2. **Cut prop instance count, not prop draw calls.** 14,651 instances for 1,555
   placements is the actual artkit cost. Fewer, larger props is a content
   decision and would cost nothing the kit does.
3. **Profile the wide views first.** `aerial` at 43 fps is a pre-existing
   problem that artkit makes worse, and fixing it buys more headroom than any
   artkit change.
