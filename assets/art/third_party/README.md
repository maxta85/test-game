# Third-party assets

Everything in this directory is downloaded by `ingest.py`, recorded in
`inventory.json`, and licensed CC0 1.0 via [Poly Haven](https://polyhaven.com).

```sh
python3 assets/art/third_party/ingest.py             # fetch, write inventory
python3 assets/art/third_party/ingest.py --verify    # check the tree, offline
python3 assets/art/third_party/albedo_stats.py > albedo_stats.json
```

`--verify` is the authority on "are these assets licensed". It exits nonzero if
any asset on disk is unclaimed, any claimed file is missing or altered, or any
row's licence is unaccepted, non-redistributable or unsourced.

## Files

| Path | What |
|---|---|
| `ingest.py` | fetch + hash-verify + write `inventory.json`; `--verify` checks the tree |
| `inventory.json` | machine-readable provenance for all 22 assets (**the record**) |
| `albedo_stats.py` | measures each albedo map's luma percentiles |
| `albedo_stats.json` | those measurements, consumed by `ArtKitLicensing.albedo_mean()` |
| `LICENSE-CC0-1.0.txt` | full CC0 legal code, shipped not linked |
| `textures/<set>/` | 7 sets x 3 maps (albedo, normal, roughness) at 1k |
| `hdri/` | 1 sky HDRI |
| `capture_hoare.sh` | before/after Hoare Street GPU frames |
| `shot_kit.sh` | before/after prop contact sheet |

## Why `ingest.py` asserts the licence against the *provider*, not the asset

The first version called `GET /info/<id>` and required a `CC0` field. Every
asset failed, with `aerial_grass_rock: provider does not declare CC0`.

The API has **no per-asset licence field.** `/info/<id>` returns name, tags,
authors, categories, coordinates and dimensions — nothing about terms. That is a
schema mismatch, not a licence failure, and failing closed on correct assets is
the worst failure direction for an ingest tool because it looks like a licence
problem.

Poly Haven licenses its entire library CC0 in one statement. So the ingest
verifies *that* — the live licence page must still say CC0, the API must still
serve the asset types, and the asset must be a member of the library — and
records per asset that the claim's scope is the provider. If Poly Haven ever adds
a non-CC0 asset, this cannot detect it on its own; there is no field to detect it
from. That ceiling is recorded in the inventory
(`per_asset_license_field_available: false`) rather than papered over, because a
licence claim that sounds stronger than its evidence is worse than one that
admits its own limit.

## Low-poly geometry: what was assessed and why nothing was taken

The brief asked for "low-poly palms/trees/scrub and useful street furniture
where a clean source exists". The honest finding is that **no clean source beat
what the kit already generates**, so all geometry stayed procedural and only
surfaces were replaced.

`artkit/props.gd` generates 24 props — 7 palms, 3 melaleuca, scrub, street
furniture (bollards, benches, bins, poles, hydrant, cabinets) — as code, and
`artkit/artkit_check.gd` checks all of them: distinct facet counts per frond,
crown gaps, ground contact, no NaN, one material per part, 600 placements
collapsing to 24 draw calls.

Against that:

- **Poly Haven models are CC0 but low-poly in the *wrong* direction.** They are
  scanned/reconstructed real-world assets. Swapping them in would replace a
  stylistic, budgeted, single-material-per-part prop set with high-poly meshes
  that break the draw-call budget and the palette contract, in exchange for
  photogrammetry the night look does not want.
- **Mixing sources produces a worse result than either alone.** Procedural
  geometry and imported geometry differ in scale, origin, pivot convention and
  UV space. A street with three imported benches among 200 procedural ones reads
  as an error, not as detail.
- **The gain was in surfaces, and it was taken.** A licensed photograph of
  asphalt has aggregate, chipping and patching that `FastNoiseLite` cannot
  produce at any seed. That is what a hero surface needs.

The trade is reversible: if a specific CC0 prop is wanted later, it enters
through `ingest.py`, gets an inventory row, and the procedural generator stays
as the fallback — which is the same contract the texture layer already follows.

## UV space: the bug that made the textures invisible

Worth writing down because it cost the most time and the symptom pointed the
wrong way.

`artkit/materials.gd` has two UV conventions and they are **not** the same:

- a spec's `uv` is metres-per-tile for **triplanar world-space** sampling —
  `0.0625` means one 16 m tile, because the shader samples from world position;
- the prop meshes carry **per-object normalised UVs**, measured at a span of
  ~1.0 unit across a 13 m palm trunk and ~0.25 around its circumference.

Reusing `uv` for the licensed captures magnified each capture to about one
sixteenth of a tile over the whole trunk. The result was a flat grey gradient,
and the measured frame difference was 0.58% — a number that reads as "the
texture did nothing", which is exactly what it looked like, and would have
prompted deleting a working texture.

`TEX_UV` in `artkit/materials.gd` now carries metres-per-tile per material, in
the unit a photographic capture is authored in. A 1k asphalt scan is a 2 m
square of real road, not a 16 m one.

## The value normalisation

Photographs carry their own mean luminance. `albedo_stats.py` measures it and
`ArtKitLicensing` divides each albedo by its own mean, so the texture supplies
*detail* and `ArtKitPalette` keeps supplying *value* — which is what
`ART_DIRECTION.md` requires (neighbouring surfaces differ in a chosen value, not
in whatever a photograph happened to average).

Measured means, and why they are all different problems:

| Set | mean luma | p05–p95 spread |
|---|---|---|
| `asphalt_01` | 81/255 | 0.082 |
| `palm_bark` | 79/255 | 0.118 |
| `red_brick` | 110/255 | 0.146 |
| `concrete_floor` | 138/255 | 0.152 |
| `painted_plaster_wall` | 164/255 | 0.086 |
| `aerial_grass_rock` | 96/255 | 0.164 |

`asphalt_01` has the narrowest spread (0.082) of the seven. A road that looks
flat is *correct* for asphalt — but it is why the wet/dry roughness ramp, not the
albedo, does the work of making the hero surface read.

## Provenance

`inventory.json` is the record. See `../../CREDITS.md` and `../../LICENSES.md`.