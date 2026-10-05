extends SceneTree
## TEMP diagnostic for t192 (not a suite: the runner only discovers test_*.gd).
## Run: /home/coder/tools/godot --headless --path . --script res://Tests/probe_t192.gd
##
## For every car: settle it on a flat road, then report, in world metres,
##   - where the imported model's lowest geometry is vs the road surface
##   - where each wheel rig's geometry is vs the physics mount it belongs to
##   - whether the physics wheel reports contact
## The body origin is at hub height, so the road is at y = -tyre_radius in body
## space and a correctly mounted tyre's lowest vertex is exactly there.

const CORNERS := ["FL", "FR", "RL", "RR"]


func _initialize() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	root.add_child(ground)
	await physics_frame
	await physics_frame

	for slot in CarDB.ALL_IDS.size():
		await _one(String(CarDB.ALL_IDS[slot]), slot)
	quit(0)


func _one(car_id: String, slot: int) -> void:
	var spec := CarDB.get_spec(car_id)
	spec.start_position = Vector3(float(slot) * 12.0, spec.tyre_radius + 0.05, 0.0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	root.add_child(car)
	for i in 150:
		await physics_frame

	var r: float = spec.tyre_radius
	var model_id: String = CarVisual.MODELS.get(car_id, "-")
	print("\n=== %s  model=%s  r=%.3f  track=%.3f  base=%.3f  hub_y(car)=%.4f" % [
		car_id, model_id, r, spec.track_width, spec.wheelbase,
		car.global_position.y])
	print("    car origin y=%.4f  -> road in body space is y=%.4f" % [car.global_position.y, -r])
	print("    physics: on_ground=%d  %s" % [car.wheels_on_ground, _flags(car)])
	print("    loads:   %s" % _loads(car))
	print("    hub_world_y per corner (physics mount): %s" % _mounts(car))

	# Whole visual: how far off the road is the lowest geometry?
	var whole := _bounds(car.visual)
	if whole.size.length() > 0.0:
		print("    visual lowest y=%.4f  (gap to road %+.4f m)  height=%.3f" % [
			whole.position.y, whole.position.y, whole.size.y])
	var holder := car.visual.get_node_or_null("Model")
	if holder != null:
		var hb := _bounds(holder)
		print("    holder origin=%s  body lowest y=%.4f  body height=%.3f  (road is y=0)" % [
			str(holder.position.snappedf(0.0001)), hb.position.y, hb.size.y])

	var rigs := car.visual.wheel_nodes()
	for w in rigs:
		var name := String(w["name"])
		var steer: Node3D = w["steer"]
		var spin: Node3D = w["spin"]
		var mnt: Vector3 = car.global_transform * (car.get_wheel(name)["mount"])
		var b := _bounds(spin)
		var centre := b.get_center()
		var lowest := b.position.y
		print("    %s steer_node_pos=%s  asked_mount=%s" % [
			name, str(steer.position.snappedf(0.0001)), str((mnt - car.global_position).snappedf(0.0001))])
		if b.size.length() > 0.0:
			print("        mesh centre offset from its own mount = %+.4f m  |  "
				% (centre - mnt).length()
				+ "geometry lowest %+.4f m above the road (want ~0)  size=%.3f x %.3f x %.3f" % [
					lowest, b.size.x, b.size.y, b.size.z])
			# A world AABB is the low point of a box around a tilted wheel, not the
			# tyre's lowest vertex, so take the real minimum over the vertices.
			var src: Dictionary = car.get_wheel(name)
			var true_low := _lowest_vertex(spin)
			var cp: Vector3 = src["contact_point"]
			print("        TRUE tyre lowest=%+.4f m  contact point y=%+.4f  gap=%+.4f m" % [
				true_low, cp.y, true_low - cp.y])
			print("        got steer world=%s  asked (mount+compression)=%s" % [
				str(steer.global_position.snappedf(0.0001)), str((car.global_transform * ((mnt - car.global_position) + Vector3(0.0, float(src["compression"]), 0.0))).snappedf(0.0001))])
			var local := _local_bounds(spin)
			print("        vertices as stored (hub-local): centre=%s  drop below hub=%.4f (spec r=%.3f)" % [
				str(local.get_center().snappedf(0.001)), -local.position.y, r])
			print("        got world centre=%s  asked centre=%s" % [
				str(centre.snappedf(0.001)), str(mnt.snappedf(0.001))])
		else:
			print("        (no geometry)")
	car.queue_free()
	for i in 3:
		await physics_frame


func _flags(car: CarBody) -> String:
	var out: Array[String] = []
	for name in CORNERS:
		var w: Dictionary = car.get_wheel(name)
		out.append("%s=%s" % [name, "yes" if bool(w["contact"]) else "NO"])
	return " ".join(out)


func _loads(car: CarBody) -> String:
	var out: Array[String] = []
	for name in CORNERS:
		out.append("%s=%.0fN" % [name, float(car.get_wheel(name)["load"])])
	return " ".join(out)


func _mounts(car: CarBody) -> String:
	var out: Array[String] = []
	for name in CORNERS:
		var p: Vector3 = car.global_transform * (car.get_wheel(name)["mount"])
		out.append("%s=%.4f" % [name, p.y])
	return " ".join(out)


func _bounds(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for c in _all_meshes(node):
		var b: AABB = c.global_transform * (c.mesh.get_aabb())
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


## Lowest world-space vertex under a node, over the real vertices rather than a
## box around them: a tilted wheel's world AABB reaches lower than the tyre does.
func _lowest_vertex(node: Node) -> float:
	var low := INF
	for c in _all_meshes(node):
		var xf: Transform3D = (c as Node3D).global_transform
		for s in (c.mesh as Mesh).get_surface_count():
			var verts: PackedVector3Array = (c.mesh as Mesh).surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			for v in verts:
				low = minf(low, (xf * v).y)
	return low


## Bounds of the geometry as the mesh files store it, ignoring every node
## transform: this is what "where did the scan put it" looks like.
func _local_bounds(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for c in _all_meshes(node):
		var b: AABB = c.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


func _all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		if (node as MeshInstance3D).visible:
			out.append(node)
	for c in node.get_children():
		out.append_array(_all_meshes(c))
	return out
