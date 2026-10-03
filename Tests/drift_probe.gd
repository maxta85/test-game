extends SceneTree
## Throwaway measurement probe for the drift investigation. Not a suite: it has
## no assertions, it exists to produce the numbers that Tests/test_drift.gd's
## thresholds are then derived from.
##
##   godot --headless --path . --script res://Tests/drift_probe.gd
##
## Sweeps initiation method x speed and reports, over a fixed window after the
## input is applied, whether the REAR axle is the one past its peak (a drift)
## or the FRONT is (understeer / a freight train).

const CAR_ID := "kairo_s13"
const PEAK_SLIP_DEG := 7.45


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(9000, 1, 9000)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)
	await process_frame
	await process_frame

	print("\n%-34s %6s %6s %6s %6s %6s %6s %6s %6s" % [
		"case", "rear>", "meangap", "maxgap", "holdbod", "holdrear", "holdfrnt", "peakyaw", "spun%"])
	for mode in ["handbrake", "lift", "power", "power_lowlock"]:
		for kph in [40.0, 60.0, 80.0, 100.0, 140.0]:
			await _case(world, mode, kph)
	# and the slide-armed family, which is the state a real drift is held from
	for kph in [40.0, 60.0, 80.0, 100.0, 140.0]:
		await _case(world, "armed_counter", kph)
	quit(0)


func _car(world: Node3D) -> CarBody:
	var c := CarBody.new()
	c.build_visual = false
	c.spec = CarDB.get_spec(CAR_ID)
	world.add_child(c)
	return c


func _axles(c: CarBody) -> Array:
	var fl: Dictionary = c.get_wheel("FL")
	var fr: Dictionary = c.get_wheel("FR")
	var rl: Dictionary = c.get_wheel("RL")
	var rr: Dictionary = c.get_wheel("RR")
	var rear := maxf(rad_to_deg(absf(float(rl["slip_angle"]))), rad_to_deg(absf(float(rr["slip_angle"]))))
	var front := maxf(rad_to_deg(absf(float(fl["slip_angle"]))), rad_to_deg(absf(float(fr["slip_angle"]))))
	return [rear, front]


func _case(world: Node3D, mode: String, kph: float) -> void:
	var c := _car(world)
	for i in 8:
		await process_frame
	# arm: rolling in a straight line at `kph`, except armed_* which is already
	# sideways at 30 deg (the state a countersteered hold starts from).
	var arm_slip := 0.0
	if mode == "armed_counter":
		arm_slip = 30.0
	c.throttle = 0.0
	c.brake = 0.0
	c.steer = 0.0
	c.handbrake = 0.0
	c.reset_to(Vector3(0, c.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	var v := deg_to_rad(arm_slip)
	c.linear_velocity = Vector3(sin(v), 0.0, -cos(v)) * (kph / 3.6)
	c.angular_velocity = Vector3.ZERO
	c.sleeping = false
	c.current_gear = 3

	var rear_gt := 0
	var counted := 0
	var sum_gap := 0.0
	var max_gap := -999.0
	var peak_yaw := 0.0
	var hold_bod := 0.0
	var hold_rear := 0.0
	var hold_front := 0.0
	var hold_n := 0
	var spun := 0
	for i in 300:
		await process_frame
		c.auto_shift()
		match mode:
			"handbrake":
				if i < 30:
					c.steer = -1.0
					c.handbrake = 1.0
				else:
					c.handbrake = 0.0
					c.steer = clampf(-rad_to_deg(c.slip_angle_body) / 30.0, -1.0, 1.0)
					c.throttle = 0.65
			"lift":
				c.steer = -0.45
				c.throttle = 0.55 if i < 120 else 0.0
			"power":
				c.steer = -0.55
				c.throttle = 0.85
			"power_lowlock":
				c.steer = -0.30
				c.throttle = 0.85
			_:
				c.steer = clampf(-rad_to_deg(c.slip_angle_body) / 30.0, -1.0, 1.0)
				c.throttle = 0.65
		var ax := _axles(c)
		var gap: float = float(ax[0]) - float(ax[1])
		peak_yaw = maxf(peak_yaw, absf(c.angular_velocity.y))
		if i >= 20:
			counted += 1
			sum_gap += gap
			max_gap = maxf(max_gap, gap)
			if gap > 0.0:
				rear_gt += 1
			if absf(rad_to_deg(c.slip_angle_body)) > 90.0:
				spun += 1
		if i >= 180:
			hold_n += 1
			hold_bod += absf(rad_to_deg(c.slip_angle_body))
			hold_rear = maxf(hold_rear, float(ax[0]))
			hold_front = maxf(hold_front, float(ax[1]))
	hold_n = maxi(hold_n, 1)
	print("%-34s %6.1f %8.1f %6.1f %8.1f %8.1f %9.1f %7.2f %5.1f" % [
		"%s @%3.0f kph" % [mode, kph],
		100.0 * rear_gt / maxf(counted, 1), sum_gap / maxf(counted, 1), max_gap,
		hold_bod / hold_n, hold_rear, hold_front, peak_yaw,
		100.0 * spun / maxf(counted, 1)])
	world.remove_child(c)
	c.queue_free()
	await process_frame
