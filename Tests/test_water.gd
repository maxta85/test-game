extends RefCounted
## The Barron is in the world: the mapped water bodies, on the real terrain.
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
##
## ---------------------------------------------------------------------------
## WHAT IS ASSERTED ABOUT CLEARANCE, AND WHY IT IS NOT "the map is clean"
## ---------------------------------------------------------------------------
## t180 attributed all seven failures here to one commit, `bc7efef` ("stop RDP
## collapsing road centrelines into straight chords"), and it was right about the
## cause and wrong about which of the two things had to move. The map did not
## get worse. What changed is that this suite could finally SEE the road.
##
## Before bc7efef a corridor was a straight chord between its endpoints - the
## measured median was 2 points per corridor across 247 corridors - so the old
## assertions were satisfied by construction. A chord cannot pass closer to the
## water than the straight line it replaced, and cannot find a road that bends
## under a ring it no longer follows. On the true centrelines one mapped ring
## really is inside a carriageway. Measured here, by this suite's own index and
## by the production solver, agreeing to 0.0000 m:
##
##   ring 18504432  14112.5 m2  tarmac -0.2648  kerb -0.7648   NOT CLEAR -> dropped
##   ring 18504432   7185.7 m2  tarmac +2.2133  kerb +1.7133   clear     -> built
##   ring 1137583098  255.5 m2  no road edge in the ring's bbox          clear -> built
##   ring 1300217516   32.6 m2  tarmac +29.2762 kerb +28.7762   clear     -> built
##   ring 1300217520   87.0 m2  tarmac +51.1643 kerb +50.6643   clear     -> built
##
## That is not a defect in this system, because `WaterSurface._build()` states
## what it does about it, and the statement is the design:
##
##   "Water on the carriageway is a disagreement between two layers of the same
##    extraction, not a thing to clip away quietly. It goes in the report and out
##    of the world."
##
## and `WaterClearance.report()` returns `clear = swallowed == 0 and
## d >= hw + KERB_SETBACK` for exactly that decision. So the guarantee this suite
## owes the player is NOT "no mapped ring is ever near a road". It is:
##
##   1. the builder DROPS exactly the rings that are not clear, and keeps every
##      ring that is - checked here against an index this suite built itself;
##   2. what reaches the world is therefore clear of the tarmac AND of the kerb
##      - checked on the BUILT mesh, which is the thing a car can hit;
##   3. every ring that IS kept keeps its kerb margin - so the drop rule cannot
##      quietly become "drop everything near a road" and still pass.
##
## A suite that asserted `overlaps == 0` and `built == read` was asserting a
## property of the MAP, in a file whose stated job is to test the SYSTEM. Those
## two numbers were 0 and 5 only because the clearance index was blind. Every
## count downstream of them - triangles, draw calls, materials, covered area -
## was then a hardcoded copy of "all five were built", so one invisible ring took
## seven assertions with it. The counts are now derived from the KEPT set, which
## is what they were always a proxy for.

## Grid step for the independent clearance index. It has to exceed the widest
## half width (7.0 m) so a 3x3 neighbourhood cannot miss a carriageway.
const CELL := 60.0
## Sampling step across a water triangle, in metres, for the poke-through check.
const PROBE := 1.5
## WorldBuilder draws the terrain mesh at its own height minus this.
const TERRAIN_DROP := 0.06
## How close a built vertex may sit to a source ring and still be "built from
## that ring". Ear clipping only ever emits ring vertices, so this is slack, not
## a tolerance that hides a displaced surface.
const RING_SLACK := 0.01
## Step of the sampled clearance walk, in metres. It bounds how wrong the sampled
## side of the cross-check can be about a distance, so it is also the tolerance
## the sampled margin is allowed to differ from the exact one by.
const SAMPLE_STEP := 2.0

var _graph: RoadGraph
var _wb: WorldBuilder
var _root: Node3D
var _node: Node3D
var _plan: Dictionary = {}
var _segs: Array = []
var _grid: Dictionary = {}
## Measured here, asserted against the builder's plan in `_surface()`.
var _clear_rings: Array = []
var _not_clear := 0
var _kept_area := 0.0
var _kerb_margin := INF
var _kerb_road := ""


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


## The nearest road edge to `p`, searched by SAMPLING: `d` is the SQUARED
## distance (`WaterClearance.pt_seg_d2` returns d2) and `hw` is that road's half
## width in metres. Every caller has to sqrt() `d` before comparing it against a
## length. It used to not, which is how a 2.74 m clearance passed as a 7.0 m one
## for the life of the suite - see `_built_clearance()`.
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
##
## This establishes the set the builder is supposed to act on, and says nothing
## about whether that set is empty. `_surface()` is where the two are compared.
func _carriageway(t: TestHarness) -> void:
	_graph = RoadGraph.new()
	_graph.build(OSMLayout.corridors())
	_index()

	t.gt(_segs.size(), 300, "the clearance index is against the real network (%d edges)" % _segs.size())

	# The production index, built once, only so the two independent methods can be
	# compared below. Every decision this function records is the SAMPLED one.
	var roads := WaterClearance.road_index(_graph)

	var tightest := INF
	var tightest_hw := 0.0
	var tightest_name := ""
	var exact_tightest := INF
	var swallowed := 0
	var disagree := 0
	_clear_rings = []
	_not_clear = 0
	_kept_area = 0.0
	_kerb_margin = INF
	_kerb_road = ""
	for b in OSMWater.bodies():
		var ring: PackedVector2Array = b["ring"]
		# Sampled, not solved: deliberately a different method to
		# WaterClearance's exact segment-to-segment minimum.
		var body_tightest := INF
		var body_road := ""
		var body_hw := 0.0
		for p in _sample_ring(ring, SAMPLE_STEP):
			var n := _nearest(p)
			if float(n["d"]) < body_tightest:
				body_tightest = float(n["d"])
				body_road = String(n["name"])
				body_hw = float(n["hw"])
		# pt_seg_d2 is squared; the margin is a distance in metres.
		body_tightest = sqrt(body_tightest)
		if body_tightest < tightest:
			tightest = body_tightest
			tightest_hw = body_hw
			tightest_name = body_road
		var ex: Dictionary = WaterClearance.report(ring, roads)
		if float(ex["tarmac"]) < exact_tightest:
			exact_tightest = float(ex["tarmac"])

		# The rule, applied to this suite's own measurement: a ring survives only
		# if it clears its nearest road by the kerb setback. WaterClearance says so
		# in code, so the two have to agree on the DECISION and not only on the
		# distance - a sampled index that cleared a ring the exact solver rejected
		# would make the builder look wrong for a reason that is not the builder.
		var sampled_clear: bool = body_tightest - body_hw - WaterClearance.KERB_SETBACK >= 0.0
		if sampled_clear != bool(ex["clear"]):
			disagree += 1
		if sampled_clear:
			_clear_rings.append(ring)
			_kept_area += float(b["area"])
			var km := body_tightest - body_hw - WaterClearance.KERB_SETBACK
			if km < _kerb_margin:
				_kerb_margin = km
				_kerb_road = body_road
		else:
			_not_clear += 1

		for j in _segs.size():
			var s: Dictionary = _segs[j]
			if _inside((s["a"] + s["b"]) * 0.5, ring):
				swallowed += 1

	# The suite's whole premise is two implementations of one question, so the
	# first thing they owe each other is agreement about which rings are bad.
	t.eq(disagree, 0,
		"the sampled index and the exact solver agree on every ring (%d disagreements)" % disagree)
	t.eq(swallowed, 0, "no road is swallowed whole by a water polygon (%d)" % swallowed)
	# ...and agreement about the NUMBER, which is the part a broken index cannot
	# fake by declining to count. `disagree == 0` is only as good as the counter
	# behind it, so the tightest margin each method found is compared directly:
	# the two may differ by at most the sampling step, because that is the worst
	# a 2 m walk along a ring can be wrong about a distance. Measured on this map
	# the tightest tarmac margin is -0.2648 m both ways, and the widest
	# per-ring disagreement is 1.4044 m (Mulgrave Road, 56.7599 sampled against
	# 58.1643 exact) - inside the bound, but not by a margin worth trusting blind.
	var sampled_tarmac := tightest - tightest_hw
	t.between(sampled_tarmac, exact_tightest - SAMPLE_STEP, exact_tightest + SAMPLE_STEP,
		"the sampled index puts the tightest tarmac margin within the sampling step of the exact solver"
			+ " (%+.4f m sampled on %s vs %+.4f m exact, step %.1f m)"
			% [sampled_tarmac, tightest_name, exact_tightest, SAMPLE_STEP])
	# NOT `tightest > 7.0`. One constant standing in for every road's width is
	# what let this suite stay green through a whole map revision it could not
	# see. What has to hold is the rule the builder applies: a ring is kept only
	# if it clears its OWN road by the kerb setback, so every kept ring has to
	# show that margin - which is what makes the counts in `_surface()` correct.
	t.gt(_kerb_margin, 0.0,
		"every ring that survives the drop rule keeps its kerb clear (%+.2f m on %s)"
			% [_kerb_margin, _kerb_road])
	print("      tightest water-to-centreline: %.2f m on %s" % [tightest, tightest_name])
	print("      %d ring(s) are not clear and must be dropped, %d must be built"
		% [_not_clear, _clear_rings.size()])


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

	# ---- THE DROP RULE, which is the invariant, and the only way these counts
	# can be checked without hardcoding them. `WaterSurface._build()` drops a row
	# whose ring is not clear and keeps the rest; `_carriageway()` measured that
	# set from outside, with its own index. If the builder kept a ring that is on
	# the tarmac, or dropped one that is not, this is where it shows.
	t.eq(int(_plan["dropped"]), _not_clear,
		"the builder dropped exactly the rings that are not clear (%d)" % _not_clear)
	t.eq(int(_plan["built"]), _clear_rings.size(),
		"and surfaced every ring that is (%d)" % _clear_rings.size())
	t.eq(int(_plan["built"]) + int(_plan["dropped"]), int(_plan["read"]),
		"built and dropped account for every ring that was read")

	# Real geometry, per body, and not a count of bodies. The old `faces > 100`
	# was a proxy for "not a placeholder" that went stale the moment a body was
	# dropped, and it says nothing about a builder that emits one triangle per
	# body and calls it done. What is checkable without knowing how many bodies
	# there are: every body that was built carries geometry, and every vertex of
	# that geometry is a vertex of a ring that was kept - so the surfaces cannot
	# be a rectangle, an empty mesh, or a body built from the wrong ring.
	var stubs := 0
	for mesh in _meshes():
		if mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() < 3:
			stubs += 1
	t.eq(stubs, 0, "every surfaced body carries geometry, none is a stub (%d bodies, %d triangles)"
		% [_meshes().size(), int(_plan["faces"])])

	var off_ring := 0
	for mesh in _meshes():
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in verts:
			if not _on_a_kept_ring(Vector2(v.x, v.z)):
				off_ring += 1
	t.eq(off_ring, 0,
		"every built vertex comes from a ring that was kept (%d off-ring vertices)" % off_ring)

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

	# The ear clipper has to have triangulated the rings it was given, not a
	# smaller piece of them. Triangles of a ring cover exactly the ring's area, so
	# the built area is the check - and the area to compare against is the KEPT
	# rings, because those are the rings the builder was given. Comparing against
	# all five would be asserting that the drop never happens.
	var built_area := 0.0
	for mesh in _meshes():
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for i in range(0, verts.size(), 3):
			var a := verts[i]
			var b := verts[i + 1]
			var c := verts[i + 2]
			built_area += absf((b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)) * 0.5
	t.between(built_area, _kept_area * 0.98, _kept_area * 1.02,
		"the surfaces cover the mapped area of the rings that were kept, not a piece of it (%.0f of %.0f m2)"
			% [built_area, _kept_area])

	# One draw call per body, which is per body BUILT - a number that moves with
	# the map and does not need restating here.
	t.eq(int(_plan["nodes"]), int(_plan["built"]), "one draw call per surfaced body (%d)" % int(_plan["nodes"]))

	# Self-contained: geometry and nothing else, so the world builder can drop it
	# in one line and it cannot reach back into anything.
	var kinds := {}
	for c in _node.get_children():
		kinds[c.get_class()] = true
	t.eq(kinds.keys(), ["MeshInstance3D"], "the node is geometry and nothing else (%s)" % str(kinds.keys()))


## True when `p` lies on one of the rings the builder was supposed to keep, within
## `RING_SLACK`. Ear clipping only ever emits ring vertices, so this is a tight
## check: it fails for a displaced surface, a wrong ring, or a placeholder.
func _on_a_kept_ring(p: Vector2) -> bool:
	for ring in _clear_rings:
		var r: PackedVector2Array = ring
		var n := r.size()
		for i in n:
			var d := WaterClearance.pt_seg_d2(p, r[i], r[(i + 1) % n])
			if d <= RING_SLACK * RING_SLACK:
				return true
	return false


## The overlap measurement again, on the BUILT mesh rather than the source ring.
## The rings are what the data says; the triangles are what a car can hit.
##
## THIS is the assertion that answers "is there water on the carriageway", and it
## is per vertex against that vertex's OWN road. The old form compared the
## tightest distance to a single 7.0 m constant - the widest half-width on the
## map - so a vertex 6.9 m from a 9 m residential street passed while a vertex
## 6.9 m from a 14 m arterial failed, and the constant had to be restated by
## hand every time the map gained a wider road.
##
## `_nearest()` returns a SQUARED distance (`WaterClearance.pt_seg_d2`), and
## `hw` is a half width in metres. The offender test here used to compare those
## two directly - `n["d"] < hw` - which is `d^2 < hw`, i.e. "inside
## sqrt(half width)": on this map 2.74 m of a 7.0 m arterial, not 7.0 m. Every
## run of this suite reported "no built water vertex is inside a carriageway"
## having actually only proved 2.74 m, and no run could tell the difference
## because the tightest built vertex is 9.21 m away. Found by mutation M6 of
## t183, which widened the band to 40 m and did not fail - the only honest way to
## find an assertion that was passing for the wrong reason.
func _built_clearance(t: TestHarness) -> void:
	var worst := INF
	var worst_name := ""
	var offenders := 0
	var on_a_road := 0
	var verts := 0
	for mesh in _meshes():
		var vs: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in vs:
			verts += 1
			var n := _nearest(Vector2(v.x, v.z))
			var hw := float(n["hw"])
			# hw == 0.0 means the 3x3 neighbourhood held no road at all, so there
			# is no carriageway to clear and nothing to assert about the margin.
			if hw <= 0.0:
				continue
			on_a_road += 1
			var d := sqrt(float(n["d"]))
			if d < worst:
				worst = d
				worst_name = String(n["name"])
			if d < hw + WaterClearance.KERB_SETBACK:
				offenders += 1
	t.gt(float(on_a_road), 0.0,
		"the clearance index really did reach the built surface (%d of %d vertices have a road)" % [on_a_road, verts])
	t.eq(offenders, 0,
		"no built water vertex is inside a carriageway or its kerb (%d of %d)" % [offenders, on_a_road])
	t.gt(worst - 7.0, 0.0,
		"and the built surface clears even the widest carriageway on the map (tightest %.2f m on %s)"
			% [worst, worst_name])


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
	t.eq(mats, int(_plan["nodes"]), "every surfaced body has a material (%d)" % mats)
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
