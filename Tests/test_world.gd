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

	_connectivity(t, g)
	_geometry(t, g)
	_queries(t, g)
	_loops(t, g)


func _connectivity(t: TestHarness, g: RoadGraph) -> void:
	# A road network that is not connected is not a city, it is several cities.
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
