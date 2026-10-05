# Credits

Third-party assets used by this project. **Every entry here is also recorded
machine-readably in `assets/art/third_party/inventory.json`**, with its source
URL, SHA-256 and licence. That file is the authority; this document is the
human-readable view of the same facts.

Verify at any time:

```sh
python3 assets/art/third_party/ingest.py --verify
```

That command exits nonzero if any asset on disk is missing from the inventory,
if any inventoried file has been altered, if any row's licence is absent from
`ArtKitLicensing.ACCEPTED` or does not permit redistribution, or if any row has no
fetchable source URL. It is also run inside the acceptance suite
(`artkit/artkit_check.gd`, section "licensed assets"), so an unlicensed asset
fails `./test.sh`.

## Poly Haven

All texture sets and the sky HDRI below come from
[Poly Haven](https://polyhaven.com), which publishes its entire library under
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/) —
public domain, no attribution required, commercial use permitted. The full
licence text ships at `assets/art/third_party/LICENSE-CC0-1.0.txt`.

CC0 does not require attribution, so the list below is a courtesy rather than an
obligation. It is kept because "we reused someone's photograph and did not say
who" is the kind of debt that gets discovered later and is much more expensive
to have never incurred.

Poly Haven states its licence once, site-wide, at
<https://polyhaven.com/license>. Its API exposes **no per-asset licence field** —
`GET /info/<id>` returns name, tags, authors and categories and nothing about
terms. `ingest.py` therefore verifies the site-wide declaration against the live
page and records, per asset, that the claim's scope is the provider rather than
the asset. The inventory says so explicitly
(`declaration_scope: "provider-wide"`, `per_asset_license_field_available: false`)
rather than implying a per-asset guarantee the API cannot provide.

### Surface texture sets

| Set | Used by | Asset page | Authors |
|---|---|---|---|
| `asphalt_01` | road surface (wet + dry) | [asphalt_01](https://polyhaven.com/a/asphalt_01) | Dario Barresi (processing), Charlotte Baglioni (photography) |
| `concrete_floor` | footpath, kerb | [concrete_floor](https://polyhaven.com/a/concrete_floor) | see inventory |
| `concrete_layers` | drainage channel, older kerb | [concrete_layers](https://polyhaven.com/a/concrete_layers) | see inventory |
| `painted_plaster_wall` | rendered walls (6 palette variants) | [painted_plaster_wall](https://polyhaven.com/a/painted_plaster_wall) | see inventory |
| `red_brick` | brick masonry | [red_brick](https://polyhaven.com/a/red_brick) | see inventory |
| `palm_bark` | palm and melaleuca bark (7 species) | [palm_bark](https://polyhaven.com/a/palm_bark) | see inventory |
| `aerial_grass_rock` | verge, dirt | [aerial_grass_rock](https://polyhaven.com/a/aerial_grass_rock) | Rob Tuytel |

Each set supplies three maps at 1k: albedo (`*_diff.jpg`), OpenGL-convention
normal (`*_nor_gl.png`) and roughness (`*_rough.jpg`). Normal maps are PNG
because 8-bit JPEG chroma subsampling visibly bends a normal map; the other two
are JPEG because the renderer reads 8 bits anyway and that is a third of the
bytes.

### Sky

| Set | Used by | Asset page | Author |
|---|---|---|---|
| `dikhololo_sunset_1k` | ambient/IBL source for the daylight world | [dikhololo_sunset](https://polyhaven.com/a/dikhololo_sunset) | Greg Zaal |

Cairns is at 16.9°S and Dikhololo is at 25.4°S, so it is the closest CC0 sky on
Poly Haven with palms on the horizon and a low sun — the honest reuse rather
than a generic blue dome.

**It is not used as a visible sky dome in the night frame.** `World/night_env.gd`
deliberately uses a `ProceduralSkyMaterial`: the look is a humid 1am tropical
night lit from below by city glow, which is a *designed* sky and not something a
sunset photograph should replace. The HDRI is ingested, inventoried and
available through `ArtKitLicensing.hdri()` as an IBL source for the daytime
world, and this entry says where it is and is not applied. Verifying that its
bytes are a true radiance map (luma 0.017–9.83, above 1.0) is one line of
`artkit/tex_probe.gd`-adjacent tooling; it is not wired into the night scene.

## Models

**None.** Every piece of geometry in this project — palms, melaleuca, scrub,
buildings, street furniture, bollards, benches, bins — is generated in code by
`artkit/props.gd` and `artkit/buildings.gd`. The brief asked for low-poly palms,
trees, scrub and street furniture "where a clean source exists"; the honest
finding is that no clean source beat what the kit already generates, so the
geometry stayed procedural and only the *surfaces* were replaced. Reasoning and
measurements are in `assets/art/third_party/README.md`.

## What this file is checked against

`artkit/artkit_check.gd` runs four licensing checks on every `./test.sh`:

1. every inventoried asset carries an accepted, redistributable licence with a
   source URL;
2. no asset file on disk is missing from the inventory;
3. the unclaimed-file walk actually reached asset files (a witness — see
   `artkit/licensing.gd` for why a crashed walk would otherwise pass);
4. `artkit/` loads assets only through `ArtKitLicensing`, so every load is
   inventoried by construction rather than by review.

and one on the layer itself:

5. at least one licensed texture actually reached a material
   (`TEXTURES_APPLIED >= 1`), so a download that succeeded but a wiring that did
   not cannot pass.