extends SceneTree
## MAP-FLIGHT AUDIT - fly every route segment and write down what is standing in the
## carriageway.
##
##     godot --headless --path . --fixed-fps 60 \
##           --script res://Tools/map_flight_audit.gd -- --out /tmp/reports
##
## Why this lives in `Tools/`: the map role owns `World/**`, `Tests/run_tests.gd` only
## discovers `res://Tests/test_*.gd`, and this audit must not change the map it
## audits. It is read-only by construction - it loads `World/`, `Systems/` and
## `artkit/` and asserts against what they produced.
##
## ## What "obstacle" means
##
## The carriageway is the corridor of half-width `width / 2` either side of an edge's
## centre line. `LANE_MARGIN` is the tolerance added outside it, and it exists because
## two of the three object sources are boxes: a 40 cm palm-trunk box that lands 2 cm
## outside the kerb is not a car-stopping obstacle, and an audit that cries wolf about
## it gets switched off.
##
## Everything placed in the world is tested, not just buildings - 1618 palms, 1234
## bushes, the fronds, the poles, the lamp heads, the power lines, the stilt stumps
## and the parked cars at the Car Meet. "No obstacle in the lane" is only a claim
## about the map if the thing standing in the lane could have been anything.
##
## ## Three object sources, because the world is built that way
##
## 1. **Buildings** are merged per material tint (`Wall0`, `Roof1`, `WindowWarm`...), so
##    the scene tree has no per-building node. They are read from
##    `OSMBuildings.plan(graph)` instead - which is the *same* array the world builder
##    and the collision bake consume - and tested as exact polygons. This is the
##    ground truth the task names, used as ground truth rather than re-derived.
## 2. **Batches** are `MultiMeshInstance3D`, so every palm, bush, pole and kerb has its
##    own transform and the audit can name it.
## 3. **The Car Meet** is loose `MeshInstance3D` children.
##
## ## Why the boxes over-report
##
## Sources 2 and 3 are tested as world AABBs projected to the ground plane, and a
## rotated pole's box is bigger than the pole. Over-reporting is the right direction
## here: it costs a number in a report, it does not cost a car hitting a tree. It is
## also deterministic, which a per-triangle test on llvmpipe is not.
##
## ## Exit status
##
## 0 clean, 1 something is in a lane, 2 the audit could not run. 2 is deliberately
## distinct from 1: "the tool broke" and "the map is wrong" must never look the same.

const LANE_MARGIN := 0.5
## t60's building setback (`OSMBuildings.CLEARANCE`). Reported, not asserted: a
## building 2.0 m off the kerb is ugly but it is not in the lane.
const SETBACK_M := 2.5
## Floor, not furniture. The terrain and the outer floor are what the carriageway is
## cut into; counting them would report every segment as blocked.
const IGNORE_ROOTS := ["Terrain", "TerrainCollision", "RoadCollision", "OuterFloor"]
## 46 towers several km inland, on the horizon by construction.
const IGNORE_EXTRA := ["skyline", "Skyline"]
## Paint is *on* the carriageway by design, so it is not an obstacle by definition.
const PAINT_BATCHES := ["markings", "giveway"]
## The road edge itself: the kerb top, the dished channel, the footpath and the open
## drain. They sit *on* the kerb line - flush is correct, that is the construction -
## so they are checked against a different question ("does the road edge intrude on
## the carriageway?") instead of being silently dropped. Both answers are reported.
const EDGE_BATCHES := ["kerbs", "channels", "footpaths", "drainage", "drainage_water"]
## How far an object may cross the kerb line before it counts as being in the lane.
## Outward the tolerance is `LANE_MARGIN`; inward it is 5 cm, because a kerb that
## overhangs its own road by 4 cm is construction noise and a palm trunk that does is
## a tree in the road.
const LANE_TOL := 0.05
## How tall a car is. An object only obstructs the carriageway if it is low enough to
## meet one: a coconut palm's crown arching 7 m over the middle of a street is the
## signature of a north Queensland suburb, not a defect, and reporting it as one
## would bury the two poles and lamp heads that genuinely are in the road.
const CAR_CLEARANCE := 1.9
## Building shells are baked in world space and merged per material - one `Wall0`
## node holds every wall in the city, so its box is the whole city and its origin
## is (0, 0). Testing one of those boxes against a lane measures the origin, not
## the geometry, which is how a whole city reports itself as sitting in the middle
## of Gordon Street. Anything wider than this is a merged shell, not an object, and
## the OSM footprints are audited exactly instead.
const MERGED_SHELL_HALF := 40.0
## Console evidence has to stay readable: a blocked arterial lists 3000 kerb pieces.
## The JSON keeps every one of them.
const BLOCKS_PRINTED := 10

var _total_objects := 0
var _total_in_lane := 0
var _total_setback := 0
var _total_edge_faults := 0
var _total_overhead := 0
var _shells_excluded: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/reports"
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			_:
				i += 1

	print("[audit] ground truth")
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	if g.edges.is_empty():
		return _bail("road graph has no edges - the map did not load")

	var routes := _routes(g)
	if routes.is_empty():
		return _bail("no route segments - the race catalogue produced nothing")
	var segs: Dictionary = routes["unique"]
	print("[audit] %d routes, %d legs, %d unique segments" % [
		(routes["routes"] as Array).size(), _legs(routes["routes"]), segs.size()])

	# Buildings first: this is the ground truth and it costs no build time.
	var plan := OSMBuildings.plan(g)
	var objects := _buildings(plan)

	print("[audit] building the world (~35 s)")
	var world := WorldBuilder.new()
	world.name = "AuditWorld"
	world.build(g)
	root.add_child(world)
	_batches(world, objects)

	var self_tests := _selftest()
	var self_ok := true
	for t in self_tests:
		if not bool(t["ok"]):
			self_ok = false

	print("[audit] auditing %d segments against %d objects" % [segs.size(), objects.size()])
	var rows: Array = []
	for eid in segs.keys():
		rows.append(_audit_segment(g, int(eid), segs[eid], objects))

	# Footprint count equality, in two parts, because they fail for different
	# reasons. `data == read` catches the JSON being parsed wrong. `read == built +
	# dropped` catches the carriageway test throwing buildings away without counting
	# them. A mismatch in either is the map disagreeing with its own ground truth,
	# which is the loudest thing this audit can find and is invisible in a
	# screenshot.
	var read := int(plan.get("read", 0))
	var built_n := int(plan.get("built", 0))
	var dropped := int(plan.get("dropped", 0))
	var fp_check := {
		"name": "footprint counts: OSM data == parsed == built + dropped",
		"in_file": OSMBuildings.data().get("buildings", []).size(),
		"read": read, "built": built_n, "dropped": dropped,
		"ok": OSMBuildings.data().get("buildings", []).size() == read and read == built_n + dropped,
	}
	var seg_check := {
		"name": "segment counts: every catalogue leg resolves to a graph edge",
		"legs": _legs(routes["routes"]), "unresolved": _unresolved(routes["routes"]),
		"ok": _unresolved(routes["routes"]) == 0 and segs.size() > 0,
	}
	# The artkit fill cannot be audited per building - it bakes into the same merged
	# world-space shells as the OSM shells - so its *rule* is asserted instead of
	# sampled. `_frontage_offset` is the map's own setter-back and `_too_close_to_road`
	# rejects any plot whose centre is closer, so on every edge in the map
	#   kerb -> plot centre = FOOTPATH_WIDTH + FRONTAGE_OFFSET, independently of the
	#   road's width. That part is guaranteed, and is asserted here.
	#
	# What is *not* guaranteed is the building's near face: a plot centre 4.6 m off the
	# kerb with a 9 m half-width puts its wall 4.4 m inside the carriageway. So the
	# rule gives a hard width ceiling and it is reported rather than assumed.
	var kerb_to_plot: float = WorldBuilder.FOOTPATH_WIDTH + WorldBuilder.FRONTAGE_OFFSET
	var fill_check := {
		"name": "artkit fill: every plot centre is outside the lane on every edge width",
		"kerb_to_centre_m": snappedf(kerb_to_plot, 0.01),
		"width_ceiling_m": snappedf(2.0 * (kerb_to_plot - LANE_MARGIN), 0.01),
		"ok": kerb_to_plot >= LANE_MARGIN,
	}

	for r in rows:
		_total_in_lane += ((r as Dictionary)["obstacles"] as Array).size()
		_total_setback += ((r as Dictionary)["near_miss"] as Array).size()
		_total_edge_faults += ((r as Dictionary)["edge_faults"] as Array).size()
		_total_overhead += ((r as Dictionary)["overhead"] as Array).size()
	_total_objects = objects.size()

	var report := {
		"lane_margin_m": LANE_MARGIN,
		"setback_m": SETBACK_M,
		"objects_audited": _total_objects,
		"totals": {"objects": _total_objects, "in_lane": _total_in_lane,
			"near_miss": _total_setback, "edge_faults": _total_edge_faults,
			"overhead": _total_overhead},
		"buildings": {"read": read, "built": built_n, "dropped": dropped,
			"clipped": int(plan.get("clipped", 0)), "moved": int(plan.get("moved", 0)),
			"clear": int(plan.get("clear", 0))},
		"routes": routes["routes"],
		"segments": rows,
		"checks": [fp_check, seg_check, fill_check],
		"selftest": self_tests,
		"merged_shells_excluded": _shells_excluded,
	}
	_write(out, report)
	_report(rows, fp_check, seg_check, fill_check, plan, self_tests)
	if _total_in_lane > 0 or _total_edge_faults > 0 or not bool(fp_check["ok"]) or not bool(seg_check["ok"]) \
			or not bool(fill_check["ok"]) or not self_ok:
		quit(1)
	quit(0)


# ------------------------------------------------------------------- the routes
## Every catalogue route, its legs, and the deduplicated set of graph edges they
## cross. Deduplicated because the audit is about the map, not about the routes: a
## stretch of street shared by three routes is one stretch of street and gets one
## answer.
func _routes(g: RoadGraph) -> Dictionary:
	var list: Array = []
	var unique: Dictionary = {}
	for d in RaceDef.catalogue(g):
		var path: Array = (d as RaceDef).path
		var legs: Array = []
		for k in maxi(path.size() - 1, 0):
			var a := int(path[k])
			var b := int(path[k + 1])
			if a == b:
				continue
			var eid := _edge_between(g, a, b)
			legs.append({"a": a, "b": b, "edge": eid,
				"street": String(g.street_names.get(eid, ""))})
			if eid < 0:
				continue
			if not unique.has(eid):
				unique[eid] = {"street": String(g.street_names.get(eid, "")),
					"class": int(g.edges[eid]["class"]),
					"length": g.edge_length(eid), "width": float(g.edges[eid]["width"]),
					"routes": [(d as RaceDef).display_name], "legs": 1}
			else:
				unique[eid]["legs"] = int(unique[eid]["legs"]) + 1
				(unique[eid]["routes"] as Array).append((d as RaceDef).display_name)
		list.append({"id": (d as RaceDef).id, "name": (d as RaceDef).display_name,
			"nodes": path.size(), "legs": legs.size(), "segment": legs})
	return {"routes": list, "unique": unique}


func _edge_between(g: RoadGraph, a: int, b: int) -> int:
	if a < 0 or b < 0 or a >= g.nodes.size() or b >= g.nodes.size():
		return -1
	for eid in (g.nodes[a]["edges"] as Array):
		var e: Dictionary = g.edges[int(eid)]
		if int(e["a"]) == b or int(e["b"]) == b:
			return int(eid)
	return -1


func _legs(routes: Array) -> int:
	var n := 0
	for r in routes:
		n += int((r as Dictionary)["legs"])
	return n


func _unresolved(routes: Array) -> int:
	var n := 0
	for r in routes:
		for leg in ((r as Dictionary)["segment"] as Array):
			if int((leg as Dictionary)["edge"]) < 0:
				n += 1
	return n


# ------------------------------------------------------------------ the objects
## Buildings, read from the plan the world builder itself consumes. Exact polygons,
## so no false positives from an L-shaped or rotated footprint's bounding box.
func _buildings(plan: Dictionary) -> Array:
	var out: Array = []
	for e in (plan.get("buildings", []) as Array):
		out.append({
			"kind": "building",
			"paint": false,
			"edge": false,
			"ring": (e as Dictionary)["ring"],
			"id": "osm:%d" % int((e as Dictionary).get("id", 0)),
		})
	return out


## Batches and loose meshes, per instance, straight out of the built tree.
func _batches(world: Node3D, objects: Array) -> void:
	_collect(world, objects)


func _collect(n: Node, objects: Array) -> void:
	# `_label`, not `n.name`: `Batch_skyline` is only the holder, the mesh with the
	# 46 towers' instances on it is an auto-named `@MultiMeshInstance3D@1684`
	# underneath it, so a name test up here never matches and the horizon comes back
	# as an obstacle standing in Gordon Street.
	var skip := false
	for s in IGNORE_ROOTS + IGNORE_EXTRA:
		var label := _label(n)
		if label == s or label.begins_with(s):
			skip = true
	if not skip and n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm != null and mm.mesh != null:
			var batch := _label(n)
			var half := _ground_half_extent(mm.mesh.get_aabb())
			if half.x > MERGED_SHELL_HALF or half.y > MERGED_SHELL_HALF:
				# A baked batch: one mesh holding the whole city's props, so its
				# bounds are the map's bounds. Every instance would test as 800 m
				# wide and the map would report itself as solid.
				_shells_excluded.append({"node": batch,
					"half_x": snappedf(half.x, 0.1), "half_z": snappedf(half.y, 0.1)})
			else:
				var aabb := mm.mesh.get_aabb()
				for i in mm.instance_count:
					var x := mmi.global_transform * mm.get_instance_transform(i)
					objects.append({
						"kind": batch, "paint": batch in PAINT_BATCHES,
						"edge": batch in EDGE_BATCHES,
						"p": Vector2(x.origin.x, x.origin.z), "half": half,
						"half_max": maxf(half.x, half.y), "radius": _radius(x, aabb),
					"aabb": aabb, "xf": x,
						"id": "%s#%d" % [batch, i],
					})
	elif not skip and n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			var half := _ground_half_extent(mi.mesh.get_aabb())
			if half.x > MERGED_SHELL_HALF or half.y > MERGED_SHELL_HALF:
				_shells_excluded.append({"node": String(mi.name),
					"half_x": snappedf(half.x, 0.1), "half_z": snappedf(half.y, 0.1)})
			else:
				var x := mi.global_transform
				objects.append({"kind": "mesh:" + String(mi.name), "paint": false,
					"edge": String(mi.name) in EDGE_BATCHES,
					"p": Vector2(x.origin.x, x.origin.z), "half": half,
					"half_max": maxf(half.x, half.y), "radius": _radius(x, mi.mesh.get_aabb()),
					"aabb": mi.mesh.get_aabb(), "xf": x,
					"id": String(mi.name)})
	for c in n.get_children():
		_collect(c, objects)


## The batch a node belongs to. Godot auto-names a node that was never given a
## name (`@MultiMeshInstance3D@1674`), and an audit that reports objects by that
## string is an audit nobody can act on, so the nearest named ancestor wins.
func _label(n: Node) -> String:
	var walk := n
	while walk != null:
		var s := String(walk.name)
		if not s.begins_with("@"):
			return s.replace("Batch_", "")
		walk = walk.get_parent()
	return "unnamed"


## The furthest the instance can reach from its origin in the ground plane, scale
## included. The reject test depends on this being an over-estimate: it is only ever
## used to throw objects away, so a too-small value costs time and a too-large value
## costs nothing.
func _radius(xf: Transform3D, aabb: AABB) -> float:
	var bx := xf.basis
	var lx := Vector2(bx.x.x, bx.x.z).length()
	var lz := Vector2(bx.z.x, bx.z.z).length()
	return maxf(aabb.size.x * 0.5 * lx, aabb.size.z * 0.5 * lz) * 1.415


## Half-extent of a mesh's bounds in the ground plane. The Y half is dropped: a
## building is 20 m tall and 8 m wide, and testing its height against a lane would be
## nonsense.
func _ground_half_extent(a: AABB) -> Vector2:
	return Vector2(a.size.x * 0.5, a.size.z * 0.5)


# ------------------------------------------------------------------ the audit
## One segment: what is inside the lane corridor, and what is merely inside the
## setback band behind it.
func _audit_segment(g: RoadGraph, eid: int, meta: Dictionary, objects: Array) -> Dictionary:
	var e: Dictionary = g.edges[eid]
	var a: Vector2 = g.node_pos(int(e["a"]))
	var b: Vector2 = g.node_pos(int(e["b"]))
	var delta := b - a
	var length := delta.length()
	var dir := delta / maxf(length, 0.001)
	var ex := dir
	var ey := Vector2(-dir.y, dir.x)
	var half_w: float = float(e["width"]) * 0.5

	var corridor := _corridor(a, ex, ey, length, half_w)
	var in_lane: Array = []
	var near: Array = []
	var overhead: Array = []
	var edge_faults: Array = []
	var overhead_edge: Array = []
	var closest := {"id": "", "kind": "", "gap_m": -1.0}
	var closest_edge := {"id": "", "kind": "", "gap_m": -1.0}
	for o in objects:
		if bool(o["paint"]):
			continue
		var d := _lateral(o, corridor, ex, a, length, LANE_MARGIN + SETBACK_M, half_w)
		if d.x < 0.0:
			continue
		var entry := {"id": String(o["id"]), "kind": String(o["kind"]),
			"gap_m": snappedf(d.x, 0.01), "along_m": snappedf(d.y, 0.1),
			"intrude_m": snappedf(d.z, 0.01), "y_lo": _y_low(o)}
		# Height first. An object is counted against the carriageway only when it is
		# low enough for a car to meet it; the rest are overhead and get their own
		# class, because a coconut crown 7 m over a street is the suburb and not a bug.
		var low: bool = float(entry["y_lo"]) < CAR_CLEARANCE
		var edge := bool(o.get("edge", false))
		if edge:
			if float(entry["intrude_m"]) > LANE_TOL:
				if low:
					edge_faults.append(entry)
				else:
					overhead_edge.append(entry)
			if float(closest_edge["gap_m"]) < 0.0 or d.x < float(closest_edge["gap_m"]):
				closest_edge = entry.duplicate()
			continue
		if float(closest["gap_m"]) < 0.0 or d.x < float(closest["gap_m"]):
			closest = entry.duplicate()
		if not low:
			if float(entry["intrude_m"]) > LANE_TOL:
				overhead.append(entry)
			continue
		if float(entry["intrude_m"]) > LANE_TOL:
			in_lane.append(entry)
		elif d.x <= LANE_MARGIN:
			near.append(entry)

	var by_gap := func(x, y): return float(x["gap_m"]) < float(y["gap_m"])
	var by_in := func(x, y): return float(x["intrude_m"]) > float(y["intrude_m"])
	in_lane.sort_custom(by_in)
	edge_faults.sort_custom(by_in)
	near.sort_custom(by_gap)
	return {
		"edge": eid, "street": String(meta["street"]), "class": int(meta["class"]),
		"length_m": snappedf(length, 0.1), "width_m": float(e["width"]),
		"half_width_m": snappedf(half_w, 0.01), "lanes": g.lanes_for(int(e["class"])),
		"routes": meta["routes"],
		"obstacles": in_lane, "near_miss": near, "edge_faults": edge_faults,
		"overhead": overhead, "overhead_edge": overhead_edge,
		"ok": in_lane.is_empty() and edge_faults.is_empty(),
		"closest": closest, "closest_edge": closest_edge,
	}


## Distance from an object to a segment, or `(-1, -1)` when the object lies beyond
## either end. Beyond the ends is deliberate: that ground belongs to the neighbouring
## segment or to the junction, and crediting a blocker to both would double-count the
## one palm at the corner of Gordon and Mulgrave.
## Distance from an object to the carriageway, or -1 when the object lies beyond
## either end of the segment.
##
## The measurement is a polygon gap: the object's own oriented footprint against the
## corridor's rectangle. It is exact under rotation and scale, and that matters here
## because the map's drainage is a 4 m tile scaled 8.4x into a 33 m run - a bounding
## box in the street's frame turns that into a 15 m wide slab and reports the whole
## city as blocking every arterial. Two earlier versions of this measurement did
## exactly that, which is why the calibration below exists.
##
## Beyond the ends is deliberate: that ground belongs to the neighbouring segment or
## to the junction, and crediting a blocker to both would double-count the one palm
## at the corner of Gordon and Mulgrave.
func _lateral(o: Dictionary, corridor: PackedVector2Array, ex: Vector2, a: Vector2,
		length: float, reach: float, half_w: float) -> Vector3:
	if o.has("ring"):
		var poly := _ring_poly(o["ring"])
		var g := _gap(poly, corridor, ex, a, length, reach)
		return Vector3(g.x, g.y, _intrusion(poly, ex, a, half_w))
	var p: Vector2 = o["p"]
	var r: float = float(o.get("radius", o["half_max"]))
	# Cheap reject first: 120k objects times 16 segments is 2M footprint builds, and
	# almost none of them are near a road. The world-space radius cannot produce a
	# false negative - it is the largest half-extent the object can have under any
	# rotation.
	if p.distance_to(a) > length + reach + r:
		return Vector3(-1.0, -1.0, 0.0)
	var poly := _obb_poly(o["xf"], o["aabb"])
	if poly.size() < 3:
		return Vector3(-1.0, -1.0, 0.0)
	var g := _gap(poly, corridor, ex, a, length, reach)
	return Vector3(g.x, g.y, _intrusion(poly, ex, a, half_w))


## The bottom of the object in world metres. Zero for a ring, which is a footprint
## with no height of its own - OSM footprints are buildings, and a building is always
## at ground level as far as a car is concerned.
func _y_low(o: Dictionary) -> float:
	if not o.has("xf"):
		return 0.0
	var aabb: AABB = o["aabb"]
	var xf: Transform3D = o["xf"]
	var c := xf * aabb.get_center()
	var hy: float = xf.basis.y.length() * aabb.size.y * 0.5
	return c.y - hy


## How far an object reaches past the kerb line, into the carriageway. Zero means it
## is outside or flush; positive means it is standing in the road.
func _intrusion(poly: PackedVector2Array, ex: Vector2, a: Vector2, half_w: float) -> float:
	if poly.size() < 3:
		return 0.0
	var ey := Vector2(-ex.y, ex.x)
	var min_c := INF
	for q in poly:
		min_c = minf(min_c, absf((q - a).dot(ey)))
	return maxf(half_w - min_c, 0.0)


## The carriageway of one segment: `width / 2` either side of the centre line, and
## nothing beyond the two nodes.
func _corridor(a: Vector2, ex: Vector2, ey: Vector2, length: float, half_w: float) -> PackedVector2Array:
	return PackedVector2Array([
		a + ey * half_w, a + ex * length + ey * half_w,
		a + ex * length - ey * half_w, a - ey * half_w,
	])


## The ground footprint of an instance: the four corners of its mesh AABB after the
## instance transform, which for a box is exactly its oriented footprint whatever
## the rotation and scale.
func _obb_poly(xf: Transform3D, aabb: AABB) -> PackedVector2Array:
	var bx := xf.basis
	var lx := Vector2(bx.x.x, bx.x.z).length()
	var lz := Vector2(bx.z.x, bx.z.z).length()
	if lx < 0.0001 or lz < 0.0001:
		return PackedVector2Array()
	var u := Vector2(bx.x.x, bx.x.z).normalized()
	var v := Vector2(bx.z.x, bx.z.z).normalized()
	var c := xf * aabb.get_center()
	var hu := aabb.size.x * 0.5 * lx
	var hv := aabb.size.z * 0.5 * lz
	return PackedVector2Array([
		Vector2(c.x, c.z) + u * hu + v * hv,
		Vector2(c.x, c.z) - u * hu + v * hv,
		Vector2(c.x, c.z) - u * hu - v * hv,
		Vector2(c.x, c.z) + u * hu - v * hv,
	])


## Distance between an object's footprint and the carriageway, plus how far along
## the segment the closest approach happens.
func _gap(poly: PackedVector2Array, corridor: PackedVector2Array, ex: Vector2,
		a: Vector2, length: float, reach: float) -> Vector2:
	var lo := INF
	var hi := -INF
	for q in poly:
		var t := (q - a).dot(ex)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	if hi < 0.0 or lo > length:
		return Vector2(-1.0, -1.0)
	var d := _poly_gap(poly, corridor)
	if d > reach + 100.0:
		return Vector2(-1.0, -1.0)
	var t := 0.0
	var best := INF
	for i in poly.size():
		var q: Vector2 = poly[i]
		var q2: Vector2 = poly[(i + 1) % poly.size()]
		for j in corridor.size():
			var e0: Vector2 = corridor[j]
			var e1: Vector2 = corridor[(j + 1) % corridor.size()]
			var dd := minf(_point_seg(q, e0, e1), _point_seg(q2, e0, e1))
			if dd < best:
				best = dd
				t = (q - a).dot(ex)
	return Vector2(d, clampf(t, 0.0, length))


## Exact distance between two convex polygons: zero when they overlap, otherwise
## the smallest vertex-to-edge distance in either direction. A vertex-only test
## against a corridor line is not enough - a footprint's edge can be closer than any
## of its corners.
func _poly_gap(p: PackedVector2Array, q: PackedVector2Array) -> float:
	for v in p:
		if _point_in_ring(v, q):
			return 0.0
	for v in q:
		if _point_in_ring(v, p):
			return 0.0
	for i in p.size():
		if _cross(p[i], p[(i + 1) % p.size()], q[0], q[1]) \
				or _cross(p[i], p[(i + 1) % p.size()], q[2], q[3]):
			return 0.0
	var best := INF
	for i in p.size():
		var a0: Vector2 = p[i]
		var a1: Vector2 = p[(i + 1) % p.size()]
		for j in q.size():
			var b0: Vector2 = q[j]
			var b1: Vector2 = q[(j + 1) % q.size()]
			best = minf(best, _seg_seg(a0, a1, b0, b1))
	return best


## Do two segments properly cross? Without this, a footprint that straddles the whole
## carriageway - every vertex outside it, every corridor corner outside the footprint,
## the two polygons plainly on top of each other - measured as the distance between
## their nearest edges. A 10 m building across an 8 m street came out 1 m clear, and
## the audit would have called a house standing in the road clear of it.
func _cross(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> bool:
	var d1 := (b1 - b0).cross(a0 - b0)
	var d2 := (b1 - b0).cross(a1 - b0)
	var d3 := (a1 - a0).cross(b0 - a0)
	var d4 := (a1 - a0).cross(b1 - a0)
	if (d1 > 0.0 and d2 < 0.0 or d1 < 0.0 and d2 > 0.0) \
			and (d3 > 0.0 and d4 < 0.0 or d3 < 0.0 and d4 > 0.0):
		return true
	return false


func _seg_seg(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> float:
	return minf(minf(_point_seg(a0, b0, b1), _point_seg(a1, b0, b1)),
		minf(_point_seg(b0, a0, a1), _point_seg(b1, a0, a1)))


func _point_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(_closest_on_segment(p, a, b))


func _closest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var d := b - a
	var l2 := d.length_squared()
	if l2 < 0.000001:
		return a
	return a + d * clampf((p - a).dot(d) / l2, 0.0, 1.0)


## A footprint is already in the map's own ground-plane coordinates.
func _ring_poly(ring: PackedVector2Array) -> PackedVector2Array:
	return ring


func _ring_lateral(ring: PackedVector2Array, a: Vector2, dir: Vector2, length: float) -> Vector2:
	var best := INF
	var best_t := 0.0
	for q in ring:
		var t := (q - a).dot(dir)
		if t < 0.0 or t > length:
			continue
		var c := a + dir * t
		var d := q.distance_to(c)
		if d < best:
			best = d
			best_t = t
	if best == INF:
		return Vector2(-1.0, -1.0)
	# A polygon that straddles the segment's endpoints is inside the lane even when
	# every vertex projects outside - the corner case that catches a building sitting
	# on the middle of a junction.
	var r0 := a + dir * 0.0
	var r1 := a + dir * length
	if _point_in_ring(r0, ring) or _point_in_ring(r1, ring):
		return Vector2(0.0, best_t)
	return Vector2(best, best_t)


func _point_in_ring(p: Vector2, ring: PackedVector2Array) -> bool:
	var inside := false
	var n := ring.size()
	for i in n:
		var j := (i + 1) % n
		var vi := ring[i]
		var vj := ring[j]
		if (vi.y > p.y) == (vj.y > p.y):
			continue
		var x := (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x
		if p.x < x:
			inside = not inside
	return inside


# ------------------------------------------------------------------ calibration
## The measurement is the instrument, so the instrument is checked before its output
## is believed. Each case has a hand-computed answer, and each one is the shape of
## mistake this audit has already made once - a kerb run reported in the middle of the
## carriageway, and a whole city reporting itself as solid.
##
## A green audit on an instrument that always returns 0.0 is not a clean map, it is a
## broken tool, and the two must not look the same.
func _selftest() -> Array:
	var a := Vector2(0.0, 0.0)
	var ex := Vector2(1.0, 0.0)
	var ey := Vector2(0.0, 1.0)
	var length := 120.0
	var reach := 10.0
	# An 8 m street in the calibration frame: its carriageway is 4.0 m either side of
	# the line at across = 0, so "in the lane" means a near face under 4.5 m.
	var hw := 4.0
	var cases: Array = []

	# A 0.4 m pole whose near face is 0.2 m inside the lane margin has to be caught.
	var pole := _box(AABB(Vector3(-0.2, 0.0, -0.2), Vector3(0.4, 1.0, 0.4)),
		Transform3D(Basis(), Vector3(60.0, 0.0, hw + 0.1)), "pole")
	cases.append(_case("a 0.4 m pole inside the lane margin is flagged",
		_lateral(pole, _corridor(a, ex, ey, length, hw), ex, a, length, reach, hw), 0.0, 0.05, true))

	# The same pole 2 m off the kerb has to pass.
	var pole_back := _box(AABB(Vector3(-0.2, 0.0, -0.2), Vector3(0.4, 1.0, 0.4)),
		Transform3D(Basis(), Vector3(60.0, 0.0, hw + 2.2)), "pole")
	cases.append(_case("the same pole 2 m off the kerb is clear",
		_lateral(pole_back, _corridor(a, ex, ey, length, hw), ex, a, length, reach, hw), 2.0, 0.05, false))

	# A 0.3 m strip running 60 m along the street, hugging the kerb. Its along extent
	# is 60 m and its across extent is 0.3 m, so this case fails - by 30 m - on any
	# measurement that does not rotate into the street's frame.
	var strip := _box(AABB(Vector3(-30.0, 0.0, -0.15), Vector3(60.0, 0.3, 0.3)),
		Transform3D(Basis(), Vector3(60.0, 0.0, hw - 0.05)), "kerb-run")
	cases.append(_case("a 60 m kerb run measures 0.2 m across, not 30 m along",
		_lateral(strip, _corridor(a, ex, ey, length, hw), ex, a, length, reach, hw), 0.05, 0.1, true))

	# The same run, properly set back, has to pass.
	var strip_back := _box(AABB(Vector3(-30.0, 0.0, -0.15), Vector3(60.0, 0.3, 0.3)),
		Transform3D(Basis(), Vector3(60.0, 0.0, hw + 2.15)), "kerb-run")
	cases.append(_case("the same kerb run 2 m off the kerb is clear",
		_lateral(strip_back, _corridor(a, ex, ey, length, hw), ex, a, length, reach, hw), 2.0, 0.05, false))

	# A building footprint beside the street, wall 0.4 m inside the kerb.
	var ring := PackedVector2Array([Vector2(40.0, hw - 0.4), Vector2(46.0, hw - 0.4),
		Vector2(46.0, hw + 5.0), Vector2(40.0, hw + 5.0)])
	cases.append({"name": "a footprint wall inside the lane margin is flagged",
		"ok": _lateral({"ring": ring}, _corridor(a, ex, ey, length, hw), ex, a,
			length, reach, hw).z > LANE_TOL,
		"detail": "measured a %.2f m gap, %.2f m over the kerb line, flagged" % [
			_lateral({"ring": ring}, _corridor(a, ex, ey, length, hw), ex, a,
				length, reach, hw).x,
			_lateral({"ring": ring}, _corridor(a, ex, ey, length, hw), ex, a,
				length, reach, hw).z]})

	# The same footprint, set back, has to pass.
	var ring_back := PackedVector2Array([Vector2(40.0, hw + 2.6), Vector2(46.0, hw + 2.6),
		Vector2(46.0, hw + 7.0), Vector2(40.0, hw + 7.0)])
	cases.append({"name": "the same footprint 2.6 m off the kerb is clear",
		"ok": _lateral({"ring": ring_back}, _corridor(a, ex, ey, length, hw), ex, a,
			length, reach, hw).z <= LANE_TOL,
		"detail": "measured a %.2f m gap, %.2f m over the kerb line, clear" % [
			_lateral({"ring": ring_back}, _corridor(a, ex, ey, length, hw), ex, a,
				length, reach, hw).x,
			_lateral({"ring": ring_back}, _corridor(a, ex, ey, length, hw), ex, a,
				length, reach, hw).z]})

	# Past the end of the segment belongs to the next segment, not this one.
	var past := _box(AABB(Vector3(-0.2, 0.0, -0.2), Vector3(0.4, 1.0, 0.4)),
		Transform3D(Basis(), Vector3(140.0, 0.0, 0.0)), "pole")
	cases.append({"name": "an object beyond the segment's ends is not counted on it",
		"ok": _lateral(past, _corridor(a, ex, ey, length, hw), ex, a,
			length, reach, hw).x < 0.0, "detail": "beyond the end node, not counted"})

	# A house-sized box genuinely in the middle of the carriageway.
	var house := _box(AABB(Vector3(-5.0, 0.0, -5.0), Vector3(10.0, 6.0, 10.0)),
		Transform3D(Basis(), Vector3(60.0, 0.0, 0.0)), "house")
	# A house that straddles the whole street has no gap to measure: its footprint and
	# the carriageway are the same piece of ground, and the gap is 0 by definition.
	# The obstruction signal for a shape like that is the overlap, not the intrusion.
	var house_d := _lateral(house, _corridor(a, ex, ey, length, hw), ex, a, length, reach, hw)
	cases.append({"name": "a house in the middle of the carriageway is flagged",
		"ok": house_d.x <= 0.0 or house_d.z > LANE_TOL,
		"detail": "measured a %.2f m gap, %.2f m over the kerb line, footprint on the carriageway" % [
			house_d.x, house_d.z]})

	# The frame is anchored on the segment, not on the world origin: the same pole on
	# a segment that starts 600 m away has to measure identically.
	var far := _box(AABB(Vector3(-0.2, 0.0, -0.2), Vector3(0.4, 1.0, 0.4)),
		Transform3D(Basis(), Vector3(660.0, 0.0, hw + 0.1)), "pole")
	cases.append(_case("a segment 600 m from the origin measures the same pole",
		_lateral(far, _corridor(Vector2(600.0, 0.0), ex, ey, length, hw), ex,
			Vector2(600.0, 0.0), length, reach, hw), 0.0, 0.05, true))
	return cases


## A synthetic object in the audit's own shape, so the calibration exercises the
## production measurement path rather than a copy of it.
func _box(aabb: AABB, xf: Transform3D, id: String) -> Dictionary:
	var half := Vector2(aabb.size.x * 0.5, aabb.size.z * 0.5)
	var origin := xf * aabb.get_center()
	return {"kind": id, "paint": false, "edge": false, "p": Vector2(origin.x, origin.z), "half": half,
		"half_max": maxf(half.x, half.y), "radius": _radius(xf, aabb),
		"aabb": aabb, "xf": xf, "id": id}


## `_lateral` returns the gap between the object's footprint and the carriageway, so
## 0.0 means it is touching the lane and "flagged" means the gap is at or under
## `LANE_MARGIN`. Every expectation below is a gap on an 8 m street, so a reader can
## check the arithmetic against the fixture the case names.
func _case(name: String, got: Vector3, want: float, tol: float, expect_flag: bool) -> Dictionary:
	var ok: bool = got.x >= 0.0 and absf(got.x - want) <= tol and (got.z > LANE_TOL) == expect_flag
	return {"name": name, "ok": ok,
		"detail": "measured a %.2f m gap and %.2f m over the kerb line, expected %.2f m +/- %.2f, tolerance %.2f m, %s" % [
			got.x, got.z, want, tol, LANE_TOL, "flagged" if expect_flag else "clear"]}


# --------------------------------------------------------------------- reporting
func _report(rows: Array, fp: Dictionary, sc: Dictionary, fill: Dictionary,
		plan: Dictionary, self_tests: Array) -> void:
	var blocked: Array = []
	for r in rows:
		if not bool((r as Dictionary)["ok"]):
			blocked.append(r)
	print("")
	print("  === MAP-FLIGHT AUDIT ===")
	print("  segments audited      : %d" % rows.size())
	print("  blocked segments      : %d" % blocked.size())
	print("  objects tested        : %d" % _total_objects)
	print("  props in a lane       : %d  (crossing the kerb line)" % _total_in_lane)
	print("  road-edge intrusions  : %d  (kerb/channel/footpath/drain)" % _total_edge_faults)
	print("  props within 0.5 m of: %d  (reported, not asserted)" % _total_setback)
	print("    the carriageway")
	print("  overhead crossings     : %d  (above %.1f m, not car obstacles)" % [
		_total_overhead, CAR_CLEARANCE])
	print("  merged shells skipped : %d (World/ batches baked per material tint)" % _shells_excluded.size())
	print("")
	if blocked.is_empty():
		print("  every audited carriageway is clear")
	else:
		for r in blocked:
			print("  BLOCKED  %-28s edge %-4d %-9s %5.0f m  %4.1f m wide  %d route(s)" % [
				String((r as Dictionary)["street"]), int((r as Dictionary)["edge"]),
				_class_name(int((r as Dictionary)["class"])),
				float((r as Dictionary)["length_m"]), float((r as Dictionary)["width_m"]),
				((r as Dictionary)["routes"] as Array).size()])
			_print_obstacles("props in the lane", (r as Dictionary)["obstacles"])
			_print_obstacles("overhead, above car height", (r as Dictionary)["overhead"])
			_print_obstacles("road edge intruding", (r as Dictionary)["edge_faults"])
			var cl: Dictionary = (r as Dictionary)["closest"]
			print("             closest prop: %s at %s, %.2f m clear" % [
				String(cl["id"]), String(cl["kind"]), float(cl["gap_m"])])
			var ce: Dictionary = (r as Dictionary)["closest_edge"]
			print("             closest edge piece: %s at %s, %.2f m clear, %.2f m over the kerb line" % [
				String(ce["id"]), String(ce["kind"]), float(ce["gap_m"]),
				float(ce["intrude_m"])])
	print("")
	print("  buildings: %d in the OSM file, %d parsed, %d kept, %d dropped for the carriageway, %d clipped (%d m of frontage moved)" % [
		OSMBuildings.data().get("buildings", []).size(), int(plan.get("read", 0)),
		int(plan.get("built", 0)), int(plan.get("dropped", 0)),
		int(plan.get("clipped", 0)), int(plan.get("moved", 0))])
	print("")
	print("  [%s] %s" % [_tag(bool(fp["ok"])), String(fp["name"])])
	print("      in file %d, parsed %d, kept %d + dropped %d = %d" % [
		int(fp["in_file"]), int(fp["read"]), int(fp["built"]), int(fp["dropped"]),
		int(fp["built"]) + int(fp["dropped"])])
	print("  [%s] %s" % [_tag(bool(sc["ok"])), String(sc["name"])])
	print("      %d legs, %d unresolved, %d unique segments" % [
		int(sc["legs"]), int(sc["unresolved"]), rows.size()])
	for t in self_tests:
		print("  [%s] calibration: %s" % [_tag(bool(t["ok"])), String(t["name"])])
		print("        %s" % String(t["detail"]))
	print("")
	print("  [%s] %s" % [_tag(bool(fill["ok"])), String(fill["name"])])
	print("      kerb to plot centre %.2f m on every width; a plot may be %.1f m wide before" % [
		float(fill["kerb_to_centre_m"]), float(fill["width_ceiling_m"])])
	print("      its near face reaches the lane margin - reported, not audited per building")
	print("")


func _print_obstacles(label: String, list: Array) -> void:
	if list.is_empty():
		return
	print("             %s: %d" % [label, list.size()])
	for o in list.slice(0, BLOCKS_PRINTED):
		print("               %-26s %-14s %6.2f m over the kerb line, %5.1f m along, %.1f m up" % [
			String(o["id"]), String(o["kind"]),
			float(o["intrude_m"]), float(o["along_m"]), float(o["y_lo"])])
	if list.size() > BLOCKS_PRINTED:
		print("               ... and %d more, all of them in the JSON" % [
			list.size() - BLOCKS_PRINTED])


func _tag(ok: bool) -> String:
	return "PASS" if ok else "FAIL"


func _class_name(cls: int) -> String:
	match cls:
		RoadGraph.RoadClass.HIGHWAY: return "highway"
		RoadGraph.RoadClass.ARTERIAL: return "arterial"
		RoadGraph.RoadClass.STREET: return "street"
		_: return "lane"


func _write(out: String, report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var f := FileAccess.open("%s/w9-t71-audit.json" % out, FileAccess.WRITE)
	if f == null:
		push_error("[audit] cannot write %s" % out)
		return
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("[audit] wrote %s/w9-t71-audit.json" % out)


func _bail(why: String) -> void:
	push_error("[audit] %s" % why)
	quit(2)