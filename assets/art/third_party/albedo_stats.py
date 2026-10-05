#!/usr/bin/env python3
"""Measure the ingested albedo maps, so the runtime knows how to normalise them.

Prints, per set, the mean and the spread of the luma of the diffuse map. The
runtime uses the mean to divide the map back out, so a texture contributes
*detail* and never *brightness*: a grey asphalt photograph whose mean is 0.42
must not darken a palette role that was authored at a chosen value.

    python3 assets/art/third_party/albedo_stats.py > assets/art/third_party/albedo_stats.json
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Pillow is optional. The inventory is the licence record and does not need it;
# this is a measurement convenience, so a missing Pillow is a warning, not a
# failure, and the emitted JSON says so rather than being silently absent.
try:
    from PIL import Image
except ImportError:
    Image = None


def luma_stats(path):
    im = Image.open(path).convert("RGB")
    px = list(im.getdata())
    n = len(px)
    mean = [sum(p[c] for p in px) / n / 255.0 for c in range(3)]
    lumas = [0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] for p in px]
    lumas.sort()
    return {
        "width": im.size[0],
        "height": im.size[1],
        "mean_rgb": [round(v, 5) for v in mean],
        "luma_mean": round(sum(lumas) / n, 5),
        "luma_p05": round(lumas[int(n * 0.05)], 5),
        "luma_p50": round(lumas[int(n * 0.50)], 5),
        "luma_p95": round(lumas[int(n * 0.95)], 5),
        # Contrast is what makes a surface read as a material rather than a
        # tint. A map whose p05..p95 is narrow contributes almost nothing, and
        # that is worth knowing before it is wired into a hero surface.
        "luma_spread": round((lumas[int(n * 0.95)] - lumas[int(n * 0.05)]) / 255.0, 5),
    }


def main():
    doc = json.load(open(os.path.join(HERE, "inventory.json")))
    out = {
        "schema": "cairns-after-dark/albedo-stats/1",
        "purpose": ("Mean luma of each ingested albedo map. The runtime divides "
                    "the map by its mean so the texture supplies detail and the "
                    "palette keeps supplying value."),
        "pillow_available": Image is not None,
        "sets": {},
    }
    if Image is None:
        print("WARN: Pillow not installed; emitting an empty measurement",
              file=sys.stderr)
    for entry in doc["assets"]:
        if entry.get("role") != "albedo":
            continue
        full = os.path.join(HERE, entry["path"])
        if not os.path.exists(full):
            continue
        out["sets"].setdefault(entry["set"], {})["albedo"] = luma_stats(full)
        out["sets"][entry["set"]]["file"] = entry["path"]
    json.dump(out, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()