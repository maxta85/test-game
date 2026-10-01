#!/usr/bin/env python3
"""Plot the generated OSM road network to a PNG.

The in-game aerial camera is lit for atmosphere and is too dark to read as a
map, so this plots assets/maps/cairns_map.json directly: every corridor the game
can actually drive, named, at true scale. It answers "is this really Manunda"
without needing the game running, and it makes the dropped-segment count in
'stats' visible instead of buried in a JSON field.

    python3 Tools/plot_map.py [out.png]

Draws at 3x and downsamples, because PIL line joins are jaggy at 1x.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "assets" / "maps" / "cairns_map.json"

SS = 3  # supersample factor
W, H = 1500, 1100
MARGIN = 70

BG = (14, 17, 26)
ROAD = {
    1: (232, 238, 248),
    2: (150, 176, 210),
    3: (96, 118, 150),
    4: (72, 90, 116),
}
LABEL = (255, 208, 120)
GRID = (30, 36, 50)
TEXT = (205, 215, 230)
DIM = (120, 132, 150)


def font(size):
    for p in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ):
        if Path(p).exists():
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs" / "manunda-road-network.png"
    out.parent.mkdir(parents=True, exist_ok=True)

    data = json.loads(MAP.read_text())
    corridors = data["corridors"]
    stats = data["stats"]

    pts = [p for c in corridors for p in c["points"]]
    xs = [p[0] for p in pts]
    zs = [p[1] for p in pts]
    minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)

    # metres -> pixels, uniform scale so the shape is not distorted
    spanx, spanz = maxx - minx, maxz - minz
    scale = min((W - 2 * MARGIN) / spanx, (H - 2 * MARGIN) / spanz)

    def px(p):
        return (
            (p[0] - minx) * scale + MARGIN,
            (p[1] - minz) * scale + MARGIN,
        )

    img = Image.new("RGB", (W * SS, H * SS), BG)
    d = ImageDraw.Draw(img)

    def P(p):
        x, y = px(p)
        return (x * SS, y * SS)

    # 500 m graticule, labelled in real metres
    f_small = font(11 * SS)
    step = 500
    gx = (minx // step) * step
    while gx <= maxx:
        x = (gx - minx) * scale + MARGIN
        d.line([(x * SS, 0), (x * SS, H * SS)], fill=GRID, width=SS)
        d.text((x * SS + 4, 6 * SS), f"{int(gx)}m", font=f_small, fill=DIM)
        gx += step
    gz = (minz // step) * step
    while gz <= maxz:
        y = (gz - minz) * scale + MARGIN
        d.line([(0, y * SS), (W * SS, y * SS)], fill=GRID, width=SS)
        d.text((6 * SS, y * SS + 3), f"{int(gz)}m", font=f_small, fill=DIM)
        gz += step

    # roads, widest class first so minor roads sit on top
    for cls in (1, 2, 3, 4):
        for c in corridors:
            if c["class"] != cls:
                continue
            d.line(
                [P(p) for p in c["points"]],
                fill=ROAD.get(cls, ROAD[4]),
                width=int((4 if cls == 1 else 2.6 if cls == 2 else 1.6) * SS),
                joint="curve",
            )

    # label the named streets worth reading
    f_lab = font(13 * SS)
    seen = {}
    for c in corridors:
        if c["length"] < 260:
            continue
        mid = c["points"][len(c["points"]) // 2]
        key = c["name"]
        # one label per street name, at its longest segment
        if key in seen and seen[key] >= c["length"]:
            continue
        seen[key] = c["length"]
        x, y = P(mid)
        w = d.textlength(c["name"], font=f_lab)
        d.text((x * 1 + (x - w / 2) * 0, y - 8 * SS), c["name"], font=f_lab, fill=LABEL)

    img = img.resize((W, H), Image.LANCZOS)
    d = ImageDraw.Draw(img)

    dropped = stats.get("dropped", {})
    d.text(
        (MARGIN // 2, 16),
        f"Manunda road network  -  {stats['corridors']} corridors, "
        f"{stats['segments']} segments, {stats['total_km']:.1f} km",
        font=font(21),
        fill=TEXT,
    )
    d.text(
        (MARGIN // 2, 42),
        f"extent {spanx:.0f} x {spanz:.0f} m   |   dropped: "
        f"{dropped.get('disconnected', 0)} disconnected, "
        f"{dropped.get('class', 0)} off-class, {dropped.get('short', 0)} too short   |   "
        f"{data['source']}",
        font=font(12),
        fill=DIM,
    )

    img.save(out)
    print(f"{out}  ({W}x{H})")


if __name__ == "__main__":
    main()