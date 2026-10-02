# Decision: car textures ship fine; the real bug was a fit transform measured with identity

Date: 2026-09-30
Status: accepted (`agent/car-assets`)

## Context

A player reported the car rendering as an untextured orange box. The obvious
hypothesis was a broken asset pipeline: `.gitignore` excludes
`assets/cars/*.png`, `*.jpg` and `*.jpeg`, and `git ls-files` confirms not one
PNG is tracked. A 35 MB "just commit the textures" fix looks obvious and is
wrong.

## What was checked

| Claim | Method | Result |
| --- | --- | --- |
| Textures are missing from git | `git ls-files assets/cars/*.png` | 0 tracked — but see below |
| Textures are missing from the build | parsed the `.pck` file table in `build/CairnsAfterDark.exe` at offset 84214784 | **150 car `.ctex` (45.1 MB) + 7 imported `.scn` (77.5 MB) are packed** |
| Textures are missing from a clean clone | fresh `git clone` → `godot --headless --import` | 0 PNG before, **147 PNG + 150 `.ctex` regenerated** |
| The glbs reference external files | parsed each GLB's JSON chunk | 6 of 7 **embed** their images (evo_v 17, s13 12, s15 16, supra_mk4 10, vt_commodore 3, wrx_gc8 92; `au_falcon` 0) |

**The 147 PNGs are Godot import *output*, not source.** `godot --headless
--import` re-extracts each glTF's embedded images and writes them next to the
`.glb`. They are regenerated on every clone, on the render box, and at export.
The `.gitignore` comment on those lines is correct and must not be "fixed".
Committing them would add 35 MB of machine-generated duplicates to the repo.

Rendered proof (`carhero`, `carfront` presets): a fully textured white S13 with
a `SILVIA` badge, plate `46-49`, and red/amber tail lenses.

## Decision

Do not change the asset pipeline. It is not broken.

But the investigation turned up a **separate, worse bug**: `Tools/fit_cars.gd`
measured every model with an identity transform, so `assets/cars/fit.gd` put
three of the five mapped cars somewhere they could not be seen.

## The fit bug

`Tools/fit_cars.gd` builds the scene with `GLTFDocument.generate_scene()` and
then reads `mi.global_transform` to get each mesh's placement. The generated
scene is never added to the tree, so `global_transform` returns **IDENTITY** for
every mesh and Godot logs `Condition "!is_inside_tree()" is true` once per mesh
— 940 times, silently swallowed. The walk therefore measured each mesh's raw
local AABB and ignored the entire glTF node graph, which is where the scale and
translation actually live.

Verified by walking the same node graph independently in Python and comparing
against what the fitter stored:

| model | true node-world size | old scale | rendered as |
| --- | --- | --- | --- |
| `evo_v` | 0.019 x 0.014 x 0.043 m | 0.995 | a 4 cm speck |
| `supra_mk4` | 2.013 x 1.428 x 4.547 m | 0.010 | a 2 cm speck |
| `wrx_gc8` | size right, centre (-15.3, 2.7, -12.4) | 0.252 | 3.1 m underground |
| `silvia_s13`, `silvia_s15` | unchanged | — | correct |

`usable` did not catch it: the flag tested `textured > 0`, and all three broken
cars were fully textured. They were correctly flagged, correctly imported, and
completely invisible.

Two fixes in `Tools/fit_cars.gd`:

1. Thread the parent transform down the walk instead of reading
   `global_transform`, so it works on a scene that is not in the tree.
2. Gate `usable` on measured car-sizedness (1.0–2.6 m wide, 0.9–2.2 m tall,
   3.0–6.0 m long), so a mis-measured model falls back to the procedural box
   instead of vanishing.

The `z_up`/`length_axis` entries for `supra_mk4`, `wrx_gc8` and `vt_commodore`
were tuned against the broken numbers and had to be corrected to
`z_up: false, length_axis: "z"` — the node graph already performs the Z-up
conversion, so the extra rotation was doubling up.

All 7 models now measure as real cars (1.1–2.0 m wide, 1.3–2.0 m tall,
4.3–4.9 m long). Rendered on an RTX 3060, all five mapped models appear with
correct textures, at the right scale, sitting on the ground.

## So what did the player see?

Two different things, and they were conflated:

- The **untextured orange box** is `kairo_mx90` or `kaze_type_r`. They have no
  matching glb in the downloaded set, so they deliberately keep the procedural
  box body — the comment at `car_visual.gd:37` says so explicitly, because a
  correctly sized box beats the wrong car. Under the project's amber street
  lighting, `faded_white` / `storm_white` on an untextured box reads as an
  orange crate.
- The **missing cars** were `shinobi_rs`, `tatsuya_gt` and `hayate_turbo` —
  three of the seven roster cars rendered as nothing at all. That was the fit
  bug above, and it is now fixed.

## Consequences

- **The roster is already JDM-correct.** All 7 playable cars are JDM (MX-5,
  AE86, S13, GC8, S15, A80, CP9A). Nothing in `CarDB` needed cutting.
- **Two off-brief assets were cut**: `au_falcon.glb` (48 MB) and
  `vt_commodore.glb` (2.7 MB). Neither is referenced by any `CarDB` id, and a
  JDM drift game set in Manunda has no use for a Ford Falcon or a Holden
  Commodore. They are *not* kept as unlockable rares: making them playable
  would mean new `CarSpec` entries (mass, gearing, price), a `MODELS` entry and
  unlock logic, which is speculative feature work with no design behind it.
  `au_falcon` was dead weight regardless — zero textures across 1,026,571 verts,
  and the largest asset in the repo. Both are recoverable in one command:
  `git checkout <rev> -- assets/cars/<name>.glb`.
- **`burnt_orange` in `PAINTS` (`car_visual.gd:30`)** is defined but referenced
  by no car. Harmless.
- Making the two box cars textured is **art sourcing, not code**.

## The gitignored PNGs are correct, and proven so

`assets/cars/*.png` is 35 MB (not 176 MB) and is the right thing to leave out.
The claim that a clean-clone export would ship untextured cars is false —
verified, not assumed:

```
git clone <repo> /tmp/clean-export   # 0 *.png, 0 *.ctex, no .godot at all
godot --headless --export-release "Windows Desktop" build/CleanTest.exe
```

Godot's export runs the import pass itself (the log shows `import: end` /
`reimport: end` before `savepack`). Parsing the resulting `.pck` file table:

| in the pack | count | size |
| --- | --- | --- |
| car `.ctex` | 150 | 45.1 MB |
| car `.scn` | 8 | 77.5 MB |
| raw `.png` / `.glb` | 0 / 0 | — |

Every model ships textures except `au_falcon`, which has none to ship — the
reason it is now cut. The 147 PNGs are the importer's intermediate, written
next to the `.glb` and recompiled to `.ctex`; committing them would add 35 MB
of machine-generated duplicates that a clean checkout regenerates anyway. So:
**generated at build time**, which is the third option and the one already in
place. No LFS, no committed binaries.

## One bug found on the way

`Systems/garage/garage.gd` carried a second copy of the car→glb mapping
(`MODEL_STEMS`) that disagreed with `CarVisual.MODELS` about two cars, so the
garage screen labelled a car `GLTF: EVO_V` while a Silvia S15 rendered. The
duplicate is deleted; `Garage.model_path()` reads `CarVisual.MODELS`. Same
failure mode as the fit bug — one fact written down twice, and the copies drift.


## Reusable method

1. Parse the GLB JSON chunk — embedded images vs external URIs.
2. Parse the `.pck` file table — count `.godot/imported/*.ctex`.
3. Delete the artifacts and re-import. If they come back, they were never source.
4. When a Godot tool reads `global_transform`, check it is actually in the tree.
   `!is_inside_tree()` returning IDENTITY is silent and wrong.

Repo state alone cannot answer "is it in the build". A Godot build contains
imported `.scn`/`.ctex` only — never the raw `.glb` or the extracted `.png`.

A stale `.godot` import cache also produces fake failures: a worktree checked
out from an older branch cannot resolve `class_name`s that the current branch
adds, and every reachability check then fails on a parse error. Run
`godot --headless --import` before trusting a suite result.
