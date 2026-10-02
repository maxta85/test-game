extends RefCounted
## Sanity checks on the authored road network. Run with: ./test.sh world

func run(t: TestHarness) -> void:
	var g := RoadGraph.new()
	g.build(ManundaLayout.corridors())
	var s: Dictionary = g.stats()

	t.gt(int(s["nodes"]), 40, "layout produces a real intersection graph (%d nodes)" % s["nodes"])
	t.gt(int(s["edges"]), 60, "layout produces a real road network (%d edges)" % s["edges"])
	t.gt(float(s["length_m"]), 6000.0, "network has real length (%.0f m)" % s["length_m"])
	t.gt(int(s["streets"]), 15, "the layout names a real set of streets (%d)" % s["streets"])

	await _ground_is_solid(t, g)
	await _solid(t, g)
	_connectivity(t, g)
	_geometry(t, g)
	_queries(t, g)
	_loops(t, g)


## A car must not fall out of the world when it leaves the road.
##
## This is here because it shipped broken and no test caught it. The road
## trimesh was the only collision in the scene - the terrain was drawn but had
## no collider - so driving off the kerb dropped the car into a void with
## nothing to catch it. The integration suite missed it because it builds its
## own flat ground instead of using WorldBuilder, so it never tested the world
## the player actually drives in.
func _ground_is_solid(t: TestHarness, g: RoadGraph) -> void:
	var world := t.new_root("WorldGroundTest")
	var b := WorldBuilder.new()
	world.add_child(b)
	b.build(g)
	await t.ticks(2)

	var terrain := world.find_child("TerrainCollision", true, false) as StaticBody3D
	t.ok(terrain != null, "terrain has a collision body")
	t.ok(world.find_child("RoadCollision", true, false) != null, "road has a collision body")

	# A point that is genuinely off-road. (0,0) is no good: it sits on a road, so
	# the car lands on the road trimesh and the test passes even with the terrain
	# collider deleted - which is exactly what it did the first time.
	#
	# Take a mid-block point on an edge and step well clear of it. 60 m is far
	# outside any carriageway width in the layout, so the only thing that can
	# catch the car here is the terrain.
	var e: Dictionary = g.edges[0]
	var ea: Vector2 = g.node_pos(int(e["a"]))
	var eb: Vector2 = g.node_pos(int(e["b"]))
	var mid: Vector2 = (ea + eb) * 0.5
	var away: Vector2 = mid + Vector2(-(eb - ea).y, (eb - ea).x).normalized() * 60.0
	var off: Dictionary = g.nearest_road(Vector3(away.x, 0.0, away.y))
	t.gt(float(off["lateral"]), 25.0,
		"the drop point really is off the road (%.1f m clear)" % float(off["lateral"]))

	var spec := CarDB.get_spec("kairo_s13")
	var car := CarBody.new()
	car.spec = spec
	world.add_child(car)
	car.reset_to(Vector3(away.x, 5.0, away.y), Vector3.ZERO)
	await t.ticks(300)

	# y > -1 rather than y > -20 on purpose: the outer safety floor has its top
	# at y = -2, so a loose bound would let a car sitting on that skirt pass while
	# the terrain trimesh did nothing at all. The terrain around the origin is
	# near zero, so landing on it is unambiguous.
	t.gt(car.global_position.y, -1.0,
		"a car dropped off the road lands on the terrain, not the fallback floor (y=%.2f)" % car.global_position.y)
	t.gt(int(car.wheels_on_ground), 2,
		"and it lands on its wheels (%d in contact)" % int(car.wheels_on_ground))
	t.between(absf(car.linear_velocity.y), 0.0, 1.0,
		"and it comes to rest rather than still falling (vy=%.2f)" % car.linear_velocity.y)

	await t.drop(world)


## Grid size for the road index this suite builds for itself. Same argument as
## the one in Tests/test_osm_buildings.gd, and for the same reason: a clearance
## check that asks the builder whether the builder did its job cannot fail.
## 60 m cells, and the 3x3 neighbourhood reaches further than any half-width plus
## the clearance being checked, so no offending corridor can be missed.
const ROAD_CELL := 60.0

static var _segs: Array = []
static var _grid: Dictionary = {}
static var _marked: Dictionary = {}


## Everything that can be hit, is.
##
## Four claims, and they are four because each can pass while the next fails:
## the geometry exists (faces in the buckets), it is where it should be (clear of
## every carriageway by 2.5 m), a car actually stops on it (physics, not a
## triangle count), and the things that are allowed to be driven through - scrub,
## and only scrub - are not given a collider.
func _solid(t: TestHarness, g: RoadGraph) -> void:
	var world := t.new_root("WorldSolidTest")
	var b := WorldBuilder.new()
	world.add_child(b)
	b.build(g)
	await t.ticks(2)

	var stats := b.solid_stats()
	var plan := OSMBuildings.plan(g)

	# 1. The geometry exists, and it exists for every footprint the plan kept.
	t.eq(int(stats.get("osm_buildings", 0)), int(plan["built"]),
		"every planned footprint contributed collision geometry (%d of %d)"
		% [int(stats.get("osm_buildings", 0)), int(plan["built"])])
	t.gt(int(stats.get("build_faces", 0)), 20000,
		"the walls are real triangles, not placeholders (%d)" % int(stats.get("build_faces", 0)))
	t.gt(int(stats.get("build_bodies", 0)), 4,
		"the wall colliders are bucketed, so the broadphase can reject a block (%d bodies)"
		% int(stats.get("build_bodies", 0)))
	t.gt(int(stats.get("prop_bodies", 0)), 4,
		"the props are bucketed too (%d bodies)" % int(stats.get("prop_bodies", 0)))

	var shapes := 0
	var empty := 0
	for child in b.get_children():
		var n := String(child.name)
		if not (n.begins_with("BuildingCollision") or n.begins_with("PropCollision")):
			continue
		shapes += 1
		var cs := (child as StaticBody3D).get_child(0) as CollisionShape3D
		if cs == null or not (cs.shape is ConcavePolygonShape3D) \
				or (cs.shape as ConcavePolygonShape3D).get_faces().is_empty():
			empty += 1
	t.eq(shapes, int(stats.get("build_bodies", 0)) + int(stats.get("prop_bodies", 0)),
		"every bucket became a body in the tree (%d)" % shapes)
	t.eq(empty, 0, "no bucket committed to an empty shape (%d)" % empty)

	# 2. It is where it should be. The artkit placements are the interesting half:
	# nothing else in this repo checks them, and before the setback became the
	# kind's own measured depth they stood with their balconies in the tarmac.
	_index(g)
	var plan_osm: Array = plan["buildings"]
	_worst_ring(t, plan_osm, WorldBuilder.BUILDING_CLEARANCE,
		"no mapped footprint comes within 2.5 m of a carriageway edge")

	var fill := b._artkit_fill(plan)
	var worst_building := INF
	var worst_prop := INF
	var worst_at := Vector2.ZERO
	var worst_kind := ""
	var buildings := 0
	var props := 0
	var scrub := 0
	for d in fill:
		var pos: Vector3 = d["pos"]
		var here := Vector2(pos.x, pos.z)
		var clear := INF
		if d.has("building"):
			buildings += 1
			# The box the collider was actually built from, corners and all, so
			# this measures the wall the car meets rather than the origin it grew
			# out of.
			clear = _box_clear(here, String(d["building"]), float(d.get("yaw", 0.0)),
				float(d.get("scale", 1.0)), b._kit_extent(String(d["building"])),
				WorldBuilder.BUILDING_CLEARANCE)
			if clear < worst_building:
				worst_building = clear
				worst_at = here
				worst_kind = String(d["building"])
		elif d.has("prop"):
			props += 1
			var kind := String(d["prop"])
			if kind in WorldBuilder.SOLID_FREE_PROPS:
				scrub += 1
			clear = _box_clear(here, kind, float(d.get("yaw", 0.0)),
				float(d.get("scale", 1.0)), b._prop_extent(kind), WorldBuilder.PROP_CLEARANCE)
			worst_prop = minf(worst_prop, clear)
	t.gt(buildings, 20, "the fill really did place kit buildings to check (%d)" % buildings)
	t.gt(props, 20, "and kit props to check (%d)" % props)
	t.ok(worst_building >= 0.0,
		"no kit building comes within 2.5 m of a carriageway edge (worst %.2f m, a %s at %.0f, %.0f)"
		% [worst_building, worst_kind, worst_at.x, worst_at.y])
	t.ok(worst_prop >= 0.0,
		"no solid kit prop comes within 1.0 m of a carriageway edge (worst %.2f m)" % worst_prop)

	# 3. Only scrub was left without a collider, and nothing was thrown away.
	t.eq(int(stats.get("kit_props_free", 0)), scrub,
		"the only props left unsolid are the ones a car drives through (%d scrub)" % scrub)
	t.gt(int(stats.get("kit_props_free", 0)), 0,
		"scrub is not solid, or the exclusion list is decorative")
	t.eq(int(stats.get("props_dropped", 0)), 0,
		"nothing had to be removed from the road: %s"
		% str((stats.get("props_dropped_reasons", []) as Array)))
	t.eq(int(stats.get("kit_skipped", 0)), 0, "the kit skipped no placement in the fill")
	t.eq(int(stats.get("kit_buildings", 0)) + int(stats.get("kit_props", 0))
		+ int(stats.get("kit_props_free", 0)), buildings + props,
		"every placement either got a collider or is on the pass-through list")

	# 4. A car actually stops. Everything above is a triangle count; this is a car
	#    with an initial velocity and 180 frames of physics behind it.
	await _car_stops_at_a_wall(t, world, plan_osm)

	# 5. And the screen that keeps props off the tarmac is a real function, not a
	#    comment: three placements it would never see from here.
	_screen_unit(t, g)

	await t.drop(world)


## Distance to a carriageway edge, from this suite's own index over the live
## graph. Negative means inside the tarmac.
static func _clear_at(p: Vector2) -> float:
	if _grid.is_empty():
		return INF
	var best := INF
	var cx := floori(p.x / ROAD_CELL)
	var cy := floori(p.y / ROAD_CELL)
	# A corridor's *edge* distance is what "too close to the road" means, so the
	# answer is the smallest `d - hw` and not the smallest `d`: a point 9.1 m
	# from a 6 m lane's centreline is 6.1 m clear of that lane and can still be
	# inside an 18 m highway further off. Growing the search one ring at a time
	# is what keeps that honest - a fixed 3x3 around `p` is only guaranteed to
	# hold everything within one cell of `p`, and a highway is allowed to be
	# wider than that and still be the nearest tarmac.
	var ring := 1
	while ring <= 32:
		for gx in range(cx - ring, cx + ring + 1):
			for gy in range(cy - ring, cy + ring + 1):
				if ring > 1 and absi(gx - cx) != ring and absi(gy - cy) != ring:
					continue
				for id in _grid.get(Vector2i(gx, gy), []):
					var e: Dictionary = _segs[id]
					var a: Vector2 = e["a"]
					var b: Vector2 = e["b"]
					var u := b - a
					var l2: float = u.length_squared()
					var tt: float = 0.0 if l2 < 1e-9 else clampf((p - a).dot(u) / l2, 0.0, 1.0)
					best = minf(best, p.distance_to(a + u * tt) - float(e["hw"]))
		if float(ring) * ROAD_CELL - 9.0 >= best:
			break
		ring += 1
	return best if best < INF else INF


static func _index(g: RoadGraph) -> void:
	if not _grid.is_empty():
		return
	for e in g.edges:
		var a: Vector2 = g.node_pos(int(e["a"]))
		var b: Vector2 = g.node_pos(int(e["b"]))
		if a.distance_squared_to(b) < 0.01:
			continue
		var id := _segs.size()
		_segs.append({"a": a, "b": b, "hw": g.width_for(int(e["class"])) * 0.5})
		var lo := Vector2i(floori(minf(a.x, b.x) / ROAD_CELL), floori(minf(a.y, b.y) / ROAD_CELL))
		var hi := Vector2i(floori(maxf(a.x, b.x) / ROAD_CELL), floori(maxf(a.y, b.y) / ROAD_CELL))
		for cx in range(lo.x, hi.x + 1):
			for cy in range(lo.y, hi.y + 1):
				var key := Vector2i(cx, cy)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(id)


## Worst clearance over every ring edge, sampled. Sampled, not exact: a polygon
## boolean would be the exact version and is not worth carrying here. The exact
## test lives in the builder and is checked independently in
## Tests/test_osm_buildings.gd; this is the same invariant asserted from the
## outside so neither can be the only witness for the other.
static func _worst_ring(t: TestHarness, entries: Array, want: float, label: String) -> void:
	var worst := INF
	var worst_id := 0
	for e in entries:
		var ring: PackedVector2Array = e["ring"]
		for i in ring.size():
			var a := ring[i]
			var b := ring[(i + 1) % ring.size()]
			var steps: int = maxi(int(a.distance_to(b) / 2.0), 1)
			for s in steps + 1:
				var c := _clear_at(a.lerp(b, float(s) / float(steps)))
				if c < worst:
					worst = c
					worst_id = int(e["id"])
	t.ok(worst >= want - 0.05,
		"%s (worst %.2f m, osm %d)" % [label, worst, worst_id])


## Worst clearance over the four rotated corners of a placement's box.
##
## `ext` is the builder's own measured extent, so this reuses its arithmetic; what
## it does not reuse is the answer. The corners, the rotation, the road index and
## the clearance rule are all computed here, and the road index is this suite's.
static func _box_clear(p: Vector2, _kind: String, yaw: float, scale: float,
		ext: Dictionary, want: float) -> float:
	var half_x := 0.0
	# The box's own -Z and +Z edges relative to the placement's origin. For a
	# building these are the measured front and back; for a prop the mesh box
	# around its own centre, which is not the origin - a bin's geometry starts
	# part-way up its own frame.
	var z_lo := 0.0
	var z_hi := 0.0
	if ext.has("half"):
		half_x = float(ext["half"]) * scale
		z_lo = -float(ext["front"]) * scale
		z_hi = float(ext["back"]) * scale
	else:
		var size: Vector3 = ext["size"]
		var centre: Vector3 = ext["centre"]
		half_x = absf(size.x) * 0.5 * scale
		z_lo = (centre.z - absf(size.z) * 0.5) * scale
		z_hi = (centre.z + absf(size.z) * 0.5) * scale
	var c := cos(yaw)
	var s := sin(yaw)
	var worst := INF
	for sx in [-1.0, 1.0]:
		for sz in [0.0, 1.0]:
			var local := Vector2(sx * half_x, lerpf(z_lo, z_hi, sz))
			var off := Vector2(local.x * c + local.y * s, -local.x * s + local.y * c)
			var clear := _clear_at(p + off)
			if clear < INF:
				worst = minf(worst, clear - want)
	return worst


## A car, at speed, aimed at a wall.
##
## Not a triangle count and not a raycast. The car is put down 9 m out from the
## middle of one ring edge, pointed at it, given 18 m/s and the throttle, and
## given three seconds of real physics. Two things then have to be true: it
## reported contact with a `BuildingCollision` body, and it is not inside the
## footprint afterwards. Either alone would pass with a broken world - the first
## because the car could touch the wall and still be pushed through it, the second
## because a car that never moved never gets inside anything.
func _car_stops_at_a_wall(t: TestHarness, world: Node3D, entries: Array) -> void:
	var target := _aim_point(entries)
	if target.is_empty():
		t.ok(false, "no footprint offered a wall to aim a car at")
		return
	var wall: Vector2 = target["wall"]
	var start: Vector2 = target["start"]

	var car := CarBody.new()
	car.spec = CarDB.get_spec("kairo_s13")
	car.build_visual = false
	# Both before the tree sees it: `contact_monitor` is only read when the body
	# enters the physics server, which is at add_child time, so setting it after
	# is a monitor that never turns on.
	car.contact_monitor = true
	car.max_contacts_reported = 8
	var hits: Array[String] = []
	car.body_entered.connect(func(body: Node) -> void:
		hits.append(String(body.name)))
	world.add_child(car)

	var dir := (wall - start).normalized()
	# CarBody drives -Z forward, so yaw is chosen to put -Z on `dir`. Vector2's
	# y is the world's Z; writing dir.z here is a parse error, not a typo.
	car.reset_to(Vector3(start.x, 1.2, start.y),
		Vector3(0.0, atan2(-dir.x, dir.y), 0.0))
	car.linear_velocity = Vector3(dir.x, 0.0, dir.y) * 18.0
	car.throttle = 0.5
	car.brake = 0.0
	await t.ticks(180)

	var wall_hit := 0
	for h in hits:
		if h.begins_with("BuildingCollision"):
			wall_hit += 1
	t.ok(wall_hit > 0, "the car reported contact with a building collider (%s)" % str(hits))
	t.gt(hits.size(), 0, "and the contact monitor was on at all (%d bodies)" % hits.size())
	t.fails(_in_ring(Vector2(car.global_position.x, car.global_position.z),
			target["ring"] as PackedVector2Array),
		"the car was stopped outside the footprint (at %.1f, %.1f, wall %.1f, %.1f)"
		% [car.global_position.x, car.global_position.z, wall.x, wall.y])
	# It has to have arrived, or "stopped outside" is a statement about a car that
	# never moved.
	t.gt(start.distance_to(Vector2(car.global_position.x, car.global_position.z)), 5.0,
		"and it got there before it stopped (%.1f m from where it started)"
		% start.distance_to(Vector2(car.global_position.x, car.global_position.z)))
	await t.drop(car)


## A long ring edge with clear ground 9 m out from it, so the car has somewhere
## to start that is not inside the building next door.
##
## The occupancy mark is the builder's own bounding-box grid, rebuilt here: a car
## that spawns overlapping a neighbour's wall would satisfy "contact with a
## building collider" while testing nothing about the wall it was aimed at.
static func _aim_point(entries: Array) -> Dictionary:
	if _marked.is_empty():
		for e in entries:
			var ring: PackedVector2Array = e["ring"]
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for q in ring:
				lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
				hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
			for cx in range(floori(lo.x / 16.0), floori(hi.x / 16.0) + 1):
				for cy in range(floori(lo.y / 16.0), floori(hi.y / 16.0) + 1):
					_marked[Vector2i(cx, cy)] = true
	for e in entries:
		var ring: PackedVector2Array = e["ring"]
		for i in ring.size():
			var a := ring[i]
			var b := ring[(i + 1) % ring.size()]
			if a.distance_to(b) < 9.0:
				continue
			var mid := (a + b) * 0.5
			# Same outward normal as OSMBuildings._band(): rings are wound so the
			# outside of a -> b is (dy, -dx).
			var n := Vector2(b.y - a.y, a.x - b.x).normalized()
			var start := mid + n * 9.0
			if _marked.has(Vector2i(floori(start.x / 16.0), floori(start.y / 16.0))):
				continue
			if _clear_at(start) < 0.0:
				continue
			return {"wall": mid, "start": start, "ring": ring}
	return {}


## `_screen_placements()` on placements the fill never produced, because the fill
## gets them right. Each case is a branch it has never had to take.
func _screen_unit(t: TestHarness, g: RoadGraph) -> void:
	var b := WorldBuilder.new()
	b.graph = g
	var lane := _lane_point(g)
	if lane.is_empty():
		t.ok(false, "no stretch of carriageway long enough to test the screen against")
		return
	var centre: Vector2 = lane["centre"]
	var side: Vector2 = lane["side"]
	var near_edge: Vector2 = centre + side * float(lane["hw"])

	# Dead centre of a lane: no "away" exists, so it has to be removed and said so.
	var centred := b._screen_placements([{"prop": "bin", "pos": Vector3(centre.x, 0.0, centre.y), "seed": 1}])
	t.eq(int(centred["dropped"]), 1, "a bin on a centreline is removed, not nudged (%s)"
		% str(centred["reasons"]))
	t.eq((centred["out"] as Array).size(), 0, "and it is not in the list any more")

	# Half a metre inside the carriageway edge: in the lane, but there is an away,
	# so it is moved rather than dropped, and the result is verified clear. This is
	# the placement the push distance has to be right for - start it anywhere
	# further in and one shove of a couple of metres is not enough to clear the
	# box, and the screen drops it.
	var off := b._screen_placements([{"prop": "bin", "pos": Vector3(near_edge.x, 0.0, near_edge.y), "seed": 2}])
	t.eq(int(off["moved"]), 1, "a bin half a metre inside the kerb is pushed out (%s)" % str(off["reasons"]))
	t.eq(int(off["dropped"]), 0, "and not thrown away")
	if (off["out"] as Array).size() == 1:
		var moved: Vector3 = (off["out"] as Array)[0]["pos"]
		t.ok(_clear_at(Vector2(moved.x, moved.z)) >= WorldBuilder.PROP_CLEARANCE,
			"the pushed-out bin is genuinely clear of the tarmac (%.2f m)"
			% _clear_at(Vector2(moved.x, moved.z)))

	# The same spot with a palm at four times scale, which makes its own half
	# diagonal about 1.5 m: the case where moving the origin clear is not the same
	# as moving the object clear.
	var wide := b._screen_placements([{"prop": "palm_fan",
		"pos": Vector3(near_edge.x, 0.0, near_edge.y), "scale": 4.0, "seed": 3}])
	t.eq(int(wide["dropped"]) + int(wide["moved"]), 1, "a palm in the lane is dealt with (%s)"
		% str(wide["reasons"]))
	for d in wide["out"]:
		var p: Vector3 = d["pos"]
		t.ok(b._prop_clear(Vector2(p.x, p.z), b._prop_extent("palm_fan"), 0.0, 4.0,
			b._road_grid()) >= 0.0, "and what came out is clear across its whole width")

	# Scrub, in the middle of the lane, is left exactly where it was: drawn, not
	# solid. This is the case that proves the pass-through list is doing work.
	var bush := b._screen_placements([{"prop": "bush_scrub", "pos": Vector3(centre.x, 0.0, centre.y), "seed": 4}])
	t.eq(int(bush["moved"]) + int(bush["dropped"]), 0, "scrub is not screened")
	t.eq((bush["out"] as Array).size(), 1, "scrub survives the screen")
	if (bush["out"] as Array).size() == 1:
		var p: Vector3 = (bush["out"] as Array)[0]["pos"]
		t.near(p.distance_to(Vector3(centre.x, 0.0, centre.y)), 0.0, 0.001,
			"and it is left in the middle of the road, where a car drives through it")


## A mid-street point with carriageway either side of it, plus that street's
## half-width. `edges[0]` will not do: an arbitrary edge's midpoint is as likely
## to be a junction as a street, and a point sitting on two centrelines has no
## "away" to be pushed along, which is the other branch entirely.
static func _lane_point(g: RoadGraph) -> Dictionary:
	var best: Dictionary = {}
	var best_len := 0.0
	for e in g.edges:
		var a: Vector2 = g.node_pos(int(e["a"]))
		var b: Vector2 = g.node_pos(int(e["b"]))
		var length := a.distance_to(b)
		if length <= best_len:
			continue
		var mid := (a + b) * 0.5
		var side := Vector2(-(b - a).y, (b - a).x).normalized()
		if _clear_at(mid + side) < 0.0 and _clear_at(mid - side) < 0.0 \
				and _clear_at(mid) < -1.0:
			best = {"centre": mid, "side": side, "hw": g.width_for(int(e["class"])) * 0.5}
			best_len = length
	return best


static func _in_ring(p: Vector2, ring: PackedVector2Array) -> bool:
	var inside := false
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		if (a.y > p.y) != (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x:
			inside = not inside
	return inside


func _connectivity(t: TestHarness, g: RoadGraph) -> void:
	# Flood fill from node 0 and check we reach everything.
	var seen := {0: true}
	var stack: Array = [0]
	while stack.size() > 0:
		var n: int = stack.pop_back()
		for eid in g.nodes[n]["edges"]:
			var nxt: int = g.other_node(eid, n)
			if not seen.has(nxt):
				seen[nxt] = true
				stack.append(nxt)
	t.eq(seen.size(), g.nodes.size(),
		"whole network is connected from a single node (%d/%d)" % [seen.size(), g.nodes.size()])

	# No orphan edges.
	var orphans := 0
	for e in g.edges:
		if g.nodes[int(e["a"])]["edges"].is_empty() or g.nodes[int(e["b"])]["edges"].is_empty():
			orphans += 1
	t.eq(orphans, 0, "no edge is orphaned")

	# A handful of dead ends is correct - this suburb has cul-de-sacs. A lot of
	# them would mean the grid never joined up.
	var dead_ends := 0
	for n in g.nodes:
		if n["edges"].size() < 2:
			dead_ends += 1
	# Streets are drawn running off the edge of the playable block, so their ends
	# dangle by design; the cul-de-sacs add a few more. A much larger number
	# would mean the grid never actually joined up.
	t.fails(float(dead_ends) > float(g.nodes.size()) * 0.30,
		"dead ends are the cul-de-sacs and the open map edge, not the grid (%d of %d)" % [dead_ends, g.nodes.size()])


func _geometry(t: TestHarness, g: RoadGraph) -> void:
	# No zero-length or absurdly long edges.
	var bad := 0
	var longest := 0.0
	for e in g.edges:
		var l: float = g.edge_length(int(e["id"]))
		longest = maxf(longest, l)
		if l < 0.5 or l > 400.0:
			bad += 1
	t.eq(bad, 0, "all edges are a sensible length (longest %.0f m)" % longest)

	# No duplicate nodes sitting on top of each other - that would mean the
	# welding failed and two streets cross without sharing a junction.
	var dupes := 0
	for i in g.nodes.size():
		for j in range(i + 1, g.nodes.size()):
			if g.node_pos(i).distance_to(g.node_pos(j)) < 0.5:
				dupes += 1
	t.eq(dupes, 0, "no two junctions occupy the same spot")

	# Class widths must be ordered: a highway is wider than a lane.
	t.fails(g.width_for(RoadGraph.RoadClass.HIGHWAY) <= g.width_for(RoadGraph.RoadClass.LANE),
		"highway is wider than a lane")
	t.fails(g.width_for(RoadGraph.RoadClass.ARTERIAL) <= g.width_for(RoadGraph.RoadClass.STREET),
		"arterial is wider than a street")
	t.fails(g.speed_for(RoadGraph.RoadClass.HIGHWAY) <= g.speed_for(RoadGraph.RoadClass.LANE),
		"highway speed limit exceeds a lane's")


func _queries(t: TestHarness, g: RoadGraph) -> void:
	# A point on a known street must snap back to it.
	var on_road := Vector3(120.0, 0.0, 40.0)     # should be on BRUCE ROAD
	var near: Dictionary = g.nearest_road(on_road)
	t.gt(int(near["edge"]), -1, "nearest_road finds a road under a point on it")
	t.near(float(near["lateral"]), 0.0, 1.5, "point on the arterial snaps onto the arterial")
	var e: Dictionary = g.edges[int(near["edge"])]
	t.eq(String(e["name"]), "BRUCE ROAD", "and it is the arterial we expect")

	# A point far off the network still returns something sane.
	var off: Dictionary = g.nearest_road(Vector3(640.0, 0.0, 640.0))
	t.gt(float(off["lateral"]), 0.0, "a point off-road reports a positive offset")

	# Edge traversal must be symmetric.
	var eid: int = 0
	var a: int = int(g.edges[eid]["a"])
	var b: int = int(g.edges[eid]["b"])
	t.eq(g.other_node(eid, a), b, "other_node walks a->b")
	t.eq(g.other_node(eid, b), a, "other_node walks b->a")

	# point_on_edge clamps instead of running off the end.
	var p0: Vector3 = g.point_on_edge(eid, -50.0, true)
	var p1: Vector3 = g.point_on_edge(eid, 9999.0, true)
	t.near(p0.distance_to(p1), g.edge_length(eid), 0.5, "point_on_edge spans the edge and clamps")


func _loops(t: TestHarness, g: RoadGraph) -> void:
	# A circuit race needs a closed loop through real streets.
	var loop: Array = g.find_loop(0, 700.0)
	t.gt(loop.size(), 4, "a closed racing circuit exists (%d nodes)" % loop.size())
	if loop.size() > 1:
		t.eq(int(loop[0]), int(loop[loop.size() - 1]), "the circuit returns to where it started")
		var length := 0.0
		for i in loop.size() - 1:
			length += g.node_pos(int(loop[i])).distance_to(g.node_pos(int(loop[i + 1])))
		t.gt(length, 400.0, "the circuit is long enough to race (%.0f m)" % length)

		# Node count and total length are NOT enough. find_loop used to return a
		# 2283 m, 30-junction loop with a 0 x 1142 m bounding box: the walk ran
		# to the map edge and came straight back down the same street. Both
		# assertions above passed, and the result was undriveable. A circuit has
		# to cover ground on both axes.
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for n in loop:
			var p: Vector2 = g.node_pos(int(n))
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var extent := hi - lo
		t.gt(extent.x, 150.0, "the circuit has real width, it is not a there-and-back (%.0f m)" % extent.x)
		t.gt(extent.y, 150.0, "and real depth (%.0f m)" % extent.y)
