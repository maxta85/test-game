extends RefCounted
## The city is 2198 real OpenStreetMap footprints, not generated boxes.
## Run with: ./test.sh osm
##
## The failure this exists to catch is a footprint overlapping a carriageway. Every
## other number looks right and the car drives through a wall. So the clearance
## check here is deliberately independent of the one in World/osm_buildings.gd: it
## builds its own spatial index off the live RoadGraph and samples along every
## ring edge, rather than asking the builder whether it did its job.
##
## It also runs the same check over the *unclipped* footprints, so the assertion
## cannot pass for want of anything to test.

## Grid size for the clearance index. The 3x3 neighbourhood `_clear_at` reads
## reaches CELL in every direction, and a point that violates the clearance is by
## definition within half_width + CLEARANCE (11.4 m at the widest) of a road, so
## the neighbourhood cannot miss one.
const CELL := 60.0

static var _graph: RoadGraph
static var _report: Dictionary
static var _parent: Node3D
static var _source: Dictionary = {}
static var _edges: Array = []
static var _grid: Dictionary = {}


func run(t: TestHarness) -> void:
	_data(t)
	_geometry(t)
	_road_clearance(t)
	_heights(t)
	await t.drop(_parent)


func _data(t: TestHarness) -> void:
	t.ok(OSMBuildings.data().has("buildings"), "building footprints load (run Tools/osm_cairns.py if not)")

	var raw: Array = OSMBuildings.data().get("buildings", [])
	var fps: Array = OSMBuildings.footprints()
	t.gt(raw.size(), 2000, "the file has real footprints in it (%d)" % raw.size())
	t.eq(fps.size(), raw.size(), "every ring in the file survives parsing (%d)" % fps.size())
	t.eq(int(OSMBuildings.data().get("stats", {}).get("buildings", 0)), raw.size(),
		"the file's own stats agree with the ring count")

	# A ring has to be a ring. A two-point or zero-area ring sails through every
	# count-based check and then extrudes to nothing.
	var degenerate := 0
	for b in fps:
		var ring: PackedVector2Array = b["ring"]
		if ring.size() < 3 or float(b["area"]) <= 0.0:
			degenerate += 1
		_source[int(b["id"])] = b
	t.eq(degenerate, 0, "every footprint is a real ring with area (%d bad)" % degenerate)

	# OSM hands rings back both ways round; 199 of these arrive clockwise and would
	# otherwise extrude inside out. So the parse has to normalise, not assume.
	var clockwise := 0
	for b in raw:
		var p: Array = b["polygon"]
		var a := 0.0
		for i in p.size():
			var u: Array = p[i]
			var v: Array = p[(i + 1) % p.size()]
			a += float(u[0]) * float(v[1]) - float(v[0]) * float(u[1])
		if a < 0.0:
			clockwise += 1
	t.gt(clockwise, 0, "the raw file really does contain clockwise rings (%d)" % clockwise)
	var ccw := 0
	for b in fps:
		if float(b["area"]) > 0.0:
			ccw += 1
	t.eq(ccw, fps.size(), "every parsed ring was wound the same way (%d)" % ccw)

	_graph = RoadGraph.new()
	_graph.build(OSMLayout.corridors())
	_parent = t.new_root("OSMBuildings")
	_report = OSMBuildings.build(_parent, _graph)
	t.gt(int(_report["built"]), 2000, "the plan kept the city (%d built)" % int(_report["built"]))
	t.eq(int(_report["built"]) + int(_report["dropped"]), int(_report["read"]),
		"every footprint is either built or dropped, none lost (%d + %d = %d)"
		% [int(_report["built"]), int(_report["dropped"]), int(_report["read"])])


## Headless, with no display, and cheap: the whole city is a dozen draw calls, not
## one per building, which is the only reason 2198 of them is affordable at all.
func _geometry(t: TestHarness) -> void:
	var nodes := 0
	var verts := 0
	var faces := 0
	var materials := {}
	for child in _parent.get_children():
		nodes += 1
		var mesh: ArrayMesh = null
		var mat: Material = null
		if child is MultiMeshInstance3D:
			var mm: MultiMesh = (child as MultiMeshInstance3D).multimesh
			t.ok(mm != null and mm.mesh != null, "%s has a mesh" % child.name)
			mesh = mm.mesh if mm != null else null
			mat = (child as MultiMeshInstance3D).material_override
			verts += mesh.surface_get_array_len(0) * maxi(mm.instance_count, 0)
			faces += mesh.get_faces().size() / 3 * maxi(mm.instance_count, 0)
		elif child is MeshInstance3D:
			mesh = (child as MeshInstance3D).mesh
			mat = (child as MeshInstance3D).material_override
			t.ok(mesh != null and mesh.get_surface_count() > 0, "%s has a surface" % child.name)
			verts += mesh.surface_get_array_len(0)
			faces += mesh.get_faces().size() / 3
		else:
			t.ok(false, "unexpected child %s under the building node" % child.name)
			continue
		materials[mat] = true

	t.gt(nodes, 4, "the city is batched, not one node per building (%d nodes)" % nodes)
	t.ok(nodes <= 12, "2198 buildings cost at most a dozen draw calls (%d)" % nodes)
	t.ok(materials.size() <= nodes, "materials are shared between batches (%d for %d nodes)"
		% [materials.size(), nodes])
	t.gt(verts, 60000, "real geometry came out, not empty surfaces (%d vertices)" % verts)
	t.gt(faces, 20000, "the city is triangulated (%d faces)" % faces)
	t.gt(int(_report["stumps"]), 2000, "the flood plain is stood on stumps (%d)" % int(_report["stumps"]))


## The one that has to hold. Checked against the live graph, not against what the
## builder believed.
func _road_clearance(t: TestHarness) -> void:
	var worst := INF
	var worst_id := 0
	var checked := 0
	for b in _report["buildings"]:
		var w: float = _worst_clearance(b["ring"])
		checked += 1
		if w < worst:
			worst = w
			worst_id = int(b["id"])
	t.eq(checked, int(_report["built"]), "every planned building was checked (%d)" % checked)
	t.ok(worst >= 0.0, "no building polygon overlaps a road corridor (worst %.2f m clear, osm %d)"
		% [worst, worst_id])

	# Non-vacuity. If the raw footprints pass this too, the assertion above is
	# measuring nothing - and they must not pass, because OSM maps buildings
	# against kerbs and this network is built from centrelines.
	var raw_bad := 0
	var raw_worst := INF
	for b in OSMBuildings.footprints():
		var w: float = _worst_clearance(b["ring"])
		raw_worst = minf(raw_worst, w)
		if w < 0.0:
			raw_bad += 1
	t.gt(raw_bad, 0, "the raw file really does put buildings in the road (%d do, worst %.2f m)"
		% [raw_bad, raw_worst])
	t.gt(int(_report["clipped"]) + int(_report["dropped"]), 0,
		"so the builder fixed them (%d clipped, %d dropped)"
		% [int(_report["clipped"]), int(_report["dropped"])])

	# The authoritative cross-check, through the API the brief names, on the rings
	# the builder had to move. `lateral` is the distance to the nearest road
	# centreline and half that road's width is the carriageway.
	var verified := 0
	for b in _report["buildings"]:
		if not _moved(b):
			continue
		for p in b["ring"]:
			var nr: Dictionary = _graph.nearest_road(Vector3(p.x, 0.0, p.y))
			var half: float = _graph.width_for(int(_graph.edges[int(nr["edge"])]["class"])) * 0.5
			t.ok(float(nr["lateral"]) - half >= OSMBuildings.CLEARANCE - 0.01,
				"moved footprint %d is clear of the carriageway (%.2f m from centreline, half-width %.1f m)"
				% [int(b["id"]), float(nr["lateral"]), half])
			verified += 1
	t.gt(verified, 0, "at least one footprint was moved and re-checked (%d vertices)" % verified)


## Whether the builder shifted this footprint from the ring in the file.
static func _moved(entry: Dictionary) -> bool:
	var was: PackedVector2Array = _source[int(entry["id"])]["ring"]
	var now: PackedVector2Array = entry["ring"]
	if was.size() != now.size():
		return true
	for i in was.size():
		if not was[i].is_equal_approx(now[i]):
			return true
	return false


## Smallest (distance to a road centreline - that road's half-width - CLEARANCE)
## over a ring, sampled along every edge. Negative means it is in the road.
##
## ponytail: 3 m sampling, not an exact clip. A clearance that is checked at
## every vertex and no worse than a 3 m midspan is a clearance; anything tighter
## and this becomes a polygon boolean. The rings the builder actually moved are
## checked vertex by vertex through RoadGraph.nearest_road() regardless.
##
## Built here rather than borrowed from OSMBuildings so a bug in the builder's own
## geometry cannot hide behind itself.
static func _worst_clearance(ring: PackedVector2Array) -> float:
	var worst := INF
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var span: float = a.distance_to(b)
		var steps: int = maxi(int(span / 3.0), 1)
		for s in steps + 1:
			worst = minf(worst, _clear_at(a.lerp(b, float(s) / float(steps))))
	return worst


## Clearance at one point against every road edge near it.
##
## `RoadGraph.nearest_road()` is the obvious call and is far too slow here: it
## scans all 401 network edges for every sampled point, and there are tens of
## thousands of those. The index below is built from the graph's own edges and its
## own per-class widths, so the answer is still the real network's, just without
## the scan - and the rings the builder actually moved are then re-checked through
## `nearest_road()` itself, further up.
static func _clear_at(p: Vector2) -> float:
	if _grid.is_empty():
		_index()
	var best := INF
	var cx := floori(p.x / CELL)
	var cy := floori(p.y / CELL)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for id in _grid.get(Vector2i(cx + int(dx), cy + int(dy)), []):
				var e: Dictionary = _edges[id]
				var a: Vector2 = e["a"]
				var b: Vector2 = e["b"]
				var u := b - a
				var l2: float = u.length_squared()
				var t: float = 0.0 if l2 < 1e-9 else clampf((p - a).dot(u) / l2, 0.0, 1.0)
				best = minf(best, p.distance_to(a + u * t) - float(e["hw"]))
	return best - OSMBuildings.CLEARANCE


static func _index() -> void:
	for e in _graph.edges:
		var a: Vector2 = _graph.node_pos(int(e["a"]))
		var b: Vector2 = _graph.node_pos(int(e["b"]))
		if a.distance_squared_to(b) < 0.01:
			continue
		var id := _edges.size()
		_edges.append({"a": a, "b": b, "hw": _graph.width_for(int(e["class"])) * 0.5})
		var lo := Vector2i(floori(minf(a.x, b.x) / CELL), floori(minf(a.y, b.y) / CELL))
		var hi := Vector2i(floori(maxf(a.x, b.x) / CELL), floori(maxf(a.y, b.y) / CELL))
		for cx in range(lo.x, hi.x + 1):
			for cy in range(lo.y, hi.y + 1):
				var key := Vector2i(cx, cy)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(id)


## Cairns low-rise: a Queenslander is about 3 m to the eaves on half a metre of
## stump, a shop 4-6 m, and the stadium in this file is twice that. What must not
## happen is a city of identical boxes, which is what the generated buildings were.
func _heights(t: TestHarness) -> void:
	var lo := INF
	var hi := -INF
	var distinct := {}
	var stilts := 0
	var pitched := 0
	var flat := 0
	var tagged := 0
	for b in _report["buildings"]:
		var wall: float = b["wall"]
		lo = minf(lo, wall)
		hi = maxf(hi, wall)
		distinct[snappedf(wall, 0.01)] = true
		if float(b["lift"]) > 0.2:
			stilts += 1
		if bool(b["flat"]):
			flat += 1
		else:
			pitched += 1
		var src: Dictionary = _source[int(b["id"])]
		if src["height_m"] != null:
			tagged += 1
			t.near(wall, float(src["height_m"]), 0.001, "tagged building:levels wins for osm %d"
				% int(b["id"]))
	t.between(lo, 2.4, 24.0, "shortest wall is a building, not a wall segment (%.2f m)" % lo)
	t.between(hi, 3.0, 24.0, "tallest wall is low-rise (%.2f m)" % hi)
	t.gt(distinct.size(), 20, "heights are not all identical (%d distinct eave heights)" % distinct.size())
	t.gt(stilts, 1500, "the flood plain is stood on stumps (%d raised)" % stilts)
	t.eq(stilts, pitched, "only the pitched-roof buildings are raised (%d of %d)" % [stilts, pitched])
	t.gt(flat, 20, "the big footprints get flat roofs and parapets (%d)" % flat)

	# Counted from the file rather than written down, so a data refresh that adds
	# or loses a levels tag is a pass, not a tripwire - but an empty set is not.
	var want := 0
	for id in _source:
		if _source[id]["height_m"] != null:
			want += 1
	t.gt(want, 0, "the file has building:levels tags worth respecting (%d)" % want)
	t.eq(tagged, want, "every tagged height reached the geometry (%d)" % tagged)
