class_name WaterClearance
extends RefCounted
## Does a mapped water polygon come inside a mapped carriageway?
##
## This is a data question, not a geometry question, and it is the one thing in
## this system that has an answer that is not a visual preference. OSM maps water
## against the bank and the road network is built from centrelines, so a lake
## ring can easily straddle a street. Water that overlaps a carriageway is a
## stream running down the middle of the tarmac, and no amount of geometry
## fixes it - it means the two layers of the extraction disagree.
##
## So this measures it and says so, rather than clipping the water back out of
## the way and pretending the overlap was not there. `report()` returns signed
## margins: negative means the water is inside that band.
##
## Deliberately not read from WorldBuilder. That file is being edited next door,
## and the two constants below are the only WorldBuilder numbers involved, kept
## here so a rename there cannot take this class down with it.
##
## Two bands, because they are different failures:
##   tarmac - the carriageway proper, at the centreline's half width.
##   kerb    - plus the 0.5 m setback WorldBuilder puts the kerb face at. A
##             water edge inside this band does not drive over the water, but it
##             does put a kerb in a river, and reads as one.
const KERB_SETBACK := 0.5
## Road segments in a uniform grid, keyed by cell. A water ring is 900 m long
## and there are 401 road edges, so the bbox of the ring is the query and the
## answer is exact: nothing outside that bbox can be nearer than what is in it.
const CELL := 64.0


## Every road edge as a segment with its half-width, in a uniform grid.
static func road_index(graph: RoadGraph) -> Dictionary:
	var segs: Array = []
	var grid: Dictionary = {}
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		if a.distance_squared_to(b) < 0.01:
			continue
		var id := segs.size()
		segs.append({
			"a": a, "b": b,
			"hw": graph.width_for(int(e["class"])) * 0.5,
			"name": String(e.get("name", "")),
		})
		var lo := Vector2i(floori(minf(a.x, b.x) / CELL), floori(minf(a.y, b.y) / CELL))
		var hi := Vector2i(floori(maxf(a.x, b.x) / CELL), floori(maxf(a.y, b.y) / CELL))
		for cx in range(lo.x, hi.x + 1):
			for cy in range(lo.y, hi.y + 1):
				var key := Vector2i(cx, cy)
				if not grid.has(key):
					grid[key] = []
				grid[key].append(id)
	return {"segs": segs, "grid": grid}


## How close a water ring comes to a carriageway, and whether it gets there.
## Ring-to-centreline distance is segment-to-segment, not sampled: the tightest
## margin found in this map is under a metre, and a sampled polyline would move
## that number by more than the margin it is reporting.
##
## Returns:
##   d              metres from the ring to the nearest centreline (INF if none)
##   hw             that road's half width
##   tarmac         d - hw, negative if the water is on the carriageway
##   kerb           d - (hw + KERB_SETBACK), negative if the kerb is in the water
##   name           the street that was closest
##   swallowed      road edges with their midpoint inside the ring
static func report(ring: PackedVector2Array, roads: Dictionary) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in ring:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))

	var cand: Array = []
	var grid: Dictionary = roads["grid"]
	for cx in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
		for cy in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
			for id in grid.get(Vector2i(cx, cy), []):
				if not cand.has(id):
					cand.append(id)

	var segs: Array = roads["segs"]
	var best := INF
	var worst := -1
	var n := ring.size()
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		for j in cand:
			var s: Dictionary = segs[j]
			var d2: float = seg_seg_d2(a, b, s["a"], s["b"])
			if d2 < best:
				best = d2
				worst = j

	# A road the ring swallows whole has no near point at all: the ring passes
	# outside the centreline on both sides, so the minimum above can be large
	# while the water is still sitting on top of the street.
	var swallowed := 0
	for j in cand:
		var s: Dictionary = segs[j]
		if point_in_ring((s["a"] + s["b"]) * 0.5, ring):
			swallowed += 1

	var d := INF if worst < 0 else sqrt(best)
	var hw := 0.0
	var name := ""
	if worst >= 0:
		hw = float(segs[worst]["hw"])
		name = String(segs[worst]["name"])
	return {
		"d": d,
		"hw": hw,
		"tarmac": d - hw,
		"kerb": d - (hw + KERB_SETBACK),
		"name": name,
		"swallowed": swallowed,
		"clear": swallowed == 0 and d >= hw + KERB_SETBACK,
	}


## Convenience: the report for every body in `bodies`, plus the tightest margin
## in the file, which is the number worth putting in a handover.
static func report_all(bodies: Array, graph: RoadGraph) -> Dictionary:
	var roads := road_index(graph)
	var rows: Array = []
	var tightest := INF
	for b in bodies:
		var r := report(b["ring"], roads)
		r["id"] = b["id"]
		r["area"] = b["area"]
		if float(r["tarmac"]) < tightest:
			tightest = float(r["tarmac"])
		rows.append(r)
	return {"rows": rows, "tightest_tarmac": tightest, "segments": roads["segs"].size()}


# ------------------------------------------------------------------ geometry

## Squared distance between two 2D segments, exact. Zero if they cross.
static func seg_seg_d2(p1: Vector2, p2: Vector2, q1: Vector2, q2: Vector2) -> float:
	var d1 := _orient(q1, q2, p1)
	var d2 := _orient(q1, q2, p2)
	var d3 := _orient(p1, p2, q1)
	var d4 := _orient(p1, p2, q2)
	if ((d1 > 0.0) != (d2 > 0.0)) and ((d3 > 0.0) != (d4 > 0.0)):
		return 0.0
	if absf(d1) <= EPS and _on_segment(q1, q2, p1):
		return 0.0
	if absf(d2) <= EPS and _on_segment(q1, q2, p2):
		return 0.0
	if absf(d3) <= EPS and _on_segment(p1, p2, q1):
		return 0.0
	if absf(d4) <= EPS and _on_segment(p1, p2, q2):
		return 0.0
	return minf(
		minf(pt_seg_d2(p1, q1, q2), pt_seg_d2(p2, q1, q2)),
		minf(pt_seg_d2(q1, p1, p2), pt_seg_d2(q2, p1, p2)))


const EPS := 1e-9


static func pt_seg_d2(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 <= 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)


static func _orient(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


static func _on_segment(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return p.x >= minf(a.x, b.x) - EPS and p.x <= maxf(a.x, b.x) + EPS \
		and p.y >= minf(a.y, b.y) - EPS and p.y <= maxf(a.y, b.y) + EPS


## Crossing number, so the answer does not depend on which way the ring is wound.
static func point_in_ring(p: Vector2, ring: PackedVector2Array) -> bool:
	var inside := false
	var n := ring.size()
	var j := n - 1
	for i in n:
		var a := ring[i]
		var b := ring[j]
		if (a.y > p.y) != (b.y > p.y) \
				and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
			inside = not inside
		j = i
	return inside
