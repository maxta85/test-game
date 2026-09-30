# HANDOVER — the map is real OpenStreetMap data

Written by the agent that replaced the authored Manunda block with real Cairns
streets. Work was stopped deliberately to re-cut agent ownership, so this is a
state report, not a proposal. Nothing below is in flight.

**State: pushed to `master` as `208d23e`, green, playable on the Windows
launcher.** One other agent has uncommitted work in `Systems/vehicle/car_visual.gd`
and `Tests/test_vehicle.gd` — not mine, not touched.

---

## 1. What actually changed, and why it was done this way

The layout used to be `World/manunda_layout.gd`: an invented suburb, authored by
hand, borrowing only the *character* of the real Manunda. It is now real
OpenStreetMap street geometry for **Manunda / Westcourt / Bungalow, Cairns**,
centred on **-16.93190, 145.75130** (Mulgrave Road), which is a pin the project
lead chose.

**The single most important thing to understand before changing any of this:**
`WorldBuilder` does not read meshes. It reads a `RoadGraph`, and every downstream
system — world geometry, traffic, race routes, the racing line, kerbs, lane
markings, streetlights, the reset-to-road button — derives its geometry from that
one graph. That is why the data goes in as **road corridors** and not as a
`.glb`/`.obj` city mesh. A marketplace mesh would have to be reverse-engineered
back into road corridors, which is more work than going to the source data.

This is also why the advice on the internet ("install Blender + BlenderGIS, or
buy the Cubebrush model") was the wrong answer for this codebase.

## 2. File inventory — what exists now, and who should own what next

| File | What it is |
|---|---|
| `Tools/osm_cairns.py` | Fetcher + converter. **stdlib only** (`urllib`, `xml.etree`, `math`) — no new dependency, no Blender. Owns: network access, projection, simplification, classification, dissolve. |
| `assets/maps/cairns_map.json` | The output. 29,509 bytes, 247 corridors. Generated, never hand-edit. |
| `World/osm_layout.gd` | GDScript loader. Exposes `corridors()` in exactly `ManundaLayout`'s format, plus `anchor()`, `start_line()`, `start_grid_position()`, `car_meet_position()`, `stats()`, `available()`. |
| `Tests/test_osm_layout.gd` | 21 assertions. Auto-discovered by the runner. |
| `Tools/diag_osm.gd` | One-shot diagnostic. Prints the graph, the anchor candidate table, on-road offsets. Also writes `shots/placements.json`. |
| `Tools/plot_map.py` | Writes `shots/map_overview.png`: the network next to the OSM raster for the same extent. This is the proof the projection is right. |
| `Tools/map_view.html` | Browser viewer. Pan/zoom the extracted network over the real basemap. |
| `Game/main.gd` | 4 call sites now use `OSMLayout` instead of `ManundaLayout` (3 + 1 boot log). **Note: this half landed in another agent's commit, not mine — see §6.** |
| `World/world_builder.gd` | `_blocks()` fix (§4) + the `car_meet_position()` call site. |
| `Systems/camera/shot_poser.gd` | Only the `"street"` preset, which now follows the map. |
| `Systems/race/race_def.gd` | Two race names moved onto real streets. |

`World/manunda_layout.gd` is **still there and still referenced by five test
suites** (`test_ai`, `test_race`, `test_traffic`, `test_world`,
`test_integration`). It was deliberately left working, not deleted — those suites
are testing the graph/layout contract, not the map. Do not delete it without
moving them.

## 3. Regenerating the map

```bash
python3 Tools/osm_cairns.py                 # fetch + convert (network)
python3 Tools/osm_cairns.py --cache-only    # re-convert the cached XML, no network
godot --headless --path . --script res://Tools/diag_osm.gd    # graph + placements
python3 Tools/plot_map.py                   # shots/map_overview.png
FRAMES=70 ./render.sh street aerial         # in-engine shots
```

To see it in a browser (this box is headless — there is no other way to look at
it interactively):
```bash
python3 -m http.server 8765 --bind 100.127.160.31   # from the repo root
# then open http://100.127.160.31:8765/Tools/map_view.html
```
Bind the tailnet IP, **not** `0.0.0.0`. This server is not running now; I
started it for verification and stopped it at handover.

## 4. Two real defects the real data exposed

Both were invisible on the authored lattice. This is the reason to prefer real
data even when it is more work — it found bugs that hand-authored input hid.

1. **`World/world_builder.gd` `_blocks()` gated on `edges.size() != 4`.**
   Manunda was a perfect grid, so nearly every junction was a crossroads and
   nearly every node qualified. Real suburbs are mostly T-junctions, so the gate
   rejected almost the entire city: **13 buildings placed**. Now `< 3`, which
   gives **131**.

2. **The import left 152 nodes in disconnected islands.** Real OSM has pockets
   joined only by a `service` way the classifier drops, plus private drives and
   edge stubs. Traffic routing and race circuits both assume one network, so
   `Tools/osm_cairns.py` now runs a **dissolve** (union-find on welded positions,
   keep the largest component, trim corridors to their longest contiguous run
   inside it). Graph is now **359/359 connected**, asserted exactly in the suite.

## 5. Numbers, as measured

| | |
|---|---|
| Fetch bbox | ±0.008° from -16.93190, 145.75130 |
| Pre-dissolve | 361 corridors, 5.3 MB source XML |
| **Shipped** | **247 corridors, 381 segments, 31.7 km** |
| Extent | 2586 × 2801 m (larger than the bbox — see §7.6) |
| Graph | 359 nodes, 401 edges, 61 named streets |
| Race found | **1815 m, 3 laps**, "Mulgrave Road Circuit" |
| Buildings | 131 (was 13 before the fix) |
| Tests | osm 21/21, race 99/99, integration 27/27, world 30/30 |

## 6. The concurrent-agent hazard — read this

Another agent committed with a broad `git add`, which swept **half** of the map
change (`Game/main.gd`'s `OSMLayout` call sites) into their commit `b3f71b1`
while `World/osm_layout.gd` and the map JSON stayed **untracked**. That left
`master` **unbootable**: `main.gd` called a class that was not in the repo.
`208d23e` completes it.

Consequences for whoever works here next:

- **Always `git add` explicit paths.** Never `-A`, never a broad directory.
- If you rename or move a class, check `git cat-file -e origin/master:<path>`
  before you push. A half-landed rename is a broken `master`, and the Windows
  launcher will pull it silently.
- `Windows/CairnsAfterDark.bat` step 2 is a bare `git pull --ff-only`. It cannot
  tell you the game is the wrong version, it will just start it.

## 7. Traps — things that cost time and will cost it again

1. **`RoadGraph.nearest_road()` returns the key `lateral`, not `offset`.** Full
   set: `edge`, `dist_along`, `point`, `lateral`. An in-flight edit in
   `Tests/test_world.gd` used `offset` and failed on it. There is no
   `edge_class()` accessor — read `graph.edges[eid]["class"]` directly.
2. **`RoadGraph.build()` is O(segments²)** — it intersects every segment against
   every other. 381 segments is comfortable. Tripling the corridor count (e.g.
   by keeping `service` ways) will hurt. Keep simplifying, or spatially bucket
   first.
3. **The `CLASSIFY` table in `Tools/osm_cairns.py` drops on purpose**, and the
   reasons are in the comment above it. `motorway`/`trunk` are grade-separated,
   so their centrelines never meet the streets they cross — keeping them invents
   a junction at every geometric crossing. `service`/`living_street`/footways are
   car parks and back lanes. **`tertiary` maps to STREET, not ARTERIAL** — a
   tertiary in a suburb is a residential street, and mapping it to ARTERIAL gives
   it a 14 m carriageway, lane markings and a 19 m/s limit.
4. **The projection needs `cos(latitude)`.** `x = lon * 111320 * cos(lat0)`. Drop
   it and every street is 7% too wide; nothing else complains. There is an
   assertion in the suite bounding the extent for exactly this.
5. **Overpass is unusable from this environment.** `overpass-api.de` returns
   406, and `overpass.private.coffee` / `overpass.osm.ch` return HTTP 200 with
   **zero elements** — a silent stub, which is worse than an error. Use
   `https://api.openstreetmap.org/api/0.6/map?bbox=W,S,E,N`. It is fine and
   fast. `Tools/osm_cairns.py` retries 3× but there is no mirror fallback,
   because there is no working mirror.
6. **`/api/0.6/map` returns *whole ways* that merely touch the bbox**, so the
   data is bigger than the box you asked for (2586 m of network from a 1769 m
   fetch). That is a feature — nothing is clipped mid-street — but do not be
   surprised, and do not "fix" it by clipping.
7. **`shots/` is gitignored**, so `shots/placements.json` does not travel to the
   Windows box. `Tools/map_view.html` degrades with a visible "run
   Tools/diag_osm.gd" message rather than silently. Expected.
8. **The map loads as a plain file, not an imported resource.** There is no
   `cairns_map.json.import` and no artifact in `.godot/imported/`, so
   `OSMLayout._read()` falls through to `FileAccess`. That is correct for running
   from source, which is what both the dev loop and `CairnsAfterDark.bat` do.
   **An exported PCK is unverified** — and there is no `export_presets.cfg` in
   the repo at all, so nothing has ever been exported. If anyone adds one,
   re-verify that the map still loads.
9. **Six of the seven shot presets are stale.** Only `"street"` follows the map.
   The rest are absolute Manunda coordinates and now frame nothing. `aerial`
   still roughly works because it looks at the origin.

## 8. Decisions I made, so they are not re-litigated blind

- **Anchor = the arterial nearest the network centre**, with a 200 m minimum
  length and length as tie-break. Not "longest arterial": the longest here is
  Hoare Street, 1408 m, but its midpoint is 1019 m out in an empty corner, so a
  start line on it opens the race in a field. Mulgrave Road is 825 m *and*
  central. `Tools/diag_osm.gd` prints the candidate table this is derived from
  if you want to re-check it against new data.
- **Placements are distances along the street (18 m, 70 m), not fractions of the
  polyline.** A fraction of a 250 m street and a fraction of a 1400 m one are not
  the same place — the car meet landed 3 m from the start grid until this changed.
- **The car meet is on the carriageway.** The old Manunda coordinate was a
  mid-block point that may have been inside a house, and offsetting sideways off
  a real street just walks into whatever building is there. All three placements
  are now asserted to be within the road's half-width.
- **No config flag to switch maps back.** A toggle nobody flips is speculative
  flexibility; `git checkout` is the A/B switch. If someone wants a runtime
  switch, that is a real request, not an oversight.

## 9. What is NOT done — the honest list

- **Buildings are still procedural.** The fetch pulled **2156 real OSM building
  footprints** and they are not used. The city is 131 generated boxes placed by
  the block logic. This is the biggest visual gap.
- **No water.** The Barron River runs straight through this area and is not in
  the game. `Tools/osm_cairns.py` only reads ways tagged `highway`; water was
  never extracted. The comparison PNG shows the river clearly missing.
- **No elevation.** The map is flat, and Cairns is genuinely flat at this
  location, so this is defensible rather than a gap — but it means no gradient
  for the touge route (`Systems/race/race_def.gd` deliberately treats gradient as
  an absent input rather than a fake number; do not invent one).
- **No real terrain.** `_terrain()` still generates a flat plane.
- **Six stale shot presets** (§7.9).

## 10. Suggested next split, if ownership is being re-cut

The two remaining pieces are buildings and water. **They are not cleanly
parallel as-is**, because both want to change the same two files —
`Tools/osm_cairns.py` and `World/world_builder.gd` — and two agents editing the
same file is exactly how `master` ended up unbootable today.

A shape that is safe:

1. **One agent does the fetcher** — extract buildings and water to two separate
   outputs, in a single pass. ~15 min, no concurrency, no risk.
2. **Then two agents in parallel, each owning one new file and nothing else:**
   `World/osm_buildings.gd` + `Tests/test_osm_buildings.gd`, and
   `World/osm_water.gd` + `Tests/test_osm_water.gd`. Neither touches
   `world_builder.gd` or `osm_cairns.py`.
3. **Whoever owns `World/world_builder.gd` wires both in** — two lines.

Buildings are the bigger visual win and the harder problem (footprints must not
intersect the carriageway, and `_blocks()` currently has its own idea of where
buildings go, so the two will have to be reconciled rather than simply combined).
Water is one polygon class plus a reflective material that has to obey
`ART_DIRECTION.md` — the road is the hero surface, and a mirror-smooth river
under a dark sky is an easy way to make the frame worse.

**Verify with `./test.sh osm` first** — it is 21 assertions and takes under a
second, and it is the thing that catches a fetcher change that quietly returns
zero elements.
