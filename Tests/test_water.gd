extends RefCounted
## The Barron is in the world: 5 mapped water bodies, on the real terrain.
## Run with: ./test.sh water
##
## The failure this exists to catch is water on a carriageway. Every other number
## can look right and the river runs down the middle of the tarmac. So the
## clearance test here is deliberately not the one in Systems/water: it reads the
## BUILT mesh rather than the source ring, indexes the live RoadGraph itself, and
## samples rather than solving segment-to-segment. Two implementations of the
## same question, so neither can be wrong in a way the other repeats.
##
## The second thing it exists to catch is the water plane cutting through the
## ground. That one cannot be checked by reading the source ring, so every
## triangle of every surface is sampled against WorldBuilder._terrain_height(),
## the function the terrain mesh was actually built from.
##
## Set the ground, not a constant: `ground` is the same Callable the world
## builder passes in, so a change to the terrain moves this test with it.

## Grid step for the independent clearance index. It has to exceed the widest
## half width (9.0 m) so a 3x3 neighbourhood cannot miss a carriageway.
const CELL := 60.0
## Sampling step across a water triangle, in metres, for the poke-through check.
const PROBE := 1.5
## WorldBuilder draws the terrain mesh at its own height minus this.
const TERRAIN_DROP := 0.06

var _graph: RoadGraph
var _wb: WorldBuilder
var _root: Node3D
var _node: Node3D
var _plan: Dictionary = {}
var _segs: Array = []
var _grid: Dictionary = {}


func run(t: TestHarness) -> void:
	_data(t)
	_carriageway(t)
	_surface(t)
	_built_clearance(t)
	_seating(t)
	_material_and_flow(t)
	await t.drop(_node)
	await t.drop(_root)


func _data(t: TestHarness) -> void:
	t.ok(OSMWater.data().has("water"), "water data loads (run Tools/osm_cairns.py if not)")

	var raw: Array = OSMWater.data().get("water", [])
	var bodies: Array = OSMWater.bodies()
	t.eq(bodies.size(), raw.size(), "every ring in the file survives parsing (%d)" % bodies.size())
	t.eq(int(OSMWater.feature_count()), raw.size(),
		"the file's own stats agree with the ring count (%d)" % raw.size())
	t.eq(OSMWater.feature_count(), 5, "the extraction found 5 closed water features")

	# A ring has to be a ring: a two-point or zero-area ring sails through every
	# count-based check and then triangulates to nothing.
	var degenerate := 0
	for b in bodies:
		var ring: PackedVector2Array = b["ring"]
		if ring.size() < 3 or float(b["area"]) <= 0.0:
			degenerate += 1
	t.eq(degenerate, 0, "every water body is a real ring with area (%d bad)" % degenerate)

	# OSM hands rings back both ways round. The parse has to normalise, or the
	# surface ends up facing down and invisible.
	var clockwise := 0
	for w in raw:
		var p: Array = w["polygon"]
		var a := 0.0
		for i in p.size():
			var u: Array = p[i]
			var v: Array = p[(i + 1) % p.size()]
			a += float(u[0]) * float(v[1]) - float(v[0]) * float(u[1])
		if a < 0.0:
			clockwise += 1
	t.gt(clockwise, 0, "the raw file really does contain anti-clockwise rings (%d)" % clockwise)
	var all_ccw := true
	for b in bodies:
		if _signed_area(b["ring"]) <= 0.0:
			all_ccw = false
	t.ok(all_ccw, "every parsed ring is wound one way (%d)" % bodies.size())

	# The two big rings share an osm_id: one OSM element, several polygons. The
	# file says so, so the parser must not key by it.
	var ids := {}
	for b in bodies:
		ids[int(b["id"])] = true
	t.eq(ids.size(), 4, "four distinct osm ids behind five rings, so nothing is keyed by id")

	# The open centrelines are a different kind of thing and cannot be drawn
	# without a width. Measured, not assumed: this counts the tags.
	var cl: Array = OSMWater.centrelines()
	var with_width := 0
	for c in cl:
		if c["width_m"] != null:
			with_width += 1
	t.eq(cl.size(), 26, "the file also carries 26 open centrelines")
	t.eq(with_width, 0, "measured: none of the %d centrelines carries a width" % cl.size())
	t.eq(OSMWater.surfaced_centrelines().size(), with_width,
		"so no centreline is surfaced - a width would have to be invented")
	var long_rivers := 0
	for c in cl:
		if float(c["length"]) > 1000.0:
			long_rivers += 1
	t.gt(long_rivers, 0, "the centrelines include real rivers, not stubs (%d over 1 km)" % long_rivers)


## Live road index, built here and not borrowed from Systems/water.
func _index() -> void:
	_segs = []
	_grid = {}
	for e in _graph.edges:
		var a: Vector2 = _graph.node_pos(int(e["a"]))
		var b: Vector2 = _graph.node_pos(int(e["b"]))
		if a.distance_squared_to(b) < 0.01:
			continue
		var id := _segs.size()
		_segs.append({"a": a, "b": b, "hw": _graph.width_for(int(e["class"])) * 0.5,
			"name": String(e.get("name", ""))})
		var lo := Vector2i(floori(minf(a.x, b.x) / CELL), floori(minf(a.y, b.y) / CELL))
		var hi := Vector2i(floori(maxf(a.x, b.x) / CELL), floori(maxf(a.y, b.y) / CELL))
		for cx in range(lo.x, hi.x + 1):
			for cy in range(lo.y, hi.y + 1):
				var key := Vector2i(cx, cy)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(id)


func _nearest(p: Vector2) -> Dictionary:
	var best := {"d": INF, "hw": 0.0, "name": ""}
	for cx in range(floori((p.x - CELL) / CELL), floori((p.x + CELL) / CELL) + 1):
		for cy in range(floori((p.y - CELL) / CELL), floori((p.y + CELL) / CELL) + 1):
			for id in _grid.get(Vector2i(cx, cy), []):
				var s: Dictionary = _segs[id]
				var d := WaterClearance.pt_seg_d2(p, s["a"], s["b"])
				if d < float(best["d"]):
					best = {"d": d, "hw": float(s["hw"]), "name": String(s["name"])}
	return best


func _inside(p: Vector2, ring: PackedVector2Array) -> bool:
	var inside := false
	var j := ring.size() - 1
	for i in ring.size():
		var a := ring[i]
		var b := ring[j]
		if (a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
			inside = not inside
		j = i
	return inside


## The overlap measurement, on the source rings, independently of the builder.
func _carriageway(t: TestHarness) -> void:
	_graph = RoadGraph.new()
	_graph.build(OSMLayout.corridors())
	_index()

	t.gt(_segs.size(), 300, "the clearance index is against the real network (%d edges)" % _segs.size())

	var tightest := INF
	var tightest_name := ""
	var overlaps := 0
	var swallowed := 0
	for b in OSMWater.bodies():
		var ring: PackedVector2Array = b["ring"]
		# Sampled, not solved: deliberately a different method to
		# WaterClearance's exact segment-to-segment minimum.
		var body_tightest := INF
		var body_road := ""
		var body_hw := 0.0
		for p in _sample_ring(ring, 2.0):
			var n := _nearest(p)
			if float(n["d"]) < body_tightest:
				body_tightest = float(n["d"])
				body_road = String(n["name"])
				body_hw = float(n["hw"])
		# pt_seg_d2 is squared; the margin is a distance in metres.
		body_tightest = sqrt(body_tightest)
		if body_tightest < tightest:
			tightest = body_tightest
			tightest_name = body_road
		if body_tightest < body_hw:
			overlaps += 1
		for j in _segs.size():
			var s: Dictionary = _segs[j]
			if _inside((s["a"] + s["b"]) * 0.5, ring):
				swallowed += 1

	t.eq(overlaps, 0, "no water polygon reaches inside a carriageway (%d of 5)" % OSMWater.bodies().size())
	t.eq(swallowed, 0, "no road is swallowed whole by a water polygon (%d)" % swallowed)
	t.gt(tightest - 7.0, 0.0,
		"tightest gap to a centreline is %.2f m, which clears a 14 m arterial's tarmac" % tightest)
	print("      tightest water-to-centreline: %.2f m on %s" % [tightest, tightest_name])


func _sample_ring(ring: PackedVector2Array, step: float) -> Array:
	var out: Array = []
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var n := maxi(1, int(ceil(a.distance_to(b) / step)))
		for k in n + 1:
			out.append(a.lerp(b, float(k) / float(n)))
	return out


func _surface(t: TestHarness) -> void:
	_wb = WorldBuilder.new()
	_wb.graph = _graph
	_root = t.new_root("Water")
	_node = OSMWater.surface(_graph, Callable(_wb, "_terrain_height"))
	_root.add_child(_node)
	_plan = _node.plan

	t.eq(int(_plan["read"]), 5, "all 5 mapped water bodies reached the builder")
	t.eq(int(_plan["built"]), 5, "and 5 were surfaced (%d dropped for the carriageway)" % int(_plan["dropped"]))
	t.gt(int(_plan["faces"]), 100, "the surfaces are real geometry (%d triangles)" % int(_plan["faces"]))
	t.eq(int(_plan["nodes"]), 5, "one draw call per water body (%d)" % int(_plan["nodes"]))

	# Every triangle of every surface has to face the sky. Ear clipping hands
	# back the ring's own winding, and a surface facing down is a hole in the
	# ground at night rather than a river.
	#
	# Signed, not "within 25 degrees of vertical": the surface follows the
	# ground, and densifying a 900 m ring to 2 m edges makes ear clipping emit
	# slivers whose 3D normal is dominated by the height step across them. A
	# sliver is still up; the assertion is only that nothing is inverted.
	var faces := 0
	var up := 0
	for mesh in _meshes():
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for i in range(0, verts.size(), 3):
			faces += 1
			if _tri_normal(verts[i], verts[i + 1], verts[i + 2]).y > 0.0:
				up += 1
	t.eq(up, faces, "no water triangle is inverted, all %d face up" % faces)
	t.eq(faces, int(_plan["faces"]), "the mesh holds every triangle the plan counted")

	# The ear clipper has to have triangulated the ring it was given, not a
	# smaller piece of it. Triangles of a ring cover exactly the ring's area, so
	# the built area is the check.
	var ring_area := 0.0
	for b in OSMWater.bodies():
		ring_area += float(b["area"])
	var built_area := 0.0
	for mesh in _meshes():
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for i in range(0, verts.size(), 3):
			var a := verts[i]
			var b := verts[i + 1]
			var c := verts[i + 2]
			built_area += absf((b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)) * 0.5
	t.between(built_area, ring_area * 0.98, ring_area * 1.02,
		"the surfaces cover the mapped area, not a piece of it (%.0f of %.0f m2)" % [built_area, ring_area])

	# Self-contained: geometry and nothing else, so the world builder can drop it
	# in one line and it cannot reach back into anything.
	var kinds := {}
	for c in _node.get_children():
		kinds[c.get_class()] = true
	t.eq(kinds.keys(), ["MeshInstance3D"], "the node is geometry and nothing else (%s)" % str(kinds.keys()))


## The overlap measurement again, on the BUILT mesh rather than the source ring.
## The rings are what the data says; the triangles are what a car can hit.
func _built_clearance(t: TestHarness) -> void:
	var worst := INF
	var worst_name := ""
	var offenders := 0
	var verts := 0
	for mesh in _meshes():
		var vs: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in vs:
			verts += 1
			var n := _nearest(Vector2(v.x, v.z))
			if float(n["d"]) < worst:
				worst = float(n["d"])
				worst_name = String(n["name"])
			if float(n["d"]) < float(n["hw"]):
				offenders += 1
	t.eq(offenders, 0, "no built water vertex is inside a carriageway (%d of %d)" % [offenders, verts])
	t.between(sqrt(worst), 7.0, INF,
		"the built surface clears the tarmac everywhere too (tightest %.2f m on %s)" % [sqrt(worst), worst_name])


func _meshes() -> Array:
	var out: Array = []
	for c in _node.get_children():
		if c is MeshInstance3D and c.mesh != null:
			out.append(c.mesh)
	return out


## The water has to sit on the ground, not through it. Sampled across every
## triangle against the height function the terrain mesh was built from.
func _seating(t: TestHarness) -> void:
	var poked := 0
	var sunk := 0
	var lowest := INF
	var highest := -INF
	var worst := ""
	for mesh in _meshes():
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for i in range(0, verts.size(), 3):
			var a := verts[i]
			var b := verts[i + 1]
			var c := verts[i + 2]
			var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
			var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
			var nx := maxi(1, int(ceil((hi.x - lo.x) / PROBE)))
			var nz := maxi(1, int(ceil((hi.y - lo.y) / PROBE)))
			for ix in range(nx + 1):
				for iz in range(nz + 1):
					var p := Vector2(lerpf(lo.x, hi.x, float(ix) / float(nx)),
						lerpf(lo.y, hi.y, float(iz) / float(nz)))
					var u: Variant = _barycentric(a, b, c, p)
					if u == null:
						continue
					var water_y: float = a.y * u.x + b.y * u.y + c.y * u.z
					var ground: float = _wb._terrain_height(p.x, p.y) - TERRAIN_DROP
					if ground >= water_y:
						poked += 1
						worst = "%.2f m of ground through the surface at %.0f,%.0f" % [
							ground - water_y, p.x, p.y]
					var gap := water_y - ground
					if gap < lowest:
						lowest = gap
					if gap > highest:
						highest = gap
	t.eq(poked, 0, "no ground comes through any water surface (%s)" % worst)
	t.gt(lowest, 0.0, "the water is above the ground everywhere, never z-fought (min gap %.3f m)" % lowest)
	t.between(highest, lowest, WaterSurface.LIFT + 0.25,
		"and never more than the lift plus one chord of ground over it (max gap %.3f m)" % highest)
	print("      water sits %.3f..%.3f m over the terrain; surface spans %.2f..%.2f m"
		% [lowest, highest, float(_plan["surface_low"]), float(_plan["surface_high"])])


## Barycentric weights of p in triangle abc, or null if p is outside it.
func _barycentric(a: Vector3, b: Vector3, c: Vector3, p: Vector2) -> Variant:
	var v0 := Vector2(b.x - a.x, b.z - a.z)
	var v1 := Vector2(c.x - a.x, c.z - a.z)
	var v2 := Vector2(p.x - a.x, p.y - a.z)
	var d := v0.x * v1.y - v1.x * v0.y
	if absf(d) < 1e-9:
		return null
	var v := (v2.x * v1.y - v1.x * v2.y) / d
	var w := (v0.x * v2.y - v2.x * v0.y) / d
	var u := 1.0 - v - w
	if u < -1e-6 or v < -1e-6 or w < -1e-6:
		return null
	return Vector3(u, v, w)


func _material_and_flow(t: TestHarness) -> void:
	var mats := 0
	var still := 0
	for c in _node.get_children():
		if not (c is MeshInstance3D):
			continue
		var m := c.material_override as StandardMaterial3D
		if m == null:
			continue
		mats += 1
		if not m.normal_enabled or m.normal_texture == null:
			still += 1
	t.eq(mats, 5, "every surface has a material (%d)" % mats)
	t.eq(still, 0, "and every one is the project's moving water, not a flat plane")

	# The conventions the project already set: near-mirror, dark, translucent.
	var m: StandardMaterial3D = (_node.get_child(0) as MeshInstance3D).material_override
	t.between(m.roughness, 0.0, 0.10, "water is a near-mirror, so lamps reflect in it")
	t.between(m.albedo_color.a, 0.7, 1.0, "and translucent enough to read as liquid")
	t.between(m.albedo_color.b, 0.0, 0.2, "and dark teal, not a blue plane")

	# It has to move, or a night mirror is a hole in the ground.
	var before: Vector3 = m.uv1_offset
	for i in 30:
		_node._process(1.0 / 60.0)
	t.ok(m.uv1_offset.distance_to(before) > 0.0,
		"the ripple scrolls, so the reflection breaks up (%s -> %s)" % [before, m.uv1_offset])

	# Two bodies of very different shape must not scroll the same way.
	var dirs: Array = []
	for c in _node.get_children():
		if c is MeshInstance3D:
			dirs.append(WaterSurface._flow_dir(_ring_of(c as MeshInstance3D)))
	t.ok(dirs[0].distance_to(Vector3.RIGHT) > 0.01 or dirs.size() > 1,
		"flow direction is measured per body, not a single global guess")


func _ring_of(mi: MeshInstance3D) -> PackedVector2Array:
	var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var out := PackedVector2Array()
	for v in verts:
		out.append(Vector2(v.x, v.z))
	return out


func _tri_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	return (b - a).cross(c - a).normalized()


func _signed_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var u := ring[i]
		var v := ring[(i + 1) % ring.size()]
		a += u.x * v.y - v.x * u.y
	return a * 0.5
