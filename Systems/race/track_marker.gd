class_name TrackMarker
extends Node3D
## The route, made visible. Markers out a race the player is about to drive.
##
## Every `RaceDef` already holds a real closed loop on the road graph - junction
## ids that share real edges and come back to where they started. The player
## could not see any of it: the route was geometry-less data, so a circuit asked
## you to guess which way round a 31.7 km street network to drive, at junctions,
## with nothing but the "wrong way" warning once you were already lost.
##
## So the route is marked on the road the same way a real street circuit is, and
## the marks are built from the same `RoadGraph` the streets themselves are:
##
##   - barriers down both sides of every segment, so the corridor is visible from
##     the seat and the next corner reads before you reach it
##   - direction chevrons painted on the tarmac pointing the way to drive, which
##     is what tells you the direction of travel at a junction
##   - a chequered start/finish line and two posts, on `path[0]`
##
## Barriers stop short of junctions, where they would block cross traffic, and
## the chevrons carry the route through instead.
##
## Every mark is a `MultiMeshInstance3D` with no collider, so they are purely
## visual. That is deliberate: this is a street network shared with civilian
## traffic, and a barrier you can bounce off mid-corner is a worse bug than a
## barrier you clip through. The route is meant to be read, not driven into.
##
## The route polyline is exposed as `route_points()` so a minimap can draw the
## exact same geometry the barriers sit on rather than a second, drifting copy.
##
## OWNED BY: the race system. Reads `RoadGraph` and `RaceDef`; builds no streets.
##
## ORIGINAL GAME CONTENT.

## Metres between barriers down each side.
const BARRIER_SPACING := 4.0
const BARRIER_WIDTH := 0.30
const BARRIER_HEIGHT := 0.90
const BARRIER_LENGTH := 3.2
## Metres between direction chevrons painted on the road.
const CHEVRON_SPACING := 9.0
const CHEVRON_LENGTH := 3.4
const CHEVRON_WIDTH := 2.6
## How far outside the carriageway a barrier stands.
const BARRIER_SETBACK := 0.45
## Barriers are kept out of junctions, as a real course has to be: a barrier
## across a side street is a wall, not a track edge. The chevrons carry the route
## through the gap. Same junction clearance WorldBuilder uses for footpaths, so
## the marks never sit in the middle of an intersection patch.
const JUNCTION_CLEARANCE := 0.62

## The graph the route was built from, kept so `is_closed` and the tests can
## re-derive it rather than trust a flag.
var graph: RoadGraph
var route: RaceDef

var _route_pts: Array = []      ## Vector2, the route's junctions in order


## Builds the marks for `def` through `g`, replacing anything already there.
## Rebuilding is cheap and is what a restart does.
func build(g: RoadGraph, def: RaceDef) -> void:
	clear()
	if g == null or def == null or def.path.size() < 2:
		return
	graph = g
	route = def
	_route_pts.clear()
	for n in def.path:
		_route_pts.append(g.node_pos(int(n)))

	_barriers(g)
	_chevrons()
	_start_line(g)


## Takes the marks back down. The race is over, or was abandoned, so the street
## is a street again.
func clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_route_pts.clear()
	route = null
	graph = null


## The route as a world polyline: Vector2 in map space, the line's junction
## first. A minimap draws this rather than re-deriving the path, so what is on
## the map and what is on the tarmac cannot disagree.
func route_points() -> Array:
	return _route_pts.duplicate()


## Whether this is a closed loop, checked against the graph rather than read off
## a flag. A route that claims to be a circuit but does not come back to its
## start is not a circuit, and a marker built on one would show a line that goes
## nowhere.
func is_closed() -> bool:
	if route == null or route.path.size() < 4:
		return false
	var p: Array = route.path
	if int(p[0]) != int(p[p.size() - 1]):
		return false
	return _consecutive_nodes_joined()


## Every step of the route a real edge of the road graph, with nothing skipped.
## This is what makes the route drivable rather than a list of junctions that
## happen to be nearby.
func _consecutive_nodes_joined() -> bool:
	for i in _route_pts.size() - 1:
		if _edge_between(int(route.path[i]), int(route.path[i + 1])) == -1:
			return false
	return true


# ------------------------------------------------------------------- the marks

func _barriers(g: RoadGraph) -> void:
	var red := MultiMesh.new()
	var white := MultiMesh.new()
	var mesh := _box_mesh(Vector3(BARRIER_WIDTH, BARRIER_HEIGHT, BARRIER_LENGTH))
	red.transform_format = MultiMesh.TRANSFORM_3D
	red.mesh = mesh
	white.transform_format = MultiMesh.TRANSFORM_3D
	white.mesh = mesh

	var a_count := 0
	var b_count := 0
	var alt := 0
	for i in _route_pts.size() - 1:
		var a: Vector2 = _route_pts[i]
		var b: Vector2 = _route_pts[i + 1]
		var eid := _edge_between(int(route.path[i]), int(route.path[i + 1]))
		if eid < 0:
			continue
		var w: float = g.width_for(int(g.edges[eid]["class"])) * 0.5 + BARRIER_SETBACK
		var seg := b - a
		var length := seg.length()
		if length < 1.0:
			continue
		var dir := seg / length
		var ang := atan2(dir.x, dir.y)
		var nrm := Vector2(-dir.y, dir.x)
		var t := BARRIER_SPACING * 0.5
		while t < length:
			var mid := a + dir * t
			for side in [-1.0, 1.0]:
				var p: Vector2 = mid + nrm * (w * side)
				if _in_junction(g, p):
					continue
				# Alternating red and white: two MultiMeshes rather than a texture,
				# so the stripes are real geometry at any distance.
				var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)),
					Vector3(p.x, BARRIER_HEIGHT * 0.5, p.y))
				if alt % 2 == 0:
					red.set_instance_transform(a_count, xf)
					a_count += 1
				else:
					white.set_instance_transform(b_count, xf)
					b_count += 1
			alt += 1
			t += BARRIER_SPACING

	var red_mm := _instance(red, a_count, MatLib.road_paint(Color(0.55, 0.09, 0.07), false))
	var white_mm := _instance(white, b_count, MatLib.road_paint(Color(0.72, 0.70, 0.66), false))
	for m in [red_mm, white_mm]:
		if m != null:
			add_child(m)


func _chevrons() -> void:
	var mesh := _chevron_mesh()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var n := 0
	for i in _route_pts.size() - 1:
		var a: Vector2 = _route_pts[i]
		var b: Vector2 = _route_pts[i + 1]
		var seg := b - a
		var length := seg.length()
		if length < 4.0:
			continue
		var dir := seg / length
		var ang := atan2(dir.x, dir.y)
		# Offset to the left of the direction of travel, which is where a racing
		# line's entry would be and keeps the chevrons off the centre line where
		# the existing road markings already are.
		var nrm := Vector2(-dir.y, dir.x)
		var t := CHEVRON_SPACING * 0.5
		while t < length:
			var p: Vector2 = a + dir * t + nrm * 2.4
			mm.set_instance_transform(n,
				Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(p.x, 0.035, p.y)))
			n += 1
			t += CHEVRON_SPACING
	var inst := _instance(mm, n, MatLib.road_paint(Color(0.85, 0.80, 0.20), true))
	if inst != null:
		add_child(inst)


## A chequered line across the carriageway at `path[0]`, with a post either side,
## so the start is a place on the road rather than a coordinate.
func _start_line(g: RoadGraph) -> void:
	if _route_pts.size() < 2:
		return
	var eid := _edge_between(int(route.path[0]), int(route.path[1]))
	var w: float = g.width_for(int(g.edges[eid]["class"])) if eid >= 0 \
		else float(RoadGraph.CLASS_WIDTH[RoadGraph.RoadClass.STREET])
	var a: Vector2 = _route_pts[0]
	var b: Vector2 = _route_pts[1]
	var seg := b - a
	if seg.length() < 0.01:
		return
	var dir := seg.normalized()
	var ang := atan2(dir.x, dir.y)
	var nrm := Vector2(-dir.y, dir.x)
	var base := Vector3(a.x, 0.0, a.y)

	var light := MultiMesh.new()
	var dark := MultiMesh.new()
	var mesh := _box_mesh(Vector3(w / 8.0, 0.03, 1.1), Vector3.ZERO)
	light.transform_format = MultiMesh.TRANSFORM_3D
	light.mesh = mesh
	dark.transform_format = MultiMesh.TRANSFORM_3D
	dark.mesh = mesh
	var y := 0.04
	for k in 8:
		var off := -w * 0.5 + w * (float(k) + 0.5) / 8.0
		var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)),
			base + Vector3(nrm.x * off, y, nrm.y * off))
		if k % 2 == 0:
			light.set_instance_transform(k / 2, xf)
		else:
			dark.set_instance_transform(k / 2, xf)
	var l := _instance(light, 4, MatLib.road_paint(Color(0.80, 0.80, 0.78), true))
	var d := _instance(dark, 4, MatLib.road_paint(Color(0.06, 0.06, 0.07), true))
	for m in [l, d]:
		if m != null:
			add_child(m)

	# Two posts, tall enough to be seen over the car and lit so they are the
	# brightest thing on the road at night.
	var posts := MultiMesh.new()
	posts.transform_format = MultiMesh.TRANSFORM_3D
	posts.mesh = _box_mesh(Vector3(0.16, 3.2, 0.16), Vector3(0, 1.6, 0))
	var pi := 0
	for side in [-1.0, 1.0]:
		var off: float = (w * 0.5 + 0.6) * side
		posts.set_instance_transform(pi,
			Transform3D(Basis.from_euler(Vector3(0, ang, 0)),
				base + Vector3(nrm.x * off, 0.0, nrm.y * off)))
		pi += 1
	var post_inst := _instance(posts, pi, MatLib.emissive(Color(1.0, 0.72, 0.16), 3.0))
	if post_inst != null:
		add_child(post_inst)


# ------------------------------------------------------------------- plumbing

## The edge joining two adjacent route junctions, or -1 if there is none. Scans
## the node's own edge list rather than asking the graph for a new API: it is a
## handful of entries and the race system should not need the world to grow one.
func _edge_between(a: int, b: int) -> int:
	if graph == null or a < 0 or b < 0 or a >= graph.nodes.size() or b >= graph.nodes.size():
		return -1
	for eid in graph.nodes[a]["edges"]:
		if graph.other_node(int(eid), a) == b:
			return int(eid)
	return -1


func _in_junction(g: RoadGraph, p: Vector2) -> bool:
	for n in g.nodes:
		if n["edges"].size() < 3:
			continue
		var r: float = g.width_for(int(n["class"])) * JUNCTION_CLEARANCE + 1.0
		if p.distance_squared_to(n["pos"]) < r * r:
			return true
	return false


func _instance(mm: MultiMesh, count: int, mat: Material) -> MultiMeshInstance3D:
	if count <= 0:
		return null
	mm.instance_count = count
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	# A fixed cull radius so a long course's marks are not popped out of view as
	# one block when the car is a street away from them.
	mmi.custom_aabb = AABB(Vector3(-1600, -20, -1600), Vector3(3200, 120, 3200))
	return mmi


static func _box_mesh(size: Vector3, offset: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := size * 0.5
	var c := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var faces := [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
		[3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]
	for f in faces:
		_quad(st, c[int(f[0])] + offset, c[int(f[1])] + offset,
			c[int(f[2])] + offset, c[int(f[3])] + offset)
	return st.commit()


## An arrowhead lying on the road, nose along +Z. Two swept quads rather than a
## texture: it has to read at night at a glance, which is the whole point.
static func _chevron_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := CHEVRON_WIDTH * 0.5
	var l := CHEVRON_LENGTH
	var bar := l * 0.34
	# A chevron: two arms meeting at the nose, plus the stem between them.
	var left := [Vector3(-w, 0, -l * 0.5), Vector3(0, 0, l * 0.18), Vector3(0, 0, l * 0.5)]
	var right := [Vector3(0, 0, l * 0.18), Vector3(w, 0, -l * 0.5), Vector3(0, 0, l * 0.5)]
	_tri(st, left[0], left[1], left[2])
	_tri(st, right[0], right[1], right[2])
	_quad(st, Vector3(-bar, 0, -l * 0.5), Vector3(bar, 0, -l * 0.5),
		Vector3(bar, 0, l * 0.22), Vector3(-bar, 0, l * 0.22))
	return st.commit()


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)