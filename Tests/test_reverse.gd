extends RefCounted
## Reverse gear.
##
## Two things are being pinned down here. First, that a car can actually reverse -
## which needs both the gearbox to SELECT -1 and a ratio for that gear, because
## `gear_ratio(-1)` used to be 0.0 and a gear that makes no torque is a gear that
## cannot move a car. Second, that it does not select reverse by accident: the
## whole point of a speed threshold is that a car which rolls up to a kerb and
## stops with its throttle still down pulls away forwards, not backwards into the
## kerb.
##
## Its own file rather than a case in test_vehicle.gd because the reverse rule is
## the gearbox's contract with the player, not one more handling characteristic.

const TRACK_LEN := 400.0


static func make_world(t: TestHarness) -> Node3D:
	var world := t.new_root("ReverseWorld")

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
	return world


static func spawn(world: Node3D, car_id: String) -> CarBody:
	var spec := CarDB.get_spec(car_id)
	spec.start_position = Vector3(0, spec.tyre_radius + 0.04, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	world.add_child(car)
	return car


## Holds the pedals still and steps the world, so a gear change cannot be missed
## between frames.
static func drive(t: TestHarness, car: CarBody, throttle: float, brake: float,
		steps: int) -> void:
	car.throttle = throttle
	car.brake = brake
	for i in steps:
		car.auto_shift()
		await t.ticks(1)


static func _walk(node: Node) -> Array:
	var out: Array = [node]
	for c in node.get_children():
		out.append_array(_walk(c))
	return out


func run(t: TestHarness) -> void:
	await _ratios(t)
	await _engage_reverse(t)
	await _kerb_does_not_flip(t)
	await _entry_speed_boundary(t)
	await _leave_reverse(t)
	await _reverse_lights(t)


## The defect underneath the defect: reverse was selectable on paper but had no
## ratio, so the crank torque multiplied out to nothing at the wheels.
func _ratios(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)

	t.eq(car.gear_ratio(0), 0.0, "neutral still makes no torque")
	t.ok(car.gear_ratio(-1) < 0.0, "reverse has a ratio, and it is negative (%.3f)" % car.gear_ratio(-1))
	t.near(absf(car.gear_ratio(-1)), float(car.spec.gears[1]), 0.0001,
		"reverse borrows first gear's ratio, sign flipped")
	t.ok(car.gear_ratio(1) > 0.0, "first gear is still forwards")
	await t.drop(world)


## What a player does: stop, hold the brake, press the throttle. That is S then W,
## which is what the keyboard already means, and it has to actually move the car
## backwards rather than just light a lamp on the boot.
func _engage_reverse(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)

	await drive(t, car, 0.0, 1.0, 30)
	t.ok(car.speed_mps < 0.5, "the car is stopped before reverse is asked for (%.3f m/s)" % car.speed_mps)
	t.eq(car.current_gear, 1, "standing on the brake does not select reverse by itself")

	var z0 := car.global_position.z
	await drive(t, car, 1.0, 1.0, 3)
	t.eq(car.current_gear, -1, "brake then throttle at a standstill selects reverse")

	# The car faces -Z, so reversing means +Z.
	var moved := 0.0
	for i in 150:
		car.auto_shift()
		await t.ticks(1)
		moved = car.global_position.z - z0
	t.gt(moved, 3.0, "the car actually drives backwards (%.2f m in 2.5 s)" % moved)
	t.ok(car.linear_velocity.dot(car.forward()) < 0.0, "and its velocity points backwards")
	t.gt(car.speed_kph, 5.0, "reverse has some speed in it (%.1f kph)" % car.speed_kph)

	# Off the throttle the brake pedal is an ordinary brake again, otherwise a
	# reversing car could never be stopped.
	car.throttle = 0.0
	for i in 300:
		car.auto_shift()
		await t.ticks(1)
		if car.speed_kph < 0.5:
			break
	t.ok(car.speed_kph < 0.5, "a reversing car stops on the brake (%.2f kph)" % car.speed_kph)
	t.eq(car.current_gear, -1, "and stays in reverse while it does")
	await t.drop(world)


## The kerb case. A car that brakes to a stop, lifts off the brake and pulls away
## with the throttle down must go forwards, not select reverse and back into
## whatever it just parked at.
func _kerb_does_not_flip(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)

	await drive(t, car, 1.0, 0.0, 300)
	t.gt(car.speed_kph, 30.0, "up to speed first (%.1f kph)" % car.speed_kph)
	await drive(t, car, 0.0, 1.0, 300)
	t.ok(car.speed_mps < 1.0, "braked to a stop (%.3f m/s)" % car.speed_mps)

	# The throttle never lifts. Only the brake does.
	var z0 := car.global_position.z
	await drive(t, car, 1.0, 0.0, 120)
	t.ok(car.current_gear > 0, "throttle alone at a stop does not select reverse (gear %d)" % car.current_gear)
	t.ok(car.global_position.z < z0 - 3.0,
		"it pulls away forwards instead (%.2f m)" % (car.global_position.z - z0))

	# And from a standstill, throttle with no brake on it, is not a reverse request
	# either - the only way in is brake-then-throttle.
	car.reset_to(Vector3(0, car.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	await t.ticks(6)
	await drive(t, car, 1.0, 0.0, 120)
	t.eq(car.current_gear, 1, "a standing start with the throttle down stays in 1st")
	t.ok(car.global_position.z < -3.0, "and drives forwards (z=%.2f)" % car.global_position.z)
	await t.drop(world)


## The boundary itself. Below the entry speed, brake-then-throttle is a reverse
## request; above it, the same pedal pair is just a car slowing down, which is the
## whole reason the rule has a speed term at all.
func _entry_speed_boundary(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)

	var entry := CarBody.REVERSE_ENTRY_SPEED
	var below := entry * 0.9
	var above := entry * 1.1
	# A real rolling car's speed, set directly: the point of this test is the
	# gearbox's decision, not the tyres' opinion of it.
	car.linear_velocity = car.forward() * below
	car.throttle = 1.0
	car.brake = 1.0
	car.speed_mps = below
	car.auto_shift()
	t.eq(car.current_gear, -1, "%.2f m/s (below the %.2f entry speed) selects reverse" % [below, entry])

	car.reset_to(Vector3(0, car.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	await t.ticks(4)
	car.linear_velocity = car.forward() * above
	car.throttle = 1.0
	car.brake = 1.0
	car.speed_mps = above
	car.auto_shift()
	t.eq(car.current_gear, 1, "%.2f m/s (above it) does not, even with both pedals down" % above)

	# Rolling to a stop with the throttle still down and no brake on it: the case
	# that turns every kerb into a reverse gear if the throttle alone can ask.
	car.reset_to(Vector3(0, car.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	await t.ticks(4)
	car.linear_velocity = car.forward() * (below * 0.5)
	car.throttle = 1.0
	car.brake = 0.0
	car.speed_mps = below * 0.5
	car.auto_shift()
	t.eq(car.current_gear, 1, "a car trickling to a stop on the throttle never flips into reverse")
	await t.drop(world)


## Reverse has to be leavable, both in auto and on the paddles.
func _leave_reverse(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)

	car.current_gear = -1
	car.throttle = 1.0
	car.brake = 1.0
	car.speed_mps = 0.0
	car.auto_shift()
	t.eq(car.current_gear, -1, "holding both pedals in reverse stays in reverse, not a gear bounce")

	car.brake = 0.0
	car.auto_shift()
	t.eq(car.current_gear, 1, "releasing the brake and keeping the throttle hands back 1st")

	car.current_gear = -1
	car.shift_timer = 0.0
	t.ok(car.shift_up(), "the manual paddle shifts up out of reverse")
	t.eq(car.current_gear, 0, "to neutral")
	car.shift_timer = 0.0
	t.ok(car.shift_up(), "and on to 1st")
	t.eq(car.current_gear, 1, "so a manual box is not stranded in reverse")
	await t.drop(world)


## car_visual decides the reverse lamps off `current_gear < 0` and nothing else.
## Read the material rather than the pixels - same value the renderer uses, and
## no GPU needed.
func _reverse_lights(t: TestHarness) -> void:
	var world := make_world(t)
	var car := spawn(world, "kairo_s13")
	await t.ticks(6)
	var vis := car.get_node_or_null("Visual") as CarVisual
	t.ok(vis != null, "a car has an exterior")
	if vis == null:
		await t.drop(world)
		return

	var lens: StandardMaterial3D = null
	var found := 0
	for w in _walk(vis):
		if w is MeshInstance3D and String(w.name).begins_with("Reverse"):
			found += 1
			lens = (w as MeshInstance3D).material_override as StandardMaterial3D
	t.eq(found, 2, "two reverse lamps")
	if lens == null:
		await t.drop(world)
		return

	car.current_gear = 1
	vis.sync(car)
	var off: float = lens.emission_energy_multiplier
	car.current_gear = -1
	vis.sync(car)
	t.gt(lens.emission_energy_multiplier, off * 2.0, "reverse lamps come up in reverse")
	car.current_gear = 1
	vis.sync(car)
	t.near(lens.emission_energy_multiplier, off, 0.001, "and go back down out of it")
	await t.drop(world)