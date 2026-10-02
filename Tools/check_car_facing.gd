extends SceneTree

const SOURCE_NOSE := {
	"silvia_s13": Vector3.BACK,
	"supra_mk4": Vector3.BACK,
	"wrx_gc8": Vector3.FORWARD,
	"evo_v": Vector3.BACK,
	"silvia_s15": Vector3.BACK,
}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var render := "--render" in OS.get_cmdline_user_args()
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.current = true
	camera.fov = 45.0
	var light := DirectionalLight3D.new()
	world.add_child(light)
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.light_energy = 1.5
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.15, 0.17, 0.21)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.6
	world.add_child(environment)
	var label := Label.new()
	label.position = Vector2(12, 12)
	label.add_theme_font_size_override("font_size", 24)
	root.add_child(label)
	var sheet := Image.create(1280, 360 * SOURCE_NOSE.size(), false, Image.FORMAT_RGBA8)
	var failures := 0
	var row := 0
	for car_id in CarVisual.MODELS:
		var model_id: String = CarVisual.MODELS[car_id]
		var visual := CarVisual.new()
		world.add_child(visual)
		visual.build(CarDB.get_spec(car_id))
		var model := visual.get_node_or_null("Model") as Node3D
		if model == null or not SOURCE_NOSE.has(model_id):
			printerr("FAIL: missing model or measured heading: ", model_id)
			failures += 1
		else:
			var nose: Vector3 = (model.transform.basis * SOURCE_NOSE[model_id]).normalized()
			var passed := nose.dot(Vector3.FORWARD) > 0.99
			print("%s: %s nose=%s" % ["PASS" if passed else "FAIL", model_id, nose])
			if not passed:
				failures += 1
		if render:
			for side in 2:
				camera.position = Vector3(3.0, 2.2, -6.0 if side == 0 else 6.0)
				camera.look_at(Vector3(0, 1.0, 0))
				label.text = "%s — %s" % [model_id, "FRONT (-Z)" if side == 0 else "REAR (+Z)"]
				for frame in 8:
					await process_frame
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				image.convert(Image.FORMAT_RGBA8)
				image.resize(640, 360)
				sheet.blit_rect(image, Rect2i(0, 0, 640, 360), Vector2i(side * 640, row * 360))
		world.remove_child(visual)
		visual.free()
		row += 1
	if render:
		var path := OS.get_environment("CAR_FACING_SHOT")
		if path.is_empty():
			path = "/tmp/car-facing.png"
		if sheet.save_png(path) != OK:
			failures += 1
		print("car facing sheet: ", path)
	print("car facing: %d models, %d failures" % [row, failures])
	quit(1 if failures else 0)
