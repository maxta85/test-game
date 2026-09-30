#!/usr/bin/env python3
"""Fetch real OpenStreetMap roads for a bbox and emit the corridor format
World/road_graph.gd already consumes.

Why this exists: the game wants a 3D map of Cairns. The paid marketplaces sell
pre-baked city meshes, and the "free" advice is to install Blender plus BlenderGIS
and export a .glb. Both are wrong for this project:

  - the meshes are a dead end because WorldBuilder does not read meshes. It reads
    a RoadGraph, and every downstream system (traffic, race routes, the racing
    line, kerbs, lane markings, streetlights) derives its geometry from that one
    graph. A .glb would have to be reverse-engineered back into road corridors,
    which is more work than going to the source data;
  - Blender is a GUI app on a headless box, and the whole toolchain is already
    stdlib: curl + xml.etree does the whole job.

The OSM API serves raw vector data for a bbox. This projects it to local metres,
simplifies it, and classifies it into RoadGraph.RoadClass. The output is a JSON
file that World/osm_layout.gd reads and hands straight to RoadGraph.build().

Coordinate convention matches World/manunda_layout.gd: +X east, +Z south, origin
at the centre of the bbox. That is the mapping
x = east, z = -north, so a point north of centre has negative Z.

Data (c) OpenStreetMap contributors, ODbL. Attribution is required for any
distribution; keep the header in the emitted file.

Usage:
    python3 Tools/osm_cairns.py                     # fetch + convert Cairns CBD
    python3 Tools/osm_cairns.py --bbox S,W,N,E      # somewhere else
    python3 Tools/osm_cairns.py --cache-only        # re-convert, no network
    python3 Tools/osm_cairns.py --tolerance 2.0     # coarser simplification
"""
import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Western Cairns: Bungalow / Westraland, around Mulgrave Road. Chosen over the
# CBD on purpose - this is 100+ real residential streets plus two arterials and
# a river, where the CBD is 15% parking and 60% retail frontage.
CENTRE = (-16.93190, 145.75130)
HALF_DEG = 0.008  # ~1.77 km N-S x ~1.70 km E-W, matching ManundaLayout's ~1.4 km block
CAIRNS_BBOX = (CENTRE[0] - HALF_DEG, CENTRE[1] - HALF_DEG,
               CENTRE[0] + HALF_DEG, CENTRE[1] + HALF_DEG)  # S, W, N, E
RAW = os.path.expanduser("~/.cache/osm/cairns_raw.xml")
OUT = os.path.join(ROOT, "assets", "maps", "cairns_map.json")

API = "https://api.openstreetmap.org/api/0.6/map?bbox={w},{s},{e},{n}"
UA = "cairns-after-dark/1.0 (godot prototype; OSM vector fetch)"

# OSM highway tag -> RoadGraph.RoadClass (LANE=0, STREET=1, ARTERIAL=2, HIGHWAY=3).
# None means "drop it". Two kinds of drop, both load-bearing:
#   - motorway/trunk: grade-separated, so the centreline does not meet the streets
#     it passes over. Keeping it invents a junction at every geometric crossing.
#   - service/footway/path/cycleway/living_street: car parks and back lanes. They
#     roughly triple the corridor count and RoadGraph.build() is O(segments^2).
# Tertiary is a suburban street, not an arterial - mapping it to ARTERIAL gives a
# 14 m road with lane markings and 19 m/s speed limit down a residential block.
CLASSIFY = {
    "motorway": None, "motorway_link": None, "trunk": None, "trunk_link": None,
    "primary": 2, "secondary": 2,
    "primary_link": 1, "secondary_link": 1,
    "tertiary": 1, "tertiary_link": 1,
    "residential": 1, "unclassified": 1, "road": 1,
}


def fetch(bbox):
    s, w, n, e = bbox
    url = API.format(w=w, s=s, e=e, n=n)
    print(f"fetching {url}", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                data = r.read()
            os.makedirs(os.path.dirname(RAW), exist_ok=True)
            with open(RAW, "wb") as f:
                f.write(data)
            print(f"  {len(data)} bytes -> {RAW}", file=sys.stderr)
            return
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as ex:
            last = ex
            print(f"  attempt {attempt + 1} failed: {ex}", file=sys.stderr)
    sys.exit(f"could not fetch OSM data: {last}")


def project(lat, lon, lat0, lon0):
    """Equirectangular about the bbox centre. At city scale the error is
    centimetres; at Cairns' latitude a naive lon * cos(lat) is also required or
    streets come out 7% too wide."""
    m_per_deg_lat = 110574.0
    m_per_deg_lon = 111320.0 * math.cos(math.radians(lat0))
    return ((lon - lon0) * m_per_deg_lon, -(lat - lat0) * m_per_deg_lat)


def rdp(points, eps):
    """Ramer-Douglas-Peucker, iterative so a long street cannot blow the stack."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        ax, az = points[lo]
        bx, bz = points[hi]
        dx, dz = bx - ax, bz - az
        seg2 = dx * dx + dz * dz
        worst, worst_i = -1.0, -1
        for i in range(lo + 1, hi):
            px, pz = points[i]
            if seg2 == 0.0:
                d = math.hypot(px - ax, pz - az)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / seg2))
                d = math.hypot(px - (ax + t * dx), pz - (az + t * dz))
            if d > worst:
                worst, worst_i = d, i
        if worst > eps:
            keep[worst_i] = True
            stack.append((lo, worst_i))
            stack.append((worst_i, hi))
    return [p for p, k in zip(points, keep) if k]


def dissolve(corridors, snap=0.25):
    """Keep only the largest connected component, trimmed to it.

    Real OSM data is not one network. It has pockets joined by a `service` way we
    dropped, private drives, and stubs clipped at the bbox edge. Import them
    as-is and the game gets a road network with islands in it - and every
    downstream assumption (traffic routes, race circuits, a single connected
    graph) quietly breaks. QGIS calls this dissolve; it is the same operation.

    Nodes are welded by rounded position, which is what RoadGraph does too.
    """
    key = lambda p: (round(p[0] / snap), round(p[1] / snap))
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for c in corridors:
        ks = [key(p) for p in c["points"]]
        for a, b in zip(ks, ks[1:]):
            union(a, b)

    size = {}
    for k in list(parent):
        size[find(k)] = size.get(find(k), 0) + 1
    if not size:
        return corridors, 0
    main = max(size, key=size.get)

    kept = []
    for c in corridors:
        keep = [find(key(p)) == main for p in c["points"]]
        if not any(keep):
            continue
        # Longest contiguous run inside the component, so a clipped stub keeps
        # its real geometry instead of a fragment hanging off the boundary.
        best, cur = [], []
        for p, k in zip(c["points"], keep):
            cur = cur + [p] if k else []
            if len(cur) > len(best):
                best = cur
        if len(best) < 2:
            continue
        c = dict(c)
        c["points"] = best
        c["length"] = round(sum(math.dist(best[i], best[i + 1])
                                for i in range(len(best) - 1)), 1)
        kept.append(c)
    return kept, len(corridors) - len(kept)


def convert(bbox, tol):
    s, w, n, e = bbox
    lat0, lon0 = (s + n) / 2.0, (w + e) / 2.0
    print(f"parsing {RAW}", file=sys.stderr)
    root = ET.parse(RAW).getroot()
    nodes = {}
    for el in root:
        if el.tag == "node":
            nodes[el.get("id")] = (float(el.get("lat")), float(el.get("lon")))

    corridors, dropped, min_len = [], {"class": 0, "short": 0, "motorway": 0}, 12.0
    names = {}
    for el in root:
        if el.tag != "way":
            continue
        tags = {t.get("k"): t.get("v") for t in el.findall("tag")}
        hw = tags.get("highway")
        if not hw:
            continue
        pts = []
        for nd in el.findall("nd"):
            ll = nodes.get(nd.get("ref"))
            if ll:
                pts.append(project(ll[0], ll[1], lat0, lon0))
        if len(pts) < 2:
            continue
        pts = rdp(pts, tol)
        length = sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
        cls = CLASSIFY.get(hw, 0)
        if cls is None:
            dropped["motorway"] += 1
            continue
        if cls == 0:
            dropped["class"] += 1
            continue
        if length < min_len:
            dropped["short"] += 1
            continue
        name = tags.get("name") or f"{hw.title()} {el.get('id')}"
        names[name] = names.get(name, 0) + 1
        corridors.append({
            "name": name, "class": cls, "oneway": tags.get("oneway") == "yes",
            "length": round(length, 1),
            "points": [[round(p[0], 2), round(p[1], 2)] for p in pts],
        })

    corridors.sort(key=lambda c: -c["length"])
    corridors, islands = dissolve(corridors)
    corridors.sort(key=lambda c: -c["length"])
    xs = [p[0] for c in corridors for p in c["points"]]
    zs = [p[1] for c in corridors for p in c["points"]]
    segs = sum(len(c["points"]) - 1 for c in corridors)
    out = {
        "source": "OpenStreetMap contributors, ODbL 1.0",
        "note": "Generated by Tools/osm_cairns.py - do not hand-edit.",
        "bbox": {"south": s, "west": w, "north": n, "east": e},
        "axes": "+X east, +Z south, origin at bbox centre",
        "stats": {
            "corridors": len(corridors), "segments": segs,
            "total_km": round(sum(c["length"] for c in corridors) / 1000.0, 2),
            "extent_m": [round(max(xs) - min(xs), 1), round(max(zs) - min(zs), 1)],
            "dropped": dict(dropped, disconnected=islands),
        },
        "corridors": corridors,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"\n{len(corridors)} corridors, {segs} segments, "
          f"{out['stats']['total_km']} km, extent {out['stats']['extent_m']} m")
    print(f"dropped: {dropped}")
    print(f"-> {OUT} ({os.path.getsize(OUT)} bytes)")
    for c in corridors[:12]:
        print(f"   {c['length']:8.1f} m  class {c['class']}  {c['name']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", type=float, nargs=4, metavar=("S", "W", "N", "E"),
                    default=list(CAIRNS_BBOX))
    ap.add_argument("--tolerance", type=float, default=2.5,
                    help="Douglas-Peucker tolerance in metres")
    ap.add_argument("--cache-only", action="store_true")
    a = ap.parse_args()
    if not a.cache_only:
        fetch(tuple(a.bbox))
    convert(tuple(a.bbox), a.tolerance)


if __name__ == "__main__":
    main()
