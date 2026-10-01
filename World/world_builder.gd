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
const BUILDING_SETBACK := 9.0
const PALM_SPACING := 17.0

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
			_quad(st, Vector3(x0, h00, z0), Vector3(x1, h10, z0), Vector3(x1, h11, z1), Vector3(x0, h01, z1))
			_quad(st, Vector3(x0, h00, z0), Vector3(x1, h11, z1), Vector3(x1, h10, z0), Vector3(x0, h01, z0))
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


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.set_normal(_tri_normal(a, b, c))
	st.set_uv(Vector2(a.x, a.z) * 0.02)
	st.add_vertex(a)
	st.set_normal(_tri_normal(a, b, c))
	st.set_uv(Vector2(b.x, b.z) * 0.02)
	st.add_vertex(b)
	st.set_normal(_tri_normal(a, b, c))
	st.set_uv(Vector2(c.x, c.z) * 0.02)
	st.add_vertex(c)
	st.set_normal(_tri_normal(a, b, c))
	st.set_uv(Vector2(a.x, a.z) * 0.02)
	st.add_vertex(a)
	st.set_normal(_tri_normal(a, b, c))
	st.set_uv(Vector2(c.x, c.z) * 0.02)
	st.add_vertex(c)
	st.set_normal(_tri_normal(a, b, c))
	st.set_uv(Vector2(d.x, d.z) * 0.02)
	st.add_vertex(d)


static func _tri_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	return n.normalized() if n.length_squared() > 0.000001 else Vector3.UP


# --------------------------------------------------------------- road surfaces
func _road_surface() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
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
		_road_quad(st, a0, a1, b1, b0, uv_len, hw)
	var mi := MeshInstance3D.new()
	mi.name = "RoadSurface"
	mi.mesh = st.commit()
	mi.material_override = _mat("asphalt")
	mi.position.y = 0.015
	add_child(mi)


static func _road_quad(st: SurfaceTool, a0: Vector3, a1: Vector3, b1: Vector3, b0: Vector3,
		length: float, half_width: float) -> void:
	var verts := [a0, a1, b1, a0, b1, b0]
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


func _lane_markings() -> void:
	# Centre lines: dashed white on streets, solid yellow on arterials.
	var dash := _box_mesh(Vector3(0.12, 0.012, 3.0), Vector3.ZERO)
	var solid := _box_mesh(Vector3(0.12, 0.012, 4.0), Vector3.ZERO)
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 6.0:
			continue
		var dir := seg / length
		var ang := atan2(dir.x, dir.y)
		var arterial: bool = int(e["class"]) >= RoadGraph.RoadClass.ARTERIAL
		var step := 0.0
		while step < length - 2.0:
			var mid: Vector2 = a.lerp(b, (step + 1.4) / length)
			var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(mid.x, 0.028, mid.y))
			if arterial:
				_add("markings", solid, xf, "paint_yellow")
				step += 4.0
			else:
				_add("markings", dash, xf, "paint_white")
				step += 7.0


func _intersections() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		var p: Vector2 = n["pos"]
		var r: float = graph.width_for(int(n["class"])) * 0.5
		# A fan of 10 triangles fills the junction patch; at these radii and
		# heights nobody can tell it is not a perfect polygon.
		var segs := 10
		for i in segs:
			var a0 := TAU * float(i) / segs
			var a1 := TAU * float(i + 1) / segs
			var v0 := Vector3(p.x + cos(a0) * r, 0, p.y + sin(a0) * r)
			var v1 := Vector3(p.x + cos(a1) * r, 0, p.y + sin(a1) * r)
			_quad(st, Vector3(p.x, 0, p.y), v0, v1, v1)
	var mi := MeshInstance3D.new()
	mi.name = "Intersections"
	mi.mesh = st.commit()
	mi.material_override = _mat("asphalt")
	mi.position.y = 0.02
	add_child(mi)


func _drainage() -> void:
	# Open concrete channels, the reason Manunda floods and the reason every
	# kerb here has one.
	var channel := _box_mesh(Vector3(1.6, 0.30, 4.0), Vector3(0, -0.15, 0))
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
			var p := mid + nrm * (hw + 0.95)
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(p.x, 0, p.y))
			_add("drainage", channel, xf.scaled_local(Vector3(1.0, 1.0, 8.4)), "concrete")
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
		var r: float = graph.width_for(int(n["class"])) * 0.5
		var segs := 10
		for i in segs:
			var a0 := TAU * float(i) / segs
			var a1 := TAU * float(i + 1) / segs
			_quad(st, Vector3(p.x, 0, p.y),
				Vector3(p.x + cos(a0) * r, 0, p.y + sin(a0) * r),
				Vector3(p.x + cos(a1) * r, 0, p.y + sin(a1) * r),
				Vector3(p.x + cos(a1) * r, 0, p.y + sin(a1) * r))

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

## Low-rise Queensland houses: raised on stumps for flood water, corrugated roof,
## a carport out front, and lit windows. Placed in the blocks between streets.
func _buildings() -> void:
	var wall_mesh := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	var roof_mesh := _gabled_roof_mesh(1.0, 1.0, 1.0)
	var window_mesh := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	var fence_mesh := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)

	# Tint palettes: real Queensland suburbs are not one colour, they are
	# forty years of paint that nobody could agree on.
	var wall_tints := [
		Color(0.52, 0.50, 0.46), Color(0.44, 0.47, 0.44), Color(0.58, 0.53, 0.47),
		Color(0.38, 0.42, 0.40), Color(0.62, 0.58, 0.52), Color(0.48, 0.45, 0.42),
	]
	var roof_tints := [
		Color(0.30, 0.31, 0.30), Color(0.36, 0.30, 0.26), Color(0.26, 0.30, 0.30),
		Color(0.42, 0.38, 0.33), Color(0.32, 0.26, 0.24),
	]

	var placed := 0
	var lights: Array = []
	for block in _blocks():
		var origin: Vector2 = block["centre"]
		var half: Vector2 = block["half"]
		var ang: float = float(block["angle"])
		var is_commercial: bool = bool(block.get("commercial", false))
		var is_industrial: bool = bool(block.get("industrial", false))

		var front := Vector2(cos(ang), sin(ang))
		var side := Vector2(-front.y, front.x)
		var cols: int = 2 if (half.x < 42.0 or is_commercial or is_industrial) else 3
		var rows: int = 3 if (half.y < 44.0 or is_commercial or is_industrial) else 4

		for ci in cols:
			for ri in rows:
				var u: float = (float(ci) / maxf(float(cols - 1), 1.0) - 0.5) * (half.x * 1.7)
				var v: float = (float(ri) / maxf(float(rows - 1), 1.0) - 0.5) * (half.y * 1.7)
				var p: Vector2 = origin + front * u + side * v
				var near: Dictionary = graph.nearest_road(Vector3(p.x, 0, p.y))
				if float(near["lateral"]) < BUILDING_SETBACK + float(near["edge_width"] if near.has("edge_width") else 0.0):
					continue
				if float(near["lateral"]) < BUILDING_SETBACK:
					continue

				if is_industrial:
					_industrial_shed(p, ang, wall_mesh, roof_mesh, wall_tints, roof_tints, lights)
				elif is_commercial:
					_shopfront(p, ang, wall_mesh, roof_mesh, window_mesh, wall_tints, roof_tints, lights)
				else:
					_house(p, ang, wall_mesh, roof_mesh, window_mesh, fence_mesh, wall_tints, roof_tints, lights)
				placed += 1

	for l in lights:
		add_child(l)
	print("[World] %d buildings placed" % placed)


func _blocks() -> Array:
	## The gaps between streets, derived from the graph rather than authored, so
	## buildings always sit inside a real block.
	var out: Array = []
	for n in graph.nodes:
		# 3 edges or more, not exactly 4. A block only has to be enclosed by
		# streets, and a T-junction does that as well as a crossroads. Requiring
		# exactly 4 was invisible on the authored Manunda lattice, where almost
		# every junction was a crossroads, and cost almost the entire city on real
		# OSM data, where most junctions are T-junctions: 359 nodes, 13 buildings.
		if n["edges"].size() < 3:
			continue
		var p: Vector2 = n["pos"]
		# Sample a ring of points around the junction; if we stay off-road all
		# the way round, we are inside a block.
		var radii := [0.0, 55.0, 90.0]
		for r in radii:
			var corners: Array = []
			var ok := true
			for k in 4:
				var a := TAU * float(k) / 4.0 + PI * 0.25
				var q: Vector2 = p + Vector2(cos(a), sin(a)) * r
				var near: Dictionary = graph.nearest_road(Vector3(q.x, 0, q.y))
				if float(near["lateral"]) < 13.0:
					ok = false
					break
				corners.append(q)
			if ok and r > 0.0:
				out.append({
					"centre": p, "half": Vector2(r, r), "angle": 0.0,
					# Shops follow the big roads, not a hardcoded patch of the map.
					# The first pass put the commercial strip near the origin while
					# the racing happens three blocks west, so the streets anyone
					# actually drives were the only ones with nothing on them.
					"commercial": _road_class_at(p) >= RoadGraph.RoadClass.ARTERIAL,
					"industrial": p.x < -280.0 and p.y > 200.0,
				})
				break
	return out


## Class of the road nearest a point, or LANE if the block is nowhere near one.
func _road_class_at(p: Vector2) -> int:
	var near: Dictionary = graph.nearest_road(Vector3(p.x, 0, p.y))
	var eid: int = int(near["edge"])
	if eid < 0 or eid >= graph.edges.size():
		return RoadGraph.RoadClass.LANE
	return int(graph.edges[eid]["class"])


func _house(p: Vector2, ang: float, wall_mesh: ArrayMesh, roof_mesh: ArrayMesh,
		window_mesh: ArrayMesh, fence_mesh: ArrayMesh, wall_tints: Array, roof_tints: Array,
		lights: Array) -> void:
	var w := rng.randf_range(8.0, 12.0)
	var d := rng.randf_range(7.0, 10.0)
	# Queenslanders stand up on stumps because the ground floods. That gap under
	# the floor is one of the most recognisable things about the architecture.
	var lift := rng.randf_range(0.8, 1.5)
	var h := rng.randf_range(2.7, 3.2)
	var tint: Color = wall_tints[rng.randi() % wall_tints.size()]
	var roof: Color = roof_tints[rng.randi() % roof_tints.size()]
	var basis := Basis.from_euler(Vector3(0, -ang, 0))
	var base := Vector3(p.x, 0, p.y)

	var wall_key := "wall_%d" % (wall_tints.find(tint))
	_materials[wall_key] = MatLib.wall(tint)
	_add("houses", wall_mesh,
		Transform3D(basis, base + Vector3(0, lift + h * 0.5, 0)).scaled_local(Vector3(w, h, d)),
		wall_key)

	var roof_key := "roof_%d" % (roof_tints.find(roof))
	_materials[roof_key] = MatLib.corrugated(roof)
	_add("roofs", roof_mesh,
		Transform3D(basis, base + Vector3(0, lift + h, 0)).scaled_local(Vector3(w * 1.16, 1.5, d * 1.12)),
		roof_key)

	# Front verandah posts and a carport - the two things that say "Queensland".
	for i in 3:
		var u := (float(i) / 2.0 - 0.5) * (w - 1.0)
		_add("houses", wall_mesh,
			Transform3D(basis, base + basis * Vector3(u, lift + h * 0.5, -d * 0.5 - 1.6))
				.scaled_local(Vector3(0.18, h, 0.18)), wall_key)
	_add("roofs", roof_mesh,
		Transform3D(basis, base + basis * Vector3(w * 0.5 + 1.9, lift + h * 0.55, -d * 0.2))
			.scaled_local(Vector3(4.0, 0.7, d * 0.9)), roof_key)

	# Windows: most of the street is dark, some are warm. That mix is the point.
	var win_key := "window_lit"
	if not _materials.has(win_key):
		_materials[win_key] = MatLib.emissive(Color(1.0, 0.74, 0.44), 1.1)
	var dark_key := "window_dark"
	if not _materials.has(dark_key):
		_materials[dark_key] = MatLib.emissive(Color(0.10, 0.13, 0.18), 0.0)
	for i in 2:
		var lit: bool = rng.randf() < 0.45
		var u2 := (float(i) - 0.5) * w * 0.45
		_add("windows", window_mesh,
			Transform3D(basis, base + basis * Vector3(u2, lift + h * 0.55, -d * 0.5 - 0.03))
				.scaled_local(Vector3(1.1, 1.2, 0.06)),
			win_key if lit else dark_key)

	# Front fence and a concrete driveway slab.
	_add("fences", fence_mesh,
		Transform3D(basis, base + basis * Vector3(0, 0.55, -d * 0.5 - 4.0))
			.scaled_local(Vector3(w + 3.0, 1.1, 0.10)), wall_key)
	_add("fences", fence_mesh,
		Transform3D(basis, base + basis * Vector3(-w * 0.5 - 1.5, 0.55, -d * 0.5 - 2.0))
			.scaled_local(Vector3(0.10, 1.1, 4.0)), wall_key)
	_add("fences", fence_mesh,
		Transform3D(basis, base + basis * Vector3(w * 0.5 + 1.5, 0.55, -d * 0.5 - 2.0))
			.scaled_local(Vector3(0.10, 1.1, 4.0)), wall_key)


func _shopfront(p: Vector2, ang: float, wall_mesh: ArrayMesh, roof_mesh: ArrayMesh,
		window_mesh: ArrayMesh, wall_tints: Array, roof_tints: Array, lights: Array) -> void:
	var w := rng.randf_range(12.0, 20.0)
	var d := rng.randf_range(9.0, 13.0)
	var h := rng.randf_range(3.6, 5.0)
	var tint: Color = wall_tints[rng.randi() % wall_tints.size()]
	var basis := Basis.from_euler(Vector3(0, -ang, 0))
	var base := Vector3(p.x, 0, p.y)
	var key := "wall_%d" % wall_tints.find(tint)
	_materials[key] = MatLib.wall(tint)
	_add("shops", wall_mesh, Transform3D(basis, base + Vector3(0, h * 0.5, 0)).scaled_local(Vector3(w, h, d)), key)
	_add("shops", roof_mesh, Transform3D(basis, base + Vector3(0, h, 0)).scaled_local(Vector3(w * 1.1, 1.3, d * 1.1)), "concrete")

	# A big lit shopfront window, and a sign.
	var glow: String = ["neon_pink", "neon_cyan", "sodium"][rng.randi() % 3]
	if not _materials.has(glow):
		_materials[glow] = MatLib.emissive(MatLib.SODIUM if glow == "sodium" else (MatLib.NEON_PINK if glow == "neon_pink" else MatLib.NEON_CYAN), 2.4)
	_add("shops", window_mesh,
		Transform3D(basis, base + basis * Vector3(0, 1.9, -d * 0.5 - 0.05)).scaled_local(Vector3(w * 0.8, 2.6, 0.08)), glow)
	_add("shops", window_mesh,
		Transform3D(basis, base + basis * Vector3(0, h - 0.6, -d * 0.5 - 0.12)).scaled_local(Vector3(w * 0.7, 0.9, 0.10)), glow)

	var l := OmniLight3D.new()
	l.light_color = MatLib.SODIUM if glow != "neon_cyan" else MatLib.NEON_CYAN
	l.light_energy = 4.5
	l.omni_range = 26.0
	l.light_volumetric_fog_energy = 0.0
	l.position = base + basis * Vector3(0, 3.2, -d * 0.5 - 2.0)
	lights.append(l)

	# A vertical sign on the corner. This is the single cheapest thing that makes
	# a street read as a city at night: a saturated bar of light standing above
	# the roofline, doubled in the wet road, visible from three blocks away.
	if rng.randf() < 0.85:
		var sign_col: Color = [MatLib.NEON_PINK, MatLib.NEON_CYAN, MatLib.SODIUM, Color(1.0, 0.25, 0.12)][rng.randi() % 4]
		var sign_key := "sign_%s" % sign_col.to_html(false)
		if not _materials.has(sign_key):
			_materials[sign_key] = MatLib.emissive(sign_col, 3.2)
		var sh := rng.randf_range(4.5, 8.0)
		var side_x: float = (w * 0.5 - 0.5) * (1.0 if rng.randf() < 0.5 else -1.0)
		_add("signs", window_mesh,
			Transform3D(basis, base + basis * Vector3(side_x, h + sh * 0.5 - 0.3, -d * 0.5 - 0.2))
				.scaled_local(Vector3(0.6, sh, 0.4)), sign_key)


func _industrial_shed(p: Vector2, ang: float, wall_mesh: ArrayMesh, roof_mesh: ArrayMesh,
		wall_tints: Array, roof_tints: Array, lights: Array) -> void:
	var w := rng.randf_range(18.0, 30.0)
	var d := rng.randf_range(12.0, 20.0)
	var h := rng.randf_range(4.5, 6.5)
	var tint := Color(0.30, 0.31, 0.30)
	if not _materials.has("shed"):
		_materials["shed"] = MatLib.corrugated(tint)
	var basis := Basis.from_euler(Vector3(0, -ang, 0))
	var base := Vector3(p.x, 0, p.y)
	_add("sheds", wall_mesh, Transform3D(basis, base + Vector3(0, h * 0.5, 0)).scaled_local(Vector3(w, h, d)), "shed")
	_add("sheds", roof_mesh, Transform3D(basis, base + Vector3(0, h, 0)).scaled_local(Vector3(w * 1.06, 1.1, d * 1.06)), "shed")
	if rng.randf() < 0.5:
		var l := OmniLight3D.new()
		l.light_color = MatLib.MERCURY
		l.light_energy = 3.0
		l.omni_range = 28.0
		l.light_volumetric_fog_energy = 0.0
		l.position = base + Vector3(0, h - 0.5, -d * 0.5 - 1.0)
		lights.append(l)


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
static func _gabled_roof_mesh(w: float, h: float, d: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := w * 0.5
	var hd := d * 0.5
	var apex := Vector3(0, h * 0.5, 0)
	var corners := [
		Vector3(-hw, -h * 0.5, -hd), Vector3(hw, -h * 0.5, -hd),
		Vector3(hw, -h * 0.5, hd), Vector3(-hw, -h * 0.5, hd),
	]
	for i in 4:
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		_tri(st, a, b, apex)
		_tri(st, b, a, apex)
	var mesh := st.commit()
	return mesh


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
