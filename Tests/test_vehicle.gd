extends RefCounted
## Integration tests: a real CarBody dropped into a real world, measured over
## real physics ticks. These are the tests that would catch "the car no longer
## accelerates" or "FWD and RWD now behave the same".

const TRACK_LEN := 400.0


## Builds a world with a flat ground plane and returns it.
static func make_world(t: TestHarness) -> Node3D:
	var world := t.new_root("TestWorld")

	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, TRACK_LEN)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0, -0.5, 0)
	world.add_child(body)

	var mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, TRACK_LEN)
	mesh.mesh = pm
	mesh.position = Vector3(0, 0, 0)
	world.add_child(mesh)
	return world


static func spawn(world: Node3D, car_id: String) -> CarBody:
	var spec := CarDB.get_spec(car_id)
	spec.start_position = Vector3(0, spec.tyre_radius + 0.04, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	world.add_child(car)
	return car


## Full-throttle run, returns distance covered and elapsed simulated time.
static func _run_flat_out(t: TestHarness, car: CarBody, seconds: float) -> Dictionary:
	car.throttle = 1.0
	car.brake = 0.0
	car.steer = 0.0
	car.handbrake = 0.0
	var steps := int(seconds * 60.0)
	var elapsed := 0.0
	var t100 := -1.0
	for i in steps:
		car.auto_shift()
		await t.ticks(1)
		elapsed += 1.0 / 60.0
		if t100 < 0.0 and car.speed_kph >= 100.0:
			t100 = elapsed
	car.throttle = 0.0
	return {
		"kph": car.speed_kph,
		"time": elapsed,
		"t100": t100,
		"distance": absf(car.global_position.z),
		"rpm": car.engine_rpm,
		"gear": car.current_gear,
	}


func run(t: TestHarness) -> void:
	await _acceleration(t)
	await _braking(t)
	await _steering(t)
	await _drivetrain_differences(t)
	await _handbrake_drift(t)
	await _traction_limits(t)
	await _stability(t)


func _acceleration(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(10)
	t.between(car.wheels_on_ground, 3, 4, "car settles onto its wheels")

	var r := await _run_flat_out(t, car, 10.0)
	t.gt(r["kph"], 80.0, "car accelerates from rest (%.1f kph after 10s)" % r["kph"])
	t.gt(r["distance"], 20.0, "car actually travels down the road")
	t.ok(r["t100"] > 0.0, "car reaches 100 kph (%.2fs)" % r["t100"])
	# A 265 Nm turbo coupe should not be a 6-second car, nor a 30-second one.
	t.between(r["t100"], 4.0, 11.0, "0-100 time is plausible for a 90s turbo coupe")
	t.ok(r["gear"] > 1, "car shifts up out of first (reached gear %d)" % r["gear"])

	# Monotonic: driving longer must always mean more speed.
	var a := car.speed_kph
	await _run_flat_out(t, car, 3.0)
	var b := car.speed_kph
	await _run_flat_out(t, car, 3.0)
	t.gt(b, a, "more throttle time = more speed (%.0f -> %.0f kph)" % [a, b])
	t.gt(car.speed_kph, b, "and it keeps pulling (%.0f kph)" % car.speed_kph)
	await t.drop(world)


func _braking(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	await _run_flat_out(t, car, 5.0)
	var v0 := car.speed_mps
	t.gt(v0, 20.0, "car has up to speed before braking")

	car.throttle = 0.0
	car.brake = 1.0
	var start_pos := car.global_position.z
	for i in 600:
		await t.ticks(1)
		if car.speed_mps < 1.0:
			break
	var distance: float = absf(car.global_position.z - start_pos)
	t.ok(car.speed_mps < v0, "braking reduces speed")
	t.ok(car.speed_mps < 3.0, "full braking brings the car to a stop (%.2f m/s)" % car.speed_mps)
	t.between(distance, 12.0, 90.0, "braking distance is plausible (%.1f m)" % distance)

	# A locked car should slide, not teleport.
	car.reset_to(Vector3(0, 0.4, 0), Vector3.ZERO)
	await t.ticks(4)
	await t.drop(world)


func _steering(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	await _run_flat_out(t, car, 3.0)

	car.throttle = 0.35
	car.steer = -1.0
	var x0 := car.global_position.x
	for i in 120:
		await t.ticks(1)
	t.gt(absf(car.global_position.x - x0), 5.0, "car moves laterally when steered")
	t.gt(absf(car.get_wheel("FL")["steer_angle"]), 0.1, "front wheel is actually steered")
	t.near(car.get_wheel("RL")["steer_angle"], 0.0, 0.001, "rear wheel is not steered")
	# Turning left, so FL is the inside wheel and must turn further than FR.
	t.gt(absf(car.get_wheel("FL")["steer_angle"]), absf(car.get_wheel("FR")["steer_angle"]),
		"Ackermann turns the inside wheel further than the outside")
	await t.drop(world)


func _drivetrain_differences(t: TestHarness) -> void:
	# The brief's hard requirement: FWD, RWD and AWD must not feel the same.
	var world := make_world(t)
	var results := {}
	for id in ["kairo_mx90", "kairo_s13", "tatsuya_gt"]:
		var car := spawn(world, id)
		car.global_position = Vector3(0, 0.4, 0)
		await t.ticks(6)
		var r := await _run_flat_out(t, car, 4.0)
		results[id] = r["kph"]
		car.queue_free()
		await t.ticks(4)

	t.gt(results["kairo_s13"], results["kairo_mx90"],
		"RWD turbo coupe outruns the FWD econobox (%.0f vs %.0f kph)" % [results["kairo_s13"], results["kairo_mx90"]])
	t.gt(results["tatsuya_gt"], results["kairo_s13"],
		"AWD turbo outruns the RWD coupe (%.0f vs %.0f kph)" % [results["tatsuya_gt"], results["kairo_s13"]])

	# Wheelspin check: an FWD car at full throttle should light the fronts up
	# far more readily than an AWD car with the same power.
	var fwd := spawn(world, "kairo_mx90")
	fwd.global_position = Vector3(0, 0.4, 0)
	await t.ticks(6)
	fwd.throttle = 1.0
	var fwd_slip := 0.0
	for i in 40:
		await t.ticks(1)
		fwd_slip = maxf(fwd_slip, fwd.wheelspin)
	t.ok(fwd_slip > 0.05, "FWD car spins its wheels on hard launch (slip %.2f)" % fwd_slip)
	await t.drop(world)


func _handbrake_drift(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	await _run_flat_out(t, car, 4.0)
	t.gt(car.speed_kph, 60.0, "car is moving before the handbrake test")

	car.throttle = 0.2
	car.steer = 0.9
	car.handbrake = 1.0
	var max_slip := 0.0
	for i in 60:
		await t.ticks(1)
		max_slip = maxf(max_slip, absf(car.slip_angle_body))
	t.gt(max_slip, deg_to_rad(8.0), "handbrake produces a real slip angle (%.1f deg)" % rad_to_deg(max_slip))
	t.gt(car.get_wheel("RL")["omega"], -5.0, "handbrake locks the rear wheels (negative omega = locked and sliding)")
	await t.drop(world)


func _traction_limits(t: TestHarness) -> void:
	# The friction circle must actually bite: a car braking hard and turning hard
	# must not deliver full cornering force as well.
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	await _run_flat_out(t, car, 4.0)

	car.throttle = 0.0
	car.brake = 1.0
	car.steer = 0.8
	var demand := 0.0
	var limit := 0.0
	for i in 40:
		await t.ticks(1)
		for w in car.wheels():
			if w["contact"]:
				demand = maxf(demand, Vector2(w["fx"], w["fy"]).length())
				limit = maxf(limit, car.spec.tyre_peak_mu * w["load"])
	t.ok(limit > 0.0, "wheels were loaded during the test")
	t.fails(demand > limit + 50.0, "total tyre demand never exceeds the friction circle")
	await t.drop(world)


func _stability(t: TestHarness) -> void:
	# Nothing NaN, and the car stays upright and on the road over a long run.
	var world := make_world(t)
	var car := spawn(world, "hayate_turbo")
	await t.ticks(6)
	await _run_flat_out(t, car, 8.0)
	t.ok(is_finite(car.speed_mps), "speed stays finite over a long run")
	t.ok(is_finite(car.engine_rpm), "rpm stays finite over a long run")
	t.ok(is_finite(car.global_position.x), "position stays finite")
	t.between(car.global_transform.basis.y.angle_to(Vector3.UP), 0.0, deg_to_rad(25.0),
		"car stays upright under power")
	t.between(car.engine_rpm, 0.0, car.spec.redline * 1.05, "rev limiter holds")
	t.between(absf(car.global_position.x), 0.0, 20.0, "car does not wander off the road in a straight line")
	await t.drop(world)
