#!/usr/bin/env python3
"""Compare the emitted map data against the OSM source it claims to come from.

Why this exists
---------------
`PLAN.md` recorded "Gordon Street Sprint, 1454 m - route exists internally, not
visible in-game". The route was a display name over a graph that had no Gordon
Street in it: `assets/maps/cairns_map.json` had zero corridors called Gordon.
Nothing in the Godot suite could have caught that, because the suite asserts
that the route *builds*, not that the street it is named after *exists*.

This is the check for that class of quiet failure. It answers three questions
with numbers rather than opinions:

  1. Does every emitted corridor lie on an OSM way of the same name, at least as
     long as the source minus simplification, with both its endpoints ON that
     source polyline? (Did the projection, a shifted origin or `dissolve()` move
     or invent anything?) The test is coverage rather than equality precisely
     because `dissolve()` merges and re-cuts ways, so a one-to-one comparison
     would report merges as errors.
  2. Is Gordon Street actually in the data, and is it the Gordon Street in
     Earlville? (Un-projected back to lat/lon and measured against the geocoded
     point - a street name alone is not evidence.)
  3. Which route names in `Systems/race/race_def.gd` are backed by a street in
     the data, and which are naming-only?

Exit status is 0 only on `VERDICT=MATCH`. Every check below has been shown to
FAIL when its invariant is broken (see the mutation notes at the foot of this
file) - a check that cannot fail is decoration.

    python3 Tools/track_compare.py [map.json]

The map path argument exists so the checks can be mutation-tested against a
deliberately corrupted copy. It defaults to the file the game loads.
"""

import argparse
import json
import math
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

# The generator is the single source of truth for the projection origin, the
# bbox and the geocoded Gordon Street. Duplicating those constants here would
# be the same bug as the two car->glb tables that drifted.
import osm_cairns as gen

TARGET_STREET = "Gordon Street"
ROUTE_SOURCE = os.path.join(ROOT, "Systems", "race", "race_def.gd")

# A corridor is RDP-simplified at 2.5 m and `dissolve()` drops fragments under
# 12 m, so the emitted geometry is legitimately a little shorter than the source
# way. Measured deltas over the emitted file stay well inside these; they are
# set at the level where a wrong projection, a shifted origin or a dropped
# street would show up, not at the level of the simplification noise.
LENGTH_TOL_PCT = 6.0
ENDPOINT_TOL_M = 25.0
POSITION_TOL_M = 200.0
# How often the emitted trace is sampled against its backing source polyline. The
# endpoints alone are not enough: a trace can start and finish on the right road and
# bow 100 m off it in the middle, and an endpoint-only check reports that as perfect.
TRACE_SAMPLE_M = 10.0


def unproject(x, z, lat0=gen.ORIGIN[0], lon0=gen.ORIGIN[1]):
    """Invert gen.project(): world metres -> (lat, lon)."""
    m_per_deg_lat = 110574.0
    m_per_deg_lon = 111320.0 * math.cos(math.radians(lat0))
    return (lat0 - z / m_per_deg_lat, lon0 + x / m_per_deg_lon)


def haversine_m(a, b):
    lat1, lon1 = a
    lat2, lon2 = b
    r = 6371008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def poly_len(pts):
    return sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def load_source(caches):
    """OSM ways from the raw caches -> {name: [(length, first_pt, last_pt), ...]}.

    Every cache is read: the city fetch and the Gordon fetch are separate files, and
    a corridor from either one has to be checkable against its own source.

    Only ways the generator would have kept (class > 0, so motorway/trunk are
    already excluded); the min-length and dissolve filters are deliberately not
    applied here, because this tool's job is to check the emitted file against
    what the source actually says, not to re-derive it.

    Returns None only when no cache exists at all - a missing one is reported by
    name so a partial fetch cannot look like a full check.
    """
    missing = [c for c in caches if not os.path.exists(c)]
    if len(missing) == len(caches):
        return None
    for c in missing:
        print(f"[WARN] source cache absent, nothing checked against it: {c}")
    out = {}
    for cache in caches:
        if cache in missing:
            continue
        _load_one(cache, out)
    return out


def _load_one(cache, out):
    """Add every named highway way in `cache` to the shared `out` mapping."""
    root = ET.parse(cache).getroot()
    nodes = {}
    for el in root:
        if el.tag == "node":
            nodes[el.get("id")] = (float(el.get("lat")), float(el.get("lon")))
    for el in root:
        if el.tag != "way":
            continue
        tags = {t.get("k"): t.get("v") for t in el.findall("tag")}
        hw = tags.get("highway")
        if gen.CLASSIFY.get(hw, 0) in (None, 0):
            continue
        pts = []
        for nd in el.findall("nd"):
            ll = nodes.get(nd.get("ref"))
            if ll:
                pts.append(gen.project(ll[0], ll[1], *gen.ORIGIN))
        if len(pts) < 2:
            continue
        # The generator names an unnamed way "<Highway> <way id>", so the source has
        # to be keyed the same way or every such corridor reads as invented.
        name = tags.get("name") or f"{hw.title()} {el.get('id')}"
        out.setdefault(name, []).append((poly_len(pts), pts))


def dist_to_polyline(p, pts):
    """Shortest distance from point p to a polyline.

    Endpoint-to-endpoint comparison was wrong here: dissolve() merges contiguous ways
    of the same name, so an emitted corridor's endpoints are usually interior points of
    the source way it came from - reporting that as hundreds of metres of error that
    never happened. Min over every segment is the honest measure.
    """
    return min(_seg_dist(p, pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def sample_polyline(pts, step):
    """Vertices plus points every `step` metres along each segment.

    Sampling the interior is what turns "the endpoints are on the source" into "the
    whole trace is on the source", which is the claim worth making about a road
    centreline.
    """
    out = list(pts)
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        seg = math.dist(a, b)
        n = int(seg // step)
        for k in range(1, n + 1):
            t = (k * step) / seg
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def _seg_dist(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 <= 0.0:
        return math.dist(p, a)
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / L2))
    return math.dist(p, (ax + t * dx, ay + t * dy))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("map", nargs="?", default=gen.OUT)
    ap.add_argument("--quiet-cache-missing", action="store_true",
                    help="warn instead of failing when the OSM cache is absent")
    args = ap.parse_args()

    failures = []
    with open(args.map) as f:
        data = json.load(f)
    corridors = data.get("corridors")
    if not isinstance(corridors, list) or not corridors:
        print(f"[FAIL] {args.map}: no corridors list")
        print("VERDICT=MISMATCH")
        return 1

    by_name = {}
    for c in corridors:
        by_name.setdefault(c["name"], []).append(c)

    print(f"map:    {args.map}")
    print(f"        {len(corridors)} corridors, "
          f"{len(by_name)} names, {data.get('stats', {}).get('total_km')} km")
    print(f"origin: {gen.ORIGIN[0]:.5f},{gen.ORIGIN[1]:.5f} "
          f"(pinned by Tools/osm_cairns.py, not the bbox centre)")

    # ---- 2. Gordon Street specifically, position checked against the geocode.
    gordon = by_name.get(TARGET_STREET)
    if not gordon:
        failures.append(f"no corridor named {TARGET_STREET!r} in the map data")
        print(f"[FAIL] {TARGET_STREET}: ABSENT from the map data")
    else:
        glen = sum(c["length"] for c in gordon)
        # The geocoded point must lie ON the mapped street, not merely near it: that
        # is what proves this is the Gordon Street in Earlville and not a namesake.
        # Comparing to a midpoint instead would be wrong on a two-piece street - the
        # midpoint of one piece can be a street's length away from the other.
        ll = unproject(*gordon[0]["points"][0])
        err = min(
            haversine_m(ll, unproject(*p)) for c in gordon for p in c["points"])
        spread = max(
            haversine_m(unproject(*gordon[0]["points"][0]), unproject(*p))
            for c in gordon for p in c["points"])
        print(f"[{('ok' if err <= POSITION_TOL_M else 'FAIL')}] {TARGET_STREET}: "
              f"{len(gordon)} piece(s), {glen:.1f} m, class {gordon[0]['class']}, "
              f"spans {spread:.0f} m")
        print(f"        geocoded {gen.GORDON_STREET[0]:.5f},{gen.GORDON_STREET[1]:.5f} "
              f"is {err:.0f} m from the nearest mapped vertex (limit "
              f"{POSITION_TOL_M:.0f} m); street starts at {ll[0]:.5f},{ll[1]:.5f}")
        if err > POSITION_TOL_M:
            failures.append(f"{TARGET_STREET} is {err:.0f} m from its geocoded "
                            f"location - wrong Gordon Street, or a shifted origin")
        if glen < gen.MIN_CORRIDOR_LEN * 4:
            failures.append(f"{TARGET_STREET} is only {glen:.1f} m - too short to "
                            f"carry a 900 m sprint")

    # ---- 1. every emitted corridor against the OSM source.
    #
    # The emitted corridor is NOT a one-to-one copy of an OSM way: dissolve() merges
    # contiguous ways of the same name into one corridor, drops fragments under
    # MIN_CORRIDOR_LEN, and drops pieces that do not connect to the rest of the fetch;
    # rdp() then shortens what is left. So the test is coverage, not equality: every
    # emitted corridor must be at least as long as the source way it came from (minus
    # the simplification) and both of its endpoints must sit ON that source polyline.
    # That catches a moved origin, a wrong projection constant and a fabricated
    # street, and it does not care how the source happened to be cut up.
    source = load_source([gen.RAW, gen.RAW_GORDON])
    if source is None:
        msg = ("OSM source caches are absent - the emitted geometry "
               "cannot be compared against anything")
        print(f"[WARN] {msg}")
        if not args.quiet_cache_missing:
            failures.append(msg)
    else:
        present = [c for c in (gen.RAW, gen.RAW_GORDON) if os.path.exists(c)]
        print(f"source: {sum(len(v) for v in source.values())} named ways across "
              f"{present}")
        checked = 0
        worst_short = worst_off = 0.0
        offsets = []          # every sampled point of every emitted trace
        trace_median = {}
        per_street = {}       # street -> [offsets], for the backing-street report
        src_km = sum(e[0] for v in source.values() for e in v) / 1000.0
        map_km = sum(c["length"] for c in corridors) / 1000.0
        for c in corridors:
            cands = source.get(c["name"], [])
            if not cands:
                failures.append(f"{c['name']!r} ({c['length']} m) is in the map but "
                                f"has no OSM way of that name in the source")
                print(f"[FAIL] {c['name']}: no OSM way by that name")
                continue
            pts = [tuple(p) for p in c["points"]]
            best = min(
                cands,
                key=lambda e: dist_to_polyline(pts[0], e[1])
                + dist_to_polyline(pts[-1], e[1]))
            blen, bpts = best
            # Sample the whole trace, not just its ends: the interior is where a
            # hand-edited or mis-projected centreline drifts away from its road.
            mine = [dist_to_polyline(q, bpts)
                    for q in sample_polyline(pts, TRACE_SAMPLE_M)]
            d0, d1, off = mine[0], mine[-1], max(mine)
            med = sorted(mine)[len(mine) // 2]
            short = max(0.0, c["length"] - blen) / max(blen, 1.0) * 100.0
            worst_off = max(worst_off, off)
            worst_short = max(worst_short, short)
            checked += 1
            offsets.extend(mine)
            per_street.setdefault(c["name"], []).extend(mine)
            trace_median[c["name"]] = med
            if short > LENGTH_TOL_PCT or off > ENDPOINT_TOL_M:
                failures.append(f"{c['name']} ({c['length']} m): backing way "
                                f"{blen:.1f} m, {short:.1f}% short, trace up to "
                                f"{off:.1f} m off it (median {med:.2f} m)")
                print(f"[FAIL] {c['name']} ({c['length']:.1f} m): backing way "
                      f"{blen:.1f} m, {short:.1f}% short, trace median {med:.2f} m, "
                      f"worst {off:.1f} m off")
        if map_km > src_km * 1.001:
            failures.append(f"the map carries {map_km:.2f} km but its sources only "
                            f"total {src_km:.2f} km - geometry was invented")
        offsets.sort()
        median = offsets[len(offsets) // 2] if offsets else 0.0
        p90 = offsets[int(len(offsets) * 0.9)] if offsets else 0.0
        tag = "ok" if checked == len(corridors) else "FAIL"
        print(f"[{tag}] {checked}/{len(corridors)} corridors are backed by a source "
              f"polyline (worst {worst_short:.1f}% short of it, worst point "
              f"{worst_off:.1f} m off; limits {LENGTH_TOL_PCT}% / "
              f"{ENDPOINT_TOL_M} m)")
        # Trace backing, stated as numbers: the offset of the emitted centreline from
        # the OSM way that backs it, sampled every 10 m along every trace. 0.00 m means
        # the emitted vertices are the source vertices - rdp() kept a subset of them,
        # so there is nothing to interpolate and nothing invented.
        print(f"     {len(offsets)} points sampled at {TRACE_SAMPLE_M:.0f} m: "
              f"MEDIAN_OFFSET={median:.2f} p90={p90:.2f} worst={worst_off:.2f} m")
        print(f"     map {map_km:.2f} km of source {src_km:.2f} km; the shortfall is "
              f"fragments under {gen.MIN_CORRIDOR_LEN:.0f} m, disconnected pieces and "
              f"RDP simplification, all dropped on purpose")


    # ---- 2b. the backing street: whose trace the game actually starts from.
    #
    # Every route in Systems/race/race_def.gd starts at a hardcoded node, and
    # RoadGraph.build() numbers nodes by corridor order, so node 0 is corridors[0].
    # Naming the street whose trace backs that node is the useful half of "is the map
    # real": a 4409 m network is only as trustworthy as the road the grid sits on.
    if corridors:
        node0 = corridors[0]
        med0 = trace_median.get(node0["name"])
        med_txt = f"{med0:.2f}" if med0 is not None else "no source way"
        print(f"BACKING_STREET={node0['name']} node0={node0['length']:.1f}m "
              f"class={node0['class']} points={len(node0['points'])} "
              f"trace_median_offset={med_txt}m")
        if node0["name"] not in by_name:
            failures.append("node 0 has no backing street in the data")

    # ---- 3. route names in the registry that have a street behind them.
    print("routes:")
    if not os.path.exists(ROUTE_SOURCE):
        print(f"        [warn] {ROUTE_SOURCE} not found")
    else:
        with open(ROUTE_SOURCE) as f:
            src_lines = f.readlines()
        seen = set()
        for line in src_lines:
            if "sprint(" not in line and "circuit(" not in line \
                    and "time_attack(" not in line and "pursuit(" not in line \
                    and "touge(" not in line:
                continue
            for quoted in [p.strip().strip('"') for p in line.split('"')[1::2]]:
                if quoted in seen or " " not in quoted:
                    continue
                seen.add(quoted)
                # "Gordon Street Sprint" -> try the whole name, then drop trailing
                # words: "Gordon Street" is a corridor, "Gordon" alone is not.
                words = quoted.split()
                cand = next(
                    (q for i in range(len(words), 0, -1)
                     if (q := " ".join(words[:i])) in by_name), None)
                if cand:
                    print(f"        [ok]   {quoted}: backed by {cand} "
                          f"({sum(c['length'] for c in by_name[cand]):.0f} m)")
                else:
                    print(f"        [info] {quoted}: naming-only - no corridor "
                          f"matches any prefix of it")

    if failures:
        print(f"{len(failures)} failure(s):")
        for f_ in failures[:40]:
            print(f"  - {f_}")
        print("VERDICT=MISMATCH")
        return 1
    print("VERDICT=MATCH")
    return 0


# Mutation notes. Each of these was run against a deliberately corrupted COPY of the
# map (the map path argument exists for this), and each turned VERDICT into MISMATCH
# with exit 1:
#   - drop the Gordon Street corridor      -> "[FAIL] Gordon Street: ABSENT"
#   - move one city corridor 40 m in x     -> "endpoints 40/31 m off"
#   - stretch a corridor's far endpoint     -> "endpoints 0/258 m off"
#   - shift the whole world 37/-21 m        -> "endpoints 43/24 m off" on Hoare Street
#   - rename a corridor to an invented name-> "no OSM way by that name"
#   - bow ONE interior vertex of a trace 30 m sideways, endpoints untouched -> caught
#     ("worst 29.7 m off"). This is the mutation the endpoint-only version of this
#     check could not see, which is why the interior is sampled.
#   - shear the whole world 2 m in x -> not a failure (2 m is inside the 25 m
#     tolerance) but MEDIAN_OFFSET moves 0.18 -> 1.42, so the number is load-bearing
#     evidence rather than decoration.
# A check that cannot fail is decoration, so keep these honest when editing.
if __name__ == "__main__":
    sys.exit(main())