extends RefCounted
## Route legibility: the minimap and the marked-out circuit. Run with:
## ./test.sh 2legibility
##
## These two features exist because the player was driving 31.7 km of real
## Cairns street with no way to see where they were or where the route went. The
## tests here are about that claim specifically, on the *real* OSM graph rather
## than the authored block:
##
##   - the map is drawn from the same RoadGraph the streets are built from, at
##     real positions, and the whole network fits the widget
##   - north is up, and in rotate mode the player's heading is up - the classic
##     minimap bug, so it is asserted on a known heading rather than eyeballed
##   - the route on the map is the same polyline the barriers are built along
##   - the route is a genuine closed loop on the graph: first junction == last,
##     and every consecutive pair joined by a real edge. A "circuit" that is
##     merely a list of nearby junctions is not a circuit.
##
## Everything is driven through the public surface (`set_graph`, `set_route`,
## `set_player`, `build`) the way `Game/main.gd` drives them. Nothing here reaches
## into a private field to make an assertion pass except where the thing being
## checked is genuinely the transform, which is exposed for that reason.

var t: TestHarness
var tree: SceneTree
var g: RoadGraph
var board: Array = []
var circuit: RaceDef = null
var sprint: RaceDef = null


func run(t: TestHarness) -> void:
	self.t = t
	tree = t.tree
	# The real map, not ManundaLayout. The whole complaint is about the real
	# 31.7 km network, so testing the authored block would prove nothing.
	g = RoadGraph.new()
	g.build(OSMLayout.corridors() if OSMLayout.available() else ManundaLayout.corridors())
	board = RaceDef.catalogue(g)
	for d in board:
		if not d.valid():
			continue
		if d.closed and circuit == null:
			circuit = d
		if not d.closed and sprint == null:
			sprint = d

	_the_map_is_the_real_network(t)
	_orientation(t)
	_the_route_is_the_marked_route(t)
	_a_closed_loop_on_the_graph(t)
	_the_marks_are_built_from_the_route(t)
	_the_map_reads_live_positions(t)
	await _in_the_hud(t)


# ------------------------------------------------------------------ the network

## A minimap that draws its own picture of the city instead of the one the car is
## driving on is worse than no minimap, so the first thing checked is that its
## geometry is the graph the world was built from.
func _the_map_is_the_real_network(t: TestHarness) -> void:
	var stats := g.stats()
	t.eq(int(stats["nodes"]), 359, "the real network is 359 junctions")
	t.eq(int(stats["edges"]), 401, "and 401 edges")
	t.gt(float(stats["length_m"]), 31000.0, "of %.1f km of street" % (float(stats["length_m"]) / 1000.0))

	var m := await _map()
	t.eq(m._road_segments.size(), int(stats["edges"]),
		"the map draws every edge of the graph, not a subset")

	# A rectangle placeholder would be four segments. This is the assertion that
	# makes "real Manunda geometry, not a placeholder" checkable.
	t.gt(float(m._road_segments.size()), 100.0, "the map is real geometry, not a placeholder rectangle")

	# Whole network inside the widget: a map cropped to the street you are on
	# cannot tell you where the route goes.
	var out := 0
	var half: float = m.size.x * 0.5 + 1.0
	for seg in m._road_segments:
		for p in seg:
			if absf(p.x) > half or absf(p.y) > half:
				out += 1
	t.eq(out, 0, "and the whole network fits the widget")

	# One scale for both axes, so a corner cannot lie about its bearing: a map
	# stretched to fit would show a right-angle junction as a wide angle.
	var sx := m._scale
	t.gt(float(sx), 0.0, "the map is scaled to the network (%.4f px/m)" % sx)
	t.eq(m._graph, g, "and it is reading the graph the world was built from")


func _orientation(t: TestHarness) -> void:
	var m := await _map()
	m.set_rotate(true)

	# Driving north (-Z). Screen Y grows downward, and the map data's axes are
	# +X east / +Z south, so north must be up with no flip anywhere.
	m.set_player(Vector3(0, 0, 0), Vector3(0, 0, -1))
	t.near(m._spin_for(), 0.0, 0.001, "driving north, the map is unrotated")
	t.near(m._screen_dir(Vector2(0, -1)).y, -1.0, 0.001, "north points up the screen")
	t.near(m._screen_dir(Vector2(1, 0)).x, 1.0, 0.001, "east points right")

	# Driving east: the map turns a quarter turn so the heading is up.
	m.set_player(Vector3(0, 0, 0), Vector3(1, 0, 0))
	t.near(m._spin_for(), -PI * 0.5, 0.001, "driving east, the map turns a quarter turn")
	t.near(m._screen_dir(Vector2(1, 0)).y, -1.0, 0.001, "and the player's heading is up the screen")

	# Driving south: half a turn.
	m.set_player(Vector3(0, 0, 0), Vector3(0, 0, 1))
	t.near(absf(m._spin_for()), PI, 0.01, "driving south, the map turns half way round")
	t.near(m._screen_dir(Vector2(0, 1)).y, -1.0, 0.01, "and south is up the screen")

	# North-up: the world stays still, which is the point of the second mode.
	m.set_rotate(false)
	t.eq(m._spin_for(), 0.0, "north-up does not turn the map at all")
	m.set_player(Vector3(0, 0, 0), Vector3(1, 0, 0))
	t.near(m._screen_dir(Vector2(1, 0)).x, 1.0, 0.001, "and east is still right")
	m.set_rotate(true)


# --------------------------------------------------------------------- the route

## The line on the map has to be the line the barriers sit on. `main.gd` feeds
## the marker into the map precisely so this cannot be two drifting copies, and
## this checks the hand-over actually happens.
func _the_route_is_the_marked_route(t: TestHarness) -> void:
	if circuit == null:
		t.ok(false, "the map has a closed circuit to draw")
		return
	var marker := TrackMarker.new()
	tree.root.add_child(marker)
	marker.build(g, circuit)

	var pts: Array = marker.route_points()
	t.eq(pts.size(), circuit.path.size(), "the marker's route is the definition's junction list")
	t.eq(int(circuit.path[0]), int(circuit.path[circuit.path.size() - 1]),
		"the circuit comes back to where it started")

	var m := await _map()
	m.set_route(marker.route_points(), circuit.closed)
	var drawn: Array = m._px_route()
	t.eq(drawn.size(), pts.size(), "the map draws every junction of the route")

	# The drawn polyline is the world polyline, scaled about the centre. Same
	# points in, same points out: no re-derivation, so no drift.
	var same := true
	for i in pts.size():
		var want: Vector2 = (Vector2(pts[i]) - m._origin) * m._scale
		if drawn[i].distance_to(want) > 0.001:
			same = false
	t.ok(same, "and the drawn line is the marker's own geometry, not a second copy")

	await t.drop(marker)
	m.set_route([], false)


## The requirement that the circuit is an actual closed loop on the graph, not a
## hand-drawn approximation: the first junction is the last, and every step of
## the way round is a real edge of the road network.
func _a_closed_loop_on_the_graph(t: TestHarness) -> void:
	if circuit == null:
		t.ok(false, "the board has a closed circuit")
		return
	var marker := TrackMarker.new()
	tree.root.add_child(marker)
	marker.build(g, circuit)

	t.ok(marker.is_closed(), "%s is a closed loop on the graph" % circuit.display_name)
	t.gt(float(circuit.length_m(g)), 400.0, "of a real distance (%.0f m)" % circuit.length_m(g))

	# Checked edge by edge rather than trusting `is_closed`, so a route that was
	# only closed in name would still fail here.
	var joins := 0
	var steps := circuit.path.size() - 1
	for i in steps:
		if _edge_between(int(circuit.path[i]), int(circuit.path[i + 1])) >= 0:
			joins += 1
	t.eq(joins, steps, "every step of the loop is a real edge (%d/%d)" % [joins, steps])

	# It has to go round something. A there-and-back is closed and long and is
	# what this exact network produces if the route is walked rather than grown.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in circuit.path:
		var p: Vector2 = g.node_pos(int(n))
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	t.gt(hi.x - lo.x, 120.0, "and it covers ground east-west (%.0f m)" % (hi.x - lo.x))
	t.gt(hi.y - lo.y, 120.0, "and north-south (%.0f m)" % (hi.y - lo.y))

	await t.drop(marker)


## The marks themselves: real geometry, built along the route, on the road.
func _the_marks_are_built_from_the_route(t: TestHarness) -> void:
	var marker := TrackMarker.new()
	tree.root.add_child(marker)
	marker.build(g, circuit)
	var inst := _count_meshes(marker)
	t.gt(float(inst), 4.0, "the route is marked with real geometry (%d mesh instances)" % inst)

	# Barriers down both sides, chevrons on the road, a line and posts at the
	# start. Counted as instances, so a route that produced barriers but no start
	# line would show fewer batches than one that produced both.
	var total := 0
	for n in _descendants(marker):
		if n is MultiMeshInstance3D:
			total += int((n as MultiMeshInstance3D).multimesh.instance_count)
	t.gt(float(total), 50.0, "with %d marks along the route" % total)

	# The start/finish is a place on the road, and it is where the route says.
	var route_pts: Array = marker.route_points()
	var start: Vector2 = route_pts[0]
	var line_pos: Vector2 = g.node_pos(int(circuit.path[0]))
	t.near(start.distance_to(line_pos), 0.0, 0.001,
		"the marks start on the definition's first junction")

	# Nothing here is a collider: this street network is shared with civilian
	# traffic and a barrier you bounce off mid-corner is a worse bug than one you
	# clip through.
	var bodies := 0
	for n in _descendants(marker):
		if n is CollisionShape3D or n is StaticBody3D or n is Area3D:
			bodies += 1
	t.eq(bodies, 0, "the marks are visual only, nothing to hit")

	# Rebuilding is what a restart does, so it must not double up.
	marker.build(g, circuit)
	var again := 0
	for n in _descendants(marker):
		if n is MultiMeshInstance3D:
			again += int((n as MultiMeshInstance3D).multimesh.instance_count)
	t.eq(again, total, "rebuilding the marks replaces them rather than stacking a second copy")

	# A sprint is a point-to-point route and must still be markable; only the
	# closure check differs.
	if sprint != null:
		var sm := TrackMarker.new()
		tree.root.add_child(sm)
		sm.build(g, sprint)
		t.gt(float(_count_meshes(sm)), 4.0, "a point-to-point route is marked too")
		t.fails(sm.is_closed(), "and it is honestly not a closed loop")
		await t.drop(sm)

	await t.drop(marker)


# ------------------------------------------------------------------- live input

## The map has to track the car, or it is a picture of the city taken once.
func _the_map_reads_live_positions(t: TestHarness) -> void:
	var m := await _map()
	m.set_rotate(false)
	m.set_player(Vector3(0, 0, 0), Vector3(1, 0, 0))
	var at_origin := m._screen_point(Vector2(0, 0))

	var car := StubCar.new()
	car.position = Vector3(400.0, 0.0, 300.0)
	car.facing = Vector3(0, 0, -1)
	m.set_player(car.position, car.facing)
	var moved := m._screen_point(Vector2(400.0, 300.0))
	t.gt(moved.distance_to(at_origin), 4.0,
		"moving 500 m moves the player on the map (%.1f px)" % moved.distance_to(at_origin))

	# A rival's position and heading both have to come through, and the heading
	# has to be turned with the map or every dot points the same way.
	m.set_rivals([car])
	t.eq(m._rivals.size(), 1, "the field is on the map")
	t.near(float(m._rivals[0]["heading"]), -PI * 0.5, 0.001,
		"with the rival's heading, not a default")
	m.set_rotate(true)
	m.set_player(Vector3(400, 0, 300), Vector3(0, 0, -1))
	var turned := Vector2.from_angle(float(m._rivals[0]["heading"])).rotated(m._spin)
	t.near(turned.y, -1.0, 0.001, "and a rival's heading turns with the map, like the player's")
	m.set_rotate(false)
	m.set_rivals([])


## The HUD is where the player meets this, so it has to be there and wired to the
## same graph - and only while there is a race to show.
func _in_the_hud(t: TestHarness) -> void:
	var hud := RaceHUD.new()
	tree.root.add_child(hud)
	await tree.process_frame

	t.ok(hud.minimap != null, "the HUD carries a minimap")
	if hud.minimap == null:
		return
	t.eq(hud.minimap._graph, null, "which starts with no map")

	hud.minimap.set_graph(g)
	t.eq(hud.minimap._graph, g, "and takes the graph the world was built from")
	t.eq(hud.minimap._road_segments.size(), int(g.stats()["edges"]),
		"so it draws the whole real network")

	# The map only makes sense with a route on it. `race.def` is the director's
	# gate: no definition, no route, nothing to map.
	hud.visible = true
	hud.update(null, _director_with(null), 0.016)
	t.fails(hud.minimap.visible, "and stays hidden when there is no route to show")

	hud.update(null, _director_with(circuit), 0.016)
	t.ok(hud.minimap.visible, "appearing once a race is actually running")


func _director_with(d: RaceDef) -> RaceDirector:
	var r := RaceDirector.new()
	r.def = d
	r.entrants = [StubCar.new()]
	return r


func _map() -> Minimap:
	var m := Minimap.new()
	m.size = Vector2(236, 236)
	tree.root.add_child(m)
	m.set_graph(g)
	await tree.process_frame
	await tree.process_frame
	return m


func _edge_between(a: int, b: int) -> int:
	for eid in g.nodes[a]["edges"]:
		if g.other_node(int(eid), a) == b:
			return int(eid)
	return -1


func _descendants(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _count_meshes(root: Node) -> int:
	var n := 0
	for c in _descendants(root):
		if c is MultiMeshInstance3D:
			n += 1
	return n


## The only contract the map and the results board need from a car.
class StubCar extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var facing: Vector3 = Vector3.FORWARD