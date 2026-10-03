extends RefCounted
## Subgrade: the ground under the street network must not bury the street.
##
## This shipped broken and the existing suites could not see it. `test_world`
## proved the terrain HAS a collider (it dropped a car off-road and it landed),
## and every look-dev pose measured the road band, which is the tarmac mesh - not
## the ground trying to cover it. So the terrain could rise over the carriageway
## and 2093 assertions stayed green.
##
## The cause was a resolution mismatch, and it is worth writing down because the
## fix reads like a no-op otherwise. `_terrain_height()` flattened ground toward
## y=0 near a road, which is 15 mm BELOW `LookDev.TARMAC_Y`, so on the centreline
## the road won. But the height is only sampled at grid vertices, the grid is
## `max(16, extent/55)` = 27.5 m across, and the widest carriageway in this map is
## 14 m. A cell is twice the width of the road it has to clear, so the quad
## spanning a road interpolated between a flattened vertex and an unflattened one
## and ramped back up over the carriageway - and whether any vertex landed inside
## the road at all was luck.
##
## The fix is two parts, and both are needed: carve the corridor to a level below
## the tarmac (`CARVE_Y`), and subdivide any grid cell that could reach a corridor
## so the carve is resolved by a sample instead of interpolated across.

## Raycast straight down from above the tallest thing here. High enough to clear
## a building, low enough that the OuterFloor skirt (40 m thick, top at y=-2) is
## never the thing being measured.
const PROBE_FROM := 40.0

## How far above the tarmac the first hit may land and still count as "the road
## won". The tarmac is a trimesh at exactly TARMAC_Y, so this is slack for
## float error in the collider, not a licence for the terrain to peek through.
const ROAD_TOL := 0.02

## Metres either side of the centreline that counts as carriageway to sample.
## Narrower than the paved corridor on purpose: this asks "can a wheel find
## tarmac", not "is the verge tidy".

## The colliders that are GROUND. A ray straight down from 40 m does not hit the
## road first in this world - the overhead power wires sag across the carriageway
## at about 6.9 m, and a building or a sign can overhang it. The first hit of a
## naive downward ray is therefore frequently neither the road nor the terrain,
## which is not a subgrade defect at all. So the probe walks past anything that
## is not ground and asks again.
const GROUND_COLLIDERS := ["TerrainCollision", "RoadCollision", "OuterFloor"]

## How many times one ray may be stepped past a non-ground collider before it is
## given up on. Generous enough for a pole, a wire and a tree in one column.
const MAX_RAY_STEPS := 12


func run(t: TestHarness) -> void:
	var g := RoadGraph.new()
	g.build(ManundaLayout.corridors())

	var world := t.new_root("WorldSubgradeTest")
	var b := WorldBuilder.new()
	world.add_child(b)
	b.build(g)
	await t.ticks(2)

	await _terrain_is_below_the_road(t, world, b, g)
	await _carve_holds_across_the_carriageway(t, world, b, g)
	_carve_is_bounded(t, b, g)
	_carve_actually_carves(t, b, g)
	_grid_is_subdivided(t, b, g)
	await t.drop(world)


## Topmost GROUND surface directly under a world point, or -INF if there is none.
## Steps past anything that is not ground.
func _ground_under(space: PhysicsDirectSpaceState3D, x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.new()
	var from_y := PROBE_FROM
	for _step in MAX_RAY_STEPS:
		params.from = Vector3(x, from_y, z)
		params.to = Vector3(x, -PROBE_FROM, z)
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			return -INF
		var at: Vector3 = hit["position"]
		var col := hit["collider"] as Node
		if col != null and GROUND_COLLIDERS.has(col.name):
			return at.y
		from_y = at.y - 0.05
	return -INF


## The headline check, and the one that was failing: drop a ray on the carriageway
## of every edge in the network and require the FIRST thing it hits to be the
## road, not the ground.
func _terrain_is_below_the_road(t: TestHarness, world: Node3D, _b: WorldBuilder,
		g: RoadGraph) -> void:
	var space := world.get_world_3d().direct_space_state
	var buried := 0
	var probed := 0
	var missed := 0
	var worst := -INF
	var worst_where := ""

	for eid in g.edges.size():
		var e: Dictionary = g.edges[eid]
		var a := g.node_pos(int(e["a"]))
		var bpos := g.node_pos(int(e["b"]))
		var half: float = float(e["width"]) * 0.5
		var ab := bpos - a
		if ab.length_squared() < 1.0:
			continue
		var nrm := Vector2(-ab.y, ab.x).normalized()
		# Three stations down the edge, five across it. The across samples are
		# the point: a carve that only holds on the centreline passes a
		# centreline-only test.
		for i in range(3):
			var f := (float(i) + 0.5) / 3.0
			var p := a.lerp(bpos, f)
			for k in range(-2, 3):
				var q := p + nrm * (float(k) * half / 2.0)
				var y := _ground_under(space, q.x, q.y)
				if y == -INF:
					missed += 1
					continue
				probed += 1
				if y > LookDev.TARMAC_Y + ROAD_TOL:
					buried += 1
					if y > worst:
						worst = y
						worst_where = "edge %d f=%.1f lateral=%+.1f" % [eid, f, float(k) * half / 2.0]

	t.eq(buried, 0, "terrain buries no carriageway (%d rays, worst y=%.3f at %s)"
			% [probed, worst, worst_where])
	t.gt(float(probed), 500.0, "the subgrade probe actually probed the network (%d rays)" % probed)
	t.eq(missed, 0, "every carriageway sample found ground under it (%d found none)" % missed)


## The analytic half of the same claim, checked independently of the collider: at
## every paved station the height function must report the carve, not natural
## ground. Raycasts go through a trimesh and can be satisfied by a lucky triangle
## order; this cannot.
func _carve_holds_across_the_carriageway(t: TestHarness, _world: Node3D, b: WorldBuilder,
		g: RoadGraph) -> void:
	var highest := -INF
	var offenders := 0
	for eid in g.edges.size():
		var e: Dictionary = g.edges[eid]
		var a := g.node_pos(int(e["a"]))
		var bpos := g.node_pos(int(e["b"]))
		var half: float = float(e["width"]) * 0.5
		var ab := bpos - a
		if ab.length_squared() < 1.0:
			continue
		var nrm := Vector2(-ab.y, ab.x).normalized()
		for i in range(7):
			var p := a.lerp(bpos, (float(i) + 0.5) / 7.0)
			for k in range(-2, 3):
				var q := p + nrm * (float(k) * half / 2.0)
				var h := b._terrain_height(q.x, q.y)
				highest = maxf(highest, h)
				if h > LookDev.TARMAC_Y:
					offenders += 1
	t.eq(offenders, 0, "carve holds everywhere the road is paved (worst y=%.3f, tarmac %.3f)"
			% [highest, LookDev.TARMAC_Y])


## The carve must be a carve, not a flattening. If the far field came back at
## CARVE_Y too then the whole map would be a table at -0.14 and this suite would
## be green for the wrong reason - the same failure mode as a silent fallback.
func _carve_is_bounded(t: TestHarness, b: WorldBuilder, g: RoadGraph) -> void:
	var flat := 0
	var samples := 0
	var tallest := -INF
	for i in range(24):
		for j in range(24):
			var q := Vector2(-1400.0 + float(i) * 120.0, -1400.0 + float(j) * 120.0)
			var near := g.nearest_road(Vector3(q.x, 0.0, q.y))
			if float(near["lateral"]) < 90.0:
				continue
			samples += 1
			var h := b._terrain_height(q.x, q.y)
			tallest = maxf(tallest, h)
			if absf(h - WorldBuilder.CARVE_Y) < 0.001:
				flat += 1
	t.gt(float(samples), 100.0, "the far-field sample actually reached open ground (%d)" % samples)
	t.eq(flat, 0, "open ground is left at natural height, not carved flat (%d flat of %d, tallest %.3f)"
			% [flat, samples, tallest])
	t.gt(tallest, WorldBuilder.CARVE_Y + 0.5, "open ground still has real relief (%.3f)" % tallest)


## Assert the grid is actually subdivided near the roads, rather than trusting that
## it is. The raycast above only samples points along each edge's centreline, so it
## can pass without ever visiting a cell that straddles the road diagonally - which
## is exactly the cell a 27.5 m quad needs in order to ramp back up over a 14 m
## carriageway. Measured: with `CARVE_SUBDIV = 1` every other assertion in this
## suite still passed, because the hard corridor carve alone is enough for the
## points the raycast happens to visit. So the subdivision is justified by the
## render, not by the raycast, unless something here pins it.
func _grid_is_subdivided(t: TestHarness, b: WorldBuilder, g: RoadGraph) -> void:
	var coarse := 0
	var cells := 0
	var step: float = b._terrain_step()
	for x in range(-700, 700, 40):
		for z in range(-700, 700, 40):
			var n := b._cell_subdivisions(Vector2(float(x), float(z)), step)
			cells += 1
			if n <= 1:
				coarse += 1
	t.ok(coarse * 4 < cells,
			"cells within reach of a corridor are subdivided (%d of %d sample cells still coarse)" % [coarse, cells])


## And the carve must actually be doing something. A test that only checks the
## road is clear passes just as happily if `_terrain_height` returns -1000 for the
## whole map, so this pins the corridor surface between the two bounds the carve
## actually guarantees: never above the carved level (that is the whole point -
## it is what keeps the ground off the tarmac) and never absurdly far below it
## (which would mean the carve had become a pit rather than a level cut).
##
## Note it is `<=`, not `==`: the carve takes `min(natural, CARVE_Y)`, so where the
## natural ground is already below the road - a creek hollow - it is left alone and
## the corridor surface is *below* CARVE_Y. Asserting equality here is what made
## the carve fill a 1.3 m hollow and put the ground through the creek's water
## surface; the `water` suite caught that, not this one.
func _carve_actually_carves(t: TestHarness, b: WorldBuilder, g: RoadGraph) -> void:
	var e: Dictionary = g.edges[0]
	var a := g.node_pos(int(e["a"]))
	var bpos := g.node_pos(int(e["b"]))
	var mid := a.lerp(bpos, 0.5)
	var h := b._terrain_height(mid.x, mid.y)
	t.ok(h <= WorldBuilder.CARVE_Y + 0.001,
			"the corridor is never above the carved level (%.3f, max %.3f)" % [h, WorldBuilder.CARVE_Y])
	t.gt(h, WorldBuilder.CARVE_Y - 1.0,
			"and it is a level cut, not a pit (%.3f, floor %.3f)" % [h, WorldBuilder.CARVE_Y - 1.0])
	t.ok(h < LookDev.TARMAC_Y, "the carve sits under the tarmac (%.3f < %.3f)" % [h, LookDev.TARMAC_Y])