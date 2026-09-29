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

	get_tree().quit()
