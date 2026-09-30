extends RefCounted
## The shipped map is real OpenStreetMap data for western Cairns, not the
## authored Manunda block. Run with: ./test.sh osm
##
## These are the checks that catch the two ways a real-world map import goes
## wrong: the geometry does not survive the projection, or the network is not
## actually a connected drivable city.

static var _last_graph: RoadGraph


func run(t: TestHarness) -> void:
	_file(t)
	_corridors(t)
	_graph(t)
	_placements(t, _last_graph)


func _file(t: TestHarness) -> void:
	t.ok(OSMLayout.available(), "map file loads (run Tools/osm_cairns.py if not)")

	var s: Dictionary = OSMLayout.stats()
	t.gt(int(s.get("corridors", 0)), 150, "real street count (%d corridors)" % int(s.get("corridors", 0)))
	t.gt(float(s.get("total_km", 0.0)), 20.0, "real street length (%.1f km)" % float(s.get("total_km", 0.0)))

	# The projection is the one thing that can silently go wrong by a factor:
	# forgetting cos(latitude) stretches Cairns ~7% and nothing else complains.
	var extent: Array = s.get("extent_m", [0.0, 0.0])
	t.ok(float(extent[0]) > 1000.0 and float(extent[0]) < 3000.0,
		"east-west extent is city-sized, not 7%% off (%.0f m)" % float(extent[0]))
	t.ok(float(extent[1]) > 1000.0 and float(extent[1]) < 3000.0,
		"north-south extent is city-sized (%.0f m)" % float(extent[1]))


func _corridors(t: TestHarness) -> void:
	var cs := OSMLayout.corridors()
	t.gt(cs.size(), 150, "corridors() is populated (%d)" % cs.size())

	var named := 0
	var arterial := 0
	var degenerate := 0
	for c in cs:
		if not String(c["name"]).is_empty():
			named += 1
		if int(c["class"]) >= RoadGraph.RoadClass.ARTERIAL:
			arterial += 1
		if (c["points"] as PackedVector2Array).size() < 2:
			degenerate += 1
	t.eq(degenerate, 0, "every corridor has at least two points")
	t.gt(named, cs.size() * 8 / 10, "most streets keep their real OSM name (%d/%d)" % [named, cs.size()])
	t.gt(arterial, 2, "there is a real arterial to race on (%d)" % arterial)

	# Every point inside the fetched bbox, in metres. A point at |z| > 4000 means
	# the axis convention flipped (OSM is +north up, the game is +Z south).
	var worst := 0.0
	for c in cs:
		for p in c["points"]:
			worst = maxf(worst, absf(p.x))
			worst = maxf(worst, absf(p.y))
	t.ok(worst < 2000.0, "no corridor escapes the map (worst coord %.0f m)" % worst)

	# The grid and the car meet have to land on the anchor street, not in a
	# paddock. Anchoring them to real geometry is the point of doing this at all.
	t.ok(OSMLayout.start_grid_position(1).distance_to(OSMLayout.start_grid_position(0)) > 0.1,
		"grid slots are staggered, not stacked")
	t.ok(OSMLayout.car_meet_position().distance_to(OSMLayout.start_grid_position(0)) > 5.0,
		"car meet is not on the start line")


func _graph(t: TestHarness) -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	_last_graph = g
	var s := g.stats()
	t.gt(int(s["nodes"]), 100, "real Cairns yields a real intersection graph (%d nodes)" % int(s["nodes"]))
	t.gt(int(s["edges"]), 150, "real Cairns yields a real road network (%d edges)" % int(s["edges"]))
	t.gt(float(s["length_m"]), 20000.0, "network has real length (%.0f m)" % float(s["length_m"]))
	t.gt(int(s["streets"]), 20, "the map names a real set of streets (%d)" % int(s["streets"]))

	# Raw OSM imports islands: pockets joined only by a service way we dropped,
	# plus stubs clipped at the bbox edge. Tools/osm_cairns.py dissolves those, so
	# this is an exact assertion - and it is load-bearing, because traffic routing
	# and race circuits both assume there is only one network.
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
		"whole network is one connected city (%d/%d nodes)" % [seen.size(), g.nodes.size()])
	# A circuit has to exist here or the race system has nothing to build. Real
	# suburb geometry is not the out-and-back Manunda used to hand back.
	var edges_seen := 0
	for i in g.nodes.size():
		for eid in g.nodes[i]["edges"]:
			if g.other_node(eid, i) > i:
				edges_seen += 1
	t.gt(edges_seen, 100, "network has plenty of intersections to race around (%d)" % edges_seen)


## The real failure mode of anchoring to a real street: the numbers look sane and
## the car quietly spawns in somebody's living room. Assert the three placements
## are on the carriageway, not merely somewhere in the suburb.
func _placements(t: TestHarness, g: RoadGraph) -> void:
	for label in ["grid0", "grid1", "carmeet"]:
		var p := Vector3.ZERO
		match label:
			"grid0": p = OSMLayout.start_grid_position(0)
			"grid1": p = OSMLayout.start_grid_position(1)
			"carmeet": p = OSMLayout.car_meet_position()
		var nr: Dictionary = g.nearest_road(p)
		var offset: float = float(nr["lateral"])
		var half: float = g.width_for(int(g.edges[int(nr["edge"])]["class"])) * 0.5
		t.ok(offset <= half,
			"%s is on the carriageway, %.1f m off a %.1f m half-width" % [label, offset, half])
