extends SceneTree
## Diagnostic rig: drives one car and prints its state.
## ./diag.sh [car_id] [ticks]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var car_id: String = args[0] if args.size() > 0 else "kairo_s13"
	var n: int = int(args[1]) if args.size() > 1 else 180
	var thr: float = float(args[2]) if args.size() > 2 else 1.0

	var world := Node3D.new()
	root.add_child(world)

	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 900)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	var spec := CarDB.get_spec(car_id)
	spec.start_position = Vector3(0, spec.tyre_radius + 0.04, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	world.add_child(car)
	car.throttle = thr

	var t0 := Time.get_ticks_msec()
	print("car=%s thr=%.2f" % [car_id, thr])
	var t100 := -1.0
	var dist := 0.0

	for i in n:
		car.auto_shift()
		await physics_frame
		if t100 < 0.0 and car.speed_kph >= 100.0:
			t100 = float(i) / 60.0
		if i % 60 == 0:
			print("   t=%3ds kph=%6.1f gear=%d rpm=%6.0f z=%7.1f" % [i/60, car.speed_kph, car.current_gear, car.engine_rpm, car.global_position.z])
		if i % 30 != 0 and car.speed_kph < 100.0:
			continue
		var fl: Dictionary = car.get_wheel("FL")
		var rr: Dictionary = car.get_wheel("RR")
		print("t=%3d kph=%6.1f z=%7.1f gear=%d rpm=%6.0f torque=%6.0f shift=%.2f | onG=%d FL load=%7.1f sr=%6.2f sa=%6.2f fx=%8.1f | RR omega=%7.1f sr=%6.2f fx=%8.1f" % [
			i, car.speed_kph, car.global_position.z, car.current_gear, car.engine_rpm,
			car.engine_torque, car.shift_timer, car.wheels_on_ground,
			fl["load"], fl["slip_ratio"], fl["slip_angle"], fl["fx"],
			rr["omega"], rr["slip_ratio"], rr["fx"]])
	print("RESULT 0-100 = %.2f s   distance_at_end=%.1f m  final_kph=%.1f" % [t100, dist, car.speed_kph])
	quit(0)
