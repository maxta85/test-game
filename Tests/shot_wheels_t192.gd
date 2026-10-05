extends SceneTree
## Frames for t192: the wheel rig, close up, on a flat road. Not a suite - the
## runner only discovers test_*.gd.
##
##   DISPLAY=:99 /home/coder/tools/godot --path . --rendering-driver opengl3 \
##     --audio-driver Dummy --fixed-fps 60 --script res://Tests/shot_wheels_t192.gd
##
## One side-on frame with the car parked, then one with it rolling and steering,
## so the contact patches and the steered front wheels are both visible. Poses are
## printed next to every frame: asked camera transform vs the one that rendered.

const OUT := "/tmp/reports/t192-frames/"
const CARS := ["kairo_s13", "tatsuya_gt", "shinobi_rs"]
const RES := Vector2i(960, 540)

var _marks: Array = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.08)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.75)
	e.ambient_light_energy = 0.9
	env.environment = e
	root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 35.0, 0.0)
	sun.light_energy = 1.4
	root.add_child(sun)

	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	mi.mesh = pm
	mi.position = Vector3(0, -0.5, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.11, 0.11, 0.12)
	mat.roughness = 0.9
	mi.material_override = mat
	ground.add_child(mi)
	root.add_child(ground)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 50.0
	root.add_child(cam)
	await physics_frame
	await physics_frame

	for slot in CARS.size():
		await _one(String(CARS[slot]), slot * 14.0, cam)
	quit(0)


func _one(car_id: String, x: float, cam: Camera3D) -> void:
	var spec := CarDB.get_spec(car_id)
	spec.start_position = Vector3(x, spec.tyre_radius + 0.05, 0.0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	root.add_child(car)
	for i in 120:
		await physics_frame

	_mark_contacts(car)
	var asked := Vector3(x + 2.15, 0.36, -3.15)
	var look := Vector3(x - 0.25, 0.28, -0.35)
	await _shoot(cam, car, asked, look, "%s_parked" % car_id)
	# Ground level, so the road plane is nearly edge-on: a wheel a centimetre off
	# the tarmac cannot hide behind the sill at this height.
	await _shoot(cam, car, Vector3(x + 1.5, 0.11, -2.5), Vector3(x - 0.4, 0.14, 0.0),
		"%s_ground_level" % car_id)
	print("  parked: on_ground=%d  asked cam=%s" % [car.wheels_on_ground, str(asked)])
	for corner in ["FL", "FR", "RL", "RR"]:
		var w: Dictionary = car.visual.wheel_nodes()[["FL", "FR", "RL", "RR"].find(corner)]
		var src: Dictionary = car.get_wheel(corner)
		print("    %s steer node global=%s  asked (contact + radius)=%s" % [
			corner,
			str((w["steer"] as Node3D).global_position.snappedf(0.001)),
			str((src["contact_point"] as Vector3 + Vector3(0.0, float(src["radius"]), 0.0)).snappedf(0.001))])
	_clear_marks()

	# Rolling and turning, so the frames show the steered front wheels and the
	# spin the tyre model is integrating.
	car.throttle = 0.5
	car.steer = 1.0
	for i in 150:
		await physics_frame
	_mark_contacts(car)
	var asked2 := Vector3(car.global_position.x + 1.9, 0.45, car.global_position.z - 3.0)
	await _shoot(cam, car, asked2, Vector3(car.global_position.x - 0.3, 0.25, car.global_position.z - 0.3),
		"%s_rolling_steered" % car_id)
	print("  rolling: %.1f kph, steer_angle FL=%.3f FR=%.3f, spin_vis RR=%.2f" % [
		car.speed_kph, float(car.get_wheel("FL")["steer_angle"]),
		float(car.get_wheel("FR")["steer_angle"]), float(car.get_wheel("RR")["spin_vis"])])
	_clear_marks()
	car.queue_free()
	for i in 4:
		await physics_frame


## A bright disc on the tarmac under each contact point. The tyre either sits on
## it or it does not, which a perspective shot of a dark road cannot decide. It
## goes in world space, not under the car: the car's origin is a tyre radius above
## the road, so a marker parented to it floats at hub height.
func _mark_contacts(car: CarBody) -> void:
	_clear_marks()
	for corner in ["FL", "FR", "RL", "RR"]:
		var src: Dictionary = car.get_wheel(corner)
		if not bool(src["contact"]):
			continue
		var mark := MeshInstance3D.new()
		var bm := CylinderMesh.new()
		bm.top_radius = 0.19
		bm.bottom_radius = 0.19
		bm.height = 0.008
		bm.radial_segments = 16
		mark.mesh = bm
		var at: Vector3 = src["contact_point"]
		mark.position = Vector3(at.x, 0.004, at.z)
		root.add_child(mark)
		var mm := StandardMaterial3D.new()
		mm.albedo_color = Color(0.85, 0.15, 0.10)
		mm.emission_enabled = true
		mm.emission = Color(0.85, 0.15, 0.10)
		mm.emission_energy_multiplier = 1.2
		mark.material_override = mm
		_marks.append(mark)


func _clear_marks() -> void:
	for m in _marks:
		if is_instance_valid(m):
			m.queue_free()
	_marks.clear()


func _shoot(cam: Camera3D, car: CarBody, at: Vector3, look: Vector3, tag: String) -> void:
	cam.global_transform = Transform3D(cam.global_transform.basis, at)
	cam.look_at(look, Vector3.UP)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var path := OUT + tag + ".png"
	var err := img.save_png(path)
	var grey := _mean(img)
	print("[shot] %s  err=%d  camera at %s looking %s  mean=%.1f  size=%s" % [
		path, err, str(at), str(look), grey, str(img.get_size())])
	print("[shot] camera actually used: %s" % str(cam.global_transform.origin.snappedf(0.001)))


func _mean(img: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			total += img.get_pixel(x, y).get_luminance()
			count += 1
	return total / float(maxi(count, 1))
