# Architecture

Godot 4.3, GDScript, no external dependencies and no binary assets beyond the
car models. Everything is synthesised, generated or authored in-repo.

## The spine: one data source, many consumers

The single most important thing to understand before changing anything here is
that **the road network is real OpenStreetMap data** and everything else hangs
off it.

```
Tools/osm_cairns.py          fetches OSM once, offline from ~/.cache/osm/
        |
        +-- assets/maps/cairns_map.json        roads: 247 corridors, 31.7 km
        +-- assets/maps/cairns_buildings.json  2198 footprints
        +-- assets/maps/cairns_water.json      5 water features
                    |
        World/osm_layout.gd (class_name OSMLayout)
                    |
        RoadGraph.build(corridors)   computes intersections itself
                    |
     +--------+-------+--------+-----------+---------+
     |        |       |        |           |         |
  world   traffic   race    race_dir    racing   audio
  geometry  AI    (routes)  (timing)      line    (engine)
```

`RoadGraph.build()` does its own intersection detection, so every consumer
speaks the same corridor format and none of them knows or cares that the data
came from OSM. **The corridor format is `ManundaLayout`'s, unchanged** — that is
deliberate, and it is why a marketplace `.glb` was rejected in favour of going
to the source data.

## Systems

| Path | Owns | Notes |
|---|---|---|
| `World/road_graph.gd` | junctions, edges, class, speed limits, widths | the hub every system reads |
| `World/osm_layout.gd` | reads the map JSON | the only reader of `cairns_map.json` at runtime |
| `World/world_builder.gd` | terrain, roads, buildings, props, lighting | `_terrain_extent()` derives from the graph — see decisions/ |
| `Systems/vehicle/` | car physics, suspension, drivetrain, visuals | raycast vehicle, not a RigidBody + collider |
| `Systems/race/` | race definitions, circuits, race state machine | 99 assertions |
| `Systems/traffic/` + `AI/traffic/` | civilian traffic | separate agents |
| `AI/ai_racer.gd` | the racing AI driver | follows a racing line, 17 assertions |
| `AI/racer/racing_line.gd` | smoothed line + speed profile | pure geometry, no physics |
| `Audio/` | procedural engine, cues, buses, race bridge | synthesised, 135 + 37 assertions |
| `Vehicles/car_db.gd` | car specs, 7 fictionalised JDM archetypes | data only |
| `UI/` | race HUD | more to come |
| `Game/main.gd` | boots the world, builds the graph, owns cars | **merge agent's file** |

## Two hard constraints that shape every system

**1. The test suite runs headless with `--audio-driver Dummy`.** Every
`./test.sh` invocation is `godot --headless --path . --audio-driver Dummy`.
No system may assume a display or a real audio device. This is why the audio
DSP lives in a `RefCounted` and renders into a plain array rather than inside
the player: under the dummy driver the generator is never drained and no frames
come back, so a player-side synth could only be tested for "did not crash".

**2. Agents work in git worktrees, not the shared tree.** Every specialist has
its own branch and its own directory. A post-run scope audit fails any task that
touched a file outside its assigned paths. This is detection, not prevention —
there is no sandbox — so the ownership table in `/docs/agents/` is the real
control.

## Testing

No framework. `Tests/harness.gd` is deliberately tiny: asserts, counters, and a
way to create and drop a physics world. `Tests/run_tests.gd` discovers suites
by name and filters with an argument.

```bash
./test.sh              # everything
./test.sh race         # suites whose name contains "race"
./test.sh osm
```

**A test file nobody registers in `Tests/run_tests.gd` does not run, and it
passes by not existing.** `run_tests.gd` is the merge agent's file alone.

Visual systems use a different loop, because headless pixel checks lie:
`Game/main.gd --shot <path> <preset>` renders a frame, and `Tools/see.py` sends
it to a vision model and prints a description.

## Dependencies

None beyond Godot. `Tools/see.py` talks to a LiteLLM relay for vision
analysis; that is a development tool, not a runtime dependency, and the game
does not need it to run.
