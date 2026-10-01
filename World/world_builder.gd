class_name WorldBuilder
extends Node3D
## Turns the road graph into actual geometry: terrain, road surface, kerbs,
## lane markings, footpaths, buildings, palms, streetlights and power lines.
##
## Everything repeated (palms, houses, poles, kerb sections) goes into a
## MultiMesh, so a suburb of a few thousand objects still costs a handful of
## draw calls. This is the substitute for Nanite that ENGINE_DECISION.md
## describes.

const KERB_HEIGHT := 0.14
const FOOTPATH_WIDTH := 1.6
const PALM_SPACING := 17.0
## Grid resolution of the mapped-footprint coverage test. Coarse on purpose: it
## answers plot-sized questions, and a fine grid costs 16x the marks for nothing.
const OSM_CELL := 16.0
## How far back from the back of the footpath a frontage building stands. Wide
## enough that the carport does not hang over the verge.
const FRONTAGE_OFFSET := 3.0
## Frontage plot pitch. Two houses either side of a 22 m pitch is a normal
## suburban lot spacing for the block sizes this map actually has.
const PLOT_PITCH := 22.0

## Artkit planting for the blocks the kit fills. Registered names only - anything
## else is skipped by `ArtKitScatter` and reported, not silently dropped.
##
## Free-standing yard things only. `_vegetation()` already owns the road verge, so
## anything placed here that belongs on the footpath would double up with it.
const YARD_PROPS := [
	"palm_alexandrine", "tree_rain_tree", "palm_fan", "bush_scrub", "bin",
]

var graph: RoadGraph
var rng := RandomNumberGenerator.new()

# Collected batches, flushed into MultiMeshes at the end.
var _batches: Dictionary = {}
var _materials: Dictionary = {}

# Named nodes the game needs to find.
var car_meet: Node3D
var streets_lights: Node3D


func build(g: RoadGraph) -> void:
	graph = g
	rng.seed = 20260929
	_terrain()
	_road_surface()
	_kerbs_and_footpaths()
	_lane_markings()
	_junction_control()
	_intersections()
	_drainage()
	_buildings()
	_vegetation()
	_streetlights()
	_power_lines()
	_car_meet()
	_skyline()
	_flush_batches()
	_bake_collision()


## The Cairns CBD, on the horizon.
##
## Manunda is low-rise, so without something to look at the sky is a flat empty
## band and the suburb reads as a diorama. Cairns has a real CBD a few km inland
## and it is honest to put it there: a ring of towers with lit window grids and
## aircraft warning beacons. It is also the cheapest depth cue in the game - the
## whole thing is unlit boxes in two MultiMeshes, and it gives every long shot a
## floor and every straight a vanishing point.
func _skyline() -> void:
	var tower_mesh := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	var glass_key := "tower_glass"
	_materials[glass_key] = MatLib.wall(Color(0.055, 0.060, 0.075))
	var win_key := "tower_window"
	if not _materials.has(win_key):
		_materials[win_key] = MatLib.emissive(Color(0.85, 0.88, 1.0), 0.9)
	var beacon_key := "tower_beacon"
	if not _materials.has(beacon_key):
		_materials[beacon_key] = MatLib.emissive(Color(1.0, 0.15, 0.10), 6.0)

	var centre := Vector2(-150.0, 620.0)      ## inland, the way Cairns actually is
	var towers := 0
	for i in 46:
		var a: float = TAU * float(i) / 46.0 + rng.randf_range(-0.05, 0.05)
		var dist: float = rng.randf_range(1500.0, 2300.0)
		var p: Vector2 = centre + Vector2(cos(a), sin(a)) * dist
		var w: float = rng.randf_range(26.0, 52.0)
		var d: float = rng.randf_range(26.0, 52.0)
		# A few real towers, mostly low CBD blocks. Uniform height reads as a fence.
		var h: float = rng.randf_range(45.0, 150.0) if rng.randf() < 0.3 else rng.randf_range(18.0, 55.0)
		var basis := Basis.from_euler(Vector3(0, a, 0))
		var base := Vector3(p.x, 0.0, p.y)
		_add("skyline", tower_mesh,
			Transform3D(basis, base + Vector3(0, h * 0.5, 0)).scaled_local(Vector3(w, h, d)), glass_key)

		# Window bands. A tower with no lit windows is a black rectangle at night,
		# which is worse than no tower at all.
		var bands: int = clampi(int(h / 14.0), 2, 9)
		for b in bands:
			if rng.randf() < 0.35:
				continue
			var y: float = h * (float(b) + 0.5) / float(bands)
			_add("skyline", tower_mesh,
				Transform3D(basis, base + basis * Vector3(0, y, -d * 0.5 - 0.3))
					.scaled_local(Vector3(w * 0.86, h / float(bands) * 0.42, 0.4)), win_key)
		if h > 90.0:
			_add("skyline", tower_mesh,
				Transform3D(basis, base + Vector3(0, h + 1.5, 0)).scaled_local(Vector3(1.6, 3.0, 1.6)), beacon_key)
		towers += 1
	print("[World] %d CBD towers on the horizon" % towers)


# --------------------------------------------------------------------- batches
func _mat(key: String) -> StandardMaterial3D:
	if not _materials.has(key):
		match key:
			"asphalt": _materials[key] = MatLib.wet_asphalt()
			# Four grains of tarmac, one per chunk. See `_asphalt_key`.
			"asphalt0": _materials[key] = MatLib.wet_asphalt(0.06, 0)
			"asphalt1": _materials[key] = MatLib.wet_asphalt(0.06, 1)
			"asphalt2": _materials[key] = MatLib.wet_asphalt(0.06, 2)
			"asphalt3": _materials[key] = MatLib.wet_asphalt(0.06, 3)
			"paint_white": _materials[key] = MatLib.road_paint(Color(0.62, 0.60, 0.55))
			"paint_yellow": _materials[key] = MatLib.road_paint(Color(0.55, 0.40, 0.06))
			"concrete": _materials[key] = MatLib.concrete()
			"ground": _materials[key] = MatLib.ground()
			_: _materials[key] = MatLib.concrete()
	return _materials[key]


## Adds one instance of a mesh to a named batch.
func _add(batch: String, mesh: ArrayMesh, xform: Transform3D, mat_key: String) -> void:
	if not _batches.has(batch):
		_batches[batch] = {"meshes": {}, "xforms": []}
	var entry: Dictionary = _batches[batch]
	if not entry["meshes"].has(mat_key):
		entry["meshes"][mat_key] = {"mesh": mesh, "list": []}
	entry["meshes"][mat_key]["list"].append(xform)


func _flush_batches() -> void:
	for batch in _batches:
		var entry: Dictionary = _batches[batch]
		var holder := MultiMeshInstance3D.new()
		holder.name = "Batch_" + batch
		for mat_key in entry["meshes"]:
			var rec: Dictionary = entry["meshes"][mat_key]
			var list: Array = rec["list"]
			if list.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = rec["mesh"]
			mm.instance_count = list.size()
			# A fixed cull radius keeps distance culling from popping whole batches
			# out. Real per-object LOD and occlusion culling are Phase 10 work.
			mm.custom_aabb = AABB(Vector3(-900, -20, -900), Vector3(1800, 120, 1800))
			for i in list.size():
				mm.set_instance_transform(i, list[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = _mat(mat_key)
			holder.add_child(mmi)
		add_child(holder)


# --------------------------------------------------------------------- terrain
## Half-extent the terrain has to cover, with margin.
##
## This cannot be a constant. It was 800, which was right for the old authored
## block and wrong the moment the roads became real OpenStreetMap data: those
## span -1192..1394 in X and -1501..1301 in Z, so roughly 700 m of real street
## had no floor under it at all. A car that drifted out there fell through the
## world with nothing to catch it. Derived from the graph so the next map change
## cannot reopen the hole.
func _terrain_extent() -> float:
	var reach := 0.0
	for e in graph.edges:
		for nid in [int(e["a"]), int(e["b"])]:
			var p := graph.node_pos(nid)
			reach = maxf(reach, maxf(absf(p.x), absf(p.y)))
	return maxf(800.0, reach + 120.0)


func _terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := _terrain_extent()
	# The cell count is held roughly constant as the extent grows, so covering
	# four times the area does not quietly quadruple the triangle count and the
	# collision mesh with it.
	var step: float = maxf(16.0, s / 55.0)
	for gz in range(-int(s / step), int(s / step)):
		for gx in range(-int(s / step), int(s / step)):
			var x0 := float(gx) * step
			var z0 := float(gz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			var h00 := _terrain_height(x0, z0)
			var h10 := _terrain_height(x1, z0)
			var h01 := _terrain_height(x0, z1)
			var h11 := _terrain_height(x1, z1)
			# Corners walked counter-clockwise seen from above, so _quad reads
			# +Y as the outward normal. Walked the other way it reads -Y, which
			# is the ground lit from underneath - black at any exposure.
			var p00 := Vector3(x0, h00, z0)
			var p10 := Vector3(x1, h10, z0)
			var p01 := Vector3(x0, h01, z1)
			var p11 := Vector3(x1, h11, z1)
			_quad(st, p00, p01, p11, p10)
			_quad(st, p00, p11, p10, p01)
	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.material_override = _mat("ground")
	mi.position.y = -0.06
	add_child(mi)

	# The terrain needs collision. Without it the only thing the car can stand on
	# is the road trimesh, so driving off the kerb drops you into a void with no
	# surface to catch you - which is exactly what it did. Reusing the committed
	# mesh means the collision surface is the visible one, not an approximation
	# of it, and it costs one more StaticBody rather than a second piece of
	# geometry.
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = _trimesh(mesh)
	cs.shape.backface_collision = true
	body.add_child(cs)
	add_child(body)

	# The terrain only covers +/-800 m. The road network does not, so the far
	# field is still a hole at the map edge. This floor is well below the lowest
	# terrain height, which means it is only ever reached by driving off the
	# world rather than by driving across it.
	var skirt := StaticBody3D.new()
	skirt.name = "OuterFloor"
	skirt.collision_layer = 1
	skirt.collision_mask = 0
	var scs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6000.0, 40.0, 6000.0)
	scs.shape = box
	scs.position = Vector3(0.0, -22.0, 0.0)
	skirt.add_child(scs)
	add_child(skirt)
	print("[World] terrain collision: %d triangles" % int(cs.shape.get_faces().size() / 3))


## Flat flood-prone plain with a shallow dish, a creek line to the west, and a
## gentle rise toward the hills. The creek is what stops it reading as a table.
func _terrain_height(x: float, z: float) -> float:
	var h := 0.0
	# Broad, very gentle tilt: this suburb is flat but it is not level.
	h += 1.4 * sin(x * 0.0016) * cos(z * 0.0019)
	h += 0.6 * sin(x * 0.006 + 1.7) * sin(z * 0.005)
	# The creek / drainage corridor, running roughly north-south out west.
	var creek_x := -620.0 + 40.0 * sin(z * 0.004)
	var d := absf(x - creek_x)
	if d < 46.0:
		h -= 2.4 * (1.0 - d / 46.0)
	# Keep the roads themselves level: flatten toward 0 near any road.
	var near: Dictionary = graph.nearest_road(Vector3(x, 0, z))
	if float(near["lateral"]) < 26.0:
		var w: float = 1.0 - float(near["lateral"]) / 26.0
		h = lerpf(h, 0.0, w * w)
	return h


## One quad, two triangles, from four corners walked in order around the patch.
##
## **The order of a, b, c, d is the caller's OUTWARD normal**, taken as
## `_tri_normal(a, b, c)`, and the triangles are emitted *reversed* to get it.
## That indirection is not decoration. Godot only draws a face whose
## right-hand-rule normal points away from the camera, i.e. INTO the surface -
## the exact opposite of the outward normal it wants to light it with. Deriving
## both from one cross product forces a choice between being lit correctly and
## being visible at all, and this world picked wrong in both directions:
##
##   - the carriageway was lit correctly and culled from every frame above it
##   - the terrain was drawn and lit from underneath, i.e. pure black
##
## So: the normal stays as the caller ordered it, and the winding is reversed
## to match. Callers must pass corners such that a->b->c reads as outward.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var n := _tri_normal(a, b, c)
	st.set_normal(n)
	st.set_uv(Vector2(a.x, a.z) * 0.02)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(Vector2(c.x, c.z) * 0.02)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(Vector2(b.x, b.z) * 0.02)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(Vector2(a.x, a.z) * 0.02)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(Vector2(d.x, d.z) * 0.02)
	st.add_vertex(d)
	st.set_normal(n)
	st.set_uv(Vector2(c.x, c.z) * 0.02)
	st.add_vertex(c)


static func _tri_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	return n.normalized() if n.length_squared() > 0.000001 else Vector3.UP


# --------------------------------------------------------------- road surfaces
## Edge length in metres, used to cut the carriageway into chunks.
const ROAD_CHUNK_M := 160.0

## The road, cut into chunks instead of one city-sized mesh.
##
## A single 2.6 x 2.8 km surface is one object with one bounding box, and its
## centre is out in the middle of the map. Renderers choose a mesh's lights by
## that centre, so the 1278 streetlights that are actually near the camera are
## never among the ones assigned to it - the tarmac went unlit while the same
## frame's directional light lit it perfectly. Chunking puts each stretch of
## road in a box small enough that the lamps above it are the lamps that light
## it. Same reason the junction patches are chunked.
##
## Measured, at the "street" preset, by Systems/road_render/draw_calls.gd:
## road tarmac went from 2 meshes / 10 draw calls to 136 meshes / 35 draw calls
## in that frame, and the median road pixel went from literally 0.00 to 51.52.
## So this is a correctness fix bought with draw calls, not a performance win -
## do not assume otherwise. 101 of the 136 chunks were frustum-culled at street
## level, but from the air it is 58 draw calls, because then they all are in
## frame. ROAD_CHUNK_M = 160 m is inherited, not chosen by measurement: it has
## not been swept, so the honest statement is that it works and nobody has found
## the knee. Sweep it before treating the draw-call cost above as fixed.
##
## Chunk key (cell) -> SurfaceTool, filled as the geometry is emitted.
func _cell_key(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / ROAD_CHUNK_M), floori(p.y / ROAD_CHUNK_M))


## Which grain of tarmac a chunk gets.
##
## The asphalt material is triplanar, so its texture is sampled from world
## position and every 16.7 m of road shows the same tile of grain - a regular
## grid over the whole map that reads as wallpaper, not as tarmac. A per-chunk UV
## offset cannot fix that because the shader never reads the UVs; a different
## material can, and a different material per chunk is a different draw call.
## Hence four variants and a hash: the repeat becomes 160 m and non-obvious
## instead of 16.7 m and obvious, at the cost measured in the commit.
##
## Hashing the cell rather than the chunk's first edge keeps a junction patch and
## the road either side of it on the same grain, so the patch does not read as a
## differently-coloured square of tarmac.
func _asphalt_key(cell: Vector2i) -> String:
	return "asphalt%d" % (absi(cell.x * 31 + cell.y * 17) % 4)


func _road_surface() -> void:
	var cells := {}
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var dir := (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var uv_len: float = a.distance_to(b)
		var a0 := Vector3(a.x - nrm.x * hw, 0.0, a.y - nrm.y * hw)
		var a1 := Vector3(a.x + nrm.x * hw, 0.0, a.y + nrm.y * hw)
		var b0 := Vector3(b.x - nrm.x * hw, 0.0, b.y - nrm.y * hw)
		var b1 := Vector3(b.x + nrm.x * hw, 0.0, b.y + nrm.y * hw)
		_road_quad(_cell(cells, (a + b) * 0.5), a0, a1, b1, b0, uv_len, hw)
	for key in cells:
		var mi := MeshInstance3D.new()
		mi.name = "RoadSurface_%d_%d" % [key.x, key.y]
		mi.mesh = (cells[key] as SurfaceTool).commit()
		mi.material_override = _mat(_asphalt_key(key))
		mi.position.y = 0.015
		add_child(mi)


## The SurfaceTool for the chunk containing p, created on first use.
func _cell(cells: Dictionary, p: Vector2) -> SurfaceTool:
	var key := _cell_key(p)
	if not cells.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		cells[key] = st
	return cells[key]


static func _road_quad(st: SurfaceTool, a0: Vector3, a1: Vector3, b1: Vector3, b0: Vector3,
		length: float, half_width: float) -> void:
	# Wound so the right-hand-rule normal points down, into the tarmac. Godot
	# draws a face only when that normal points away from the camera, so the
	# other order is a road you can only see from underneath - the carriageway
	# was simply absent from every frame shot from above.
	var verts := [a0, b1, a1, a0, b0, b1]
	var uvs := [
		Vector2(0, 0), Vector2(half_width * 2.0, 0),
		Vector2(half_width * 2.0, length), Vector2(0, 0),
		Vector2(half_width * 2.0, length), Vector2(0, length),
	]
	for i in verts.size():
		st.set_normal(Vector3.UP)
		st.set_uv(uvs[i])
		st.add_vertex(verts[i])


func _kerbs_and_footpaths() -> void:
	var kerb_mesh := _box_mesh(Vector3(1.0, KERB_HEIGHT, 1.0), Vector3(0, 0.5, 0))
	var walk_mesh := _box_mesh(Vector3(1.0, 0.02, 1.0), Vector3(0, 0, 0))
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 2.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var pieces := int(length / 4.0)
		for i in pieces:
			var t0 := float(i) / float(maxi(pieces, 1))
			var t1 := float(i + 1) / float(maxi(pieces, 1))
			var mid: Vector2 = a.lerp(b, (t0 + t1) * 0.5)
			var ang := atan2(dir.x, dir.y)
			for side in [-1.0, 1.0]:
				var p: Vector2 = mid + nrm * (hw + 0.5) * side
				# Skip kerbs where a side street joins, so junctions do not get walls.
				if _blocked_by_junction(Vector3(p.x, 0, p.y)):
					continue
				var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)),
					Vector3(p.x, 0, p.y))
				_add("kerbs", kerb_mesh, xf.scaled_local(Vector3(1.0, 1.0, 4.2)), "concrete")
				var wp: Vector2 = mid + nrm * (hw + 0.5 + FOOTPATH_WIDTH * 0.5) * side
				var wxf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(wp.x, KERB_HEIGHT, wp.y))
				_add("footpaths", walk_mesh, wxf.scaled_local(Vector3(FOOTPATH_WIDTH, 1.0, 4.2)), "concrete")


func _blocked_by_junction(p: Vector3) -> bool:
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		if Vector2(p.x, p.z).distance_to(n["pos"]) < float(graph.width_for(int(n["class"]))) * 0.62 + 1.0:
			return true
	return false


## Lane markings: the boundaries between lanes, the lines along the kerb, and the
## stop / give-way rows at the mouths of the approaches.
##
## What was here before was one line down the middle of every road and nothing
## else - no lane boundaries, no edge lines, no junction control - so a street
## read as a grey ribbon with a dotted spine. Markings are placed from the road
## class rather than by eye: `lanes_for()` gives the lane count, and lane i's
## boundary sits at width * i / lanes, which is where the real marking is. The
## centre boundary (on an even lane count) is the only one that changes colour
## or rhythm, because that is the only one that means something.
const MARK_Y := 0.028
const LINE_W := 0.12
const LINE_T := 0.012
const EDGE_LINE_INSET := 0.35
const SOLID_PITCH := 4.0
const DASH_PITCH := 7.0
const DASH_RUN := 3.0


func _lane_markings() -> void:
	# One unit box for every marking. `_add` keys a batch's meshes by material
	# key alone, so a second mesh under a key already in use would silently
	# rescale the first one's instances; scale per instance instead, the way the
	# kerbs do.
	var box := _box_mesh(Vector3.ONE, Vector3.ZERO)
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 6.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var ang := atan2(dir.x, dir.y)
		var cls := int(e["class"])
		var w: float = float(e["width"])
		var lanes := int(graph.lanes_for(cls))
		var basis := Basis.from_euler(Vector3(0, ang, 0))
		# Not the whole edge: at a junction mouth the tarmac belongs to the
		# junction, and a lane line drawn across it is a line through a give-way
		# row. `_clear_span` trims back to where the carriageway starts.
		var span := _clear_span(a, dir, length)
		for i in range(1, lanes):
			var centre := i * 2 == lanes
			_stripe_run(box, basis, a, dir, nrm, span, -w * 0.5 + w * float(i) / float(lanes),
					centre and cls >= RoadGraph.RoadClass.ARTERIAL)
		# Edge lines, set in from the kerb, on anything wider than a single lane.
		if cls >= RoadGraph.RoadClass.STREET:
			for side in [-1.0, 1.0]:
				_stripe_span(box, basis, a, dir, nrm, span, (w * 0.5 - EDGE_LINE_INSET) * side)


## Where on an edge the tarmac stops being junction and starts being carriageway,
## as distances along the edge from `a`. Both ends are trimmed; a short edge that
## is junction all the way along returns a span with hi <= lo and places nothing.
func _clear_span(a: Vector2, dir: Vector2, length: float) -> Vector2:
	var lo := 0.0
	while lo < length * 0.5 and _in_junction(a + dir * lo):
		lo += 1.0
	var hi := length
	while hi > lo and _in_junction(a + dir * hi):
		hi -= 1.0
	return Vector2(lo, hi)


func _in_junction(p: Vector2) -> bool:
	return _blocked_by_junction(Vector3(p.x, 0.0, p.y))


## Dashes on the rhythm of a lane line, or an unbroken run of boxes for a solid
## line. One box per dash rather than one long strip, so the line bends with the
## road instead of chording across a curve.
func _stripe_run(mesh: ArrayMesh, basis: Basis, a: Vector2, dir: Vector2, nrm: Vector2,
		span: Vector2, offset: float, solid: bool) -> void:
	var pitch := SOLID_PITCH if solid else DASH_PITCH
	var run := SOLID_PITCH if solid else DASH_RUN
	var key := "paint_yellow" if solid else "paint_white"
	var t := span.x
	while t < span.y - 1.0:
		var len := minf(run, span.y - t)
		_add("markings", mesh, _mark_xf(basis, a, dir, nrm, t + len * 0.5, offset, len), key)
		t += pitch


## An unbroken line: one box for the whole span, clipped to it.
func _stripe_span(mesh: ArrayMesh, basis: Basis, a: Vector2, dir: Vector2, nrm: Vector2,
		span: Vector2, offset: float) -> void:
	var len := span.y - span.x
	if len < 1.0:
		return
	_add("markings", mesh, _mark_xf(basis, a, dir, nrm, (span.x + span.y) * 0.5, offset, len),
			"paint_white")


func _mark_xf(basis: Basis, a: Vector2, dir: Vector2, nrm: Vector2, along: float,
		offset: float, len: float) -> Transform3D:
	var p := a + dir * along + nrm * offset
	return Transform3D(basis, Vector3(p.x, MARK_Y, p.y)).scaled_local(Vector3(LINE_W, LINE_T, len))


## Stop bars and give-way rows, on the mouth of each approach.
##
## The road carrying less than the widest road at an intersection stops; the one
## carrying more gives way. Where every approach is the same class - the
## residential crossroads - neither marking is correct, so neither is drawn:
## give-way rows on all four arms of a suburban street junction is the single
## fastest way to make a city look like a diagram.
##
## Rows and bars sit just outside the junction patch, at the radius
## `_intersections` draws tarmac to, so they land on the edge of the patch rather
## than under it.
func _junction_control() -> void:
	var box := _box_mesh(Vector3.ONE, Vector3.ZERO)
	var tri := _tri_marker_mesh()
	for ni in graph.nodes.size():
		var n: Dictionary = graph.nodes[ni]
		if int(n["edges"].size()) < 3:
			continue
		var lo := RoadGraph.RoadClass.HIGHWAY
		var hi := RoadGraph.RoadClass.LANE
		for ei in n["edges"]:
			var ec := int(graph.edges[int(ei)]["class"])
			lo = mini(lo, ec)
			hi = maxi(hi, ec)
		if lo == hi:
			continue
		var p: Vector2 = n["pos"]
		var r: float = graph.width_for(int(n["class"])) * 0.5
		for ei in n["edges"]:
			var e: Dictionary = graph.edges[int(ei)]
			var cls := int(e["class"])
			var w: float = float(e["width"])
			var dir := (graph.node_pos(graph.other_node(int(ei), ni)) - p).normalized()
			var ang := atan2(dir.x, dir.y)
			var basis := Basis.from_euler(Vector3(0, ang, 0))
			var mouth := p + dir * (r + EDGE_LINE_INSET + 0.25)
			var xf := Transform3D(basis, Vector3(mouth.x, MARK_Y, mouth.y))
			if cls < hi:
				# Stop bar: across the whole approach, 0.4 m deep. Two junctions a
				# few metres apart would otherwise paint this one on the other's
				# tarmac, which is the same mistake as painting it on your own
				# patch and just as visible from the car.
				if not _patched_by_other(ni, mouth):
					_add("markings", box, xf.scaled_local(Vector3(w, LINE_T, 0.4)), "paint_white")
			else:
				# Give way: a row of triangles, apexes to the junction. The guard
				# is per triangle, not per row: a row is as wide as the approach,
				# so on a pair of junctions four metres apart its far end can land
				# on the neighbour even when its centre cannot.
				var count := maxi(1, int(w / 0.9))
				var pitch := w / float(count)
				for i in count:
					var at := mouth + Vector2(-dir.y, dir.x) * ((float(i) - (count - 1) * 0.5) * pitch)
					if _patched_by_other(ni, at):
						continue
					_add("giveway", tri,
							Transform3D(basis, Vector3(at.x, MARK_Y, at.y)), "paint_white")


## True when some junction other than `node` has already laid tarmac over p.
func _patched_by_other(node: int, p: Vector2) -> bool:
	for j in graph.nodes.size():
		if j == node or int(graph.nodes[j]["edges"].size()) < 3:
			continue
		if p.distance_to(graph.node_pos(j)) < graph.width_for(int(graph.nodes[j]["class"])) * 0.5:
			return true
	return false


## A flat give-way triangle, apex pointing down local -Z, i.e. at whatever the
## instance is aimed at. Wound and normalised the way `_junction_fan` does it,
## which is the one winding in this file that is known to face a camera above.
static func _tri_marker_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [Vector3(0, 0, -0.3), Vector3(0.3, 0, 0.3), Vector3(-0.3, 0, 0.3)]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x, v.z) * 0.5)
		st.add_vertex(v)
	return st.commit()


func _intersections() -> void:
	var cells := {}
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		var p: Vector2 = n["pos"]
		_junction_fan(_cell(cells, p), p, graph.width_for(int(n["class"])) * 0.5, true)
	for key in cells:
		var mi := MeshInstance3D.new()
		mi.name = "Intersections_%d_%d" % [key.x, key.y]
		mi.mesh = (cells[key] as SurfaceTool).commit()
		mi.material_override = _mat(_asphalt_key(key))
		mi.position.y = 0.02
		add_child(mi)


## The patch of tarmac where three or more streets meet: a fan of 10 triangles
## around the centre. At these radii and heights nobody can tell it is not a
## perfect polygon.
##
## Emitted directly rather than through _quad, because a fan is not a quad.
## `_quad(st, centre, v0, v1, v1)` passed v1 as both the third and fourth
## corner, which left a zero-area triangle behind every sector: half of every
## junction was a hole in the tarmac, and the junction collider carried twice
## the triangles it needed. Both the visible patch and the collision patch are
## built here so they cannot drift apart again.
##
## Winding points down, normal points up - the same contract as _road_quad,
## because this is the same tarmac. with_uv is false for the collider, which
## has no material to sample.
static func _junction_fan(st: SurfaceTool, p: Vector2, r: float, with_uv: bool) -> void:
	var segs := 10
	var centre := Vector3(p.x, 0, p.y)
	for i in segs:
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		for v in [centre,
				Vector3(p.x + cos(a0) * r, 0, p.y + sin(a0) * r),
				Vector3(p.x + cos(a1) * r, 0, p.y + sin(a1) * r)]:
			st.set_normal(Vector3.UP)
			if with_uv:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
			st.add_vertex(v)


func _drainage() -> void:
	# Open concrete channels, the reason Manunda floods and the reason every
	# kerb here has one.
	#
	# Measured, not assumed: the channel is DRAIN_W wide and DRAIN_DEPTH deep
	# with its top flush with the road and its centre DRAIN_OFF outside the
	# carriageway edge, so on a street it occupies hw+0.15 .. hw+1.75 and a car
	# leaving the tarmac is 150 mm from falling in. Nothing stopped it: the kerb
	# is 140 mm of visual geometry with no collider, and the channel had no lip.
	#
	# Each rail is DRAIN_RAIL_W square and stands DRAIN_DEPTH proud - as proud as
	# the channel is deep, so the lip you see is the same measure as the hole
	# behind it. Centred ON the channel edge rather than tucked inside it: a rail
	# against the edge opens a 150 mm gap between itself and the trench it is
	# there to hold. For that reason it also runs DRAIN_DEPTH * 2 tall, from the
	# trench floor to the lip, lining the wall it sits over instead of perching
	# on it.
	#
	# Local +X on this transform points away from the carriageway (the basis below
	# is yawed by atan2(dir.x, dir.y), which sends local +X to -nrm, and the piece
	# sits at +nrm). So -DRAIN_W/2 is the road-side edge and +DRAIN_W/2 the far
	# one, measured: the two rail origins come out 0.800 m either side of the
	# channel's, and 0.15 and 1.75 past the carriageway edge. Both rails are the
	# same mesh, offset per instance.
	const DRAIN_OFF := 0.95
	const DRAIN_W := 1.6
	const DRAIN_DEPTH := 0.30
	const DRAIN_RAIL_W := 0.30
	var channel := _box_mesh(Vector3(DRAIN_W, DRAIN_DEPTH, 4.0), Vector3(0, -DRAIN_DEPTH * 0.5, 0))
	var rail := _box_mesh(Vector3(DRAIN_RAIL_W, DRAIN_DEPTH * 2.0, 4.0), Vector3.ZERO)
	var water := _box_mesh(Vector3(1.1, 0.02, 4.0), Vector3.ZERO)
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 12.0:
			continue
		var dir := seg / length
		var ang := atan2(dir.x, dir.y)
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var pieces := int(length / 8.0)
		for i in pieces:
			var mid: Vector2 = a.lerp(b, (float(i) + 0.5) / float(maxi(pieces, 1)))
			var p := mid + nrm * (hw + DRAIN_OFF)
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(p.x, 0, p.y))
			_add("drainage", channel, xf.scaled_local(Vector3(1.0, 1.0, 8.4)), "concrete")
			for edge in [-DRAIN_W * 0.5, DRAIN_W * 0.5]:
				_add("drainage", rail,
					xf.scaled_local(Vector3(1.0, 1.0, 8.4)).translated_local(Vector3(edge, 0.0, 0.0)),
					"concrete")
			_add("drainage_water", water,
				Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(p.x, 0.02, p.y)),
				"asphalt")


# ----------------------------------------------------------------- primitives
static func _box_mesh(size: Vector3, offset: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := size * 0.5
	var corners := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var faces := [
		[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
		[3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5],
	]
	for f in faces:
		var a: Vector3 = corners[int(f[0])] + offset
		var b: Vector3 = corners[int(f[1])] + offset
		var c: Vector3 = corners[int(f[2])] + offset
		var d: Vector3 = corners[int(f[3])] + offset
		_quad(st, a, b, c, d)
	var mesh := st.commit()
	return mesh


# ------------------------------------------------------------------ colliders
func _bake_collision() -> void:
	# One trimesh for the drivable surface. Cheaper and far more robust than
	# thousands of box colliders, and the car only ever needs the road.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var dir := (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		_road_quad(st,
			Vector3(a.x - nrm.x * hw, 0, a.y - nrm.y * hw),
			Vector3(a.x + nrm.x * hw, 0, a.y + nrm.y * hw),
			Vector3(b.x + nrm.x * hw, 0, b.y + nrm.y * hw),
			Vector3(b.x - nrm.x * hw, 0, b.y - nrm.y * hw),
			a.distance_to(b), hw)
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		var p: Vector2 = n["pos"]
		_junction_fan(st, p, graph.width_for(int(n["class"])) * 0.5, false)
	var body := StaticBody3D.new()
	body.name = "RoadCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = _trimesh(st.commit())
	# Raycast wheels come from above; a one-sided trimesh wound the wrong way
	# would silently let the whole car fall through the world.
	cs.shape.backface_collision = true
	body.add_child(cs)
	add_child(body)
	print("[World] road collider: %d triangles" % int(cs.shape.get_faces().size() / 3))


static func _trimesh(mesh: ArrayMesh) -> ConcavePolygonShape3D:
	var shape := ConcavePolygonShape3D.new()
	if mesh == null or mesh.get_surface_count() == 0:
		return shape
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# SurfaceTool.commit() leaves ARRAY_INDEX null when no index buffer was built,
	# so this cannot be a typed PackedInt32Array assignment.
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	var faces: Array = []
	if indices == null or (indices as PackedInt32Array).is_empty():
		for i in range(0, verts.size() - 2, 3):
			faces.append(verts[i])
			faces.append(verts[i + 1])
			faces.append(verts[i + 2])
	else:
		var idx: PackedInt32Array = indices
		for i in range(0, idx.size() - 2, 3):
			faces.append(verts[idx[i]])
			faces.append(verts[idx[i + 1]])
			faces.append(verts[idx[i + 2]])
	shape.set_faces(faces)
	return shape


# =============================================================================
# Props. These are what make it read as a tropical Queensland suburb at night
# rather than as a grey road network.
# =============================================================================

## Real mapped buildings, then the artkit for whatever the map did not cover.
##
## `OSMBuildings` owns the footprints. It brings 2198 rings out of
## `assets/maps/cairns_buildings.json`, the carriageway test that keeps a car out of
## a wall, and the stumps a Queenslander stands on. None of that is expressible as
## an artkit placement - `wrap_footprint()` takes a storey count and no lift - so
## the footprints keep their own material batching and the kit is given the gap.
##
## The kit goes in through `ArtKitScatter` and nowhere else. That is what makes it
## one mesh per material rather than one per placement: a raw generator called in
## the loop builds fresh geometry every time, every signature differs, and a suburb
## arrives as ~2200 draw calls instead of ~20.
func _buildings() -> void:
	var osm := OSMBuildings.build(self, graph)
	var scatter := ArtKitScatter.attach(self, _artkit_fill(osm))
	print("[World] artkit filled the gaps OSM left: %d buildings, %d props, %d draw calls, %d instances, %.0fk triangles"
		% [int(scatter.stats.get("buildings", 0)), int(scatter.stats.get("props", 0)),
			int(scatter.stats.get("nodes", 0)), int(scatter.stats.get("instances", 0)),
			float(scatter.stats.get("triangles", 0)) / 1000.0])


## The kit's placement list: buildings and yard planting along the frontages OSM
## left empty.
##
## Frontages, not blocks, and that is the whole difference between art and a
## curiosity. `_blocks()` finds 19 blocks on this map - real OSM data is mostly
## T-junctions, so almost nothing is ever fully enclosed - and 19 blocks put 21
## houses in a 31 km city. A road already knows its own frontage: walk its length
## at a setback and build on the side the map left blank. That scales with the
## street network rather than with the junctions.
##
## The cells are the other half of the decision. OSM covers western Cairns unevenly,
## and without a coverage test the fill either doubles up on mapped houses or leaves
## a hole where the map ran out; both read as a bug from the driver's seat.
func _artkit_fill(osm: Dictionary) -> Array:
	var cells := _osm_cells(osm.get("buildings", []))
	var out: Array = []
	var n := 0

	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var length: float = a.distance_to(b)
		if length < PLOT_PITCH:
			continue
		var dir := (b - a) / length
		var nrm := Vector2(-dir.y, dir.x)
		var plots := maxi(1, int(length / PLOT_PITCH))
		var step: float = length / float(plots)
		# Back of footpath, then a front yard, off this edge's own width, so a
		# highway frontage stands further back than a lane's.
		var off: float = _frontage_offset(float(e["width"]))
		var kind := _kind_for(int(e["class"]))

		for side in [-1.0, 1.0]:
			for i in plots:
				var p: Vector2 = a.lerp(b, (float(i) + 0.5) / float(plots)) + nrm * (off * side)
				if _skip_frontage(p, cells):
					continue
				var pos := Vector3(p.x, 0.0, p.y)
				out.append({
					"building": kind,
					"pos": pos,
					# Front to the road. `facing()` is the kit's own answer to which
					# way its geometry looks, so the guess stays in one place.
					"yaw": ArtKitBatch.facing(pos,
						Vector3(p.x - nrm.x * off * side, 0.0, p.y - nrm.y * off * side)),
					"seed": n,
				})
				n += 1

				# Yard planting in the half pitch to the next plot.
				var q: Vector2 = p + dir * (step * 0.5)
				if not _skip_frontage(q, cells):
					var q3 := Vector3(q.x, 0.0, q.y)
					out.append({
						"prop": YARD_PROPS[posmod(n, YARD_PROPS.size())],
						"pos": q3,
						"yaw": ArtKitBatch.facing(q3, Vector3(p.x, 0.0, p.y)),
						"seed": n,
					})
					n += 1
	return out


## What stands on this class of road. Shops follow the big roads rather than a
## hardcoded patch of the map - the same call the block grid used to make, so the
## commercial strip still lands where anyone actually drives.
func _kind_for(cls: int) -> String:
	match cls:
		RoadGraph.RoadClass.ARTERIAL: return "qld_shop"
		RoadGraph.RoadClass.HIGHWAY: return "walk_up_block"
		_: return "qld_house"


## Nothing to build here: too near a carriageway, in a junction mouth, or on a cell
## OSM has already put a real house on.
func _skip_frontage(p: Vector2, cells: Dictionary) -> bool:
	if _too_close_to_road(p):
		return true
	if _blocked_by_junction(Vector3(p.x, 0.0, p.y)):
		return true
	return cells.has(Vector2i(int(floor(p.x / OSM_CELL)), int(floor(p.y / OSM_CELL))))


## Occupancy grid over the mapped rings, one cell per OSM_CELL.
##
## Bounding boxes rather than edge walking: the only question asked downstream is
## "is this block mapped at all", so marking a few cells too many cannot change an
## answer, and 2198 small rings cost one tight loop each. A mapped stadium can span
## a hundred cells, so anything that big contributes its middle cell alone - a
## sparse mark can only ever make a block look emptier than it is, and the fallback
## house lands in ground the map never claimed.
func _osm_cells(entries: Array) -> Dictionary:
	var cells := {}
	for e in entries:
		var ring: PackedVector2Array = e.get("ring", PackedVector2Array())
		if ring.size() < 3:
			continue
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for q in ring:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
		var x0 := int(floor(lo.x / OSM_CELL))
		var x1 := int(floor(hi.x / OSM_CELL))
		var z0 := int(floor(lo.y / OSM_CELL))
		var z1 := int(floor(hi.y / OSM_CELL))
		if (x1 - x0 + 1) * (z1 - z0 + 1) > 64:
			cells[Vector2i(int(floor((lo.x + hi.x) * 0.5 / OSM_CELL)),
				int(floor((lo.y + hi.y) * 0.5 / OSM_CELL)))] = true
			continue
		for gx in range(x0, x1 + 1):
			for gz in range(z0, z1 + 1):
				cells[Vector2i(gx, gz)] = true
	return cells


## How far back from a road's centreline a frontage building stands: half the
## carriageway, the footpath behind it, then the yard.
func _frontage_offset(width: float) -> float:
	return width * 0.5 + FOOTPATH_WIDTH + FRONTAGE_OFFSET


## Too near a carriageway to build on.
##
## Measured to the kerb, not to the centreline. The old test was a bare
## `lateral < BUILDING_SETBACK` - 9 m from the middle of the road - which on a
## 9 m street is inside its own kerb, so it rejected every residential frontage in
## the city and left only the arterials standing. Measured: 413 buildings, all of
## them `qld_shop`, zero houses, on a network that is 270 streets and 131 arterials.
func _too_close_to_road(p: Vector2) -> bool:
	var near: Dictionary = graph.nearest_road(Vector3(p.x, 0.0, p.y))
	var eid := int(near["edge"])
	if eid < 0 or eid >= graph.edges.size():
		return true
	return float(near["lateral"]) < _frontage_offset(float(graph.edges[eid]["width"]))

## Coconut palms. The single most identifiable thing about a north Queensland
## street, and they break up the roofline so the suburb is not a row of boxes.
func _vegetation() -> void:
	var trunk_mesh := _tapered_cylinder_mesh(0.22, 0.34, 1.0, 7)
	var frond_mesh := _frond_mesh()
	var bush_mesh := _icosphere(rng.randf_range(1.4, 2.6), 0)

	_materials["palm_trunk"] = MatLib.palm_bark()
	_materials["palm_frond"] = MatLib.foliage(Color(0.10, 0.24, 0.09))
	_materials["bush"] = MatLib.foliage(Color(0.075, 0.17, 0.06))

	var palms := 0
	var bushes := 0
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 20.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var count := int(length / PALM_SPACING)
		for i in count:
			var mid: Vector2 = a.lerp(b, (float(i) + rng.randf()) / float(maxi(count, 1)))
			var side: float = 1.0 if rng.randf() < 0.5 else -1.0
			var off: float = float(graph.edges[e["id"]]["width"]) * 0.5 + FOOTPATH_WIDTH + rng.randf_range(1.0, 3.0)
			var p: Vector2 = mid + nrm * off * side
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var h := rng.randf_range(6.5, 13.0)
			var lean := rng.randf_range(-0.09, 0.09)
			var xf := Transform3D(Basis.from_euler(Vector3(lean, rng.randf() * TAU, 0)), Vector3(p.x, 0, p.y))
			_add("palms", trunk_mesh, xf.scaled_local(Vector3(1.0, h, 1.0)), "palm_trunk")
			var frond_count := 9
			for f in frond_count:
				var ang := TAU * float(f) / frond_count + rng.randf() * 0.2
				var droop := rng.randf_range(0.35, 0.75)
				_add("fronds", frond_mesh,
					Transform3D(Basis.from_euler(Vector3(droop, ang, 0)), Vector3(p.x, h * 0.99, p.y))
						.scaled_local(Vector3(1.0, 1.0, 1.0)), "palm_frond")
			palms += 1

		# Low scrub along the verges.
		for i in int(length / 22.0):
			var mid2: Vector2 = a.lerp(b, (float(i) + rng.randf() * 0.8) / float(maxi(int(length / 22.0), 1)))
			var p2: Vector2 = mid2 + nrm * (float(graph.edges[e["id"]]["width"]) * 0.5 + 3.5) * (1.0 if rng.randf() < 0.5 else -1.0)
			_add("bushes", bush_mesh,
				Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)), Vector3(p2.x, 0.4, p2.y)),
				"bush")
			bushes += 1
	print("[World] %d palms, %d bushes" % [palms, bushes])


func _streetlights() -> void:
	## Sodium lamps. Warm orange, spaced the way a suburban council actually
	## spaces them - alternating sides, at the kerb, every ~34 m.
	var pole := _tapered_cylinder_mesh(0.09, 0.13, 1.0, 6)
	var arm := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	var lamp := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	_materials["pole"] = MatLib.wall(Color(0.16, 0.17, 0.17))
	if not _materials.has("lamp_glow"):
		_materials["lamp_glow"] = MatLib.emissive(MatLib.SODIUM, 1.15)

	var count := 0
	for ei in graph.edges.size():
		var e: Dictionary = graph.edges[ei]
		if int(e["class"]) < RoadGraph.RoadClass.STREET:
			continue
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 24.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var n := maxi(int(length / 21.0), 1)
		for i in n:
			var mid: Vector2 = a.lerp(b, (float(i) + 0.5) / float(n))
			var side: float = 1.0 if (ei + i) % 2 == 0 else -1.0
			var off: float = float(e["width"]) * 0.5 + 1.2
			var p: Vector2 = mid + nrm * off * side
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var h := 7.0
			var base := Vector3(p.x, KERB_HEIGHT, p.y)
			_add("poles", pole, Transform3D(Basis(), base).scaled_local(Vector3(1.0, h, 1.0)), "pole")
			var tip: Vector3 = base + Vector3(nrm.x * -1.4 * side, h, nrm.y * -1.4 * side)
			_add("poles", arm, Transform3D(Basis.from_euler(Vector3(0, atan2(-dir.x, -dir.y), 0)), tip + Vector3(0, -0.2, 0)).scaled_local(Vector3(0.12, 0.12, 1.5)), "pole")
			_add("lamps", lamp, Transform3D(Basis(), tip).scaled_local(Vector3(0.42, 0.16, 0.75)), "lamp_glow")

			var l := OmniLight3D.new()
			l.light_color = MatLib.SODIUM
			l.light_energy = Look.STREETLIGHT_ENERGY
			l.omni_range = Look.STREETLIGHT_RANGE
			l.omni_attenuation = Look.STREETLIGHT_ATTENUATION
			# 1121 lamps all injecting into a 70 m fog slab turns the sky into
			# sodium soup - the exact failure night_env.gd warns about. Street
			# lighting only needs to light tarmac; the fog is there for
			# headlight beams, which stay volumetric.
			l.light_volumetric_fog_energy = 0.0
			l.position = tip - Vector3(0, 0.3, 0)
			l.shadow_enabled = false   # hundreds of shadow-casting lights would melt a CPU raster
			add_child(l)
			count += 1
	print("[World] %d streetlights" % count)


func _power_lines() -> void:
	## Timber poles and sagging catenary wires. Nothing says "outer suburban
	## Australia" faster than power lines over a street.
	var pole := _tapered_cylinder_mesh(0.14, 0.19, 1.0, 6)
	_materials["pole_wood"] = MatLib.wall(Color(0.19, 0.16, 0.13))
	_materials["wire"] = MatLib.wall(Color(0.05, 0.05, 0.05))

	var pole_positions: Array = []
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 30.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var count := maxi(int(length / 45.0), 1)
		for i in count:
			var mid := a.lerp(b, (float(i) + 0.5) / float(count))
			var side: float = 1.0 if i % 2 == 0 else -1.0
			var p := mid + nrm * (float(e["width"]) * 0.5 + 2.6) * side
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var h := 9.5
			_add("poles_wood", pole, Transform3D(Basis(), Vector3(p.x, 0, p.y)).scaled_local(Vector3(1.0, h, 1.0)), "pole_wood")
			pole_positions.append(Vector3(p.x, h - 0.8, p.y))
	_connect_wires(pole_positions)


func _connect_wires(points: Array) -> void:
	# Join each pole to its nearest neighbour on roughly the same street, then
	# sag the span. Crude, but overhead wires only ever need to read as wires.
	if points.size() < 2:
		return
	var used := {}
	for i in points.size():
		var best := -1
		var best_d := 1e9
		for j in points.size():
			if i == j:
				continue
			var d: float = (points[i] as Vector3).distance_to(points[j] as Vector3)
			if d < best_d and d > 8.0 and d < 52.0:
				best_d = d
				best = j
		if best < 0:
			continue
		var key := "%d_%d" % [mini(i, best), maxi(i, best)]
		if used.has(key):
			continue
		used[key] = true
		_sag_wire(points[i], points[best])


func _sag_wire(a: Vector3, b: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var segs := 8
	var sag: float = a.distance_to(b) * 0.06
	var prev := a
	for i in range(1, segs + 1):
		var t := float(i) / segs
		var p: Vector3 = a.lerp(b, t)
		p.y -= sin(t * PI) * sag
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(prev)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p)
		prev = p
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _materials["wire"]
	add_child(mi)


func _car_meet() -> void:
	## The hub. A vacant lot off the arterial with a handful of parked cars,
	## floodlights and a crowd - the place the whole game loops back to.
	car_meet = Node3D.new()
	car_meet.name = "CarMeet"
	car_meet.position = OSMLayout.car_meet_position()
	add_child(car_meet)

	var m := OmniLight3D.new()
	m.light_color = MatLib.MERCURY
	m.light_energy = 9.0
	m.omni_range = 45.0
	m.position = Vector3(0, 9, 0)
	car_meet.add_child(m)

	var m2 := OmniLight3D.new()
	m2.light_color = MatLib.SODIUM
	m2.light_energy = 5.0
	m2.omni_range = 32.0
	m2.position = Vector3(9, 5, 6)
	car_meet.add_child(m2)


# ------------------------------------------------------------------- primitives
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := _tri_normal(a, b, c)
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x, v.z) * 0.3)
		st.add_vertex(v)


static func _tapered_cylinder_mesh(r_bottom: float, r_top: float, h: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in sides:
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var b0 := Vector3(cos(a0) * r_bottom, -h * 0.5, sin(a0) * r_bottom)
		var b1 := Vector3(cos(a1) * r_bottom, -h * 0.5, sin(a1) * r_bottom)
		var t0 := Vector3(cos(a0) * r_top, h * 0.5, sin(a0) * r_top)
		var t1 := Vector3(cos(a1) * r_top, h * 0.5, sin(a1) * r_top)
		_tri(st, b0, b1, t0)
		_tri(st, b1, t1, t0)
	var mesh := st.commit()
	return mesh


## A single palm frond: a tapered, drooping blade built from quads.
static func _frond_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 5
	var length := 3.2
	for i in segs:
		var t0 := float(i) / segs
		var t1 := float(i + 1) / segs
		var w0: float = sin(t0 * PI) * 0.55 + 0.05
		var w1: float = sin(t1 * PI) * 0.55 + 0.05
		var p0 := Vector3(0, -t0 * t0 * 1.5, t0 * length)
		var p1 := Vector3(0, -t1 * t1 * 1.5, t1 * length)
		_tri(st, p0 + Vector3(-w0, 0, 0), p0 + Vector3(w0, 0, 0), p1 + Vector3(-w1, 0, 0))
		_tri(st, p0 + Vector3(w0, 0, 0), p1 + Vector3(-w1, 0, 0), p1 + Vector3(w1, 0, 0))
	var mesh := st.commit()
	return mesh


static func _icosphere(radius: float, subdiv: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 4
	var segs := 6
	for r in rings:
		var v0 := PI * float(r) / rings
		var v1 := PI * float(r + 1) / rings
		for s in segs:
			var u0 := TAU * float(s) / segs
			var u1 := TAU * float(s + 1) / segs
			var p := func(v: float, u: float) -> Vector3:
				return Vector3(sin(v) * cos(u), cos(v), sin(v) * sin(u)) * radius
			_tri(st, p.call(v0, u0), p.call(v1, u0), p.call(v1, u1))
			_tri(st, p.call(v0, u0), p.call(v1, u1), p.call(v0, u1))
	return st.commit()
