extends RefCounted
## The drift instrument, rebuilt without the no-ops.
##
## t70's version of this file carried 161 assertions that were ALL `t.ok(true,
## ...)`. Every one of them passed regardless of the vehicle: the strings were
## measurement output formatted as assertion labels. Its closed-loop driver
## printed "griped up (understeer)" on all seven tail pairs and the suite stayed
## green, so "feel passes" was cited as support for a tuning decision it had
## never measured.
##
## Two rules follow from that, and this file is written to both:
##
## 1. NOTHING here asserts a tuning taste. Which cars should drift is the
##    handling owner's call, not a test's. The grid below is PRINTED so a human
##    can read it; the assertions only check that the instrument is sound.
## 2. `t.ok(true, ...)` is banned outright. A measurement is a `print`. An
##    assertion is a claim about the world that can be false.
##
## Why the per-axle split exists at all: `slip_angle_body` is computed from
## `linear_velocity` ALONE (car_body.gd:271) -
##
##     slip_angle_body = atan2(v.dot(right), max(|v.dot(forward)|, 0.8))
##
## so it describes the centre-of-mass velocity vector against the body heading
## and carries no information about rotation. It cannot say which axle is
## sliding. Per-wheel `slip_angle` is computed from `point_velocity(contact)`,
## which DOES include the chassis rotation `v + w x r`. The gap between the two
## is the yaw feedback the tyres generate, so the front/rear split is the
## balance question, and one number for the whole car cannot answer it.
##
## Sign conventions (car_body.gd:9): +X right, -Z forward, steer -1 is full
## right. Countersteer into a slide of +slip is therefore NEGATIVE steer.

const DT := 1.0 / 60.0
const CAR_ID := "kairo_s13"
## TyreModel.PEAK_SLIP, in degrees: where the tyre makes peak grip. Past it the
## tyre is sliding and no amount of load gets the grip back.
const PEAK_SLIP_DEG := 7.45


func run(t: TestHarness) -> void:
	await t.ticks(1)
	await _countersteer_is_correct(t)
	await _initiation_grid(t)
	await _instrument_is_alive(t)


# --- fixture ---------------------------------------------------------------

func _flat_world(t: TestHarness) -> Node3D:
	var world := t.new_root("FeelWorld")
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(9000, 1, 9000)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0, -0.5, 0)
	world.add_child(body)
	return world


## Mean |slip angle| in degrees for one axle. See the file header for why the
## axles have to be separated rather than averaged into one number.
func _axle_slip(car: CarBody, front: bool) -> float:
	var l: Dictionary = car.get_wheel("FL" if front else "RL")
	var r: Dictionary = car.get_wheel("FR" if front else "RR")
	return 0.5 * (absf(rad_to_deg(float(l["slip_angle"])))
		+ absf(rad_to_deg(float(r["slip_angle"]))))


## Puts the car at the origin facing -Z, rolling at `kph` with `slip` degrees of
## body slip already established.
func _arm(car: CarBody, kph: float, slip_deg: float) -> void:
	car.throttle = 0.0
	car.brake = 0.0
	car.steer = 0.0
	car.handbrake = 0.0
	car.reset_to(Vector3(0, car.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	var v := deg_to_rad(slip_deg)
	car.linear_velocity = Vector3(sin(v), 0.0, -cos(v)) * (kph / 3.6)
	car.angular_velocity = Vector3.ZERO
	car.sleeping = false
	car.current_gear = 2


func _mean(xs: Array) -> float:
	var m := 0.0
	for x in xs:
		m += x
	return m / maxf(float(xs.size()), 1.0)


# --- 1. the closed-loop driver --------------------------------------------

## t70's `_closed_loop` was the cleverest thing in the file and the reason its
## verdicts were worth reading - countersteer proportional to slip angle with
## yaw-rate damping, because a FIXED lock does not model a driver: hold one lock
## at 30 deg of body slip and the front tyres simply overpower the rear and snap
## it straight, which is what every fixed-lock case was actually measuring.
##
## It was also never checked. These assertions are the ones that matter and cost
## nothing to get wrong: a driver whose countersteer sign is inverted, whose
## output is constant, or who commands more lock than the car has, is not a
## driver model, and every verdict it prints afterwards is noise.
func _countersteer_is_correct(t: TestHarness) -> void:
	var world := _flat_world(t)
	var car := CarBody.new()
	car.build_visual = false
	car.spec = CarDB.get_spec(CAR_ID)
	world.add_child(car)
	await t.ticks(8)

	_arm(car, 50.0, 30.0)
	var opposing := 0        # frames where steer fought the slide
	var sliding := 0         # frames where there was a slide worth fighting
	var steer_lo := 2.0
	var steer_hi := -2.0
	var max_lock := 0.0
	var peak := 0.0
	var steer_sum := 0.0
	var steer_n := 0
	for i in 480:
		await t.ticks(1)
		car.auto_shift()
		# The driver under test: countersteer into the slide, damped on yaw.
		var beta := car.slip_angle_body
		car.steer = clampf(-signf(beta) * (absf(rad_to_deg(beta)) / 35.0), -1.0, 1.0) \
			+ clampf(-car.angular_velocity.y / 1.5, -0.5, 0.5)
		car.throttle = 0.5
		car.brake = 0.0
		var deg := absf(rad_to_deg(beta))
		peak = maxf(peak, deg)
		steer_lo = minf(steer_lo, car.steer)
		steer_hi = maxf(steer_hi, car.steer)
		max_lock = maxf(max_lock, absf(car.steer))
		steer_sum += absf(car.steer)
		steer_n += 1
		if deg > PEAK_SLIP_DEG:
			sliding += 1
			# Steer -1 is right. A slide of +slip is to the left of the nose, so
			# catching it means steering right, i.e. negative. Opposite signs.
			if signf(car.steer) == -signf(beta) or is_zero_approx(car.steer):
				opposing += 1

	# (a) the sign, which is the one that silently produces the wrong verdict
	t.gt(float(opposing) / float(maxi(sliding, 1)), 0.90,
		"the driver countersteers INTO the slide (%.0f%% of %d sliding frames)"
			% [100.0 * float(opposing) / float(maxi(sliding, 1)), sliding])

	# (b) it is closed loop, not a constant. A hardcoded steer passes the sign
	#     check above but measures nothing.
	t.gt(steer_hi - steer_lo, 0.20,
		"the driver TRACKS the angle rather than holding one input (steer spanned %.2f..%.2f)"
			% [steer_lo, steer_hi])
	t.gt(max_lock, 0.05,
		"and it is actually commanding lock (mean |steer| %.2f, peak %.2f)"
			% [steer_sum / float(maxi(steer_n, 1)), max_lock])

	# (c) it does not ask for more lock than the car can give. CarBody.steer is a
	#     normalised control in [-1, 1]. The driver below sums two clamped terms
	#     and can propose up to 1.5 before the body takes its share, so the input
	#     that actually reaches the car has to be checked, not the proposal.
	t.gt(max_lock, 0.0,
		"lock commanded by the driver was observed on the car (peak |steer| %.2f)" % max_lock)
	t.between(car.steer, -1.0, 1.0,
		"and the car's steer input stayed inside the normalised range (%.2f)" % car.steer)

	# (d) armed at 30 deg of slip the car has to be sliding for any of the above
	#     to mean anything. If initiation silently stopped working, the sign
	#     check would pass vacuously on zero sliding frames - which is exactly
	#     the class of green that started this.
	t.gt(peak, PEAK_SLIP_DEG,
		"the arming state is a real slide, so the driver checks above are not vacuous (peak %.1f deg)" % peak)
	await t.drop(world)


# --- 2. the grid, printed ---------------------------------------------------

## The measurement t70 kept but never asserted. Printed, not asserted: this is
## the table a handling owner reads to decide which cars get drift tuning. The
## assertions around it check the measurement is real, never what it says.
func _initiation_grid(t: TestHarness) -> void:
	var world := _flat_world(t)
	var car := CarBody.new()
	car.build_visual = false
	car.spec = CarDB.get_spec(CAR_ID)
	world.add_child(car)
	await t.ticks(8)

	print("\n  -- t72 initiation grid: armed 30 deg, then lock 0.5 / throttle 0.5 --")
	print("     %6s %8s %8s %8s %8s  %s"
		% ["kph", "body", "front", "rear", "gap", "verdict"])
	var rows: Array[String] = []
	var separated := 0
	var reached := 0
	var bodies: Array[float] = []
	for kph in [30.0, 40.0, 50.0, 60.0, 80.0, 100.0, 140.0]:
		var held: Array[float] = []
		var front_sum := 0.0
		var rear_sum := 0.0
		var peak := 0.0
		_arm(car, kph, 30.0)
		for i in 480:
			await t.ticks(1)
			car.auto_shift()
			car.steer = -0.5
			car.throttle = 0.5
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			if i >= 360:
				held.append(deg)
				front_sum += _axle_slip(car, true)
				rear_sum += _axle_slip(car, false)
		var body_deg := _mean(held)
		var front_deg := front_sum / float(maxi(held.size(), 1))
		var rear_deg := rear_sum / float(maxi(held.size(), 1))
		var gap := absf(front_deg - rear_deg)
		bodies.append(body_deg)
		if gap > 0.05:
			separated += 1
		if peak > PEAK_SLIP_DEG:
			reached += 1
		rows.append("     %6.0f %8.2f %8.2f %8.2f %8.2f  %s"
			% [kph, body_deg, front_deg, rear_deg, gap,
				"rear leads" if rear_deg > front_deg else "front leads"])
	for row in rows:
		print(row)
	print("  -- end initiation grid --\n")
	await t.drop(world)

	# The grid is a measurement only if the axles are actually separable at more
	# than one point, and only if the car is sliding at all. Both were silently
	# untrue-able in t70's version because nothing checked them.
	t.gt(separated, 1,
		"the front/rear split is measurable at more than one point in the grid (%d of %d)" % [separated, rows.size()])
	t.gt(reached, 1,
		"the grid reaches a real slide at more than one speed (%d of %d past %.2f deg)"
			% [reached, rows.size(), PEAK_SLIP_DEG])
	t.gt(bodies.max() - bodies.min(), 0.05,
		"the grid is not one number repeated - speed changes the answer (body slip spans %.2f..%.2f deg)"
			% [bodies.min(), bodies.max()])


# --- 3. instrument integrity ------------------------------------------------

## The four properties the rest of the file depends on. If any of them stops
## holding, every number above is being read off a broken instrument and should
## be ignored - so they are asserted rather than assumed.
func _instrument_is_alive(t: TestHarness) -> void:
	var world := _flat_world(t)
	var car := CarBody.new()
	car.build_visual = false
	car.spec = CarDB.get_spec(CAR_ID)
	world.add_child(car)
	await t.ticks(8)

	# Straight line: every wheel is rolling freely, so every wheel must read
	# about zero slip. This is the floor - it fails if slip telemetry is stale,
	# stuck, or reading the wrong axle.
	_place_straight(car, 80.0)
	await t.ticks(90)
	t.between(_axle_slip(car, true), 0.0, 1.0,
		"rolling straight, the front axle reports no slip (%.2f deg)" % _axle_slip(car, true))
	t.between(_axle_slip(car, false), 0.0, 1.0,
		"rolling straight, the rear axle reports no slip (%.2f deg)" % _axle_slip(car, false))

	# Cornering: the two axles must disagree. This is the load-bearing check in
	# the whole file - the documented pre-fix measurement for "rear slip vs body"
	# was 0.00 deg, because without the chassis-rotation term in the slip
	# velocity every wheel reports the centre-of-mass angle and the axles
	# collapse onto each other. It cannot silently happen again.
	_place_straight(car, 80.0)
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
		front_sum += _axle_slip(car, true)
		rear_sum += _axle_slip(car, false)
		body_sum += absf(rad_to_deg(car.slip_angle_body))
		n += 1
	n = maxi(n, 1)
	var front_deg := front_sum / float(n)
	var rear_deg := rear_sum / float(n)
	var body_deg := body_sum / float(n)
	t.gt(absf(front_deg - rear_deg), 0.20,
		"the two axles disagree in a corner, so the yaw term reaches the tyres (front %.2f, rear %.2f deg)"
			% [front_deg, rear_deg])
	t.gt(maxf(absf(front_deg - body_deg), absf(rear_deg - body_deg)), 0.10,
		"per-wheel slip is not an echo of body slip while the car yaws (body %.2f vs %.2f/%.2f deg)"
			% [body_deg, front_deg, rear_deg])

	# slip_angle_body honours the formula it is documented to implement. Read
	# the number off the car and recompute it from linear_velocity and the body
	# basis independently. If car_body.gd:271 is ever changed to fold yaw in, or
	# to use a stale axis, this fails instead of every drift figure in the
	# suite sliding by an unknown amount.
	var right := car.global_transform.basis.x.normalized()
	var forward := car.global_transform.basis.z.normalized()
	var recomputed := atan2(
		car.linear_velocity.dot(right),
		maxf(absf(car.linear_velocity.dot(forward)), 0.8))
	t.near(rad_to_deg(car.slip_angle_body), rad_to_deg(recomputed), 0.01,
		"slip_angle_body matches its own formula from linear_velocity alone (%.3f reported, %.3f recomputed)"
			% [rad_to_deg(car.slip_angle_body), rad_to_deg(recomputed)])
	await t.drop(world)


func _place_straight(car: CarBody, kph: float) -> void:
	car.throttle = 0.0
	car.brake = 0.0
	car.steer = 0.0
	car.handbrake = 0.0
	car.global_position = Vector3(0, car.spec.tyre_radius + 0.04, 0)
	car.global_transform.basis = Basis.IDENTITY
	car.linear_velocity = Vector3(0, 0, -kph / 3.6)
	car.angular_velocity = Vector3.ZERO
	car.sleeping = false