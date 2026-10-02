extends SceneTree
## Self-check for the winding defect this file documents.
##
## Godot draws a face only when its right-hand-rule normal points AWAY from the
## camera, i.e. INTO the surface - the opposite of the outward normal the face
## should be lit with. WorldBuilder used to derive both from one cross product,
## which meant every ground surface in the game was either culled from above or
## lit from underneath (black). This asserts the two are now separate and
## correct: the stored vertex normal points OUT, the winding points IN.
##
## Run with:  godot --headless --path . --script res://Systems/road_render/winding_check.gd
## Exits non-zero on failure.

var _failed := 0


func _init() -> void:
	# 1. Every quad from _quad: normal out, winding in.
	_ground_faces("terrain quad", [
		Vector3(0, 0, 0), Vector3(0, 0, 16), Vector3(16, 0, 16), Vector3(16, 0, 0)])

	# 2. A box: each face's normal must point away from the box centre while the
	#    winding points into it. A box is the only closed primitive whose
	#    per-face "out" is unambiguous, so it is the real test of _quad.
	_box_faces()

	# 3. The carriageway and the junction patch are the game's hero surface.
	_road_quad()
	_junction_fan()

	# 4. A building wall, the same two rules against an arbitrary outward normal
	#    rather than up. OSMBuildings wound its quads to match their own normal,
	#    which made every wall, roof slope, window pane and sign a back face.
	_osm_wall_quad()

	if _failed > 0:
		print("WINDING CHECK FAILED: %d problem(s)" % _failed)
		quit(1)
		return
	print("winding check passed")
	quit(0)


## Assert a flat ground patch is lit from above and drawn from above.
func _ground_faces(label: String, corners: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	WorldBuilder._quad(st, corners[0], corners[1], corners[2], corners[3])
	var arrays: Array = st.commit().surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in n.size():
		_check(n[i].y > 0.5, "%s: vertex %d normal points up (got %s)" % [label, i, str(n[i])])
	_check(v.size() == 6, "%s: 6 vertices, got %d" % [label, v.size()])
	for t in v.size() / 3:
		var r: Vector3 = (v[t * 3 + 1] - v[t * 3]).cross(v[t * 3 + 2] - v[t * 3])
		_check(r.y < 0.0, "%s: triangle %d winds downward so it draws from above (got %s)" % [
			label, t, str(r)])


func _box_faces() -> void:
	var v: PackedVector3Array = WorldBuilder._box_mesh(Vector3.ONE, Vector3.ZERO) \
		.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = WorldBuilder._box_mesh(Vector3.ONE, Vector3.ZERO) \
		.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var mid := Vector3.ZERO
	for p in v:
		mid += p
	mid /= float(v.size())
	for t in v.size() / 3:
		var r: Vector3 = (v[t * 3 + 1] - v[t * 3]).cross(v[t * 3 + 2] - v[t * 3])
		var out_dir: Vector3 = (v[t * 3] + v[t * 3 + 1] + v[t * 3 + 2]) / 3.0 - mid
		_check(r.dot(out_dir) < 0.0,
			"box face %d winds inward so it draws from outside" % t)
		_check(n[t * 3].dot(out_dir) > 0.0,
			"box face %d normal points outward" % t)


func _road_quad() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dir := Vector2(1, 0)
	var nrm := Vector2(-dir.y, dir.x)
	var hw := 5.0
	var pa := Vector2(0, 0)
	var pb := Vector2(10, 0)
	WorldBuilder._road_quad(st,
		Vector3(pa.x - nrm.x * hw, 0, pa.y - nrm.y * hw),
		Vector3(pa.x + nrm.x * hw, 0, pa.y + nrm.y * hw),
		Vector3(pb.x + nrm.x * hw, 0, pb.y + nrm.y * hw),
		Vector3(pb.x - nrm.x * hw, 0, pb.y - nrm.y * hw),
		pa.distance_to(pb), hw)
	_winding_and_normals("road quad", st.commit())


## The junction patch is the same tarmac as the carriageway: up normal, downward
## winding, and no zero-area triangles. This drives the production helper rather
## than a copy of it - a check that re-implements the thing it checks proves
## only that the copy is correct.
func _junction_fan() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := Vector2(0, 0)
	WorldBuilder._junction_fan(st, p, 7.0, true)
	var mesh: ArrayMesh = st.commit()
	_winding_and_normals("junction fan", mesh)
	var v: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(v.size() == 30, "junction fan is 10 sectors of one triangle, got %d vertices" % v.size())
	for t in v.size() / 3:
		var a: Vector3 = v[t * 3]
		var b: Vector3 = v[t * 3 + 1]
		var c: Vector3 = v[t * 3 + 2]
		_check((b - a).cross(c - a).length_squared() > 0.000001,
			"junction fan triangle %d has area, not the zero-area sliver _quad(centre, v0, v1, v1) left" % t)


## A wall band straight from the production helper, checked against the one
## invariant that does not need a reference direction: the stored normal and the
## winding normal point opposite ways.
##
## OSMBuildings wound its quads to match their own normal. Godot draws a face only
## when its winding normal points AWAY from the camera, so that made every wall,
## roof slope, window pane and sign in the file a back face - correct geometry,
## drawn from nowhere, and invisible from the only side a building is seen from.
func _osm_wall_quad() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring := PackedVector2Array([Vector2(0, 0), Vector2(0, 8), Vector2(6, 8), Vector2(6, 0)])
	OSMBuildings._band(st, ring, 0.0, 4.0)
	_normal_against_winding("wall band", st.commit())


func _normal_against_winding(label: String, mesh: ArrayMesh) -> void:
	var arrays: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for t in v.size() / 3:
		var r: Vector3 = (v[t * 3 + 1] - v[t * 3]).cross(v[t * 3 + 2] - v[t * 3])
		_check(r.length_squared() > 0.000001, "%s: triangle %d has area" % [label, t])
		for k in 3:
			_check(n[t * 3 + k].normalized().dot(r.normalized()) < -0.99,
				"%s: triangle %d vertex %d normal is opposite its winding, or it is a back face (got %s vs %s)"
					% [label, t, k, str(n[t * 3 + k]), str(r.normalized())])


func _winding_and_normals(label: String, mesh: ArrayMesh) -> void:
	var arrays: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in n.size():
		_check(n[i].y > 0.5, "%s: vertex %d normal points up (got %s)" % [label, i, str(n[i])])
	for t in v.size() / 3:
		var r: Vector3 = (v[t * 3 + 1] - v[t * 3]).cross(v[t * 3 + 2] - v[t * 3])
		_check(r.y < 0.0, "%s: triangle %d winds downward so it draws from above (got %s)" % [
			label, t, str(r)])


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failed += 1
		print("  FAIL: %s" % msg)
