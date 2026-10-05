# Licences

Machine-readable counterpart to `CREDITS.md`. This file is short on purpose:
the per-asset facts live in `assets/art/third_party/inventory.json`, which is
generated from `assets/art/third_party/ingest.py` and is the authoritative
record. Writing them out a second time here would create a second copy that
drifts.

## Accepted licences

Only one, defined in `ArtKitLicensing.ACCEPTED` in `artkit/licensing.gd`:

| SPDX | Name | Redistributable | Attribution required |
|---|---|---|---|
| `CC0-1.0` | Creative Commons CC0 1.0 Universal | yes | no |

An asset whose licence is **not** in this table is reported as unlicensed. That
default is deliberate: a permissive-by-default list is how "unlicensed" becomes
a state a build can be in.

## The licence text

`assets/art/third_party/LICENSE-CC0-1.0.txt` — the full Creative Commons CC0 1.0
Universal legal code, shipped in the repository rather than merely linked, so a
checkout with no network still contains the terms the bytes are under.

Poly Haven licenses its whole library CC0 site-wide at
<https://polyhaven.com/license>. Its API has no per-asset licence field, so the
ingest verifies that site-wide statement against the live page and records the
scope honestly per asset. This is a real limitation of the evidence, not a
formality, and the inventory states it in both spellings:
`declaration_scope: "provider-wide"` and `per_asset_license_field_available: false`.

## Provenance guarantees

Each of the 22 inventoried assets carries, in the inventory:

- `path` — location relative to `assets/art/third_party/`
- `sha256` — the SHA-256 the file must hash to
- `md5` — the MD5 Poly Haven published, used to verify the download in transit
- `bytes` — exact file size
- `source.file_url` — the exact URL the bytes came from
- `source.asset_page` — the human-facing page for that asset
- `source.authors` — the photographers/processors credited by the provider
- `license` — SPDX id, URL, declaration scope, and the shipped text file

Two independent directions are checked:

```sh
python3 assets/art/third_party/ingest.py --verify   # offline, no network
```

- **inventory → disk**: every claimed file exists and still hashes to its
  recorded SHA-256. An altered byte fails.
- **disk → inventory**: every image, model, audio or radiance file under
  `assets/art/third_party/` is claimed by an entry. A hand-dropped `.jpg` fails.

Plus a licence check on every row: the SPDX id must be accepted, must permit
redistribution, must name an https licence URL, and the row must carry a
fetchable source URL.

## What is not licensed, and is not third-party

No model files. No audio. No fonts. All geometry is generated in code by
`artkit/props.gd` and `artkit/buildings.gd`; all other audio in the project is
either synthesised at runtime or covered by the audio service's own attribution
records. The inventory covers exactly the 22 files it lists and
`artkit/artkit_check.gd` fails if that stops being true in either direction.

## Derived data

Two files in `assets/art/third_party/` are produced by our tooling rather than
downloaded, and both are excluded from the asset walk because they are code and
measurements, not assets:

- `albedo_stats.json` — mean and percentile luma of each ingested albedo map,
  written by `albedo_stats.py`. The runtime divides each albedo by its own mean
  so the texture supplies detail and `ArtKitPalette` keeps supplying value.
- `inventory.json` — the record itself.

**The albedo normalisation happens in the engine, not in the repository.** The
bytes on disk are the provider's bytes, so `--verify` keeps meaning something
about provenance instead of about our own post-processing.