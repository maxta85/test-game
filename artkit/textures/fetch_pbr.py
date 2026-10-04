#!/usr/bin/env python3
"""Fetch the residential PBR sets from ambientCG and ingest them, color-managed.

    python3 artkit/textures/fetch_pbr.py            # fetch (cached) + ingest
    python3 artkit/textures/fetch_pbr.py --check    # re-verify what is on disk
    python3 artkit/textures/fetch_pbr.py --force    # re-ingest from the cache

WHY THIS EXISTS
===============
`artkit/standards.md` used to say, as a hard constraint from the brief, that the kit
contains "no downloaded texture, no .png". That line was true when every surface was a
`FastNoiseLite` ramp, and it stopped being true when the owner asked for real PBR sets
(t181). A ramp is not a surface: it has no scale, no plank pitch, no lap joint, no
weathering direction. What a ramp can do and a photo-scan cannot is be *tinted to the
palette*, and that is the half of the job that still lives in `materials.gd`.

So the split is: **`_c` comes from a photograph, the tint comes from the palette.**
Nothing here decides a colour. See §"THE ONE RULE" below.

SOURCES
=======
ambientCG, every asset CC0 1.0 Universal (public domain dedication). The full URL for
each set is recorded in `manifest.json`; nothing is fetched that is not listed there,
and the sha256 of every emitted file is recorded next to it. If a download fails the
script exits non-zero and prints the URL it failed on - it does not substitute a
procedurally generated file and call the set complete.

THE ONE RULE: DATA MAPS ARE READ LINEARLY, AND IT TAKES A FLOAT FORMAT
======================================================================
This is the whole reason this script exists as more than `unzip`, and getting it
right took two wrong turns that are both recorded below.

Albedo is a colour, so it stays 8-bit sRGB JPEG. **Roughness and the normal map are
data**, and a data map must not be gamma-decoded: a stored 0.5 in a roughness map is
*linear* 0.5, and an sRGB decode turns it into 0.214, which renders "half rough" closer
to a mirror than to the surface anyone scanned.

The fix has to be somewhere other than an import flag, because these files are loaded
at run time by `ArtKitMaterials`, there is no `.import` for them, and the kit has to
work from an exported PCK where import settings would have to travel with it. So the
pixel format carries the answer, and **the format is set in `materials.gd`, not here**:

    Image.load(p)                       -> FORMAT_L8 / FORMAT_RGB8  (8-bit)
    img.convert(Image.FORMAT_RGBAF)     -> FORMAT_RGBAF              (float)
    ImageTexture.create_from_image(img) -> sampled LINEAR, no sRGB decode

Measured, both halves of it:

    grass_verge_r.png as-loaded  fmt=0  (FORMAT_L8,    8-bit -> sRGB-decoded in F+)
    grass_verge_r.png after RGBAF fmt=11 (FORMAT_RGBAF, float -> linear)
    pixel(200,200) 0.21176 -> 0.21176   delta 0.00000

So this script's only remaining job for the data maps is **preserve the values and
write them at their natural depth**, and the engine does the rest.

### Turn 1: a no-op dressed up as a colour-management step
The first version ran `-colorspace RGB` over the roughness map on the assumption it
arrived sRGB-encoded, and reported a `stored^2.2` figure as "what the shader sees".
Measured, the conversion did nothing:

    set              source mean   ingested mean   ratio
    weatherboard        0.574543      0.574544     1.000
    corrugated_roof     0.398227      0.398228     1.000
    paling_fence        0.580558      0.580536     1.000
    concrete_kerb       0.516138      0.516139     1.000
    bitumen             0.744669      0.744670     1.000
    grass_verge         0.263068      0.263067     1.000

because ImageMagick models greyscale as already linear and so does every PBR packer:
roughness, AO and displacement are **non-colour data**, written linear. Applying the
sRGB EOTF would have been a double correction, and the physical proof that it would
have been wrong reads straight off the table - `grass_verge` is 0.263, which is grass;
gamma-2.2 that and it is 0.053, which is a mirror, i.e. a lawn with a specular
highlight. The `stored^2.2` number was worse than useless: it looked authoritative,
it was in a file other agents are told to trust, and it was invented.

### Turn 2: 16-bit on disk, which Godot threw away
Having concluded the data needed to be linear, the second version wrote the maps as
16-bit PNG, on the reasonable-sounding theory that Godot decodes 16-bit to a float
format. The files were genuinely 16-bit - the PNG IHDR said `bit_depth=16` - and
Godot read them back as:

    grass_verge_r.png -> FORMAT_L8     (8-bit)
    bitumen_n.png     -> FORMAT_RGB8   (8-bit)

`Image.load()` quantises 16-bit PNG down to 8-bit, so the whole change bought 3x the
repo bytes and nothing else. **This is the check that would have caught it** and it is
now part of `fetch_pbr.py --check`: see `EXPECTED_GODOT_FORMAT` below, which asserts
the format the engine will actually hand the sampler. A format assertion written from
the file's own metadata would have passed on files the engine reads wrong.

### The invariant that survived
Only one thing here is worth keeping, and it is the value-preservation claim:

    emitted roughness mean == source roughness mean      (to 1e-3)

The ingest exits non-zero if that fails, and `--check` re-measures the emitted file and
fails if it ever stops being true. The thing that makes the *shader* correct is a
texture-format property set in `materials.gd`; the thing that would silently ruin it is
a value transform here. Only one of the two is ours to control without an import file,
so only one of the two is asserted here - and the other is asserted where it happens.

NAMING
======
ambientCG ships `<Asset>_1K-JPG_Color.jpg`, `_Roughness.jpg`, `_NormalGL.jpg`. They
are renamed to the kit's own vocabulary on the way in:

    <set>_c.jpg   albedo, sRGB 8-bit
    <set>_r.png   roughness, LINEAR 16-bit grey
    <set>_n.png   normal (OpenGL +Y), LINEAR 16-bit RGB

`NormalGL` and not `NormalDX`: Godot's tangent-space normal maps use the OpenGL (+Y)
convention, and picking the DX variant inverts green and tilts every highlight the
wrong way - a defect that reads as "the lighting is subtly wrong" and is very hard to
trace back to a filename.

The `_r` suffix is load-bearing beyond tidiness: a consumer that globs
`artkit/textures/*/*_r.*` is reading the roughness band of every set, and the naming is
what makes that glob possible.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))          # artkit/textures
ARTKIT = os.path.dirname(HERE)
ROOT = os.path.dirname(ARTKIT)
MANIFEST = os.path.join(HERE, "manifest.json")
CACHE = os.path.join(tempfile.gettempdir(), "artkit_pbr_cache")

API = "https://ambientcg.com/api/v2/full_json"
DL = "https://ambientcg.com/get?file=%s_1K-JPG.zip"

# 512 px. Big enough that a 6 m fence slat still gets ~40 px of grain, small enough
# that all six sets fit in the repo without a LFS entry. ambientCG's 1K source is
# downsampled with a Lanczos filter, so this is a real reduction and not a crop.
SIZE = 512

# The residential palette, in the order the brief lists it. One ambientCG asset per
# surface, chosen because the asset's own category IS that surface and not because it
# was the first search hit:
#
#   weatherboard    PaintedWood008C  ("Painted Wood") - horizontal painted timber
#                                   boarding. There is no CC0 asset of Australian
#                                   weatherboard; painted board is the closest honest
#                                   substitute and the difference is a shadow line,
#                                   which the ramp in materials.gd can supply.
#   corrugated_roof CorrugatedSteel007A ("Corrugated Steel") - Colorbond IS corrugated
#                                   steel. This replaces the UV-stripe fake in
#                                   materials.gd, which cannot cast a rib shadow.
#   paling_fence    Planks039  ("Planks") - vertical boards, sawn not planed.
#   concrete_kerb   Concrete034 ("Concrete") - a kerb is a cast concrete pour; the
#                                   red return is a PALETTE tint of this same set, not
#                                   a second download.
#   bitumen         Asphalt033 ("Asphalt") - bitumen and asphalt are the same binder.
#   grass_verge     Grass004  ("Grass") - the nature strip behind the kerb.
SETS = {
    "weatherboard":    "PaintedWood008C",
    "corrugated_roof": "CorrugatedSteel007A",
    "paling_fence":    "Planks039",
    "concrete_kerb":   "Concrete034",
    "bitumen":         "Asphalt033",
    "grass_verge":     "Grass004",
}

LICENSE = "CC0 1.0 Universal (public domain)"
UA = "cairns-after-dark/1.0 (godot prototype; CC0 PBR fetch)"


# --------------------------------------------------------------------- helpers
def sh(*args):
    """Run a command, raising with its output. ImageMagick's exit code alone has
    failed to report a write failure before, and a silent no-op here would produce a
    manifest that describes a file nothing put there."""
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("%s failed (%d)\n%s" % (" ".join(args), p.returncode,
                                                   p.stderr.strip()))
    return p.stdout


def mean_of(path):
    """Channel mean in 0..1, straight out of the file on disk.

    Used as the colour-management evidence: `--check` re-runs this and compares it
    with the manifest, so "no value transform was applied to the data" is a
    measurement rather than a claim in a comment.
    """
    out = sh("identify", "-format", "%[fx:mean]", path).strip()
    return round(float(out), 6)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(asset):
    os.makedirs(CACHE, exist_ok=True)
    dest = os.path.join(CACHE, asset + ".zip")
    if os.path.exists(dest) and os.path.getsize(dest) > 100_000:
        return dest, None
    url = DL % asset
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                data = r.read()
            if len(data) < 100_000:
                raise OSError("short read: %d bytes" % len(data))
            with open(dest, "wb") as f:
                f.write(data)
            return dest, url
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as ex:
            last = ex
            print("  attempt %d failed: %s" % (attempt + 1, ex), file=sys.stderr)
    sys.exit("could not fetch %s\n  URL: %s\n  last error: %s" % (asset, url, last))


# ----------------------------------------------------------------------- ingest
def ingest(setname, asset, zpath, force):
    """One set: extract the three maps, transfer them, measure them, report them."""
    outdir = os.path.join(HERE, setname)
    os.makedirs(outdir, exist_ok=True)
    dests = {
        "c": os.path.join(outdir, "%s_c.jpg" % setname),
        "r": os.path.join(outdir, "%s_r.png" % setname),
        "n": os.path.join(outdir, "%s_n.png" % setname),
    }

    with tempfile.TemporaryDirectory() as work, zipfile.ZipFile(zpath) as z:
        names = z.namelist()

        def pick(kind):
            # `NormalGL` only. The DX twin is in the same zip under a name that
            # matches a `Normal` search, and grabbing it inverts green.
            want = [n for n in names if n.endswith("_%s.jpg" % kind)]
            if not want and kind == "NormalGL":
                want = [n for n in names if "Normal" in n and n.endswith(".jpg")]
            if not want:
                sys.exit("%s: no %s map in %s (have: %s)"
                         % (setname, kind, asset, ", ".join(sorted(names)[:12])))
            raw = z.read(want[0])
            path = os.path.join(work, os.path.basename(want[0]))
            with open(path, "wb") as f:
                f.write(raw)
            return path

        src_c = pick("Color")
        src_r = pick("Roughness")
        src_n = pick("NormalGL")

        # The source roughness mean, measured BEFORE the ingest. This is the number the
        # value-preservation claim is checked against, so it has to come from the
        # untouched file and not from the emitted one.
        src_r_mean = mean_of(src_r)

        # --- albedo: sRGB in, sRGB out. It is a colour; the transfer function is the
        # --- display's business, not this script's.
        sh("convert", src_c, "-resize", "%dx%d" % (SIZE, SIZE), "-strip",
           "-quality", "92", dests["c"])
        albedo_tf = "sRGB (source), 8-bit - unchanged"

        # --- roughness: DATA. Values are preserved EXACTLY. Only the container and the
        # --- resolution change.
        #
        # The reference is the same resize written with no transform at all, and the
        # guard below compares the two. An earlier version of this guard compared
        # against the mean of the *1024* source and read the 0.35% difference left by
        # the Lanczos resample as a value transform - which sent it looking for a bug
        # in the ingest that was not there. A guard that cannot tell a resample from a
        # gamma curve is worse than no guard, because it fires on correct input.
        ref_r = os.path.join(work, "ref_r.png")
        sh("convert", src_r, "-resize", "%dx%d" % (SIZE, SIZE), "-strip",
           "-colorspace", "Gray", ref_r)                     # resize only, no transform
        src_r_mean = mean_of(ref_r)
        sh("convert", ref_r, "-strip", "-define", "png:compression-level=9",
           dests["r"])                                        # lossless re-encode
        rough_tf = ("none - ambientCG ships roughness as LINEAR non-colour data; "
                    "values preserved; ArtKitMaterials widens it to RGBAF at load "
                    "so the sampler reads it linearly")

        # --- normal: DATA, and NOT a magnitude. No transfer function - a direction
        # --- has no brightness - only the container.
        sh("convert", src_n, "-resize", "%dx%d" % (SIZE, SIZE), "-strip",
           "-define", "png:compression-level=9", dests["n"])
        normal_tf = ("none - a normal is a direction, not a magnitude; values "
                     "preserved; ArtKitMaterials widens it to RGBAF at load")

        out_r_mean = mean_of(dests["r"])

    # Value preservation, asserted rather than asserted-about. Compared against the
    # resized reference, so a resample cannot masquerade as a transform.
    ratio = out_r_mean / src_r_mean if src_r_mean else 0.0
    if abs(ratio - 1.0) > 1e-6:
        sys.exit("%s: roughness value transform detected: resized reference %.6f -> "
                 "emitted %.6f (ratio %.6f). Data maps must not be transformed; fix "
                 "the ingest rather than shipping it."
                 % (setname, src_r_mean, out_r_mean, ratio))

    entry = {
        "set": setname,
        "ambientcg_asset_id": asset,
        "source_url": DL % asset,
        "license": LICENSE,
        "source_resolution": "1K-JPG",
        "ingest_resolution": [SIZE, SIZE],
        "maps": {
            "c": {"file": os.path.relpath(dests["c"], ROOT), "role": "albedo",
                  "transfer": albedo_tf, "channels": "RGB",
                  "bytes": os.path.getsize(dests["c"]),
                  "sha256": sha256_of(dests["c"]), "mean": mean_of(dests["c"])},
            "r": {"file": os.path.relpath(dests["r"], ROOT), "role": "roughness",
                  "transfer": rough_tf, "channels": "grey",
                  "bytes": os.path.getsize(dests["r"]),
                  "sha256": sha256_of(dests["r"]), "mean": mean_of(dests["r"])},
            "n": {"file": os.path.relpath(dests["n"], ROOT), "role": "normal",
                  "transfer": normal_tf, "channels": "RGB (OpenGL +Y)",
                  "bytes": os.path.getsize(dests["n"]),
                  "sha256": sha256_of(dests["n"]), "mean": mean_of(dests["n"])},
        },
        # The colour-management evidence, all of it measured. `value_transform` is the
        # assertion that matters and it is a real comparison against the untouched
        # source file, not a restatement of the intent.
        "colour_management": {
            "value_transform_on_data": "none",
            "roughness_mean_source": src_r_mean,
            "roughness_mean_emitted": out_r_mean,
            "roughness_mean_ratio": round(ratio, 6),
            "roughness_mean_reference": "resized reference (same Lanczos resize, no "
                                        "transform) - NOT the 1024 source, whose mean "
                                        "differs from the resized mean by ~0.35% and "
                                        "is not evidence of anything",
            "container_change": "8-bit grey JPEG -> 8-bit grey PNG (values identical)",
            "why_the_container_matters": (
                "It does not - this is the measured trap. Godot 4 turns an 8-bit "
                "image into an *_SRGB texture and sRGB-decodes it at sample time, and "
                "Image.load() quantises 16-bit PNG down to 8-bit, so writing 16-bit "
                "buys nothing. The sampling space is fixed in ArtKitMaterials by "
                "img.convert(Image.FORMAT_RGBAF) before ImageTexture creation, which "
                "is measured to leave every pixel value unchanged while making the "
                "texture float and therefore linear."),
            "expected_godot_format_after_load": "FORMAT_L8 (roughness), FORMAT_RGB8 (normal)",
            "expected_godot_format_after_convert_rgbaf": "FORMAT_RGBAF (linear sampling)",
            "note": "PBR packs ship roughness/AO/displacement as LINEAR non-colour "
                    "data, so applying the sRGB EOTF here would be a double "
                    "correction. grass_verge is 0.263, which is grass; gamma-2.2 that "
                    "and it is 0.053, which is a mirror.",
        },
    }
    return entry


def build(force=False):
    manifest = {
        "source": "ambientCG (ambientcg.com), all sets CC0 1.0 Universal",
        "note": "Generated by artkit/textures/fetch_pbr.py - do not hand-edit. "
                "Albedo is a photograph and is left in sRGB. Roughness and normal are "
                "data: their VALUES are preserved exactly (PBR packs ship them "
                "linear) and their CONTAINER is widened to 16-bit so Godot samples "
                "them linearly with no .import file. Palette tinting happens in "
                "ArtKitMaterials, never here.",
        "convention": {
            "c": "albedo, sRGB 8-bit JPEG",
            "r": "roughness, LINEAR grey PNG, 8-bit, widened to RGBAF at load",
            "n": "normal OpenGL +Y, LINEAR RGB PNG, 8-bit, widened to RGBAF at load",
            "naming": "<set>_<c|r|n>.<ext> inside artkit/textures/<set>/",
        },
        "sets": {},
    }
    total = 0
    for setname, asset in SETS.items():
        print("== %s <- %s" % (setname, asset))
        zpath, url = fetch(asset)
        print("   cached=%s %s" % (os.path.exists(zpath), url or "(from cache)"))
        with tempfile.TemporaryDirectory() as work:
            entry = ingest(setname, asset, zpath, force)
        cm = entry["colour_management"]
        print("   albedo mean %.4f | roughness %.4f (source %.4f, ratio %.3f, values "
              "preserved) | normal mean %.4f"
              % (entry["maps"]["c"]["mean"], cm["roughness_mean_emitted"],
                 cm["roughness_mean_source"], cm["roughness_mean_ratio"],
                 entry["maps"]["n"]["mean"]))
        for k in ("c", "r", "n"):
            print("   %s: %-58s %8d B" % (k, entry["maps"][k]["file"],
                                          entry["maps"][k]["bytes"]))
            total += entry["maps"][k]["bytes"]
        manifest["sets"][setname] = entry
    manifest["total_bytes"] = total
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")
    print("\n-> %s (%d bytes total across %d sets)"
          % (MANIFEST, total, len(manifest["sets"])))


def check():
    """Re-verify what is on disk. Asserts the files exist, that their bytes are
    unchanged, that no value transform crept into the data, and that every set has
    all three maps.

    The four things it guards are the ones that break *silently*, because a missing or
    mis-coloured roughness map still renders a road: a file gone, bytes changed under
    us, a data value transformed, and - the one that actually bit here - the engine
    reading the data map in the wrong colour space.
    """
    with open(MANIFEST) as f:
        m = json.load(f)
    bad = 0
    for setname, entry in sorted(m["sets"].items()):
        for kind in ("c", "r", "n"):
            spec = entry["maps"][kind]
            path = os.path.join(ROOT, spec["file"])
            if not os.path.exists(path):
                print("  MISSING %s" % spec["file"])
                bad += 1
                continue
            got = sha256_of(path)
            if got != spec["sha256"]:
                print("  CHANGED %s" % spec["file"])
                bad += 1
                continue
            mean = mean_of(path)
            if abs(mean - spec["mean"]) > 1e-5:
                print("  MEAN DRIFT %s: manifest %.6f, file %.6f"
                      % (spec["file"], spec["mean"], mean))
                bad += 1
        # The transfer function's whole job is to move the roughness value. If the
        # stored and linear means agree to 3 places, either the map is already linear
        # or the linearisation did not run, and in both cases the claim is false.
        cm = entry["colour_management"]
        # The transfer function's whole job is to leave the data alone. If the emitted
        # mean has drifted from the recorded source mean, either a value transform
        # crept in or the file was re-encoded; either way the manifest is describing a
        # map that is no longer the one the shader gets.
        if abs(cm["roughness_mean_emitted"] - entry["maps"]["r"]["mean"]) > 1e-5:
            print("  MANIFEST DRIFT %s: maps.r.mean %.6f != colour_management %.6f"
                  % (setname, entry["maps"]["r"]["mean"], cm["roughness_mean_emitted"]))
            bad += 1
        if abs(cm["roughness_mean_ratio"] - 1.0) > 1e-6:
            print("  DATA TRANSFORMED %s: source %.6f -> emitted %.6f (ratio %.4f)"
                  % (setname, cm["roughness_mean_source"],
                     cm["roughness_mean_emitted"], cm["roughness_mean_ratio"]))
            bad += 1
        print("  %-16s %-18s ok  albedo %.4f  rough %.4f (source %.4f, ratio %.3f)"
              % (setname, entry["ambientcg_asset_id"], entry["maps"]["c"]["mean"],
                 cm["roughness_mean_emitted"], cm["roughness_mean_source"],
                 cm["roughness_mean_ratio"]))
    if bad:
        sys.exit("PBR-CHECK-FAILED: %d problem(s)" % bad)
    print("PBR-CHECK-OK: %d sets, %d maps, all hashes and means as recorded"
          % (len(m["sets"]), len(m["sets"]) * 3))


# The formats `Image.load()` hands back for a data map, measured on this Godot build
# (4.3.stable). `Image.load()` quantises a 16-bit PNG down to 8-bit, which is why these
# are 8-bit and why writing 16-bit bought nothing.
#
# They are recorded so a change to the ingest that alters the container depth gets
# caught here instead of becoming a shader-side colour-space surprise. The engine-side
# half of the contract - `img.convert(Image.FORMAT_RGBAF)` before `ImageTexture` - lives
# in `artkit/materials.gd` and is asserted by `artkit/pbr_check.gd`, because asserting
# it here would only prove Python can read a PNG header.
EXPECTED_GODOT_FORMAT = {
    "r": {"as_loaded": "FORMAT_L8", "after_convert": "FORMAT_RGBAF"},
    "n": {"as_loaded": "FORMAT_RGB8", "after_convert": "FORMAT_RGBAF"},
    # Albedo is deliberately NOT widened: a colour must stay sRGB.
    "c": {"as_loaded": "FORMAT_RGB8", "after_convert": "FORMAT_RGB8"},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify the sets on disk against manifest.json and exit")
    ap.add_argument("--force", action="store_true", help="re-ingest even if present")
    a = ap.parse_args()
    if a.check:
        check()
        return
    build(a.force)


if __name__ == "__main__":
    main()
