extends Node
## Prints what the camera can actually see, so "the frame is black" becomes a
## specific number instead of a guess. Enabled with: --probe

func _ready() -> void:
	var main := get_tree().current_scene
	for i in 30:
		await get_tree().process_frame

	var cam := main.get_node_or_null("Camera")
	var car := main.get_node_or_null("PlayerCar")
	if cam == null or car == null:
		print("[Probe] missing camera or car")
		get_tree().quit()
		return

	var lights := 0
	var meshes := 0
	var stack: Array = [main]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Light3D:
			lights += 1
		if n is MeshInstance3D or n is MultiMeshInstance3D:
			meshes += 1
		for c in n.get_children():
			stack.append(c)

	var cam3d: Camera3D = cam.get_child(0) as Camera3D
	print("[Probe] camera pos=%s fov=%.1f" % [str(cam.global_position), cam3d.fov if cam3d else 0.0])
	print("[Probe] car pos=%s wheels_on_ground=%d" % [str(car.global_position), car.wheels_on_ground])
	# How far the camera is from its own car, and whether the car is wearing an
	# exterior at all. "The frame has no car in it" is otherwise undebuggable.
	var vis := car.get_node_or_null("Visual")
	print("[Probe] camera->car = %.2f m, car visual=%s%s" % [
		cam.global_position.distance_to(car.global_position),
		vis != null,
		"" if vis == null else " (%d children)" % vis.get_child_count()])
	print("[Probe] lights=%d mesh nodes=%d" % [lights, meshes])

	var env := main.get_node_or_null("NightEnvironment") as NightEnv
	if env != null:
		var e: Environment = env.environment
		print("[Probe] ambient_energy=%.2f exposure=%.2f white=%.1f tonemap=%d" % [
			e.ambient_light_energy, e.tonemap_exposure, e.tonemap_white, e.tonemap_mode])
		print("[Probe] fog begin=%.1f end=%.1f glow=%.2f" % [
			e.fog_depth_begin, e.fog_depth_end, e.glow_intensity])

	# What is actually in front of the camera?
	var space := get_viewport().world_3d.direct_space_state
	var from: Vector3 = cam.global_position
	var to: Vector3 = from - cam.global_transform.basis.z * 60.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	var hit := space.intersect_ray(q)
	print("[Probe] forward ray: %s" % ("open air - nothing hit" if hit.is_empty() else str(hit["position"])))

	# And straight down, to confirm the car is over the road collider.
	var q2 := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 30.0)
	q2.collision_mask = 1
	var hit2 := space.intersect_ray(q2)
	print("[Probe] ground ray: %s" % ("NO GROUND UNDER CAMERA" if hit2.is_empty() else str(hit2["position"])))

	# "The frame is black" is almost always "nothing is lighting this bit of
	# road". Find the nearest real light to the camera and how far down the view
	# direction it sits - a lamp 40 m away at 2 m off the ground cannot help.
	var all := _all_nodes(main)
	var nearest := INF
	var nearest_pos := Vector3.ZERO
	var n_energy := 0.0
	for n in all:
		if n is Light3D and not (n is DirectionalLight3D):
			var d: float = cam.global_position.distance_to(n.global_position)
			if d < nearest:
				nearest = d
				nearest_pos = n.global_position
				n_energy = (n as Light3D).light_energy
	var fwd: Vector3 = -cam.global_transform.basis.z
	if nearest < INF:
		var to_l: Vector3 = (nearest_pos - cam.global_position).normalized()
		print("[Probe] nearest light %.1f m away, energy %.1f, %.1f m up, angle off view axis %.0f deg" % [
			nearest, n_energy, nearest_pos.y - cam.global_position.y, rad_to_deg(fwd.angle_to(to_l))])

	# Light density in the near field, bucketed by distance. A uniform "1121
	# streetlights" total is useless to judge a single frame by: the question is
	# how many of them are within lamp range of THIS camera, and how much of
	# the frame is covered.
	for r in [20.0, 40.0, 80.0]:
		var within := 0
		var energy_sum := 0.0
		for n in all:
			if n is OmniLight3D:
				var o := n as OmniLight3D
				if cam.global_position.distance_to(o.global_position) <= r:
					within += 1
					energy_sum += o.light_energy
		print("[Probe] omni lights within %3.0f m: %4d (avg energy %.1f)" % [r, within, energy_sum / maxi(within, 1)])

	# The car's real on-screen size. Framing presets are written as offsets from
	# the car origin, so a spec with an unexpectedly long body fills the frame
	# even though the numbers in shot_poser.gd look reasonable.
	var total := AABB()
	var first := true
	for n in _all_nodes(car):
		# Light3D extends VisualInstance3D, and a light's AABB is its debug gizmo
		# (28 m for an omni, ~58 m for a spot). Counting them makes a 4 m car
		# report a 74 m bounding box.
		if n is VisualInstance3D and not (n is Light3D) and (n as VisualInstance3D).visible:
			var vi := n as VisualInstance3D
			var b: AABB = vi.get_aabb()
			# get_aabb() is in the node's own space, so it has to be transformed
			# into car space before merging - comparing raw local boxes is how a
			# sane car ends up reporting a 58 m bounding box.
			var world: Transform3D = car.global_transform.affine_inverse() * vi.global_transform
			b = world * b
			total = b if first else total.merge(b)
			first = false
			if b.size.length() > 8.0:
				print("[Probe]   oversized part %-12s size=%s at %s" % [vi.name, str(b.size), str(b.get_center())])
	if not first:
		print("[Probe] car visual AABB size=%s  (from camera %.2f m)" % [
			str(total.size), cam.global_position.distance_to(car.global_position)])
	# Car-space sizes hide a global scale, which is exactly the sort of thing
	# makes a correct-looking AABB render as a cube. Report it separately.
	var s: Vector3 = car.global_transform.basis.get_scale()
	print("[Probe] car global scale=%.3f x %.3f x %.3f" % [s.x, s.y, s.z])

	get_tree().quit()


func _all_nodes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
