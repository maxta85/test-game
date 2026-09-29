extends SceneTree
## Measures render throughput on this machine, so iteration cost is a known
## number rather than a guess.  ./bench.sh [objects] [frames]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var n_objects: int = int(args[0]) if args.size() > 0 else 2000
	var n_frames: int = int(args[1]) if args.size() > 1 else 120

	var world := Node3D.new()
	root.add_child(world)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 3, 12)
	world.add_child(cam)

	# A stand-in for the world: a few thousand instances across a ground plane,
	# which is roughly what a dense Manunda block costs to draw.
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	ground.mesh = pm
	world.add_child(ground)

	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.6, 4.0, 0.6)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.33, 0.3)
	mesh.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = n_objects
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in n_objects:
		mm.set_instance_transform(i, Transform3D(
			Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)),
			Vector3(rng.randf_range(-120, 120), 0, rng.randf_range(-120, 120))))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	world.add_child(mmi)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.shadow_enabled = true
	world.add_child(light)

	for i in 3:
		await process_frame

	var t0 := Time.get_ticks_msec()
	for i in n_frames:
		await process_frame
	var elapsed: float = (Time.get_ticks_msec() - t0) / 1000.0
	print("BENCH objects=%d frames=%d elapsed=%.2fs  ->  %.1f fps (software raster)" % [
		n_objects, n_frames, elapsed, n_frames / maxf(elapsed, 0.001)])
	quit(0)
