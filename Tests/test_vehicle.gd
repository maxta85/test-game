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
	await _steering_direction(t)
	await _player_input_steers_the_right_way(t)
	await _drivetrain_differences(t)
	await _handbrake_drift(t)
	await _traction_limits(t)
	await _stability(t)
	await _spec_numbers(t)
	await _exterior(t)
	await _car_models(t)


## The garage stat card is only as honest as `zero_to_hundred()`. It used to be an
## untraction-limited integration that reported 2.5 s for the econobox, so every
## car in the roster came out with the same acceleration bar and the traffic
## agent's civilian roster saturated identically. Order and bounds are the two
## properties anything downstream actually relies on.
func _spec_numbers(t: TestHarness) -> void:
	var times := {}
	for spec in CarDB.all():
		var z: float = spec.zero_to_hundred()
		times[spec.id] = z
		t.between(z, 3.0, 20.0, "%s 0-100 is plausible (%.2f s)" % [spec.id, z])
		t.gt(spec.top_speed_mps(), 30.0, "%s has a real top speed" % spec.id)
		t.gt(spec.peak_power_kw(), 20.0, "%s has a real power figure" % spec.id)
	t.gt(times["kairo_mx90"], times["kairo_s13"],
		"the econobox is slower to 100 than the turbo coupe (%.2f vs %.2f s)" % [
			times["kairo_mx90"], times["kairo_s13"]])
	t.gt(times["kairo_s13"], times["tatsuya_gt"],
		"the AWD turbo out-accelerates the RWD coupe (%.2f vs %.2f s)" % [
			times["kairo_s13"], times["tatsuya_gt"]])
	# Rain has to make the same car slower, or the weather is decoration.
	var dry := CarDB.get_spec("kairo_s13")
	t.gt(dry.zero_to_hundred_scaled(0.6), dry.zero_to_hundred(),
		"the same car is slower to 100 on a wet road")


## The exterior that has to follow the physics - wheels that steer, brake
## lights that light. If that silently stops, it is a black box in the middle of
## the frame and nothing else will tell you.
##
## Uses kairo_mx90 deliberately. It is one of the two cars with no imported
## model, so it still gets the procedural exterior; the modelled path is
## covered by _car_models.
func _exterior(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_mx90")
	await t.ticks(6)
	var vis := car.get_node_or_null("Visual") as CarVisual
	t.ok(vis != null, "a car has an exterior")
	if vis == null:
		await t.drop(world)
		return

	t.eq(vis.wheel_nodes().size(), 4, "four wheels on the exterior")
	t.eq(vis.get_node_or_null("Model"), null, "a car with no imported model keeps its boxes")
	for w in vis.wheel_nodes():
		t.near((w["steer"] as Node3D).position.y, 0.0, 0.001,
			"%s wheel sits at hub height" % w["name"])

	# Wheels follow the tyres the physics actually computed, not their own idea.
	car.steer = 1.0
	car.throttle = 0.0
	await t.ticks(4)
	vis.sync(car)
	var fl: float = (vis.wheel_nodes()[0]["steer"] as Node3D).rotation.y
	var rl: float = (vis.wheel_nodes()[2]["steer"] as Node3D).rotation.y
	t.near(fl, car.get_wheel("FL")["steer_angle"], 0.001, "front wheel visual matches the tyre model")
	t.near(rl, 0.0, 0.001, "rear wheel visual is not steered")

	await _run_flat_out(t, car, 1.5)
	vis.sync(car)
	t.gt(absf((vis.wheel_nodes()[2]["spin"] as Node3D).rotation.x), 0.05,
		"rear wheel is rolling")

	# Brake lights. Read the material, not the pixels - it is the same value the
	# renderer uses, and it does not need a GPU to check.
	var tail: StandardMaterial3D = null
	var found := 0
	for w in _walk(vis):
		if w is MeshInstance3D and String(w.name).begins_with("Tail"):
			found += 1
			tail = (w as MeshInstance3D).material_override as StandardMaterial3D
	t.eq(found, 2, "two tail lights")
	if tail != null:
		var off: float = tail.emission_energy_multiplier
		car.brake = 1.0
		vis.sync(car)
		t.gt(tail.emission_energy_multiplier, off * 2.0, "brake lights come up under braking")
		car.brake = 0.0
		vis.sync(car)
		t.near(tail.emission_energy_multiplier, off, 0.001, "and go back down when the pedal does")

	# Headlights exist and point the way the car points.
	var beams := 0
	for w in _walk(vis):
		if w is SpotLight3D:
			beams += 1
			t.ok((w as SpotLight3D).global_transform.basis.z.dot(-car.forward()) > 0.9,
				"headlight beam points where the car is pointing")
	t.eq(beams, 1, "one headlight beam per car")
	await t.drop(world)


## A car with an imported model builds that model instead of a box exterior.
##
## This test exists because the fallback is invisible. When the CarDB-to-glb
## mapping went stale the first time, every car quietly reverted to boxes and
## the whole suite still passed - a box car is correct behaviour, so nothing
## else could fail. Assert the model is actually there or the mapping rots
## unnoticed.
func _car_models(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	var vis := car.get_node_or_null("Visual") as CarVisual
	t.ok(vis != null, "the player car has an exterior")
	if vis == null:
		await t.drop(world)
		return

	var model := vis.get_node_or_null("Model") as Node3D
	t.ok(model != null, "the player car uses its imported model, not a box")
	if model == null:
		await t.drop(world)
		return
	t.ok(model.get_child_count() > 0, "the model is instanced, not an empty node")

	# The scans have their wheels baked in. Leaving the procedural wheels on as
	# well would draw two sets, one inside the other.
	t.eq(vis.wheel_nodes().size(), 0,
		"a modelled car drops its procedural wheels rather than doubling them up")

	# The car's origin sits at hub height, so a model fitted to stand on y=0 has
	# to be lifted by a tyre radius or it sinks into the road.
	var fit: Dictionary = CarFit.ALL[CarVisual.MODELS["kairo_s13"]]
	t.near(model.position.y, float(fit["offset"].y) + vis.spec.tyre_radius, 0.001,
		"the model is lifted by a tyre radius so it stands on the ground")
	await t.drop(world)


static func _walk(node: Node) -> Array:
	var out: Array = [node]
	for c in node.get_children():
		out.append_array(_walk(c))
	return out


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


func _steering_direction(t: TestHarness) -> void:
	# The sign of steering, which _steering above never checked: it asserts
	# absf(lateral movement), so an inverted steering mapping passes it happily.
	# That is how a build where holding "steer right" turned the car left got
	# through - the player literally could not drive.
	for pair in [[1.0, "positive"], [-1.0, "negative"]]:
		var steer_value: float = pair[0]
		var label: String = pair[1]
		var world := make_world(t)
		var car := spawn(world, "kairo_s13")
		await t.ticks(6)
		await _run_flat_out(t, car, 2.5)

		car.throttle = 0.35
		car.steer = steer_value
		var x0: float = car.global_position.x
		for i in 150:
			await t.ticks(1)
		# Facing -Z, right is +X. Positive steer yaws toward -X.
		var expected: float = -signf(steer_value)
		var actual: float = signf(car.global_position.x - x0)
		t.near(actual, expected, 0.5,
			"%s steer sends the car %s (x moved %.1f m)" % [
				label, "left (-X)" if expected < 0.0 else "right (+X)",
				car.global_position.x - x0])
		await t.drop(world)


func _player_input_steers_the_right_way(t: TestHarness) -> void:
	# The test that would actually have caught the inverted steering. The one
	# above sets `car.steer` by hand, so it only ever proved the CarBody physics
	# - the bug was in PlayerController's action -> axis mapping, which that test
	# cannot see. This drives the real input path: install the same action map
	# the game installs, press the action, and watch which way the car goes.
	InputSetup.install()
	for pair in [["steer_right", 1.0], ["steer_left", -1.0]]:
		var action: String = pair[0]
		var expected: float = pair[1]     # +1 == right == +X
		var world := make_world(t)
		var car := spawn(world, "kairo_s13")
		var pc := PlayerController.new()
		pc.car = car
		world.add_child(pc)
		await t.ticks(6)

		Input.action_press("throttle")
		for i in 90:
			await t.ticks(1)
		Input.action_press(action)
		var x0: float = car.global_position.x
		for i in 150:
			await t.ticks(1)
		Input.action_release(action)
		Input.action_release("throttle")
		var moved: float = car.global_position.x - x0
		t.near(signf(moved), expected, 0.5,
			"pressing %s drives the car %s" % [action, "right (+X)" if expected > 0.0 else "left (-X)"])
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
