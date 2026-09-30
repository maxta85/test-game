extends SceneTree
## Measure every car glb: true world-space AABB, mesh count, vertex count,
## whether textures survived the export.
## Run: ./run.sh --script res://Tools/measure_cars.gd

var lo := Vector3(INF, INF, INF)
var hi := Vector3(-INF, -INF, -INF)
var meshes := 0
var verts := 0
var mat_slots := 0
var textured := 0


func _initialize() -> void:
	for f in _car_files():
		_measure("res://assets/cars/" + f)
	quit()


func _car_files() -> Array:
	var d := DirAccess.open("res://assets/cars")
	if d == null:
		return []
	var out: Array = []
	for f in d.get_files():
		if f.ends_with(".glb"):
			out.append(f)
	out.sort()
	return out


func _measure(path: String) -> void:
	lo = Vector3(INF, INF, INF)
	hi = Vector3(-INF, -INF, -INF)
	meshes = 0
	verts = 0
	mat_slots = 0
	textured = 0

	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		print("%-18s LOAD FAILED" % path.get_file())
		return
	var root: Node = doc.generate_scene(st)
	if root == null:
		print("%-18s NO SCENE" % path.get_file())
		return
	get_root().add_child(root)
	_walk(root)

	print("%-18s meshes=%-4d slots=%-4d verts=%-8d textured=%d/%d" % [
		path.get_file(), meshes, mat_slots, verts, textured, meshes])
	if lo.x < INF:
		var d2: Vector3 = hi - lo
		print("%-18s   min=(%8.2f,%8.2f,%8.2f)  size=(%.2f, %.2f, %.2f)" % [
			"", lo.x, lo.y, lo.z, d2.x, d2.y, d2.z])
	get_root().remove_child(root)
	root.free()


func _walk(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m := mi.mesh
		if m == null:
			return
		meshes += 1
		var sc := m.get_surface_count()
		mat_slots += sc
		if sc > 0:
			var mt := m.surface_get_material(0) as BaseMaterial3D
			if mt != null and mt.albedo_texture != null:
				textured += 1
			var arr := m.surface_get_arrays(0)
			if arr[Mesh.ARRAY_VERTEX] != null:
				verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var xf: Transform3D = mi.global_transform
		var ab: AABB = mi.get_aabb()
		for i in 8:
			var c: Vector3 = xf * ab.get_endpoint(i)
			lo = Vector3(minf(lo.x, c.x), minf(lo.y, c.y), minf(lo.z, c.z))
			hi = Vector3(maxf(hi.x, c.x), maxf(hi.y, c.y), maxf(hi.z, c.z))
	for c in n.get_children():
		_walk(c)
