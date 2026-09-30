#!/usr/bin/env python3
"""Plot the extracted road network next to the OSM raster for the same area.

    python3 Tools/plot_map.py                 # -> shots/map_overview.png

Side by side on purpose. "There are lines in the JSON" is not evidence the
import is correct; the thing that has to be true is that the network sits on top
of the real city, the right way up, the right size. One panel of each, same
extent, same scale, and any error in the projection is obvious.
"""
import json
import math
import os
import urllib.request

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MAP = os.path.join(ROOT, "assets", "maps", "cairns_map.json")
OUT = os.path.join(ROOT, "shots", "map_overview.png")
UA = "cairns-after-dark/1.0 (map verification plot)"

M_PER_DEG_LAT = 110574.0
COLOUR = {1: (90, 150, 235), 2: (245, 165, 60)}
WIDTH = {1: 2, 2: 4}
ZOOM = 16


def tile(lon, lat, z):
    n = 2.0 ** z
    x = (lon + 180.0) / 360.0 * n
    r = math.radians(lat)
    y = (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * n
    return x, y


def lonlat_to_px(lon, lat, z, x0, y0):
    tx, ty = tile(lon, lat, z)
    return (tx - x0) * 256.0, (ty - y0) * 256.0


def main():
    data = json.load(open(MAP))
    bb = data["bbox"]
    lat0 = (bb["south"] + bb["north"]) / 2.0
    lon0 = (bb["west"] + bb["east"]) / 2.0
    mlon = 111320.0 * math.cos(math.radians(lat0))

    pts = [p for c in data["corridors"] for p in c["points"]]
    xmin, xmax = min(p[0] for p in pts), max(p[0] for p in pts)
    zmin, zmax = min(p[1] for p in pts), max(p[1] for p in pts)
    west = lon0 + xmin / mlon
    east = lon0 + xmax / mlon
    north = lat0 - zmin / M_PER_DEG_LAT
    south = lat0 - zmax / M_PER_DEG_LAT
    print(f"network extent: {(xmax - xmin):.0f} x {(zmax - zmin):.0f} m")

    x0, y0 = tile(west, north, ZOOM)
    x1, y1 = tile(east, south, ZOOM)
    w, h = int((x1 - x0) * 256) + 1, int((y1 - y0) * 256) + 1
    print(f"raster: {w} x {h} px at z{ZOOM}  ({(xmax - xmin) / w:.2f} m/px)")

    # --- left: the network, drawn from the JSON the game actually loads ------
    net = Image.new("RGB", (w, h), (12, 14, 20))
    d = ImageDraw.Draw(net)
    for cls, col in sorted(COLOUR.items()):
        for c in data["corridors"]:
            if c["class"] != cls:
                continue
            pl = [(lonlat_to_px(lon0 + p[0] / mlon, lat0 - p[1] / M_PER_DEG_LAT, ZOOM, x0, y0))
                  for p in c["points"]]
            if len(pl) > 1:
                d.line(pl, fill=col, width=WIDTH[cls], joint="curve")
    # Placements as the game computes them, read from the file World/osm_layout
    # produced. Recomputing the anchor rule in Python would be a second
    # implementation that silently drifts from the GDScript one.
    place_file = os.path.join(ROOT, "shots", "placements.json")
    anchor = "(run Tools/diag_osm.gd for the anchor)"
    if os.path.exists(place_file):
        pl = json.load(open(place_file))
        anchor = str(pl.get("anchor", "?"))
        to_px = lambda p: lonlat_to_px(lon0 + p[0] / mlon, lat0 - p[1] / M_PER_DEG_LAT,
                                       ZOOM, x0, y0)
        sx, sy = to_px(pl["start_line"])
        d.line([(sx - 13, sy), (sx + 13, sy)], fill=(255, 70, 70), width=4)
        d.line([(sx, sy - 13), (sx, sy + 13)], fill=(255, 70, 70), width=4)
        gx, gy = to_px(pl["grid"])
        d.ellipse([gx - 7, gy - 7, gx + 7, gy + 7], outline=(90, 255, 130), width=3)
        cx, cy = to_px(pl["car_meet"])
        d.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], outline=(255, 220, 90), width=3)
    d.text((14, 12), f"EXTRACTED NETWORK   anchor: {anchor}", fill=(235, 235, 235))
    d.text((14, 32), f"{len(data['corridors'])} corridors / {data['stats']['total_km']} km",
           fill=(180, 190, 205))
    d.text((14, 52), "orange = arterial   blue = street   red = start line   green = grid   amber = car meet", fill=(180, 190, 205))

    # --- right: the actual OSM raster for the same extent -------------------
    rast = Image.new("RGB", (w, h), (20, 20, 20))
    tx0, ty0 = int(math.floor(x0)), int(math.floor(y0))
    tx1, ty1 = int(math.floor(x1)), int(math.floor(y1))
    for tx in range(tx0, tx1 + 1):
        for ty in range(ty0, ty1 + 1):
            url = f"https://tile.openstreetmap.org/{ZOOM}/{tx}/{ty}.png"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                raw = urllib.request.urlopen(req, timeout=30).read()
            except Exception as ex:  # noqa: BLE001 - a missing tile is not fatal
                print(f"  tile {tx}/{ty} failed: {ex}")
                continue
            import io
            im = Image.open(io.BytesIO(raw)).convert("RGB")
            rast.paste(im, (int((tx - x0) * 256), int((ty - y0) * 256)))
    d2 = ImageDraw.Draw(rast)
    d2.text((14, 12), "OPENSTREETMAP RASTER, SAME EXTENT", fill=(20, 20, 20))
    d2.text((14, 32), "for comparison - the left panel must sit on top of this",
            fill=(40, 40, 40))

    pad, cap = 16, 74
    out = Image.new("RGB", (w * 2 + pad * 3, h + cap + pad * 2), (8, 8, 10))
    out.paste(net, (pad, pad + cap))
    out.paste(rast, (pad * 2 + w, pad + cap))
    d3 = ImageDraw.Draw(out)
    d3.text((pad, pad + 20), "CAIRNS AFTER DARK - real map import", fill=(240, 240, 240))
    d3.text((pad, pad + 42),
            f"{south:.5f},{west:.5f} .. {north:.5f},{east:.5f}  |  "
            f"{(xmax - xmin) / 1000.0:.2f} x {(zmax - zmin) / 1000.0:.2f} km  |  "
            f"z{ZOOM}", fill=(150, 158, 170))
    d3.text((pad * 2 + w, pad + 20), "same bbox, same scale, same orientation",
            fill=(150, 158, 170))
    d3.text((pad * 2 + w, pad + 42), "OSM (c) OpenStreetMap contributors, ODbL",
            fill=(150, 158, 170))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out.save(OUT)
    print(f"-> {OUT}  ({out.size[0]}x{out.size[1]})")


if __name__ == "__main__":
    main()
