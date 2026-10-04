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
    python3 Tools/osm_cairns.py --check              # assert the emitted rings

Three files come out of one pass: the road corridors the graph is built from,
plus buildings and water as closed rings. The areas are in their own files
because the two downstream consumers are separate pieces of work, and a
renderer must not have to know what it did not draw.

The corridor file also carries a `width_attrs` table: the carriageway width and
lane count each corridor actually has in OSM, keyed by its geometry. See
`width_attr()` for why that is derived rather than read, and
`World/road_graph.gd::WIDTH_ATTR_PATH` for the consumer.
"""
import argparse
import collections
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
OUT_BUILDINGS = os.path.join(ROOT, "assets", "maps", "cairns_buildings.json")
OUT_WATER = os.path.join(ROOT, "assets", "maps", "cairns_water.json")

API = "https://api.openstreetmap.org/api/0.6/map?bbox={w},{s},{e},{n}"
UA = "cairns-after-dark/1.0 (godot prototype; OSM vector fetch)"

# --- street width attributes ---------------------------------------------------
#
# Measured on the fetch this map is built from, not assumed: of the 384 ways that
# survive CLASSIFY, **zero** carry `width` or `est_width`, and 137 carry `lanes`.
# OSM width tagging in this suburb is simply absent, so an extractor that reads
# `width` alone emits an empty table and every street in the game stays one width
# again - the same dead end Tests/test_water.gd already documents for the river
# centrelines. `lanes` is the only survey-grade width attribute this bbox has.
#
# So the number below is a documented convention and not a measurement, and the
# emitted table records which it is per street (`src`). A consumer is never told a
# derived number is a tagged one, because the difference is the whole point: a
# tagged width can be trusted and a derived one can only be as good as the lane
# width convention under it.
LANE_M = 3.5   # carriageway lane, on-street parking excluded (Austroads: 3.5 m urban)
KERB_M = 0.5   # kerb line, each side
MIN_WIDTH_M = 3.0
MAX_WIDTH_M = 25.0
MAX_LANES = 6  # 6 lanes is already 22 m of carriageway; nothing here is wider

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


def corridor_key(points):
    """Identity for one corridor that survives a re-sort or a re-filter.

    Not the name: the 247 corridors in this map carry 61 distinct names, so
    "Mulgrave Road" is 66 different pieces of road with four different lane
    counts between them. Not the first point either - 58 corridors start at a
    junction another corridor also starts at. The whole polyline does identify
    it, and World/road_graph.gd recomputes this string from the Vector2 points it
    was handed, so both sides have to agree on the format: every point as
    `%.2f,%.2f`, joined with `|`, at the 2 dp the points are written at.
    """
    return "|".join("%.2f,%.2f" % (x, z) for x, z in points)


def width_attr(tags):
    """(width_m, lanes, src) from a way's tags, or (None, None, None).

    `width` then `est_width` first, because that is the measurement; `lanes` only
    as the fallback. Three ways a value is refused rather than guessed at:

      - `width=2.5;3` (a lane plus a parking strip) takes the first number, which
        is the carriageway and not the whole reservation;
      - `width=24'` is rejected, not converted: `'` in this position means feet,
        and a string parser that assumed metres would ship a road 30% too wide;
      - anything outside MIN/MAX_WIDTH_M is rejected rather than clamped. A
        clamped outlier is a width nobody surveyed, and the class default it
        falls back to is a better guess than a clamped one.
    """
    raw = tags.get("width") or tags.get("est_width")
    if raw:
        try:
            w = float(str(raw).split(";")[0].strip().split(" ")[0])
        except ValueError:
            w = None
        if w is not None and MIN_WIDTH_M <= w <= MAX_WIDTH_M:
            return round(w, 2), None, "osm:width"
    raw = tags.get("lanes")
    if raw:
        try:
            n = int(float(str(raw).split(";")[0]))
        except ValueError:
            n = 0
        if 1 <= n <= MAX_LANES:
            return round(n * LANE_M + 2.0 * KERB_M, 2), n, "lanes"
    return None, None, None


# --- buildings and water --------------------------------------------------------
#
# Roads are a graph and project cleanly. Buildings and water are polygons, and
# the distinction that actually matters is closed ring vs open polyline. An open
# centreline is not a water body, it is a line where water was; closing it by
# hand invents a shape nobody mapped, and a wrong polygon is worse than a
# missing one. So a ring must arrive closed or be counted and dropped.
#
# The other trap is the tag. `waterway=river` is a centreline, `natural=water` is
# an area, and in this bbox the two disagree about what the water is: the five
# `waterway=river` ways are Chinaman Creek and Moody Creek, while the Barron
# itself is a `type=multipolygon` relation tagged `natural=water` whose four
# member ways are all *open*. Matching on `waterway` alone ships the wrong
# rivers and drops the one that matters.

AREA_TOL = 0.5  # metres. Roads get 2.5 because a kerb is a metre wide; a
                # building wall is not, and 2.5 m cuts the corners off houses.
STOREY_M = 3.0  # only ever applied to `building:levels`, which is a storey count.
MIN_RING = 4    # a closed ring: first point, two more, back to the first

# Areas that are genuinely water. `leisure=swimming_pool` is in here because it
# is a real closed water polygon, not a guess at one; the `waterway=river`
# centrelines and the drains are not, and go to `rivers` instead.
WATER_TAGS = {
    ("natural", "water"), ("natural", "coastline"), ("natural", "bay"),
    ("waterway", "riverbank"), ("landuse", "reservoir"),
    ("leisure", "swimming_pool"),
}
WATERWAY_LINES = {"river", "stream", "canal", "drain", "ditch"}


def closed_ring(el, nodes, lat0, lon0, tol):
    """A way as a simplified closed ring, or None if it is not one.

    Returns None for an open way, a way whose nodes did not all resolve, and a
    ring so small that simplification collapsed it. All three are counted by the
    caller as one number; splitting them further would be bookkeeping nobody
    reads.
    """
    pts = []
    for nd in el.findall("nd"):
        ll = nodes.get(nd.get("ref"))
        if ll:
            pts.append(project(ll[0], ll[1], lat0, lon0))
    if len(pts) < MIN_RING or pts[0] != pts[-1]:
        return None
    pts = rdp(pts, tol)
    return pts if len(pts) >= MIN_RING else None


def stitch_rings(members, nodes, lat0, lon0, tol):
    """A multipolygon's outer ways, welded back into closed rings.

    OSM splits a big ring across several ways and leaves every piece open: the
    last node of one is the first of the next. Welding them by endpoint is what
    any multipolygon assembler does, and it is the difference between the Barron
    arriving as a river and arriving as four loose polylines. Anything that will
    not close is dropped and counted, never hand-joined.

    The orientation is the whole game here. A member may have to be walked
    forwards or backwards, and a chain whose free end already matches another
    member's end has to take that member reversed - matching the wrong way round
    joins two ends that happen to be equal and leaves the ring unclosed.
    """
    segs = []
    for w in members:
        pts = []
        for nd in w.findall("nd"):
            ll = nodes.get(nd.get("ref"))
            if ll:
                pts.append(project(ll[0], ll[1], lat0, lon0))
        if len(pts) > 1:
            segs.append(pts)

    rings, dropped = [], 0

    def close(chain):
        """Record one welded chain, or count it as dropped if it is not a ring."""
        nonlocal dropped
        ring = rdp(chain, tol) if len(chain) >= MIN_RING and chain[0] == chain[-1] else []
        if len(ring) < MIN_RING:
            dropped += 1
        else:
            rings.append(ring)

    for p in segs:
        if p[0] == p[-1]:
            close(p)
    open_segs = [p for p in segs if p[0] != p[-1]]
    used = [False] * len(open_segs)

    for i in range(len(open_segs)):
        if used[i]:
            continue
        used[i] = True
        chain = list(open_segs[i])
        while chain[0] != chain[-1]:
            for j in range(len(open_segs)):
                if used[j]:
                    continue
                c = open_segs[j]
                if c[0] == chain[-1]:
                    chain += c[1:]
                elif c[-1] == chain[-1]:
                    chain += c[::-1][1:]  # reversed: land on the free end
                elif c[-1] == chain[0]:
                    chain = c[:-1] + chain
                elif c[0] == chain[0]:
                    chain = c[::-1][:-1] + chain
                else:
                    continue
                used[j] = True
                break
            else:
                break  # no unused neighbour left, so this chain does not close
        close(chain)

    return rings, dropped


def storeys(tags):
    """(levels, height_m) from `building:levels`, either of which may be None.

    Not from `height` or `building:height`: those are occasionally the height
    above ground of a roof detail rather than of the building, and a wrong
    extrude is a bug somebody has to chase back to a tag. Only 5 of the 2198
    buildings here carry `building:levels`, so most heights are null and the
    renderer picks its own default - which is why the storey count goes out
    alongside the metre figure: 3.0 m is a placeholder, and whoever renders this
    can multiply it out themselves. The clamp rejects nonsense like
    `building:levels=0` or a typo'd `=1000` rather than growing a 3 km tower.
    """
    raw = tags.get("building:levels")
    if raw is None:
        return None, None
    try:
        n = float(str(raw).split(";")[0])
    except ValueError:
        return None, None
    if not 0 < n < 60:
        return None, None
    return int(n) if n == int(n) else n, round(n * STOREY_M, 1)


def area_of(ring):
    return [[round(p[0], 2), round(p[1], 2)] for p in ring]


def extract_areas(root, nodes, lat0, lon0):
    """Buildings and water from the same parse the roads came from.

    Multipolygon relations are read first and their member ways marked consumed,
    because a member way of a relation is very often tagged the same as the
    relation - counting both would place the same building twice.
    """
    tol = AREA_TOL
    buildings, water, rivers = [], [], []
    dropped = collections.Counter()
    ways = {el.get("id"): el for el in root if el.tag == "way"}
    consumed = set()

    for el in root:
        if el.tag != "relation":
            continue
        tags = {t.get("k"): t.get("v") for t in el.findall("tag")}
        if tags.get("type") != "multipolygon":
            continue
        if "building" in tags:
            target = buildings
        elif any((k, v) in WATER_TAGS for k, v in tags.items()):
            target = water
        else:
            continue  # a multipolygon of something we do not draw: do not weld it
        members = [ways[m.get("ref")] for m in el.findall("member")
                   if m.get("type") == "way" and m.get("ref") in ways
                   and m.get("role") in ("outer", "")]
        for m in el.findall("member"):
            if m.get("type") == "way":
                consumed.add(m.get("ref"))
        if not members:
            continue
        rings, n_dropped = stitch_rings(members, nodes, lat0, lon0, tol)
        dropped["relation_unclosed"] += n_dropped
        for ring in rings:
            if target is buildings:
                levels, height = storeys(tags)
                target.append({
                    "osm_id": int(el.get("id")), "kind": tags.get("building"),
                    "levels": levels, "height_m": height, "polygon": area_of(ring)})
            else:
                target.append({
                    "osm_id": int(el.get("id")), "kind": "closed_way",
                    "width_m": None, "polygon": area_of(ring)})

    for el in root:
        if el.tag != "way" or el.get("id") in consumed:
            continue
        tags = {t.get("k"): t.get("v") for t in el.findall("tag")}
        is_water = any((k, tags.get(k)) in WATER_TAGS
                       for k in ("natural", "waterway", "landuse", "leisure"))

        if "building" in tags:
            ring = closed_ring(el, nodes, lat0, lon0, tol)
            if ring is None:
                dropped["building_unclosed"] += 1
                continue
            levels, height = storeys(tags)
            buildings.append({
                "osm_id": int(el.get("id")), "kind": tags.get("building"),
                "levels": levels, "height_m": height, "polygon": area_of(ring),
            })
        elif is_water:
            ring = closed_ring(el, nodes, lat0, lon0, tol)
            if ring is None:
                dropped["water_unclosed"] += 1
                continue
            water.append({
                "osm_id": int(el.get("id")), "kind": "closed_way",
                "width_m": None, "polygon": area_of(ring),
            })
        elif tags.get("waterway") in WATERWAY_LINES:
            pts = []
            for nd in el.findall("nd"):
                ll = nodes.get(nd.get("ref"))
                if ll:
                    pts.append(project(ll[0], ll[1], lat0, lon0))
            if len(pts) < 2:
                dropped["river_unresolved"] += 1
                continue
            raw_w = tags.get("width")
            try:
                width = float(raw_w) if raw_w else None
            except ValueError:
                width = None
            rivers.append({
                "osm_id": int(el.get("id")),
                "name": tags.get("name"),
                "kind": tags.get("waterway"),
                "width_m": width,
                "centreline": area_of(rdp(pts, tol)),
            })

    return {"buildings": buildings, "water": water, "rivers": rivers,
            "dropped": dict(dropped)}


def dump(path, obj):
    """Write `obj` as JSON, or leave the file alone if it is already that.

    A conversion that produces identical buildings and water should not rewrite
    them: it dirties two files the map agent does not own (and did not change),
    which in a fleet of agents working in parallel worktrees is a scope violation
    with a innocent-looking cause.
    """
    body = json.dumps(obj, separators=(",", ":"))
    if os.path.exists(path):
        with open(path) as f:
            if f.read() == body:
                print(f"== {path} unchanged ({len(body)} bytes)")
                return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)
    print(f"-> {path} ({os.path.getsize(path)} bytes)")


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
    # Counted per way as the class filter passes, before the length and
    # connectivity drops below, so `--check` can recount them straight out of
    # the raw fetch and prove the emitted numbers came from the source data.
    ways_with_attr = collections.Counter()
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
        attr_w, attr_lanes, attr_src = width_attr(tags)
        if attr_src:
            ways_with_attr[attr_src] += 1
        if length < min_len:
            dropped["short"] += 1
            continue
        name = tags.get("name") or f"{hw.title()} {el.get('id')}"
        names[name] = names.get(name, 0) + 1
        corridors.append({
            "name": name, "class": cls, "oneway": tags.get("oneway") == "yes",
            "length": round(length, 1),
            "points": [[round(p[0], 2), round(p[1], 2)] for p in pts],
            # Carried through dissolve() (which copies the dict) and popped below.
            "_attr": {"width_m": attr_w, "lanes": attr_lanes, "src": attr_src},
        })

    corridors.sort(key=lambda c: -c["length"])
    corridors, islands = dissolve(corridors)
    corridors.sort(key=lambda c: -c["length"])

    # One entry per corridor that has a width, keyed by its geometry. Not per
    # street name, because a name is not a corridor: 66 ways here are all called
    # Mulgrave Road and they disagree about how many lanes they have.
    width_attrs, attr_srcs, lane_hist = {}, collections.Counter(), collections.Counter()
    for c in corridors:
        # `w` is the bbox west longitude in this function and stays that way.
        attr = c.pop("_attr", None) or {}
        attr_width = attr.get("width_m")
        if attr_width is None:
            continue
        width_attrs[corridor_key(c["points"])] = {
            "width_m": attr_width, "lanes": attr.get("lanes"), "src": attr.get("src")}
        attr_srcs[attr.get("src")] += 1
        if attr.get("lanes"):
            lane_hist[int(attr["lanes"])] += 1
    derived = sorted(v["width_m"] for v in width_attrs.values())
    width_stats = {
        "corridors": len(corridors),
        "corridors_with_width": len(width_attrs),
        "corridors_on_class_default": len(corridors) - len(width_attrs),
        "tagged": attr_srcs["osm:width"],
        "derived_from_lanes": attr_srcs["lanes"],
        "ways_tagged": ways_with_attr["osm:width"],
        "ways_with_lanes": ways_with_attr["lanes"],
        "lanes_histogram": {str(k): v for k, v in sorted(lane_hist.items())},
        "width_m": {"min": derived[0], "max": derived[-1]} if derived else None,
        "key": "corridor polyline, '%.2f,%.2f' per point joined with '|'",
        "dropped_with_width": (ways_with_attr["osm:width"] + ways_with_attr["lanes"]
                               - len(width_attrs)),
    }
    xs = [p[0] for c in corridors for p in c["points"]]
    zs = [p[1] for c in corridors for p in c["points"]]
    segs = sum(len(c["points"]) - 1 for c in corridors)
    out = {
        "source": "OpenStreetMap contributors, ODbL 1.0",
        "note": "Generated by Tools/osm_cairns.py - do not hand-edit. "
                "'width_attrs' carries each corridor's surveyed carriageway width, "
                "keyed by its geometry; 'src' says whether that width was tagged "
                "in OSM or derived from the lane count.",
        "bbox": {"south": s, "west": w, "north": n, "east": e},
        "axes": "+X east, +Z south, origin at bbox centre",
        "stats": {
            "corridors": len(corridors), "segments": segs,
            "total_km": round(sum(c["length"] for c in corridors) / 1000.0, 2),
            "extent_m": [round(max(xs) - min(xs), 1), round(max(zs) - min(zs), 1)],
            "dropped": dict(dropped, disconnected=islands),
            "width": width_stats,
        },
        "width_attrs": width_attrs,
        "corridors": corridors,
    }
    areas = extract_areas(root, nodes, lat0, lon0)
    drop = areas["dropped"]
    bstats = {
        "buildings": len(areas["buildings"]),
        "with_levels": sum(1 for b in areas["buildings"] if b["levels"] is not None),
        "max_points": max((len(b["polygon"]) for b in areas["buildings"]), default=0),
        "total_vertices": sum(len(b["polygon"]) for b in areas["buildings"]),
        "dropped": {"building_unclosed": drop.get("building_unclosed", 0)},
    }
    wstats = {
        "water": len(areas["water"]),
        "rivers_centreline": len(areas["rivers"]),
        "named_rivers": sum(1 for r in areas["rivers"] if r["name"]),
        "max_points": max((len(w["polygon"]) for w in areas["water"]), default=0),
        "dropped": {
            "water_unclosed": drop.get("water_unclosed", 0),
            "river_unresolved": drop.get("river_unresolved", 0),
            "relation_unclosed": drop.get("relation_unclosed", 0),
        },
    }
    for path, extra in (
        (OUT_BUILDINGS, {
            "note": "Generated by Tools/osm_cairns.py - do not hand-edit. "
                    "Building footprints, as closed OSM rings.",
            "stats": bstats, "buildings": areas["buildings"]}),
        (OUT_WATER, {
            "note": "Generated by Tools/osm_cairns.py - do not hand-edit. "
                    "Water areas as closed OSM rings; open centrelines, which are "
                    "not polygons, are in 'rivers'. One OSM element can yield "
                    "several polygons (a multipolygon), so do not key by osm_id.",
            "stats": wstats, "water": areas["water"], "rivers": areas["rivers"]}),
    ):
        dump(path, dict({
            "source": "OpenStreetMap contributors, ODbL 1.0",
            "bbox": {"south": s, "west": w, "north": n, "east": e},
            "axes": "+X east, +Z south, origin at bbox centre",
        }, **extra))
    dump(OUT, out)
    print(f"\n{len(corridors)} corridors, {segs} segments, "
          f"{out['stats']['total_km']} km, extent {out['stats']['extent_m']} m")
    print(f"dropped: {dropped}")
    print(f"widths: {width_stats['corridors_with_width']}/"
          f"{width_stats['corridors']} corridors "
          f"({width_stats['tagged']} tagged in OSM, "
          f"{width_stats['derived_from_lanes']} derived from lanes), lanes "
          f"{width_stats['lanes_histogram']}, range {width_stats['width_m']} m")
    print(f"buildings: {bstats}")
    print(f"water: {wstats}")
    for c in corridors[:12]:
        print(f"   {c['length']:8.1f} m  class {c['class']}  {c['name']}")


def check(path, key, minimum):
    """Assert the emitted file still holds usable rings. Exits non-zero if not.

    This is the check for the quiet failure MAP_HANDOVER.md section 9 warns
    about: a fetcher change that returns no elements, or rings that stopped
    being closed, still passes everything else in the project. Asserts only, no
    framework and no fixtures, and it reads the emitted file rather than the
    cache so it can be run on its own after a fetch.
    """
    with open(path) as f:
        data = json.load(f)
    feats = data.get(key)
    assert isinstance(feats, list), f"{key}: no list in {path} (keys: {list(data)})"
    assert len(feats) >= minimum, f"{key}: {len(feats)} features, want >= {minimum}"
    for feat in feats:
        poly = feat["polygon"]
        oid = feat.get("osm_id")
        assert len(poly) >= 4, f"{key} {oid}: {len(poly)} points, want >= 4"
        assert poly[0] == poly[-1], f"{key} {oid}: ring is not closed"
        twice = 0.0
        for (x1, z1), (x2, z2) in zip(poly, poly[1:]):
            twice += x1 * z2 - x2 * z1
        assert abs(twice) > 2.0, f"{key} {oid}: zero-area ring"
    print(f"  {key}: {len(feats)} rings, all closed")


def check_roads(path):
    """Assert the emitted width table is intact, and still derived from the fetch.

    Three things can go wrong here that nothing downstream would notice, because
    every consumer treats a missing width as "use the class default" and the class
    default is a perfectly good-looking road:

      - the key format drifts between this file and World/road_graph.gd, so the
        graph silently stops finding the table and every street goes back to one
        width. Hence the key is recomputed from the emitted corridors and matched
        both ways, rather than trusted;
      - two corridors collide on one key, so the table is a lookup that can answer
        with the wrong street's width;
      - the table stops matching the source data, e.g. a tag-filter change that
        silently drops every `lanes`. Hence the raw fetch is recounted when it is
        still on disk, which is the only part of this that can catch a fetcher
        quietly returning less than it used to.
    """
    with open(path) as f:
        data = json.load(f)
    table = data.get("width_attrs")
    assert isinstance(table, dict), f"width_attrs: not a dict in {path}"
    cors = data.get("corridors")
    assert isinstance(cors, list) and cors, f"corridors: no list in {path}"
    stats = data.get("stats", {}).get("width", {})

    keys = {}
    for c in cors:
        pts = [(float(p[0]), float(p[1])) for p in c["points"]]
        k = corridor_key(pts)
        assert k not in keys, (f"two corridors share one width key: {keys.get(k)} and "
                              f"{c['name']}")
        keys[k] = c["name"]

    for k, v in table.items():
        assert k in keys, f"width_attrs key matches no corridor: {k[:60]}"
        w = v.get("width_m")
        assert isinstance(w, (int, float)) and MIN_WIDTH_M <= w <= MAX_WIDTH_M, \
            f"{keys[k]}: width {w} outside {MIN_WIDTH_M}-{MAX_WIDTH_M} m"
        assert v.get("src") in ("osm:width", "lanes"), \
            f"{keys[k]}: src {v.get('src')!r} is not a known provenance"
        lanes = v.get("lanes")
        assert lanes is None or 1 <= lanes <= MAX_LANES, \
            f"{keys[k]}: lanes {lanes} outside 1-{MAX_LANES}"

    assert len(table) == stats.get("corridors_with_width"), \
        f"width_attrs has {len(table)} entries, stats claims {stats}"
    assert stats.get("tagged", 0) + stats.get("derived_from_lanes", 0) == len(table), \
        f"tagged+derived {stats} does not add up to {len(table)} entries"
    assert (stats.get("corridors_with_width", 0)
            + stats.get("corridors_on_class_default", 0) == len(cors)), \
        f"width stats {stats} do not add up to {len(cors)} corridors"
    assert (stats.get("tagged", 0) + stats.get("derived_from_lanes", 0)
            + stats.get("dropped_with_width", 0)
            == stats.get("ways_tagged", 0) + stats.get("ways_with_lanes", 0)), \
        f"corridor and way width counts disagree: {stats}"

    if os.path.exists(RAW):
        root = ET.parse(RAW).getroot()
        recount = collections.Counter()
        for el in root:
            if el.tag != "way":
                continue
            tags = {t.get("k"): t.get("v") for t in el.findall("tag")}
            cls = CLASSIFY.get(tags.get("highway"), 0)
            if cls is None or cls == 0:
                continue
            src = width_attr(tags)[2]
            if src:
                recount[src] += 1
        assert recount["osm:width"] == stats.get("ways_tagged", 0), (
            f"raw fetch has {recount['osm:width']} tagged-width ways, emitted "
            f"{stats.get('ways_tagged')}")
        assert recount["lanes"] == stats.get("ways_with_lanes", 0), (
            f"raw fetch has {recount['lanes']} lanes-tagged ways, emitted "
            f"{stats.get('ways_with_lanes')}")
        print(f"  width_attrs: {len(table)} entries match the fetch "
              f"({recount['osm:width']} tagged + {recount['lanes']} lanes ways)")
    else:
        print("  width_attrs: %d entries (raw fetch absent, source not recounted)"
              % len(table))
    print(f"  width_attrs: {stats.get('tagged', 0)} tagged, "
          f"{stats.get('derived_from_lanes', 0)} derived, lanes "
          f"{stats.get('lanes_histogram')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", type=float, nargs=4, metavar=("S", "W", "N", "E"),
                    default=list(CAIRNS_BBOX))
    ap.add_argument("--tolerance", type=float, default=2.5,
                    help="Douglas-Peucker tolerance in metres")
    ap.add_argument("--cache-only", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="assert the emitted buildings/water have usable rings and "
                         "the road width table is intact, then exit without "
                         "fetching or converting")
    a = ap.parse_args()
    if a.check:
        check(OUT_BUILDINGS, "buildings", 1000)
        check(OUT_WATER, "water", 5)
        check_roads(OUT)
        print("EXTRACT-OK")
        return
    if not a.cache_only:
        fetch(tuple(a.bbox))
    convert(tuple(a.bbox), a.tolerance)


if __name__ == "__main__":
    main()
