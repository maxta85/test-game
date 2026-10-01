class_name OSMBuildings
extends RefCounted
## Real OpenStreetMap building footprints for western Cairns, as real geometry.
##
## assets/maps/cairns_buildings.json is 2198 closed rings in the same local metre
## projection the corridors use (+X east, +Z south, origin at the bbox centre),
## extracted by Tools/osm_cairns.py. WorldBuilder._buildings() still invents its
## own boxes from block logic; this consumes what is actually mapped.
##
## One line to wire in, from WorldBuilder._buildings():
##     OSMBuildings.build(self, graph)
##
## The part that is not plumbing is the carriageway test. A footprint that
## overlaps a road is a car driving through a wall, and OSM maps buildings
## against kerbs while a road network is built from centrelines, so some of them
## do overlap. `_worst_clearance()` finds them, `_clip()` pushes the offending
## vertices back out, and anything that cannot be pushed clear is dropped.
##
## Geometry is batched by material: one ArrayMesh per wall tint, one per roof tint,
## one for each of the two window tints, one MultiMesh for the stumps. Ten draw
## calls for the whole city, rather than 2198 if every footprint were its own mesh.
##
## Regenerate with:  python3 Tools/osm_cairns.py
## Data (c) OpenStreetMap contributors, ODbL 1.0.

const DATA_PATH := "res://assets/maps/cairns_buildings.json"

## How far a wall has to stay back from a road centreline. WorldBuilder puts the
## kerb at half_width + 0.5 and the footpath out to half_width + 2.1, so 2.4
## leaves a driveway's width of yard in front of the wall.
##
## Deliberately not read from WorldBuilder: that file is being edited next door,
## and a renamed constant there would take this class down with it.
const CLEARANCE := 2.4

## Uniform grid over the road edges, so the carriageway test is local work.
const CELL := 48.0
## Query padding. Must stay larger than the widest corridor half-width (HIGHWAY,
## 9.0 m) plus CLEARANCE: a corridor that violates anything is by definition
## within hw + CLEARANCE of the footprint, so anything wider than this lies
## inside the padded box, and a uniform grid cannot then fail to offer it up.
const QUERY_PAD := 20.0
## How many times a clipped ring is pushed clear before it is given up on.
const CLIP_PASSES := 4
## Roof overhang. High eaves are the tropical tell, and the shadow they throw is
## most of what makes a low-rise street read at night.
const EAVES := 0.6
const PARAPET := 0.45
## A footprint this size or bigger is a shop, a shed or a warehouse, not a house.
const FLAT_AREA := 400.0

## How far off the carriageway a wall can be and still be treated as frontage.
## Past this it is a backland wall: another building is between it and the road,
## and glazing it would be glazing a wall nobody sees.
const FRONTAGE_M := 6.0

## Facade geometry, in metres. A window is a size, not a fraction of the wall: the
## whole point of a grid is that every pane on the street is the same pane, which
## is what makes a building look built rather than textured.
const STOREY := 2.6
const SILL := 1.0
const PANE_W := 1.15
const PANE_H := 1.3
const CORNER_MARGIN := 0.85
## Shopfront: glazed to here, sign fascia above it.
const SHOP_TOP := 3.2
const SHOP_SILL := 0.45
const SIGN_H := 0.7
## How far the glass stands off the wall, so it does not z-fight the render band.
const GLASS_OUT := 0.05
## Only 5 of the 2198 rings carry `building:levels` and 2159 are tagged plain
## `building=yes`, so kind and area are what actually decide the height.
const FLAT_KINDS := ["stadium", "retail", "commercial", "industrial", "warehouse", "church"]
## Same family as WorldBuilder's house palette on purpose: until the merge agent
## deletes the generated boxes the two systems share a street, and a different
## set of greys would read as two different suburbs.
const WALL_TINTS := [
	Color(0.52, 0.50, 0.46), Color(0.44, 0.47, 0.44),
	Color(0.58, 0.53, 0.47), Color(0.38, 0.42, 0.40),
]
const ROOF_TINTS := [
	Color(0.30, 0.31, 0.30), Color(0.36, 0.30, 0.26), Color(0.26, 0.30, 0.30),
]

static var _data: Variant = null
static var _raw: Array = []


static func data() -> Dictionary:
	if _data == null:
		_data = _read()
	return _data if _data is Dictionary else {}


## Every ring in the file, closing point dropped and wound counter-clockwise in
## (x, z) so the outward normal of the edge a -> b is always (dy, -dx). 199 of
## the rings OSM hands back are the other way round, and those would otherwise
## extrude inside out and present their backfaces to the street.
static func footprints() -> Array:
	if not _raw.is_empty():
		return _raw
	var out: Array = []
	for b in data().get("buildings", []):
		var ring := _ring(b.get("polygon", []))
		if ring.size() < 3:
			continue
		out.append({
			"id": int(b.get("osm_id", 0)),
			"kind": String(b.get("kind", "yes")),
			"height_m": b.get("height_m"),
			"levels": b.get("levels"),
			"ring": ring,
			"area": _area(ring),
		})
	_raw = out
	return out


## The footprints that survived the carriageway test, with height, lift and roof
## shape decided. No geometry, so the test and the world agree on which buildings
## exist without either of them having to build anything.
static func plan(graph: RoadGraph) -> Dictionary:
	var roads := _road_index(graph)
	var rng := RandomNumberGenerator.new()
	var kept: Array = []
	var clipped := 0
	var dropped := 0
	var moved := 0

	for b in footprints():
		var ring: PackedVector2Array = b["ring"]
		var cand := _candidates(roads, ring)
		if not cand.is_empty() and float(_worst_clearance(ring, cand, roads)["over"]) < 0.0:
			ring = _clip(ring, cand, roads)
			if ring.is_empty():
				dropped += 1
				continue
			clipped += 1
			moved += _moved(b["ring"], ring)

		# Seeded per footprint rather than once per run, so the same building gets
		# the same height whichever order the file happens to be read in.
		rng.seed = int(b["id"])
		var flat := _is_flat(b)
		var entry := {
			"id": int(b["id"]),
			"kind": String(b["kind"]),
			"ring": ring,
			"flat": flat,
			"wall": _wall_height(b, flat, rng),
			# Queenslanders stand on stumps because the ground floods; a shop is
			# poured on its own slab. That gap under the floor is one of the most
			# recognisable things about the architecture, and this is a flood plain.
			"lift": 0.0 if flat else rng.randf_range(0.55, 1.05),
			"rise": 0.0 if flat else clampf(0.32 * _frame(ring)["run"], 0.9, 2.6),
			"tint": rng.randi() % WALL_TINTS.size(),
			"roof": rng.randi() % ROOF_TINTS.size(),
			# Most of a suburban street at night is dark and a few rooms are warm.
			# That mix is the point, and a wall with no lit window is a hole.
			"warm": rng.randf() < 0.72,
		}
		entry["faces"] = _street_faces(ring, cand, roads)
		kept.append(entry)

	return {
		"buildings": kept,
		"read": footprints().size(),
		"built": kept.size(),
		"clipped": clipped,
		"dropped": dropped,
		"moved": moved,
		"clear": kept.size() - clipped,
	}


## Builds the geometry under `parent` and returns the plan plus what it cost:
## the node and vertex counts, so the caller can log the budget it just spent.
static func build(parent: Node3D, graph: RoadGraph) -> Dictionary:
	var p := plan(graph)
	var walls: Array[SurfaceTool] = []
	var roofs: Array[SurfaceTool] = []
	var windows: Array[SurfaceTool] = [_batch(), _batch()]
	var signs: Array[SurfaceTool] = [_batch()]
	for tint in WALL_TINTS.size():
		walls.append(_batch())
	for tint in ROOF_TINTS.size():
		roofs.append(_batch())
	var posts: Array[Transform3D] = []
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)

	for e in p["buildings"]:
		var ring: PackedVector2Array = e["ring"]
		var lift: float = e["lift"]
		var wall: float = e["wall"]
		var tint: int = e["tint"]
		var roof: int = e["roof"]
		_band(walls[tint], ring, lift, lift + wall)
		_facade(windows, signs, ring, e)
		for q in ring:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))

		if bool(e["flat"]):
			# Flat roof: a slab with an upstand around it, overhanging the wall
			# by EAVES so the shadow line under the parapet reads.
			var eave := _offset(ring, EAVES)
			_cap(roofs[roof], eave, lift + wall, true)
			_band(roofs[roof], eave, lift + wall, lift + wall + PARAPET)
		else:
			_pitched(roofs[roof], ring, lift + wall, float(e["rise"]))
			_cap(walls[tint], ring, lift, false)
			_stumps(posts, ring, lift)

	var nodes := 0
	for tint in walls.size():
		nodes += _emit(parent, "Wall%d" % tint, walls[tint], MatLib.wall(WALL_TINTS[tint]))
	for tint in roofs.size():
		# Seen from both sides: a car can drive under a stilt house, and a
		# one-sided slab shows the sky through the gap.
		var mat := MatLib.corrugated(ROOF_TINTS[tint])
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		nodes += _emit(parent, "Roof%d" % tint, roofs[tint], mat)
	# Energy is the whole game on a facade. At 1.1 a lit pane sat under a sodium
	# lamp and lost to the wall the lamp was lighting - the glass was there and
	# the street still read as blank render. A lit window at night is brighter
	# than the wall around it; that is the whole reason a facade reads at all.
	nodes += _emit(parent, "SignFascia", signs[0], MatLib.emissive(Color(1.0, 0.78, 0.45), 3.4))
	nodes += _emit(parent, "WindowWarm", windows[0], MatLib.emissive(Color(1.0, 0.74, 0.44), 2.4))
	nodes += _emit(parent, "WindowCool", windows[1], MatLib.emissive(Color(0.62, 0.76, 0.95), 2.0))
	if not posts.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _stump_mesh()
		mm.instance_count = posts.size()
		# Culling box from the real extent in X/Z, and a ceiling over the tallest
		# eave in Y, so distance culling cannot pop a whole batch out of a frame.
		mm.custom_aabb = AABB(Vector3(lo.x, -1.0, lo.y), Vector3(hi.x - lo.x, 24.0, hi.y - lo.y))
		for i in posts.size():
			mm.set_instance_transform(i, posts[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Stumps"
		mmi.multimesh = mm
		mmi.material_override = MatLib.wall(Color(0.19, 0.16, 0.13))
		parent.add_child(mmi)
		nodes += 1

	var out: Dictionary = p.duplicate()
	out["nodes"] = nodes
	out["stumps"] = posts.size()
	print("[OSM buildings] %d real footprints: %d clear, %d clipped (%d vertices moved), %d dropped, %d draw calls"
		% [int(p["read"]), int(p["clear"]), int(p["clipped"]), int(p["moved"]), int(p["dropped"]), nodes])
	return out


# ----------------------------------------------------------------- decisions

static func _is_flat(b: Dictionary) -> bool:
	return FLAT_KINDS.has(String(b["kind"])) or float(b["area"]) > FLAT_AREA


## Eave height in metres, the wall top. `building:levels * 3 m` where the tag is
## there at all - 5 footprints out of 2198 - and the kind/area default for the
## rest, because a city of identically sized boxes is the thing being replaced.
static func _wall_height(b: Dictionary, flat: bool, rng: RandomNumberGenerator) -> float:
	var tagged: Variant = b["height_m"]
	if tagged != null:
		# The fetcher already clamped levels to 1..59, so this cannot grow a tower.
		return clampf(float(tagged), 2.4, 24.0)
	if String(b["kind"]) == "stadium":
		return rng.randf_range(9.0, 14.0)
	if flat:
		return rng.randf_range(3.8, 6.4)
	if float(b["area"]) > 120.0:
		return rng.randf_range(3.0, 3.6)
	return rng.randf_range(2.7, 3.2)


## Every ring edge that presents a face to a street, nearest road first.
##
## This used to be `_front_edge`: one edge per building, the one whose middle was
## nearest a centreline, and a 2x2 grid of panes on it. That left a corner
## building - the one you drive past twice - glazed on one side and blank on the
## other, and put the same four panes on a 6 m shopfront and a 40 m one. The
## road class comes along with the face because a main road frontage is what
## earns a sign.
static func _street_faces(ring: PackedVector2Array, cand: Array, roads: Dictionary) -> Array:
	var out: Array = []
	var nearest := {"i": 0, "gap": INF}
	for i in ring.size():
		var mid := (ring[i] + ring[(i + 1) % ring.size()]) * 0.5
		var gap := INF
		var cls := RoadGraph.RoadClass.LANE
		if not cand.is_empty():
			var nr := _nearest(mid, cand, roads)
			gap = float(nr["d"]) - float(nr["hw"])
			cls = int(roads["segs"][int(nr["seg"])]["cls"])
		if gap < float(nearest["gap"]):
			nearest = {"i": i, "gap": gap}
		if gap > FRONTAGE_M:
			continue
		out.append({"i": i, "cls": cls, "gap": gap})
	# A building with no road in front of it still gets one glazed face, or the
	# far side of the map goes dark. Same fallback the old single-edge search was.
	if out.is_empty() and not cand.is_empty():
		out.append({"i": int(nearest["i"]), "cls": RoadGraph.RoadClass.LANE,
				"gap": float(nearest["gap"])})
	out.sort_custom(func(x, y): return float(x["gap"]) < float(y["gap"]))
	return out


# --------------------------------------------------------- carriageway test

## Every road edge as a segment with its half-width, in a uniform grid.
##
## `RoadGraph.nearest_road()` scans every edge in the network, so asking it once
## per sample turns the carriageway test into tens of millions of edge tests and
## tens of seconds of world build. The grid holds the same corridors with the
## same per-class half-widths, restricted to the ones that can physically reach
## the footprint (see QUERY_PAD), which is what makes the test local work.
## `RoadGraph.nearest_road()` is still what settles the footprints that had to be
## clipped: see Tests/test_osm_buildings.gd.
static func _road_index(graph: RoadGraph) -> Dictionary:
	var segs: Array = []
	var grid: Dictionary = {}
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		if a.distance_squared_to(b) < 0.01:
			continue
		var id := segs.size()
		segs.append({"a": a, "b": b, "hw": graph.width_for(int(e["class"])) * 0.5,
				"cls": int(e["class"])})
		var lo := Vector2i(floori(minf(a.x, b.x) / CELL), floori(minf(a.y, b.y) / CELL))
		var hi := Vector2i(floori(maxf(a.x, b.x) / CELL), floori(maxf(a.y, b.y) / CELL))
		for cx in range(lo.x, hi.x + 1):
			for cy in range(lo.y, hi.y + 1):
				var key := Vector2i(cx, cy)
				if not grid.has(key):
					grid[key] = []
				grid[key].append(id)
	return {"segs": segs, "grid": grid}


static func _candidates(roads: Dictionary, ring: PackedVector2Array) -> Array:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in ring:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	lo -= Vector2(QUERY_PAD, QUERY_PAD)
	hi += Vector2(QUERY_PAD, QUERY_PAD)
	var out: Array = []
	var grid: Dictionary = roads["grid"]
	for cx in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
		for cy in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
			for id in grid.get(Vector2i(cx, cy), []):
				if not out.has(id):
					out.append(id)
	return out


## How far inside the carriageway a ring reaches, and where.
##
## `over` is d^2 - required^2 at the worst point, so the inner loop needs no
## square root; it is negative exactly when the footprint intrudes.
## `road_inside` is the case no push can fix: a road through the middle of it.
static func _worst_clearance(ring: PackedVector2Array, cand: Array, roads: Dictionary) -> Dictionary:
	var segs: Array = roads["segs"]
	var n := ring.size()
	var over := INF
	var at := -1
	var road := -1
	var inside := false
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		for j in cand:
			var s: Dictionary = segs[j]
			var need: float = float(s["hw"]) + CLEARANCE
			var d2: float = _seg_seg_d2(a, b, s["a"], s["b"])
			if d2 - need * need < over:
				over = d2 - need * need
				at = i
				road = j
	for j in cand:
		var s: Dictionary = segs[j]
		# A corridor the footprint swallows whole: no vertex is the problem, so
		# nothing can be pushed out of the way.
		if _in_ring((s["a"] + s["b"]) * 0.5, ring):
			var need: float = float(s["hw"]) + CLEARANCE
			over = minf(over, -need * need)
			inside = true
	return {"over": over, "edge": at, "road": road, "road_inside": inside}


## Push the two vertices of the offending edge straight out of the corridor, then
## look again. An empty ring means "drop it": four passes were not enough, or a
## road runs through the middle.
static func _clip(ring: PackedVector2Array, cand: Array, roads: Dictionary) -> PackedVector2Array:
	# duplicate(), not `:= ring`. Packed arrays are reference types in GDScript, so
	# writing through the copy would edit the ring cached in footprints() and the
	# unclipped original would be lost - which is exactly what the test's
	# before/after comparison and the raw-footprint check both rely on.
	var out := ring.duplicate()
	var w := _worst_clearance(ring, cand, roads)
	for pass_i in CLIP_PASSES:
		if bool(w["road_inside"]):
			return PackedVector2Array()
		if float(w["over"]) >= 0.0:
			return out
		var i: int = int(w["edge"])
		var j := (i + 1) % ring.size()
		out[i] = _push_out(out[i], ring, cand, roads)
		out[j] = _push_out(out[j], ring, cand, roads)
		w = _worst_clearance(out, cand, roads)
	return PackedVector2Array()


## One vertex out to the clearance line, along the way out of the nearest road.
static func _push_out(p: Vector2, ring: PackedVector2Array, cand: Array, roads: Dictionary) -> Vector2:
	var near := _nearest(p, cand, roads)
	var away: Vector2 = p - near["point"]
	if away.length() < 0.05:
		# Dead on the centreline, so "away from the road" is undefined. Take the
		# side of the carriageway the rest of the ring is on.
		var s: Dictionary = roads["segs"][int(near["seg"])]
		var a: Vector2 = s["a"]
		var b: Vector2 = s["b"]
		var dir := (b - a).normalized()
		var side := Vector2(dir.y, -dir.x)
		away = side if _in_ring((a + b) * 0.5, ring) else -side
	away = away.normalized()
	return p + away * (float(near["hw"]) + CLEARANCE + 0.05 - float(near["d"]))


## Nearest corridor to a point: { d, point, hw, seg }. Only ever asked about
## points already known to be near a road, so `d` is the true distance to the
## nearest of them.
static func _nearest(p: Vector2, cand: Array, roads: Dictionary) -> Dictionary:
	var segs: Array = roads["segs"]
	var best := {"d": INF, "point": Vector2.ZERO, "hw": 0.0, "seg": 0}
	for j in cand:
		var s: Dictionary = segs[j]
		var a: Vector2 = s["a"]
		var b: Vector2 = s["b"]
		var u := b - a
		var l2: float = u.length_squared()
		var t: float = 0.0 if l2 < 1e-9 else clampf((p - a).dot(u) / l2, 0.0, 1.0)
		var q := a + u * t
		var d: float = p.distance_to(q)
		if d < float(best["d"]):
			best = {"d": d, "point": q, "hw": float(s["hw"]), "seg": j}
	return best


## Squared distance between two segments; 0 when they cross.
static func _seg_seg_d2(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if _cross(c, d, a) * _cross(c, d, b) < 0.0 and _cross(a, b, c) * _cross(a, b, d) < 0.0:
		return 0.0
	return minf(minf(_pt_seg_d2(a, c, d), _pt_seg_d2(b, c, d)),
		minf(_pt_seg_d2(c, a, b), _pt_seg_d2(d, a, b)))


static func _pt_seg_d2(p: Vector2, a: Vector2, b: Vector2) -> float:
	var u := b - a
	var l2: float = u.length_squared()
	var t: float = 0.0 if l2 < 1e-9 else clampf((p - a).dot(u) / l2, 0.0, 1.0)
	return p.distance_squared_to(a + u * t)


static func _cross(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


## Crossing number. Rings are wound counter-clockwise by _ring(), so no
## orientation special case is needed.
static func _in_ring(p: Vector2, ring: PackedVector2Array) -> bool:
	var inside := false
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		if (a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
			inside = not inside
	return inside


## How many vertices a clip actually moved, for the before/after count the test
## checks. A size change means the ring was rebuilt, so all of it counts.
static func _moved(before: PackedVector2Array, after: PackedVector2Array) -> int:
	if before.size() != after.size():
		return after.size()
	var n := 0
	for i in before.size():
		if not before[i].is_equal_approx(after[i]):
			n += 1
	return n


# ------------------------------------------------------------------ geometry

## Vertical band around a ring: a wall, a parapet, a slab edge.
static func _band(st: SurfaceTool, ring: PackedVector2Array, y0: float, y1: float) -> void:
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var out := Vector3(b.y - a.y, 0.0, a.x - b.x)
		if out.length_squared() < 1e-6:
			continue
		_quad(st, Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y),
			Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y), out.normalized())


## Hip roof over a real footprint: two slopes and a ridge along the long axis,
## hipped at the ends. Reads as a Queenslander from any angle, which a flat slab
## over the same ring does not.
static func _pitched(st: SurfaceTool, ring: PackedVector2Array, eave: float, rise: float) -> void:
	var eaved := _offset(ring, EAVES)
	var f := _frame(ring)
	var mid: Vector2 = f["mid"]
	var dir: Vector2 = f["dir"]
	var perp: Vector2 = f["perp"]
	var s0: float = f["s0"]
	var s1: float = f["s1"]
	var run: float = f["run"]
	var top := eave + rise
	for i in ring.size():
		var j := (i + 1) % ring.size()
		_quad(st,
			_v(eaved[i], eave + rise * clampf(1.0 - 2.0 * absf((ring[i] - mid).dot(perp)) / run, 0.0, 1.0)),
			_v(eaved[j], eave + rise * clampf(1.0 - 2.0 * absf((ring[j] - mid).dot(perp)) / run, 0.0, 1.0)),
			_ridge(mid, dir, s0, s1, (ring[j] - mid).dot(dir), top),
			_ridge(mid, dir, s0, s1, (ring[i] - mid).dot(dir), top),
			Vector3.UP)


## The point on the ridge line above a footprint point. Clamping the along-axis
## coordinate to the ridge is what turns the end walls into hips instead of
## letting the roof overhang past its own gable.
static func _ridge(mid: Vector2, dir: Vector2, s0: float, s1: float, along: float, y: float) -> Vector3:
	var s: Vector2 = mid + dir * clampf(along, s0, s1)
	return Vector3(s.x, y, s.y)


## A ring's frame: its long axis (the two furthest-apart vertices, so the roof
## ridge runs along it), and the run a roof slope has to cover. A 20 x 8 house
## gets a ridge down its length; a square one gets a pyramid, which is what a hip
## roof is anyway. O(n^2) on a 7-point house and a 125-point stadium, so the
## budget is nothing.
static func _frame(ring: PackedVector2Array) -> Dictionary:
	var bi := 0
	var bj := 1
	var best := -1.0
	for i in ring.size():
		for j in range(i + 1, ring.size()):
			var d: float = ring[i].distance_squared_to(ring[j])
			if d > best:
				best = d
				bi = i
				bj = j
	var mid := _centroid(ring)
	var dir := ring[bj] - ring[bi]
	dir = dir.normalized() if dir.length() > 1e-6 else Vector2(1, 0)
	var perp := Vector2(-dir.y, dir.x)
	var s0 := INF
	var s1 := -INF
	var lo := INF
	var hi := -INF
	for p in ring:
		var along: float = (p - mid).dot(dir)
		var across: float = (p - mid).dot(perp)
		s0 = minf(s0, along)
		s1 = maxf(s1, along)
		lo = minf(lo, across)
		hi = maxf(hi, across)
	return {
		"mid": mid, "dir": dir, "perp": perp, "s0": s0, "s1": s1,
		"run": maxf((hi - lo) * 0.5, 0.5),
	}


## Ring pushed out by `d` along its own outward normals.
##
## A mitre, clamped: at a corner sharper than about 70 degrees the true mitre
## point is metres away, and a Queenslander does not have a 3 m spike on it.
static func _offset(ring: PackedVector2Array, d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := ring.size()
	for i in n:
		var a := ring[i]
		var p := ring[(i - 1 + n) % n]
		var q := ring[(i + 1) % n]
		var n1 := Vector2(a.y - p.y, p.x - a.x).normalized()
		var n2 := Vector2(q.y - a.y, a.x - q.x).normalized()
		var m := n1 + n2
		m = n1 if m.length() < 1e-4 else m.normalized()
		out.append(a + m * minf(d / maxf(m.dot(n1), 0.35), d * 3.0))
	return out


## Fills a ring: up for a roof slab, down for the floor of a stilt house.
static func _cap(st: SurfaceTool, ring: PackedVector2Array, y: float, up: bool) -> void:
	var tris := Geometry2D.triangulate_polygon(ring)
	if tris.is_empty():
		# ponytail: fan from the centroid when Geometry2D refuses a ring, which a
		# clip can leave behind. Not exact for a concave shape, but a hole in a
		# roof is worse than a slightly wrong one. Upgrade path: ear-clip it.
		var c := _centroid(ring)
		for i in ring.size():
			_tri(st, _v(c, y), _v(ring[i], y), _v(ring[(i + 1) % ring.size()], y), up)
		return
	for i in range(0, tris.size(), 3):
		_tri(st, _v(ring[tris[i]], y), _v(ring[tris[i + 1]], y), _v(ring[tris[i + 2]], y), up)


## The facade treatment: on every street-facing edge, a grid of windows scaled to
## the wall, a glazed shopfront where the building is a shop, and a sign fascia
## over a main road frontage.
##
## Everything lit goes into `windows` (two emissive batches) or `signs` (one), so
## the whole facade pass costs a single extra draw call for the city of 2198 -
## which matters, because Tests/test_osm_buildings.gd caps this at a dozen and the
## cap is the reason a facade can be worth drawing at all.
static func _facade(windows: Array, signs: Array, ring: PackedVector2Array, e: Dictionary) -> void:
	for f in e["faces"]:
		_face(windows, signs, ring, e, f)


static func _face(windows: Array, signs: Array, ring: PackedVector2Array, e: Dictionary,
		f: Dictionary) -> void:
	var i := int(f["i"])
	var a := ring[i]
	var b := ring[(i + 1) % ring.size()]
	var span := a.distance_to(b)
	var inner := span - CORNER_MARGIN * 2.0
	if span < 2.4 or inner < 1.0:
		return
	var dir := (b - a) / span
	# Same outward normal as `_band`: rings are wound so the outward normal of
	# a -> b is (dy, -dx).
	var nrm := Vector3(dir.y, 0.0, -dir.x)
	var along := Vector3(dir.x, 0.0, dir.y)
	var up := Vector3(0.0, 1.0, 0.0)
	var ground: float = e["lift"]
	var wall: float = e["wall"]
	var flat := bool(e["flat"])
	var shop := flat and wall > SHOP_TOP + 1.2

	# A lit panel on the wall, `t` metres along the edge from a.
	var panel := func(st: SurfaceTool, t: float, y0: float, half_w: float, h: float) -> void:
		var c := a + dir * t
		var p := Vector3(c.x, ground + y0, c.y) + nrm * GLASS_OUT
		_quad(st, p - along * half_w, p + along * half_w,
				p + along * half_w + up * h, p - along * half_w + up * h, nrm)

	if shop:
		# Shopfront: a run of bays, mullions left as the gaps between them.
		var bays := clampi(int(inner / 2.6), 1, 6)
		var bpitch := inner / float(bays)
		var glass: SurfaceTool = windows[0 if bool(e["warm"]) else 1]
		for k in bays:
			panel.call(glass, CORNER_MARGIN + (float(k) + 0.5) * bpitch, SHOP_SILL,
					minf(1.15, bpitch * 0.4), SHOP_TOP - SHOP_SILL)

	# Signage. A shop signs its own frontage; anything on an arterial or a
	# highway is a main road frontage and gets one whether or not it is a shop,
	# because that is the stretch where a sign is what you read at 60 km/h.
	var sign_y: float = ground + (SHOP_TOP + 0.3 if shop else 3.4)
	if sign_y + SIGN_H < ground + wall and (shop or int(f["cls"]) >= RoadGraph.RoadClass.ARTERIAL):
		# A sign is a sign, not a length of wall: 40 m of fascia across a
		# warehouse frontage reads as a stripe, so the band is capped at a
		# believable width and centred on the face.
		var sign_w := minf(inner * 0.5 - 0.3, 3.5)
		if sign_w > 0.3:
			# One fascia in four goes to the cool batch, so a street of amber
			# signs has the odd cold one in it.
			var neon := int(e["id"]) % 4 == 0
			panel.call(signs[0] if not neon else windows[1], span * 0.5, sign_y - ground,
					sign_w, SIGN_H)

	# Windows: a grid, not a scatter. Columns come from the width of the frontage
	# and rows from the height of the wall, so a wide two-storey shopfront gets a
	# row of panes and the townhouse beside it gets two. The column count is
	# capped by the pitch rather than by a flat number: eight windows spread over
	# 40 m of frontage is one every five metres, which is not a grid.
	var first := SHOP_TOP + 0.6 if shop else 0.0
	var rows := clampi(int((wall - first - SILL - PANE_H) / STOREY) + 1, 0, 4)
	var cols := clampi(int(inner / 2.3), 1, maxi(1, int(inner / 1.6)))
	if rows < 1 or cols < 1:
		return
	var pitch := inner / float(cols)
	var half_w := minf(PANE_W * 0.5, pitch * 0.32)
	for row in rows:
		var y := first + SILL + float(row) * STOREY
		if y + PANE_H > wall - 0.35:
			break
		for col in cols:
			# A few dark panes among the lit ones: "most of a suburban street at
			# night is dark and a few rooms are warm" is a claim about rooms, and a
			# facade where every pane is lit is an office block.
			var warm: bool = bool(e["warm"]) if (int(e["id"]) + row * 7 + col * 13) % 5 > 0 \
					else not bool(e["warm"])
			panel.call(windows[0 if warm else 1], CORNER_MARGIN + (float(col) + 0.5) * pitch,
					y, half_w, PANE_H)


## Stumps under a raised house, one per corner of the ring and thinned out, so a
## 14 m wall does not get a row of seven. Only pitched roofs are raised, so `lift`
## is always the 0.55..1.05 the plan gave them.
static func _stumps(into: Array, ring: PackedVector2Array, lift: float) -> void:
	var last := Vector2(INF, INF)
	for p in ring:
		if p.distance_to(last) < 2.4:
			continue
		last = p
		into.append(Transform3D(Basis(), Vector3(p.x, lift * 0.5, p.y))
			.scaled_local(Vector3(0.18, lift, 0.18)))


## A batch to append triangles to. SurfaceTool.commit() on a tool that was never
## begun returns an empty mesh, so the begin() has to happen here, not in _tri.
static func _batch() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


static func _stump_mesh() -> ArrayMesh:
	var st := _batch()
	var h := 0.5
	var c := [
		Vector3(-h, -h, -h), Vector3(h, -h, -h), Vector3(h, h, -h), Vector3(-h, h, -h),
		Vector3(-h, -h, h), Vector3(h, -h, h), Vector3(h, h, h), Vector3(-h, h, h),
	]
	for f in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]:
		_tri(st, c[int(f[0])], c[int(f[1])], c[int(f[2])])
		_tri(st, c[int(f[0])], c[int(f[2])], c[int(f[3])])
	return st.commit()


## Commits one batched surface. An empty batch costs no draw call.
static func _emit(parent: Node3D, name: String, st: SurfaceTool, mat: Material) -> int:
	var mesh: ArrayMesh = st.commit()
	if mesh.get_surface_count() == 0:
		return 0
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	return 1


static func _v(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)


## Two triangles wound to face `facing`. Everything is generated this way rather
## than with a fixed order because a roof pitch flips the winding halfway round a
## concave ring, and 199 of the 2198 footprints arrive clockwise.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, facing: Vector3) -> void:
	if (b - a).cross(c - a).dot(facing) < 0.0:
		_wind(st, a, d, c, facing)
		_wind(st, a, c, b, facing)
		return
	_wind(st, a, b, c, facing)
	_wind(st, a, c, d, facing)


## One triangle of a `_quad`: the stored normal goes out along `facing` and the
## winding points back into the surface.
##
## Those are opposite directions and have to be. Godot draws a face only when its
## right-hand-rule winding normal points AWAY from the camera, so a quad wound to
## match its own normal is a back face - culled from every side a building is
## ever seen from. That is what every wall, roof slope, window pane and sign in
## this file was: correct geometry, drawn from nowhere. See
## Systems/road_render/winding_check.gd, which holds both conventions still.
static func _wind(st: SurfaceTool, p: Vector3, q: Vector3, r: Vector3, facing: Vector3) -> void:
	if (q - p).cross(r - p).length_squared() < 1e-12:
		return
	for v in [p, r, q]:
		st.set_normal(facing)
		st.set_uv(Vector2(v.x, v.z) * 0.2)
		st.add_vertex(v)


## `flip` reverses the winding. Rings arrive counter-clockwise in (x, z), which in
## 3D is a downward face, so a roof cap needs the flip and a floor does not.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, flip: bool = false) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	if flip:
		n = (c - a).cross(b - a)
	n = n.normalized()
	for v in [a, c, b] if flip else [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x, v.z) * 0.2)
		st.add_vertex(v)


# ---------------------------------------------------------------------- input

static func _ring(raw: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in raw:
		pts.append(Vector2(float(p[0]), float(p[1])))
	# An OSM ring closes; the repeat is the seam, not a corner.
	if pts.size() > 1 and pts[0].is_equal_approx(pts[pts.size() - 1]):
		pts.remove_at(pts.size() - 1)
	if _area(pts) < 0.0:
		pts.reverse()
	return pts


static func _area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func _centroid(ring: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in ring:
		c += p
	return c / maxf(float(ring.size()), 1.0)


## Load via ResourceLoader so this works in an exported PCK, falling back to a raw
## read for source runs. Returns {} rather than failing the boot.
static func _read() -> Dictionary:
	if ResourceLoader.exists(DATA_PATH):
		var res := ResourceLoader.load(DATA_PATH)
		if res is JSON:
			return (res as JSON).data
	if FileAccess.file_exists(DATA_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if parsed is Dictionary:
			return parsed
	push_warning("OSMBuildings: no footprints at %s - run Tools/osm_cairns.py" % DATA_PATH)
	return {}
