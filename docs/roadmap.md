# Roadmap

Priority, in the order that matters: **playability, visual quality, core racing
loop, stable architecture, integration, content, polish, distribution.**

The target is one cohesive game, not seven agents generating features. The unit
of progress is the **vertical slice working end to end**, not a subsystem
existing.

## The vertical slice

```
Main Menu → Garage → choose a car → Start Race → night Cairns
          → race the AI → HUD → audio → finish → results → money → Garage
```

Everything except three links already exists:

| Link | State |
|---|---|
| Garage scene, car selection, upgrades | **missing** — the garage agent's job |
| Main menu, race select, results screen | **missing** — the UI agent's job |
| Choose car → start race wiring | **missing** — needs `Game/main.gd` |
| Night Cairns with real roads | done, roads are OSM |
| Race the AI | done, 17 assertions |
| HUD | done, `UI/race_hud.gd` |
| Audio | done, 135 + 37 assertions |
| Results, money, records | done, `Systems/race/` |

So the slice is blocked on **garage + menu + the wiring between them**. That is
the highest-value work in the project and it is the next thing dispatched.

## In flight

| Agent | Work | Gate |
|---|---|---|
| `agent/map-buildings` | 2198 real OSM footprints in the world, none intruding on the carriageway | `./test.sh osm && ./test.sh vehicle` |
| `agent/map-roads` | diagnose and fix the road surface | `./test.sh osm && ./test.sh vehicle` |

## Queued, in priority order

1. **Garage** — scene, car select, stats, upgrades, money. The largest single
   missing piece of the slice.
2. **UI** — main menu, race select, results, pause. Generic Godot controls are
   not acceptable here.
3. **Wiring the slice** — merge agent's job: one `Game/main.gd` change that
   takes you from menu → garage → race → results.
4. **Cars** — extend the roster to the full archetype set (Silvia, Skyline,
   RX-7, Supra, Evo, Integra, Civic, Chaser — five of eight exist) and get the
   two cars that still draw boxes onto real models.
5. **Water** — the Barron River is in the data and not in the world.
6. **Installer** — distribution is last on the priority list. The current
   `windows/CairnsAfterDark.bat` exists; a real installer is not close.

## Known gaps, honestly

- **Buildings are still procedural.** 131 generated Queensland houses. The
  2198 OSM footprints are extracted and committed but not consumed yet. This is
  the biggest visual gap and it is in flight.
- **The river is missing.** 5 water features extracted, none in the world.
- **Two of seven cars still draw primitive boxes** (`kairo_mx90`, `kaze_type_r`
  have no glb mapping) and two downloaded glb files are unused — 50 MB of
  storage for a car that never spawns.
- **No elevation, and that is deliberate.** Cairns CBD is flat. The touge route
  treats gradient as an absent input rather than a fake number. Do not invent
  one.
- **Audio is not in the game yet.** The system and the race bridge are
  committed and green; nothing creates the bridge at boot. One line in
  `Game/main.gd`.
- **The AI suite takes 5–6 minutes** because physics in this harness is
  real-time bound. A simulated second is a wall-clock second.

## Decisions

Recorded in `/docs/decisions/`. The ones that will bite you if you do not read
them:

- terrain extent is derived from the road graph, never a constant — a hardcoded
  800 m left 700 m of real street with no floor under it
- circuits are grown by detouring a loop around blocks and validated for
  corners, because `find_loop` can return a degenerate out-and-back
- the racing line is clamped to within 2.5 m of the route, because smoothing
  that is not clamped cuts the block behind a corner
