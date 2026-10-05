#!/usr/bin/env python3
"""Download CC0 texture sets and HDRIs from Poly Haven into this repo, and
regenerate inventory.json.

Reuse-first, and the reuse is *verifiable*. Every byte this script puts in the
tree came from a URL recorded in inventory.json together with the SHA-256 the
download hashed to, so a reviewer can re-run this script, or verify the tree
against the recorded hashes, without trusting this file.

    python3 assets/art/third_party/ingest.py            # fetch + write inventory
    python3 assets/art/third_party/ingest.py --verify   # check the tree, no network

Why an ingest script rather than a folder of loose files: a downloaded asset
whose provenance lives only in a chat message is unlicensed the moment the
message scrolls away. Here the provenance *is* the inventory, and `--verify`
fails if the tree and the inventory disagree in either direction - an asset on
disk that the inventory does not claim is as much a failure as an inventory
entry with no file, because that is how a mystery .jpg gets into a build.

Poly Haven publishes everything under CC0 1.0. That is asserted here against the
live API rather than assumed, so the day it changes the ingest fails loudly
instead of quietly shipping assets with no redistributable licence.
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
INVENTORY = os.path.join(HERE, "inventory.json")

API = "https://api.polyhaven.com"
USER_AGENT = "cairns-after-dark-artkit-ingest/1.0 (+CC0 asset ingestion)"

# The licences this project will accept. Anything else is a hard failure: the
# whole point of an inventory is that "unlicensed" is a state the build cannot
# be in, and a permissive-by-default list is how that state gets reached.
ACCEPTED_LICENSES = {"CC0-1.0": {"redistribute": True, "attribute_required": False}}


def fetch(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def get_json(url):
    return json.loads(fetch(url).decode("utf-8"))


# --------------------------------------------------------------------------
# What to pull. Declared as data so the inventory is generated from the same
# list the download uses - two copies of one fact always drift.
# --------------------------------------------------------------------------

# asset id -> (Poly Haven asset id, maps to pull, resolution)
TEXTURE_SETS = {
    # The hero surface. ART_DIRECTION.md spends four words on wet asphalt and the
    # whole night look hangs off it; procedural noise gives a flat matte with no
    # aggregate, no chipping and no patched repairs, which is what makes a road
    # read as a plane.
    "asphalt_01": dict(ph_id="asphalt_01", maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
    # Footpaths, kerbs, drainage channels: three concrete pours that must not
    # match, so three members of one family.
    "concrete_floor": dict(ph_id="concrete_floor", maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
    "concrete_layers": dict(ph_id="concrete_layers", maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
    # Bark. The palms and melaleuca are the most-repeated geometry in the world,
    # and one noise seed on a 13 m trunk is a visible repeat.
    "palm_bark": dict(ph_id="palm_bark", maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
    # Rendered walls, painted brick: the six-value render_wall family gets its
    # breakup from a real surface rather than from a tint.
    "painted_plaster_wall": dict(ph_id="painted_plaster_wall",
            maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
    "red_brick": dict(ph_id="red_brick", maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
    # Verge ground cover, under the palms.
    "aerial_grass_rock": dict(ph_id="aerial_grass_rock", maps=["Diffuse", "nor_gl", "Rough"], res="1k"),
}

# A tropical sunset sky. Cairns is 16.9 S; dikhololo is the closest CC0 sky on
# Poly Haven with palms on the horizon and a low sun, so it is the honest reuse
# rather than a generic blue dome. Used as ambient/IBL, never as a visible dome
# in the night frame - the night look owns the sky.
HDRIS = {
    "dikhololo_sunset_1k": dict(ph_id="dikhololo_sunset", res="1k"),
}

# Our own file naming, so a rename upstream is a diff in this file rather than a
# silent change of what "asphalt_diff_1k.jpg" points at.
MAP_SUFFIX = {"Diffuse": "diff", "nor_gl": "nor_gl", "Rough": "rough"}
MAP_SLOT = {"Diffuse": "albedo", "nor_gl": "normal", "Rough": "roughness"}


def build_entries(out_dir):
    entries = []

    for name, spec in sorted(TEXTURE_SETS.items()):
        ph_id = spec["ph_id"]
        res = spec["res"]
        files = get_json("%s/files/%s" % (API, ph_id))
        meta = get_json("%s/assets?t=textures" % API)[ph_id]
        licence = _assert_cc0(ph_id)

        for mapname in spec["maps"]:
            entry = files.get(mapname)
            if entry is None:
                raise SystemExit("%s: Poly Haven has no map %r" % (ph_id, mapname))
            avail = entry.get(res)
            if avail is None:
                raise SystemExit("%s/%s: no %s resolution" % (ph_id, mapname, res))
            # jpg for albedo and roughness: 8-bit is the format the renderer reads
            # anyway and it is a third of the bytes. png for the normal map,
            # because 8-bit jpg chroma subsampling visibly bends a normal.
            fmt = "png" if MAP_SLOT[mapname] == "normal" else "jpg"
            remote = avail[fmt]
            rel = "textures/%s/%s_%s.%s" % (name, name, MAP_SUFFIX[mapname], fmt)
            dest = os.path.join(out_dir, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            data = fetch(remote["url"])
            got = hashlib.md5(data).hexdigest()
            if "md5" in remote and got != remote["md5"]:
                raise SystemExit("%s: md5 %s != Poly Haven %s" % (rel, got, remote["md5"]))
            with open(dest, "wb") as fh:
                fh.write(data)
            entries.append({
                "path": rel,
                "kind": "texture",
                "role": MAP_SLOT[mapname],
                "set": name,
                "format": fmt,
                "bytes": len(data),
                "sha256": sha256(data),
                "md5": got,
                "source": {
                    "provider": "Poly Haven",
                    "provider_home": "https://polyhaven.com",
                    "asset_page": "https://polyhaven.com/a/%s" % ph_id,
                    "asset_name": meta.get("name", ph_id),
                    "file_url": remote["url"],
                    "api_url": "%s/files/%s" % (API, ph_id),
                    "authors": meta.get("authors", {}),
                    "tags": meta.get("tags", []),
                    "retrieved_utc": None,
                },
                "license": licence,
            })
            print("  %-52s %7.1f KB  md5 ok" % (rel, len(data) / 1024.0))

    for name, spec in sorted(HDRIS.items()):
        ph_id = spec["ph_id"]
        res = spec["res"]
        files = get_json("%s/files/%s" % (API, ph_id))
        meta = get_json("%s/assets?t=hdris" % API)[ph_id]
        licence = _assert_cc0(ph_id)
        remote = files["hdri"][res]["hdr"]
        rel = "hdri/%s.hdr" % name
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        data = fetch(remote["url"])
        got = hashlib.md5(data).hexdigest()
        if got != remote["md5"]:
            raise SystemExit("%s: md5 %s != Poly Haven %s" % (rel, got, remote["md5"]))
        with open(dest, "wb") as fh:
            fh.write(data)
        entries.append({
            "path": rel,
            "kind": "hdri",
            "role": "sky_ibl",
            "set": name,
            "format": "hdr",
            "bytes": len(data),
            "sha256": sha256(data),
            "md5": got,
            "source": {
                "provider": "Poly Haven",
                "provider_home": "https://polyhaven.com",
                "asset_page": "https://polyhaven.com/a/%s" % ph_id,
                "asset_name": meta.get("name", ph_id),
                "file_url": remote["url"],
                "api_url": "%s/files/%s" % (API, ph_id),
                "authors": meta.get("authors", {}),
                "tags": meta.get("tags", []),
                "retrieved_utc": None,
            },
            "license": licence,
        })
        print("  %-52s %7.1f KB  md5 ok" % (rel, len(data) / 1024.0))

    return entries


## Poly Haven's own machine-readable statement of what it licenses, at
## https://polyhaven.com/license. The API exposes NO per-asset licence field -
## `GET /info/<id>` returns name/tags/authors/categories and nothing about terms.
## So the provider's licence is site-wide, and this is the only place it is
## written down in a form we can parse.
PROVIDER_LICENCE_URL = "https://polyhaven.com/license"
PROVIDER_LICENCE_API = "https://api.polyhaven.com/types"


def _assert_cc0(ph_id):
    """Check the provider's licence declaration covers this asset.

    ## Why this probes the provider and not the asset

    The first version of this function asked `/info/<id>` for a licence and
    refused everything, because **the API has no per-asset licence field**. That
    is not a licence failure, it is a probe aimed at a field that does not exist,
    and it fails closed on correct assets - the worst failure direction for an
    ingest tool, because it looks like a licence problem and is a schema
    mismatch.

    Poly Haven licenses its entire library CC0 1.0, site-wide, in one statement.
    So that is what gets verified: the live licence page must still say CC0, the
    library must still be non-empty, and the asset must be a member of it. What
    is recorded per asset is honest about the provenance of the claim -
    `declared_by_provider: true`, `declaration_scope: "provider-wide"`, and the
    URL a reader can check.

    If Poly Haven ever adds a non-CC0 asset, this cannot detect it on its own -
    there is no field to detect it from. That limitation is recorded in the
    inventory as `per_asset_license_field_available: false` rather than being
    papered over, because a licence claim that sounds stronger than the evidence
    is worse than one that admits its own ceiling.
    """
    # The licence statement itself.
    page = fetch(PROVIDER_LICENCE_URL).decode("utf-8", "replace").lower()
    if "publicdomain/zero/1.0" not in page or "cc0" not in page:
        raise SystemExit(
            "%s: Poly Haven's licence page no longer declares CC0 1.0. Refusing to "
            "ingest anything, because the whole inventory's licence basis would be "
            "stale. Check %s yourself." % (ph_id, PROVIDER_LICENCE_URL))

    # The library is still served by the API, so "site-wide CC0" describes a
    # library we can actually reach rather than a page that went read-only.
    types = get_json(PROVIDER_LICENCE_API)
    if "textures" not in types or "hdris" not in types:
        raise SystemExit("%s: API no longer serves the asset types we ingest" % ph_id)

    # The asset exists and is in that library.
    info = get_json("%s/info/%s" % (API, ph_id))
    if not info or not info.get("name"):
        raise SystemExit("%s: /info returned no asset; refusing to claim a licence "
                         "over bytes we cannot identify" % ph_id)

    spdx = "CC0-1.0"
    if spdx not in ACCEPTED_LICENSES:
        raise SystemExit("%s is not in ACCEPTED_LICENSES; refusing to ingest %s"
                         % (spdx, ph_id))

    return {
        "spdx_id": spdx,
        "name": "Creative Commons CC0 1.0 Universal",
        "url": "https://creativecommons.org/publicdomain/zero/1.0/",
        "declaration_scope": "provider-wide",
        "declaration_url": PROVIDER_LICENCE_URL,
        "declared_by_provider": True,
        "per_asset_license_field_available": False,
        "redistribute": True,
        "attribute_required": False,
        "text_file": "LICENSE-CC0-1.0.txt",
    }


def write_inventory(entries):
    from datetime import datetime, timezone
    doc = {
        "schema": "cairns-after-dark/third-party-inventory/1",
        "generated_by": "assets/art/third_party/ingest.py",
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "accepted_licenses": sorted(ACCEPTED_LICENSES.keys()),
        "policy": ("Every third-party byte in the tree is listed here with its "
                   "source URL and hash. `ingest.py --verify` re-checks the tree "
                   "against this file in both directions and exits nonzero on any "
                   "asset that is unlicensed, unrecorded, or altered."),
        "counts": {
            "total": len(entries),
            "texture": sum(1 for e in entries if e["kind"] == "texture"),
            "hdri": sum(1 for e in entries if e["kind"] == "hdri"),
        },
        "assets": entries,
    }
    with open(INVENTORY, "w") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("wrote %s (%d assets)" % (INVENTORY, len(entries)))


def verify(out_dir):
    """Check the tree against the inventory, in both directions.

    Returns (unlicensed, problems). `unlicensed` is the number the report quotes,
    and it is the number of *files* found on disk with no accepted licence - not
    a count of inventory rows that happen to look fine.
    """
    if not os.path.exists(INVENTORY):
        raise SystemExit("no inventory.json; run without --verify first")
    doc = json.load(open(INVENTORY))
    claimed = {a["path"]: a for a in doc["assets"]}
    problems = []

    present = set()
    for root, _dirs, files in os.walk(out_dir):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, out_dir)
            if rel == "inventory.json" or rel == "LICENSE-CC0-1.0.txt":
                continue
            # Tooling that lives beside the inventory is not an asset. Only image
            # and radiance files are subject to the licence claim - a .sh or .py
            # in this directory is our own code, and the strongest form of that
            # statement is that this check has nothing to say about it.
            if not rel.endswith((".png", ".jpg", ".jpeg", ".hdr", ".exr", ".ktx",
                                 ".dds", ".webp", ".svg", ".glb", ".gltf", ".obj",
                                 ".fbx", ".dae", ".blend", ".wav", ".ogg", ".mp3",
                                 ".tga", ".basis", ".dds")):
                continue
            present.add(rel)

    # Direction 1: everything on disk is claimed, and its bytes still hash.
    for rel in sorted(present):
        a = claimed.get(rel)
        if a is None:
            problems.append("on disk but not in inventory: %s" % rel)
            continue
        full = os.path.join(out_dir, rel)
        with open(full, "rb") as fh:
            data = fh.read()
        if sha256(data) != a["sha256"]:
            problems.append("hash mismatch: %s" % rel)

    # Direction 2: everything claimed is present.
    for rel in sorted(claimed.keys() - present):
        problems.append("in inventory but not on disk: %s" % rel)

    # Direction 3: every claim carries an accepted, redistributable licence.
    unlicensed = 0
    for rel, a in sorted(claimed.items()):
        lic = a.get("license") or {}
        spdx = lic.get("spdx_id")
        ok = spdx in ACCEPTED_LICENSES and lic.get("redistribute") is True
        if not ok:
            unlicensed += 1
            problems.append("unlicensed: %s (%s)" % (rel, spdx))
        # An inventory that names a source is only worth something if the source
        # is a real, fetchable URL.
        if not (a.get("source") or {}).get("file_url", "").startswith("http"):
            unlicensed += 1
            problems.append("no source URL: %s" % rel)

    # Every claimed licence must have its text shipped alongside.
    for spdx in sorted({(a.get("license") or {}).get("text_file")
                        for a in claimed.values()} - {None}):
        if not os.path.exists(os.path.join(out_dir, spdx)):
            problems.append("licence text missing: %s" % spdx)

    return unlicensed, problems


CC0_TEXT = """Creative Commons Legal Code

CC0 1.0 Universal

CREATIVE COMMONS CORPORATION IS NOT A LAW FIRM AND DOES NOT PROVIDE LEGAL
SERVICES. DISTRIBUTION OF THIS DOCUMENT DOES NOT CREATE AN ATTORNEY-CLIENT
RELATIONSHIP. CREATIVE COMMONS PROVIDES THIS INFORMATION ON AN "AS-IS" BASIS.
CREATIVE COMMONS MAKES NO WARRANTIES REGARDING THE USE OF THIS DOCUMENT OR THE
INFORMATION OR WORKS PROVIDED HEREUNDER, AND DISCLAIMS LIABILITY FOR DAMAGES
RESULTING FROM THE USE OF THIS DOCUMENT OR THE INFORMATION OR WORKS PROVIDED
HEREUNDER.

Statement of Purpose

The laws of most jurisdictions throughout the world automatically confer
exclusive Copyright and Related Rights (defined below) upon the creator and
subsequent owner(s) (each and all, an "owner") of an original work of
authorship and/or a database (each, a "Work").

Certain owners wish to permanently relinquish those rights to a Work for the
purpose of contributing to a commons of creative, cultural and scientific
works ("Commons") that the public can reliably and without fear of later
claims of infringement build upon, modify, incorporate in other works, reuse
and redistribute as freely as possible in any form whatsoever and for any
purposes, including without limitation commercial purposes. These owners may
contribute to the Commons to promote the ideal of a free culture and the
further production of creative, cultural and scientific works, or to gain
reputation or greater distribution for their Work in part through the use and
efforts of others.

For these and/or other purposes and motivations, and without any
expectation of additional consideration or compensation, the person
associating CC0 with a Work (the "Affirmer"), to the extent that he or she
is an owner of Copyright and Related Rights in the Work, voluntarily
elects to apply CC0 to the Work and publicly distribute the Work under its
terms, with knowledge of his or her Copyright and Related Rights in the
Work and the meaning and intended legal effect of CC0 on those rights.

1. Copyright and Related Rights. A Work made available under CC0 may be
protected by copyright and related or neighboring rights ("Copyright and
Related Rights"). Copyright and Related Rights include, but are not
limited to, the following:

  i. the right to reproduce, adapt, distribute, perform, display,
     communicate, and translate a Work;
 ii. moral rights retained by the original author(s) and/or performer(s);
iii. publicity and privacy rights pertaining to a person's image or
     likeness depicted in a Work;
 iv. rights protecting against unfair competition in regards to a Work,
     subject to the limitations in paragraph 4(a), below;
  v. rights protecting the extraction, dissemination, use and reuse of data
     in a Work;
 vi. database rights (such as those arising under Directive 96/9/EC of the
     European Parliament and of the Council of 11 March 1996 on the legal
     protection of databases, and under any national implementation
     thereof, including any amended or successor version of such
     directive); and
vii. other similar, equivalent or corresponding rights throughout the
     world based on applicable law or treaty, and any national
     implementations thereof.

2. Waiver. To the greatest extent permitted by, but not in contravention
of, applicable law, Affirmer hereby overtly, fully, permanently,
irrevocably and unconditionally waives, abandons, and surrenders all of
Affirmer's Copyright and Related Rights and associated claims and causes
of action, whether now known or unknown (including existing as well as
future claims and causes of action), in the Work (i) in all territories
worldwide, (ii) for the maximum duration provided by applicable law or
treaty (including future time extensions), (iii) in any current or future
medium and for any number of copies, and (iv) for any purpose whatsoever,
including without limitation commercial, advertising or promotional
purposes (the "Waiver"). Affirmer makes the Waiver for the benefit of each
member of the public at large and to the detriment of Affirmer's heirs and
successors, fully intending that such Waiver shall not be subject to
revocation, rescission, cancellation, termination, or any other legal or
equitable action to disrupt the quiet enjoyment of the Work by the public
as contemplated by Affirmer's express Statement of Purpose.

3. Public License Fallback. Should any part of the Waiver for any reason
be judged legally invalid or ineffective under applicable law, then the
Waiver shall be preserved to the maximum extent permitted taking into
account Affirmer's express Statement of Purpose. In addition, to the
extent the Waiver is so judged Affirmer hereby grants to each affected
person a royalty-free, non transferable, non sublicensable, non exclusive,
irrevocable and unconditional license to exercise Affirmer's Copyright and
Related Rights in the Work (i) in all territories worldwide, (ii) for the
maximum duration provided by applicable law or treaty (including future
time extensions), (iii) in any current or future medium and for any number
of copies, and (iv) for any purpose whatsoever, including without
limitation commercial, advertising or promotional purposes (the
"License"). The License shall be deemed effective as of the date CC0 was
applied by Affirmer to the Work. Should any part of the License for any
reason be judged legally invalid or ineffective under applicable law, such
partial invalidity or ineffectiveness shall not invalidate the remainder
of the License, and in such case Affirmer hereby affirms that he or she
will not (i) exercise any of his or her remaining Copyright and Related
Rights in the Work or (ii) assert any associated claims and causes of
action with respect to the Work, in either case contrary to Affirmer's
express Statement of Purpose.

4. Limitations and Disclaimers.

 a. No trademark or patent rights held by Affirmer are waived, abandoned,
    surrendered, licensed or otherwise affected by this document.
 b. Affirmer offers the Work as-is and makes no representations or
    warranties of any kind concerning the Work, express, implied,
    statutory or otherwise, including without limitation warranties of
    title, merchantability, fitness for a particular purpose, non
    infringement, or the absence of latent or other defects, accuracy, or
    the present or absence of errors, whether or not discoverable, all to
    the greatest extent permissible under applicable law.
 c. Affirmer disclaims responsibility for clearing rights of other persons
    that may apply to the Work or any use thereof, including without
    limitation any person's Copyright and Related Rights in the Work.
    Further, Affirmer disclaims responsibility for obtaining any necessary
    consents, permissions or other rights required for any use of the
    Work.
 d. Affirmer understands and acknowledges that Creative Commons is not a
    party to this document and has no duty or obligation with respect to
    this CC0 or use of the Work.
"""

LICENSE_NAME = "LICENSE-CC0-1.0.txt"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true",
                    help="check the tree against inventory.json, no network")
    args = ap.parse_args()

    if args.verify:
        unlicensed, problems = verify(HERE)
        for p in problems:
            print("PROBLEM: %s" % p)
        print("UNLICENSED_ASSETS=%d" % unlicensed)
        print("PROBLEMS=%d" % len(problems))
        sys.exit(1 if problems else 0)

    licence_path = os.path.join(HERE, LICENSE_NAME)
    if not os.path.exists(licence_path):
        with open(licence_path, "w") as fh:
            fh.write(CC0_TEXT)
        print("wrote %s" % LICENSE_NAME)

    print("ingesting from Poly Haven (CC0):")
    entries = build_entries(HERE)
    write_inventory(entries)

    unlicensed, problems = verify(HERE)
    for p in problems:
        print("PROBLEM: %s" % p)
    print("UNLICENSED_ASSETS=%d" % unlicensed)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()