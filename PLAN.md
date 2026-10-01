# Cairns After Dark — current plan and evidence

Written because long-running commands get interrupted when the player speaks, and
an interrupted turn used to lose the whole task. Everything needed to resume is
here. Live state: `bash ~/kilo-fleet/state.sh` (returns in ~3s).

## Operating rules for the lead

1. **Never run a blocking command.** No `sleep 300`, no suite in the foreground,
   no render in the foreground. The player's messages interrupt them and the task
   is lost. Fire it in the background, return immediately, read the result on a
   later turn.
2. **Delegate the long work.** Ten workers are already running. Do not re-do their
   jobs; write a precise brief with the evidence and move on.
3. **A green test suite is not evidence.** 1115 tests passed while the cars drove
   backwards. Verification means looking at a rendered frame.

## The playtest harness (the fix for the above)

`Tools/playtest.gd` + `Tools/playtest.tscn` boots the real `Game/main.tscn`, starts
a race, applies scripted throttle/steer/handbrake over five phases, writes
`shots/playtest_*.png`, prints a `PLAYTEST VERDICT` block (travel along
start-forward, peak km/h, gear, wheel spin, slip angle, wheels down) and
`shots/playtest_telemetry.tsv`.

    DISPLAY=:99 godot --path . --rendering-driver vulkan --audio-driver Dummy \
      --fixed-fps 60 res://Tools/playtest.tscn

Needs `Xvfb :99` and takes ~10 min locally under llvmpipe (software). Much faster
on the renderbox. Run it in the background.

## What the player reported, and what was confirmed by driving it

Every item below was reproduced, not assumed.

| Complaint | Status | Root cause |
|---|---|---|
| Cars are backwards | **CONFIRMED** | `assets/cars/fit.gd` has `rot_deg: Vector3(0,0,0)` for every car. `Tools/fit_cars.gd` assumed a GLB nose lies along +Y; in glTF it is +Z. `carfront` camera preset shows the REAR (SILVIA badge, tail lights, QLD plate). Chase cam sees the car's front. |
| Wheels don't spin | **CONFIRMED** | `spin_vis` is computed (`car_body.gd:577,629`) and read (`car_visual.gd:324`) but nothing visibly rotates. Cast likely null, or wrong node, or wrong axis. |
| Handling/physics trash | **CONFIRMED** | 4 s of full throttle from rest = 16 km/h. |
| AI is useless | **CONFIRMED** | Rival drives onto the kerb at a bad angle, off the racing line. |
| Audio makes no sense | wired, unaudited | Beds up, engine voice per car (`KAIRO_S13` 4-cyl, `SHINOBI_RS` 6-cyl) but never verified to track revs or fire per event. |
| Roads terrible | **CONFIRMED** | Renders as blue/orange glitter — specular aliasing, not tarmac. |
| No minimap | **CONFIRMED** | Does not exist. |
| No marked-out circuit | **CONFIRMED** | Route exists internally (`Gordon Street Sprint`, 1454 m) but is not visible in-game. |
| Palms bad | **CONFIRMED** | Brown poles, two green blades. |
| Buildings bad | **CONFIRMED** | Flat untextured slabs, blown-out white windows. |
| Car textures untracked | **CONFIRMED** | `.gitignore:14-16` excludes `assets/cars/*.png` (176 MB), so a clean-clone export ships untextured cars. 147 textures on disk, 0 tracked. |
| Car fit scales garbage | **CONFIRMED** | Spread of 16,000x (`silvia_s15` 0.0059 vs `evo_v` 99.5) — same broken axis assumption. |

## Owners

- **w1** car orientation (180 deg) — root cause blocks all other car work
- **w2** AI follows the road graph
- **w3** road surface + building facades
- **w4** palms
- **w5** wheel spin visuals + acceleration (not `car_body.gd` — w9 owns that)
- **w6** audio, proving each sound fires
- **w7** minimap + marked-out circuit
- **w8** guard test so `run_tests.gd` cannot be downgraded again
- **w9** drift feel (owns `Systems/vehicle/car_body.gd` exclusively)
- **w10** car fit scales, texture tracking, roster decision

## Traps that have cost real time

- **`agent/facades` is poisoned.** It carries a stale rebase that deletes the
  `run_tests.gd` self-check and reverts `await t.attach(self)`. It also edits
  `project.godot`, `windows/manifest.json` and deletes the map PNG. It is on the
  watchdog denylist. The clean rebuild is `facades-clean`, which keeps only
  `World/osm_buildings.gd`, `World/world_builder.gd`, `World/mat_lib.gd`,
  `Tools/frame_stats.gd`, `Tests/test_integration.gd`.
- **Never `pkill -f "bash ./watchdog.sh"`** from a shell whose command line
  contains that string — it kills the shell. This killed the watchdog twice.
- **Stale `.godot/global_script_class_cache.cfg`** after a merge that adds a
  `class_name` phantom-fails every identifier. Regenerate after merging, or the
  suite reports a dozen unrelated failures. On the renderbox the rescan must use
  `$HOME/godot`, not `/home/coder/tools/godot`.
- **`rsync` is not installed on the renderbox.** Use tar-over-ssh or scp.
- **grep piped to `head` truncates.** It produced a wrong "world_builder is dead"
  conclusion earlier. Check for truncation before repeating a claim.
- **Exports are not byte-reproducible** (two runs differed by 16 B). Bump
  `config/version` BEFORE exporting, or the manifest digest will not match.

## What is shipped

- v0.2.0 published: https://github.com/maxta85/test-game/releases/tag/v0.2.0
  `CairnsAfterDark.exe` 212,369,616 B, digest pinned, launcher verified
  152/0 anonymously. **The player reports this build is unplayable** — treat it as
  a broken baseline, not a milestone.
- Real Manunda: 247 corridors, 359 junctions, 401 edges, 31,694 m, 2198 OSM
  footprints (2190 clear, 0 dropped), artkit filling gaps with 661 buildings and
  414 props. Network is 100% connected, 0 dead-end stubs (verified at 4 m
  tolerance).
- Map plot at `docs/manunda-road-network.png`, regenerated by `Tools/plot_map.py`.

## Do not

- Do not let a worker touch `Tests/run_tests.gd`, `project.godot`, `windows/` or
  `docs/` — say so in the brief; it has to be repeated.
- Do not ship a release until a playtest frame proves driving direction, wheel
  spin and AI are right.
- Do not show the user art as "improved" without rendering it and looking.