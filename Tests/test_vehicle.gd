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
	return spawn_spec(world, CarDB.get_spec(car_id))


static func spawn_spec(world: Node3D, spec: CarSpec) -> CarBody:
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
	await _steering_response(t)
	await _steering_direction(t)
	await _player_input_steers_the_right_way(t)
	await _drivetrain_differences(t)
	await _handbrake_drift(t)
	await _drift_hold(t)
	await _drift_throttle_selects_the_angle(t)
	await _drift_needs_the_locked_diff(t)
	await _drift_unwinds(t)
	await _untuned_cars_are_untouched(t)
	await _traction_limits(t)
	await _stability(t)
	await _per_axle_slip(t)
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

	# A modelled car's wheels are lifted back out of the scan and put on the
	# steer/spin rig - see CarVisual._rig_scanned_wheels - so this used to be
	# zero, and it being zero was the bug: the wheels were baked into the body
	# and never turned. Four rigs, and none of them a pair of cylinders sitting
	# inside the ones the scan already drew.
	t.eq(vis.wheel_nodes().size(), 4,
		"a modelled car rigs four wheels instead of leaving them baked in")
	for w in vis.wheel_nodes():
		var spin := w["spin"] as Node3D
		var cylinders := 0
		for child in spin.get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).mesh is CylinderMesh:
				cylinders += 1
		t.eq(cylinders, 0, "%s %s uses scanned wheel geometry, not a cylinder" % [vis.spec.id, String(w["name"])])

	# The car's origin sits at hub height, so the road is a tyre radius BELOW it
	# and a model fitted to stand on y=0 has to be dropped by that radius. This
	# asserted the opposite sign, and the car it blessed floated a whole tyre
	# radius: measured, the imported body sat 0.50 m above the road on the Supra
	# and every tyre with it.
	var fit: Dictionary = CarFit.ALL[CarVisual.MODELS["kairo_s13"]]
	t.near(model.position.y, float(fit["offset"].y) - vis.spec.tyre_radius, 0.001,
		"the model is dropped by a tyre radius, so its tyres stand on the road")
	var source_nose: Dictionary = preload("res://Tools/check_car_facing.gd").SOURCE_NOSE
	for car_id in CarVisual.MODELS:
		var fitted_car := spawn(world, car_id)
		fitted_car.rotation.y = 0.7
		var fitted_model := fitted_car.get_node_or_null("Visual/Model") as Node3D
		t.ok(fitted_model != null, "%s has an imported model for heading validation" % car_id)
		if fitted_model == null:
			continue
		var model_id: String = CarVisual.MODELS[car_id]
		var nose: Vector3 = (fitted_model.global_basis * source_nose[model_id]).normalized()
		t.gt(nose.dot(fitted_car.forward()), 0.99,
			"%s visible nose follows the physics heading" % model_id)
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
	# Facing -Z with the +X axis to the right, so steer -1.0 is a RIGHT turn and
	# FR is the inside wheel. (This assertion used to check FL > FR on a right
	# turn, which pinned the Ackermann sign inside the steering model upside
	# down: the outside front got 38 deg of lock and the inside 17.)
	t.gt(absf(car.get_wheel("FR")["steer_angle"]), absf(car.get_wheel("FL")["steer_angle"]),
		"Ackermann turns the inside (right, on a right turn) further than the outside")
	await t.drop(world)


## Puts the car back at a fixed road speed on a known heading, settled, so each
## measurement starts from the same state instead of inheriting the last one's
## transient.
static func _place_at_speed(car: CarBody, kph: float) -> void:
	car.throttle = 0.0
	car.brake = 0.0
	car.steer = 0.0
	car.handbrake = 0.0
	car.global_position = Vector3(0, car.spec.tyre_radius + 0.04, 0)
	car.global_transform.basis = Basis.IDENTITY
	car.linear_velocity = Vector3(0, 0, -kph / 3.6)
	car.angular_velocity = Vector3.ZERO
	car.sleeping = false


## Lateral acceleration in g, as a magnitude, from the change in the car's own
## velocity over `secs` seconds measured on a freshly derived right axis.
## Differencing on a stale axis folds the chassis' own rotation into the answer
## and smears the steady-state value; differencing over one tick is all
## quantisation.
static func _lat_g(car: CarBody, v0: Vector3, secs: float) -> float:
	var right: Vector3 = car.global_transform.basis.x.normalized()
	return absf((car.linear_velocity - v0).dot(right)) / (secs * 9.80665)


## The reported symptom was "no steering feel, and no drift tuning". Both are
## downstream of one quantity: whether the tyre slip velocities include the
## chassis' own rotation, `v + w x r`. They used to read plain `linear_velocity`,
## which is only the centre-of-mass velocity, so a yawing car built no lateral
## force in the rear tyres and nothing resisted its yaw.
##
## Each assertion below is a measured number that collapses if that term is
## removed again, so the regression is a red test rather than a drive-feel
## opinion. Reference figures from kairo_s13, which is the car that plays the
## arcade drift character, at 90 km/h:
##
##                        without the yaw term   with it
##   rear slip vs body       0.00 deg             0.33-4.63 deg
##   yaw rate at steer .30  0.195 rad/s          0.344 rad/s
##   peak lateral g         0.880 g              0.988 g
##   impulse peak slip      47.8 deg             4.4 deg
##   impulse settle         1.88 s               0.48 s
func _steering_response(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	var mu: float = car.spec.tyre_peak_mu

	var yaw_at_low := 0.0
	var yaw_at_high := 0.0
	var best_g := 0.0
	var slip_gap := 0.0
	for steer_value in [0.10, 0.30]:
		_place_at_speed(car, 90.0)
		await t.ticks(60)  # let the springs and dampers settle at speed
		car.throttle = 0.30
		car.steer = steer_value
		# Sample the back 0.5 s, by which point the transient is long gone.
		for i in 150:
			await t.ticks(1)
			if i < 120:
				continue
			var v0: Vector3 = car.linear_velocity
			await t.ticks(3)
			best_g = maxf(best_g, _lat_g(car, v0, 3.0 / 60.0))
			if steer_value < 0.15:
				yaw_at_low = absf(car.angular_velocity.y)
			else:
				yaw_at_high = absf(car.angular_velocity.y)
		if steer_value > 0.15:
			# The rear axle has to disagree with the body, or the slip angles
			# carry no yaw feedback at all. Measured against the body slip, not
			# against zero, because it is the disagreement that makes a car turn.
			var rear: float = absf(car.get_wheel("RL")["slip_angle"])
			slip_gap = absf(rad_to_deg(rear) - absf(rad_to_deg(car.slip_angle_body)))

	t.gt(yaw_at_high, yaw_at_low * 1.2,
		"more lock yaws harder (0.10 -> %.3f, 0.30 -> %.3f rad/s)" % [yaw_at_low, yaw_at_high])
	t.between(best_g / mu, 0.75, 1.15,
		"a hard corner uses most of the tyre (%.3f g of mu %.2f)" % [best_g, mu])
	t.gt(slip_gap, 0.3,
		"rear slip angle departs from body slip, so the tyres see the yaw (%.2f deg apart)" % slip_gap)

	# A disturbance the driver did not ask for has to die. Without yaw in the
	# slip velocity this rang for nearly two seconds and swung 48 deg of body
	# slip; it now settles in about half a second without exceeding 4.4 deg.
	_place_at_speed(car, 79.0)
	await t.ticks(60)
	car.throttle = 0.30
	car.steer = 0.0
	await t.ticks(30)
	car.angular_velocity = Vector3(0.0, 1.2, 0.0)
	var peak_slip := 0.0
	var settled_at := -1.0
	var calm := 0.0
	for i in 150:
		await t.ticks(1)
		var slip: float = absf(rad_to_deg(car.slip_angle_body))
		peak_slip = maxf(peak_slip, slip)
		if slip < 1.5:
			calm += 1
			if calm == 30 and settled_at < 0.0:
				settled_at = (i - 29) / 60.0
		else:
			calm = 0
	t.ok(peak_slip < 12.0,
		"a yaw disturbance does not become a spin (peak %.1f deg)" % peak_slip)
	t.ok(settled_at > 0.0 and settled_at < 0.9,
		"yaw disturbance settles in under 0.9 s (%.2f s)" % settled_at)
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


## --- drift ---------------------------------------------------------------
##
## The tuning surface is two numbers per car: `rear_slide_tail`, how much grip the
## rear tyre keeps once it is properly alight, and `diff_lock`. Nothing else
## changed, so these tests are measured against the same fixed grid of countersteer
## and throttle that the tuning was chosen on.
##
## Before it, the kairo_s13 drifted in 8 of 25 grid points and every one of them
## was at the very edge of the controls; everywhere else it snapped straight.
## The helper below is that grid, so the numbers quoted in these tests are
## directly comparable to the ones the tuning came from.

## Mean |slip angle| in degrees for one axle, averaged over its two wheels.
## `slip_angle_body` is a single number for the whole car and is computed from
## `linear_velocity` alone (car_body.gd:271), so it physically cannot say WHICH
## END of the car is sliding. Every balance question - is the front out-pulling
## the rear, does the handbrake break the rear away, does countersteer unload the
## front - needs the axles separated, and that is what this reads.
static func _axle_slip_deg(car: CarBody, front: bool) -> float:
	var l: Dictionary = car.get_wheel("FL" if front else "RL")
	var r: Dictionary = car.get_wheel("FR" if front else "RR")
	return 0.5 * (absf(rad_to_deg(float(l["slip_angle"])))
		+ absf(rad_to_deg(float(r["slip_angle"]))))


## Worst single wheel on an axle, not the mean, so one wheel spinning up while
## its partner still bites shows up instead of averaging away.
static func _axle_slip_max(car: CarBody, front: bool) -> float:
	var l: Dictionary = car.get_wheel("FL" if front else "RL")
	var r: Dictionary = car.get_wheel("FR" if front else "RR")
	return maxf(absf(rad_to_deg(float(l["slip_angle"]))),
		absf(rad_to_deg(float(r["slip_angle"]))))


## Injects a slide the way a handbrake flick would, then holds the given
## countersteer and throttle and measures what the car settles into.
## Returns mean |body slip| in degrees over the last second, the speed, and the
## fraction of that second the car spent on the same side of neutral it was
## flicked to. A car being held sideways stays there; the snap-through that used
## to make this one undriveable ping-ponged across neutral and spent half its
## time on the wrong side.
##
## t72: also returns the per-axle split (mean and worst wheel, front and rear)
## over the same window, plus the mean body slip. The first three keys are
## unchanged and byte-identical to what they returned before, so every drift
## assertion above keeps measuring what it was written to measure.
static func _hold_slide(t: TestHarness, car: CarBody, lock: float, throttle: float) -> Dictionary:
	car.throttle = 0.0
	car.steer = 0.0
	car.handbrake = 0.0
	car.global_position = Vector3.ZERO
	car.global_transform.basis = Basis.IDENTITY
	car.linear_velocity = Vector3(25.0, 0.0, -43.3)
	car.angular_velocity = Vector3.ZERO
	car.sleeping = false
	car.current_gear = 2
	var sum := 0.0
	var kph := 0.0
	var n := 0
	var on_side := 0
	var side := 0.0
	var front_sum := 0.0
	var rear_sum := 0.0
	var front_max := 0.0
	var rear_max := 0.0
	for i in 480:
		await t.ticks(1)
		car.auto_shift()
		car.steer = -lock
		car.throttle = throttle
		var slip := car.slip_angle_body
		if i >= 300:
			sum += rad_to_deg(absf(car.slip_angle_body))
			kph += car.speed_kph
			n += 1
			front_sum += _axle_slip_deg(car, true)
			rear_sum += _axle_slip_deg(car, false)
			front_max = maxf(front_max, _axle_slip_max(car, true))
			rear_max = maxf(rear_max, _axle_slip_max(car, false))
			if side == 0.0 and not is_zero_approx(slip):
				side = signf(slip)
			elif side != 0.0 and signf(slip) == side:
				on_side += 1
	n = maxi(n, 1)
	return {"angle": sum / n, "kph": kph / n, "on_side": float(on_side) / n,
		"front": front_sum / n, "rear": rear_sum / n,
		"front_max": front_max, "rear_max": rear_max}


## The headline: a rear-drive car that is tuned to drift can be *held* sideways.
## Snap-through was the old failure - the slide crossed straight past neutral to
## the opposite lock in about a second at every steering angle - so the assertion
## that matters is not that it reaches an angle but that it STAYS at one.
func _drift_hold(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	var r := await _hold_slide(t, car, 0.55, 0.60)
	t.between(r["angle"], 18.0, 45.0, "kairo_s13 settles into a held drift at 55%% lock / 60%% throttle (%.0f deg)" % r["angle"])
	t.gt(r["on_side"], 0.60, "the car stays on the side it was flicked to rather than ping-ponging across neutral (%.0f%%)" % (r["on_side"] * 100.0))
	t.between(r["kph"], 15.0, 55.0, "and it carries speed through the slide (%.0f kph)" % r["kph"])
	await t.drop(world)


## The point of a drift is that the driver's right foot picks the angle. More
## throttle must mean more angle, which means the restoring moment the rear
## gives up has to be balanced by thrust the driver is holding down.
func _drift_throttle_selects_the_angle(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	var off := await _hold_slide(t, car, 0.55, 0.30)
	var on := await _hold_slide(t, car, 0.55, 0.60)
	t.gt(on["angle"], off["angle"],
		"more throttle means more angle (%.0f deg at 30%%, %.0f deg at 60%%)" % [off["angle"], on["angle"]])
	t.gt(off["angle"], 12.0, "and even the light throttle holds an angle rather than snapping straight (%.0f deg)" % off["angle"])
	await t.drop(world)


## Why the diff is in the tuning group at all. An open diff dumps the drive
## torque into the unloaded inside rear while the loaded outside rear - the one
## actually making the force that holds the slide - gets nothing extra, so
## there is no thrust to hold the slide with. Same car, same tyres, diff open.
func _drift_needs_the_locked_diff(t: TestHarness) -> void:
	var world := make_world(t)
	var locked := spawn(world, "kairo_s13")
	await t.ticks(6)
	var a := await _hold_slide(t, locked, 0.55, 0.60)

	var open_spec := CarDB.get_spec("kairo_s13")
	open_spec.diff_lock = 0.0
	var open_car := spawn_spec(world, open_spec)
	await t.ticks(6)
	var b := await _hold_slide(t, open_car, 0.55, 0.60)

	t.gt(a["angle"], b["angle"] + 5.0,
		"locking the diff is what lets the slide be held (%.0f deg locked vs %.0f deg open)" % [a["angle"], b["angle"]])
	await t.drop(world)


## The other half: a drift you cannot get out of is a spin. Lifting off and
## straightening must unwind the car, and it must end up going the same way it
## started rather than delivered to the opposite lock.
func _drift_unwinds(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	var held := await _hold_slide(t, car, 0.55, 0.60)
	car.steer = 0.0
	car.throttle = 0.0
	car.brake = 0.3
	for i in 180:
		await t.ticks(1)
		car.auto_shift()
	t.between(rad_to_deg(absf(car.slip_angle_body)), 0.0, 10.0,
		"lifting off and straightening unwinds the slide (%.0f deg in, %.0f deg out)" % [held["angle"], rad_to_deg(absf(car.slip_angle_body))])
	await t.drop(world)


## Only the two rear-drive cars are tuned. Everything else must be byte-for-byte
## the old behaviour, or this has quietly changed cars nobody asked it to.
func _untuned_cars_are_untouched(t: TestHarness) -> void:
	for car_id in CarDB.ALL_IDS:
		var spec := CarDB.get_spec(car_id)
		if car_id == "kairo_s13" or car_id == "hayate_turbo":
			t.ok(spec.diff_lock > 0.0, "%s is set up to drift" % car_id)
			t.between(spec.rear_slide_tail, 0.4, 0.72, "%s has a rear tyre that lets go" % car_id)
		else:
			t.eq(spec.diff_lock, 0.0, "%s keeps an open diff" % car_id)
			t.eq(spec.rear_slide_tail, TyreModel.LATERAL_TAIL, "%s keeps the stock rear tyre" % car_id)


## t72: per-axle slip visibility. t70's table reported one number per car and
## called it "griped up (understeer)" on all seven tail pairs, which cannot be
## argued with because nothing in it was ever asserted. `slip_angle_body` is
## computed from `linear_velocity` alone (car_body.gd:271), so it is a statement
## about the centre-of-mass velocity vector and says NOTHING about which axle is
## sliding. Front-versus-rear is the whole balance question, and this makes it
## readable.
##
## Every assertion below is an instrument-integrity property, not a taste
## judgement: each one collapses if the tyre telemetry stops being per-wheel, if
## the chassis-rotation term `v + w x r` is dropped from the slip velocity again
## (the regression documented on _steering_response), or if the reported body slip
## stops matching the formula it claims to implement. None of them say which car
## SHOULD drift - that is a tuning decision, and _untuned_cars_are_untouched
## still guards it.
func _per_axle_slip(t: TestHarness) -> void:
	# 1. Straight line, both axles at rest. If slip telemetry were stale, stuck at
	#    a constant, or wired to the wrong axle, a car rolling dead straight would
	#    still report something. This is the "is the instrument plugged in" floor.
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	_place_at_speed(car, 80.0)
	await t.ticks(90)
	var straight_front := _axle_slip_deg(car, true)
	var straight_rear := _axle_slip_deg(car, false)
	t.between(straight_front, 0.0, 1.0,
		"straight line, front axle reports no slip (%.2f deg)" % straight_front)
	t.between(straight_rear, 0.0, 1.0,
		"straight line, rear axle reports no slip (%.2f deg)" % straight_rear)

	# 2. The two axles must DISAGREE under cornering. This is the load-bearing
	#    one. The slip velocities are `v + w x r`; strip the `w x r` term and
	#    every wheel reports the same number as the centre of mass, both axles
	#    collapse onto each other, and the gap goes to zero. It measured 0.00 deg
	#    that way. Direction is deliberately NOT asserted - which axle is deeper
	#    depends on lock and throttle, which is tuning.
	_place_at_speed(car, 80.0)
	await t.ticks(60)
	car.throttle = 0.35
	car.steer = 0.35
	var front_sum := 0.0
	var rear_sum := 0.0
	var body_sum := 0.0
	var n := 0
	for i in 180:
		await t.ticks(1)
		if i < 120:
			continue
		front_sum += _axle_slip_deg(car, true)
		rear_sum += _axle_slip_deg(car, false)
		body_sum += absf(rad_to_deg(car.slip_angle_body))
		n += 1
	n = maxi(n, 1)
	var front_deg := front_sum / n
	var rear_deg := rear_sum / n
	var body_deg := body_sum / n
	var gap := absf(front_deg - rear_deg)
	t.gt(gap, 0.20,
		"front and rear axles read different slip in the same corner, so the yaw term reaches the tyres (front %.2f, rear %.2f, gap %.2f deg)"
			% [front_deg, rear_deg, gap])

	# 3. Body slip is not just the tyres echoing it back. car_body.gd:271 derives
	#    it from `linear_velocity` alone; the wheels derive theirs from
	#    `v + w x r`. While the car is rotating the two MUST part company, and
	#    that difference is the entire reason per-wheel telemetry is needed.
	var moved := maxf(absf(front_deg - body_deg), absf(rear_deg - body_deg))
	t.gt(moved, 0.10,
		"wheel slip is not an echo of body slip while the car yaws (body %.2f vs wheels %.2f/%.2f deg)"
			% [body_deg, front_deg, rear_deg])

	# 4. slip_angle_body honours the formula it is documented to implement. Read
	#    the number straight off the car and recompute it from linear_velocity and
	#    the body basis independently; if the formula is ever "fixed" to fold yaw
	#    in, or to use a stale axis, this fails instead of every drift number in
	#    the suite silently shifting.
	var recomputed := atan2(
		car.linear_velocity.dot(car.global_transform.basis.x.normalized()),
		maxf(absf(car.linear_velocity.dot(car.global_transform.basis.z.normalized())), 0.8))
	t.near(rad_to_deg(car.slip_angle_body), rad_to_deg(recomputed), 0.01,
		"slip_angle_body matches its own documented formula from linear_velocity (%.3f deg reported, %.3f deg recomputed)"
			% [rad_to_deg(car.slip_angle_body), rad_to_deg(recomputed)])
	await t.drop(world)

	# 5. The handbrake is the one input that must break a SPECIFIC axle away, and
	#    t72 measured which channel it actually shows up in. It is NOT the slip
	#    ANGLE: with the rear locked at omega 0.0 and slip_ratio -57.3 deg, a full
	#    handbrake at 0.8 lock produced front slip angle 25-59 deg against rear
	#    11-54 deg - the FRONT reads deeper, because the car is yawing at over
	#    2 rad/s and the locked rear's signature is longitudinal, not lateral.
	#    Asserting "handbrake raises rear slip angle above front" was false on
	#    this build and would have been a taste claim dressed as a measurement.
	#    The per-axle separation that IS real and physical: the rear stops
	#    turning while the front keeps rolling, and only the rear's slip ratio
	#    saturates. Both collapse if the two axles share one number.
	var hb_world := make_world(t)
	var hb := spawn(hb_world, "kairo_s13")
	await t.ticks(6)
	_place_at_speed(hb, 70.0)
	await t.ticks(60)
	hb.throttle = 0.2
	hb.steer = 0.8
	hb.handbrake = 1.0
	var hb_front_om := 0.0
	var hb_rear_om := 0.0
	var hb_front_sr := 0.0
	var hb_rear_sr := 0.0
	for i in 60:
		await t.ticks(1)
		if i < 20:
			continue
		var hfl: Dictionary = hb.get_wheel("FL")
		var hrl: Dictionary = hb.get_wheel("RL")
		hb_front_om = maxf(hb_front_om, absf(float(hfl["omega"])))
		hb_rear_om = maxf(hb_rear_om, absf(float(hrl["omega"])))
		hb_front_sr = maxf(hb_front_sr, absf(rad_to_deg(float(hfl["slip_ratio"]))))
		hb_rear_sr = maxf(hb_rear_sr, absf(rad_to_deg(float(hrl["slip_ratio"]))))
	t.gt(hb_front_om, 1.0,
		"the handbrake leaves the front axle rolling (|omega| %.1f rad/s)" % hb_front_om)
	t.between(hb_rear_om, 0.0, 1.0,
		"while the rear axle is locked (|omega| %.2f rad/s)" % hb_rear_om)
	t.gt(hb_rear_sr, hb_front_sr,
		"and only the rear's slip ratio saturates - the handbrake's signature is longitudinal (rear %.1f deg, front %.1f deg)"
			% [hb_rear_sr, hb_front_sr])
	await t.drop(hb_world)

	# 6. The table t70 could not assert: the same held slide, per car, with the
	#    front and rear split out. Printed, not asserted - it is the instrument
	#    for deciding which cars get the drift tuning, and that decision belongs
	#    to whoever owns the handling, not to this test. What IS asserted is that
	#    the instrument produces finite, separated numbers for every car in the
	#    roster, so this table can never again be a wall of identical green.
	var rows: Array[String] = []
	print("\n  -- t72 per-axle slip, held slide at 55% lock / 60% throttle --")
	print("     %-14s %7s %7s %7s %7s %8s  %s"
		% ["car", "body", "front", "rear", "gap", "kph", "verdict"])
	var instrumented := 0
	for car_id in CarDB.ALL_IDS:
		var w2 := make_world(t)
		var c := spawn(w2, car_id)
		await t.ticks(6)
		var r := await _hold_slide(t, c, 0.55, 0.60)
		var f: float = r["front"]
		var rr: float = r["rear"]
		var g := absf(f - rr)
		var verdict := "grips up" if g < 0.20 else ("rear leads" if rr > f else "front leads")
		rows.append("     %-14s %7.2f %7.2f %7.2f %7.2f %8.1f  %s"
			% [car_id, r["angle"], f, rr, g, r["kph"], verdict])
		# Instrument integrity, per car: the numbers must be finite and the two
		# axles must not be the same number, or this row proves nothing.
		t.ok(is_finite(f) and is_finite(rr),
			"%s per-axle slip is a real number (front %.2f, rear %.2f deg)" % [car_id, f, rr])
		t.gt(g, 0.05,
			"%s front and rear slip are separately readable in a held slide (%.2f vs %.2f deg)" % [car_id, f, rr])
		instrumented += 1
		await t.drop(w2)
	t.eq(instrumented, CarDB.ALL_IDS.size(),
		"the per-axle table covered every car in the roster")
	for row in rows:
		print(row)
	print("  -- end t72 per-axle table --\n")
