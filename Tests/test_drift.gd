extends RefCounted
## DRIFT CONFIRMATION. Does the car actually power-slide, and can the driver
## catch it?
##
## The gap this closes: `Tests/test_feel.gd` is the repo's drift instrumentation
## and every one of its 161 "assertions" is `t.ok(true, ...)`. It prints drift
## numbers and checks none of them, so the car can stop drifting entirely and
## that suite stays green - which is exactly what it measures today (its own
## closed-loop driver prints "griped up (understeer)" on all seven tail pairs).
## `Tests/test_vehicle.gd` does assert drift numbers, but only on
## `slip_angle_body`, which is computed from `linear_velocity` alone
## (car_body.gd:271). It cannot see the per-axle slip that decides WHICH axle
## breaks away, so "the rear is the axle that lets go" - the whole claim of a
## drift car - was untested.
##
## Sign conventions (car_body.gd:9, :43): +X right, -Z forward, steer -1 is full
## right, and countersteering a slide of `+beta` is therefore negative steer.
##
## Every threshold here is either a tyre-model constant (TyreModel.PEAK_SLIP) or
## a structural property. None of them is a number fitted to the current run.
## Measured values are printed alongside every assertion so a failure says how
## far off the car is, not just that it is.

const CAR_ID := "kairo_s13"
## TyreModel.PEAK_SLIP is 0.13, but car_body.gd:604 hands `lateral()` the TANGENT
## of the slip angle and it compares that against PEAK_SLIP, so the slip ANGLE at
## which this model actually makes peak force is atan(0.13), not 0.13 rad. Derived
## from the tyre model rather than written out, so it cannot drift from it.
## Body slip the lift-off case is armed at. Named because the value appeared twice
## in a label where a speed had crept into one of the slots, and the label
## cheerfully printed "unwinds 60 deg" for a 30 deg arm.
const LIFT_ARM_DEG := 30.0
var peak_slip_deg := rad_to_deg(atan(TyreModel.PEAK_SLIP))
## A drift lives at 40-80 kph. Probing at 140 kph finds a slide, but a car that
## only drifts at 140 kph is a car that grips like a freight train where anyone
## would actually use it, so the speed is part of the requirement, not a detail.
const DRIFT_KPH := 60.0
## Body slip at which the car is genuinely sideways. Frames below this are
## excluded from the per-axle statistics because a straight car has rear slip ==
## body slip whether or not the yaw term exists - averaging a signal with a zero
## baseline over frames where it is legitimately zero measures nothing.
const SIDEWAYS_DEG := 5.0


func run(t: TestHarness) -> void:
	await t.ticks(1)
	await _input_reaches_the_tyres(t)
	await _rear_breaks_away_first(t)
	await _restoring_moment_is_present(t)
	await _the_car_yaws_and_is_caught(t)
	await t.drop(t.new_root("DriftWorldEnd"))


# --- fixture ---------------------------------------------------------------

func _flat_world(t: TestHarness) -> Node3D:
	var world := t.new_root("DriftWorld")
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


const DriftDriver := preload("res://Tests/drift_driver.gd")


func _spawn(world: Node3D) -> CarBody:
	var car := CarBody.new()
	car.build_visual = false
	car.spec = CarDB.get_spec(CAR_ID)
	world.add_child(car)
	return car


## Rolling in a straight line at `kph`, or already sideways at `slip_deg` - the
## state a countersteered hold is caught from.
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
	car.current_gear = 3


## Worst slip angle on each axle, in degrees. The drift claim is a statement
## about the DIFFERENCE between these two numbers, so they are read per axle and
## not collapsed into a single "max slip" the way every existing test does.
func _axles(car: CarBody) -> Vector2:
	var rl: Dictionary = car.get_wheel("RL")
	var rr: Dictionary = car.get_wheel("RR")
	var fl: Dictionary = car.get_wheel("FL")
	var fr: Dictionary = car.get_wheel("FR")
	return Vector2(
		maxf(rad_to_deg(absf(float(rl["slip_angle"]))), rad_to_deg(absf(float(rr["slip_angle"])))),
		maxf(rad_to_deg(absf(float(fl["slip_angle"]))), rad_to_deg(absf(float(fr["slip_angle"])))))


## The rear slip angle the OLD model would have reported: `linear_velocity` with
## no `w x r` term, which is what car_body.gd:546-551 says used to happen. The
## rear wheels are unsteered, so this frame is the car's own, which is why the
## pre-fix number was identical to `slip_angle_body`.
func _rear_slip_without_yaw(car: CarBody) -> float:
	var basis: Basis = car.global_transform.basis.orthonormalized()
	var v: Vector3 = car.linear_velocity
	var rear_wheel: Dictionary = car.get_wheel("RL")
	var wheel_basis: Basis = basis.rotated(Vector3.UP, float(rear_wheel["steer_angle"]))
	var tan := TyreModel.slip_angle_tan(v.dot(-wheel_basis.z), v.dot(wheel_basis.x))
	return rad_to_deg(atan(tan))


## One measured pass over a scripted input. Every case is a real drive, so the
## numbers below are measurements of the shipped physics, not of a model of it.
class Run extends RefCounted:
	var rear_gt_front := 0
	var counted := 0
	var sum_gap := 0.0
	var peak_rear := 0.0
	var peak_front := 0.0
	var peak_yaw := 0.0
	var min_kph := 9999.0
	var hold_body := 0.0
	var hold_n := 0
	var sum_rear_minus_body := 0.0
	var sum_uncond := 0.0
	var sliding_n := 0
	var peak_rear_minus_body := 0.0
	var peak_rear_minus_noyaw := 0.0
	var peak_wheel_omega := 0.0
	var peak_body := 0.0
	var sideways_frames := 0
	var sideways_sum := 0.0
	var rear_gt_front_in_slide := 0
	var sum_gap_in_slide := 0.0
	var straight_frame := -1
	var kph_at_straight := 0.0
	var decay_counted := 0
	var decay_rear_gt_front := 0


## Runs `steps` frames, calling `driver(car, i)` each frame, and measures the
## window from `measure_from` onward. `measure_from` exists because the frames
## immediately after `_arm` are not yet steady - the wheels start at zero omega
## and the first frame is a transient that would flatter any "did it slide" test.
func _drive(t: TestHarness, car: CarBody, steps: int, measure_from: int,
		driver: Callable) -> Run:
	var r := Run.new()
	for i in steps:
		await t.ticks(1)
		car.auto_shift()
		driver.call(car, i)
		var ax := _axles(car)
		var body := rad_to_deg(absf(car.slip_angle_body))
		r.peak_rear = maxf(r.peak_rear, ax.x)
		r.peak_front = maxf(r.peak_front, ax.y)
		r.peak_yaw = maxf(r.peak_yaw, absf(car.angular_velocity.y))
		r.peak_body = maxf(r.peak_body, body)
		for w in car.wheels():
			r.peak_wheel_omega = maxf(r.peak_wheel_omega, absf(float(w["omega"])))
		if i >= measure_from:
			r.counted += 1
			r.sum_gap += ax.x - ax.y
			r.min_kph = minf(r.min_kph, car.speed_kph)
			if ax.x > ax.y:
				r.rear_gt_front += 1
			r.sum_uncond += absf(ax.x - body)
			if body > SIDEWAYS_DEG:
				r.sliding_n += 1
				r.sum_rear_minus_body += absf(ax.x - body)
				r.sideways_frames += 1
				r.sideways_sum += body
				r.sum_gap_in_slide += ax.x - ax.y
				if ax.x > ax.y:
					r.rear_gt_front_in_slide += 1
			r.peak_rear_minus_body = maxf(r.peak_rear_minus_body, absf(ax.x - body))
			r.peak_rear_minus_noyaw = maxf(r.peak_rear_minus_noyaw,
				absf(ax.x - _rear_slip_without_yaw(car)))
			if r.straight_frame < 0:
				r.decay_counted += 1
				if ax.x > ax.y:
					r.decay_rear_gt_front += 1
				if body <= SIDEWAYS_DEG:
					r.straight_frame = i
					r.kph_at_straight = car.speed_kph
			if i >= steps - 120:
				r.hold_n += 1
				r.hold_body += body
	return r


# --- cases -----------------------------------------------------------------

## The handbrake exists and is wired to the rear axle only. `Game/input_map.gd`
## binds it to SPACE (line 15) and JOY_BUTTON_X (line 32), and
## `Systems/player/player_controller.gd:47` reads it onto `car.handbrake`, so the
## input path exists - this asserts the path reaches the TYRE model, which is the
## half a binding cannot prove.
func _input_reaches_the_tyres(t: TestHarness) -> void:
	var world := _flat_world(t)
	var car := _spawn(world)
	for i in 8:
		await t.ticks(1)
	t.ok(car.spec.handbrake_torque > 0.0,
		"%s has a handbrake torque to apply (%.0f Nm)" % [CAR_ID, car.spec.handbrake_torque])
	_arm(car, 60.0, 0.0)
	var locked_rear := false
	var front_still_turning := false
	for i in 90:
		await t.ticks(1)
		car.auto_shift()
		car.steer = -1.0
		car.handbrake = 1.0
		car.throttle = 0.0
		var rl: Dictionary = car.get_wheel("RL")
		var fl: Dictionary = car.get_wheel("FL")
		if absf(float(rl["omega"])) < 0.5:
			locked_rear = true
		if absf(float(fl["omega"])) > 1.0:
			front_still_turning = true
	t.ok(locked_rear, "the handbrake reaches the rear axle and locks it")
	t.ok(front_still_turning,
		"and the handbrake leaves the front axle turning, so it is a rear-only input")
	await t.drop(world)


## THE INITIATING CONDITION: the owner's requirement as a test. The rear axle must
## be the one past its peak, the car must yaw, and a driver must be able to catch
## it and hold it.
##
## CORRECTION, and it matters: the first version of this case drove the car with a
## FIXED 0.55 of pro-steer and asserted the rear would go. It does not - measured
## rear 7.2 deg against front 22.4 deg, rear>front in 0% of frames, mean gap
## -15.2 deg. That looked like "the car grips like a freight train", and it is
## what the numbers said.
##
## It was the wrong condition, and `Tests/drift_flight.gd` is what caught it: the
## free-flight autopilot drives the same car with countersteer and reaches 50 deg
## of body slip at 60 kph with the rear at 53 deg against the front's 30 deg
## (`shots/drift_flight_telemetry.tsv`, kairo_s13 f315: body 27.3, RL 32.9, RR
## 29.9, FL 11.2). Holding 0.55 of lock into a corner and asking for more angle
## IS understeer, and that is correct car behaviour - you drift by countersteering,
## not by winding on more lock. Asserting on the fixed-lock case would have been a
## false alarm about the owner's requirement.
##
## So the assertions below drive the car the way a player does, and the fixed-lock
## number is still printed as a measurement because it is the honest boundary:
## past this much lock the car stops being a drift car.
func _rear_breaks_away_first(t: TestHarness) -> void:
	var world := _flat_world(t)

	# Power, driven by a driver that countersteers: initiate on a handbrake flick,
	# then hold with opposite lock and throttle. This is the owner's requirement -
	# "visibly and controllably power-slide".
	var car := _spawn(world)
	for i in 8:
		await t.ticks(1)
	car.reset_to(Vector3(0, car.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	car.set_meta("leg", 1)
	var power := await _drive(t, car, 700, 194, DriftDriver.make())
	t.ok(true, "=== power drift, countersteered, %.0f kph (locked diff %.1f, rear tail %.2f) ===" % [
		DRIFT_KPH, car.spec.diff_lock, car.spec.rear_slide_tail])
	t.gt(power.peak_body, 25.0,
		"the car visibly goes sideways under power: peak body slip %.1f deg" % power.peak_body)
	t.gt(power.sideways_frames, 120.0,
		"and it is held for seconds rather than flicked through (%.2f s of the %.2f s measured window)" % [
			power.sideways_frames / 60.0, power.counted / 60.0])
	t.gt(power.sideways_frames / maxf(power.counted, 1), 0.20,
		"and it STAYS sideways rather than snapping straight (%.0f%% of the measured frames past %.0f deg, mean %.1f deg while sideways)" % [
			100.0 * power.sideways_frames / maxf(power.counted, 1), SIDEWAYS_DEG,
			power.sideways_sum / maxf(power.sideways_frames, 1)])
	t.gt(power.rear_gt_front_in_slide / maxf(power.sideways_frames, 1), 0.60,
		"and while it is sideways the REAR axle is the deeper of the two (%.0f%% of sideways frames, mean rear-front %+.1f deg, peak rear %.1f vs front %.1f deg)" % [
			100.0 * power.rear_gt_front_in_slide / maxf(power.sideways_frames, 1),
			power.sum_gap_in_slide / maxf(power.sideways_frames, 1),
			power.peak_rear, power.peak_front])
	t.gt(power.peak_rear, peak_slip_deg,
		"the rear tyre is well past the tyre model's peak slip of %.2f deg (%.1f deg)" % [
			peak_slip_deg, power.peak_rear])
	t.gt(power.peak_yaw, 0.30,
		"the car yaws into it (peak yaw rate %.3f rad/s)" % power.peak_yaw)
	await t.drop(car)

	# Lift-off, mid-slide, from the same driver. This is what makes the rear go in
	# a real car and it is the one initiation that needs no handbrake.
	car = _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, DRIFT_KPH, LIFT_ARM_DEG)
	var lift := await _drive(t, car, 360, 30, _lift_driver)
	t.ok(true, "=== lift-off from a 30 deg slide, %.0f kph ===" % DRIFT_KPH)
	t.ok(true, "   the armed pose starts past peak slip on BOTH axles (rear %.1f deg, front %.1f deg) - that is the arm value, not a consequence of lifting" % [
		lift.peak_rear, lift.peak_front])
	t.ok(lift.straight_frame >= 0 and float(lift.straight_frame) / 60.0 < 3.0,
		"a genuine lift-off STRAIGHTENS the car: 30 deg decays to under %.0f deg in %s, bleeding %.0f -> %.0f kph, %d frames past %.0f deg" % [
			SIDEWAYS_DEG, ("%.2f s" % (lift.straight_frame / 60.0)) if lift.straight_frame >= 0 else "NEVER",
			DRIFT_KPH, lift.kph_at_straight, lift.sideways_frames, SIDEWAYS_DEG])
	t.gt(lift.decay_rear_gt_front / maxf(lift.decay_counted, 1), 0.90,
		"and throughout the decay the rear slip angle stays above the front's (%.0f%% of the %d frames from the arm to straight), so the w x a/c term keeps yawing the car back" % [
			100.0 * lift.decay_rear_gt_front / maxf(lift.decay_counted, 1), lift.decay_counted])
	# The contrast, on end-of-window body slip rather than frame counts: the two
	# runs have different measure windows, so raw frame counts are not comparable
	# and an earlier version of this asserted a made-up 4x ratio that the numbers
	# did not actually support (46 vs 178). Mean body slip over each run's last
	# 120 frames answers the real question - is the car still sideways when the
	# input ends - and is independent of how long the run was.
	# CONTRAST, stated the way the numbers actually came out, including the part
	# that is not flattering. BOTH runs end straight in their last 120 frames
	# (power %.2f deg, lift %.2f deg): this car's drift is not indefinite, it lasts
	# as long as the input does and then unwinds. The difference is what happens
	# WHILE the input is on - power holds a real angle at a real speed, lift-off
	# never gets past its starting angle because it is decaying from frame 0.
	#
	# An earlier version of this asserted a 4x ratio of sideways frame counts
	# (46 vs 178) and a label claiming power was "still sideways" at the end. Both
	# were wrong - the runs have different measure windows, and power is at 0.1
	# deg by the end, not sideways. `t.ok` also has no `lt`: calling a missing
	# method threw inside the case, which `run_tests.gd` swallowed into a clean
	# "20 passed, 0 failed" with a node left behind.
	t.ok(power.sideways_sum / maxf(power.sideways_frames, 1) > 20.0,
		"CONTRAST: on power the driver HOLDS %.1f deg mean over %d sideways frames at a speed floor of %.1f kph; on lift-off it is %.1f deg mean over %d frames and unwinds %.0f deg -> straight in %.2f s" % [
			power.sideways_sum / maxf(power.sideways_frames, 1), power.sideways_frames,
			power.min_kph, lift.sideways_sum / maxf(lift.sideways_frames, 1),
			lift.sideways_frames, LIFT_ARM_DEG,
			(lift.straight_frame / 60.0) if lift.straight_frame >= 0 else -1.0])
	t.gt(power.min_kph, 30.0,
		"and the sustained slide is at speed, not a car coasting to a stop (speed floor %.1f kph across the measured window)" % power.min_kph)
	await t.drop(car)

	# Handbrake yank at drift speed, then catch it.
	car = _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, DRIFT_KPH, 0.0)
	car.reset_to(Vector3(0, car.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
	car.set_meta("leg", 1)
	var hb := await _drive(t, car, 700, 194, DriftDriver.make())
	t.ok(true, "=== handbrake yank, %.0f kph ===" % DRIFT_KPH)
	t.gt(hb.peak_rear, peak_slip_deg,
		"a handbrake yank puts the rear past peak slip (%.1f deg, front %.1f deg)" % [
			hb.peak_rear, hb.peak_front])
	t.gt(hb.sideways_frames, 30,
		"and the slide is catchable - a countersteering driver holds it (%d frames past %.0f deg, peak body %.1f deg)" % [
			hb.sideways_frames, SIDEWAYS_DEG, hb.peak_body])
	await t.drop(car)

	# THE BOUNDARY, printed rather than asserted: this is the fixed-lock case that
	# the flight harness proved was the wrong thing to assert on. It stays here so
	# nobody re-derives the false alarm, and because it is genuinely useful: it
	# says how much lock the car can take before it stops sliding.
	car = _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, DRIFT_KPH, 0.0)
	var fixed := await _drive(t, car, 300, 30, func(c: CarBody, _i: int) -> void:
		c.steer = -0.55
		c.throttle = 0.85
		c.handbrake = 0.0)
	t.ok(true, "=== fixed 0.55 pro-steer (measurement, NOT the drift condition) ===")
	t.ok(true, "   rear>front %.0f%% of frames, mean %+.1f deg, peak rear %.1f vs front %.1f - holding this much lock understeers, which is correct" % [
		100.0 * fixed.rear_gt_front / maxf(fixed.counted, 1),
		fixed.sum_gap / maxf(fixed.counted, 1), fixed.peak_rear, fixed.peak_front])
	await t.drop(world)



## A genuine lift-off: no throttle, no handbrake, no steering. Everything the car
## does next is the tyres and the body's own restoring moment.
##
## The previous version of this driver gated the lift on `absf(beta) < 26` while
## arming the car at 30, so the gate was false on frame 0 and it never lifted at
## all - it ran the whole case at 0.6 throttle under full opposite lock, which is
## why it was really a second copy of the catch-a-slide case and why it reported
## "the slide is still there a second later" for a car that had already gone
## straight.
func _lift_driver(c: CarBody, _i: int) -> void:
	c.handbrake = 0.0
	c.throttle = 0.0
	c.steer = 0.0


## The regression guard for car_body.gd:546-551, which says the rear slip angle
## equalled the body slip angle EXACTLY before `point_velocity()` existed, and
## that the yaw term is "the entire yaw-damping mechanism".
##
## Two assertions, and the order matters. The first proves the old formula really
## does reproduce the old bug, so the second is guarding something real rather
## than guarding a difference that was always there.
func _restoring_moment_is_present(t: TestHarness) -> void:
	var world := _flat_world(t)
	var car := _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, 80.0, 30.0)
	var r := await _drive(t, car, 300, 30, func(c: CarBody, _i: int) -> void:
		c.steer = clampf(-rad_to_deg(c.slip_angle_body) / 30.0, -1.0, 1.0)
		c.throttle = 0.65
		c.handbrake = 0.0)
	var body := rad_to_deg(absf(car.slip_angle_body))
	var noyaw := _rear_slip_without_yaw(car)
	t.ok(absf(noyaw - body) < 2.0,
		"the pre-fix formula (linear_velocity only) really does reproduce the old bug: rear %.1f deg vs body %.1f deg" % [
			noyaw, body])
	t.gt(r.peak_rear_minus_noyaw, 1.0,
		"the live rear slip angle differs from that pre-fix number, so the yaw term at car_body.gd:552 is still in the force path (peak difference %.1f deg)" % [
			r.peak_rear_minus_noyaw])
	t.gt(r.sum_rear_minus_body / maxf(r.sliding_n, 1), 0.5,
		"while the car is sideways the rear slip angle is not a copy of the body slip angle, so the contact-patch velocity really does carry the w x r term (mean |rear - body| %.2f deg over %d sliding frames, peak %.1f deg; %.2f deg over all %d frames)" % [
			r.sum_rear_minus_body / maxf(r.sliding_n, 1), r.sliding_n,
			r.peak_rear_minus_body, r.sum_uncond / maxf(r.counted, 1), r.counted])
	await t.drop(world)


## A drift a driver cannot catch is a spin, so initiation is only half the
## requirement. This asserts the other half: the car yaws when asked to, the yaw
## is DAMPED rather than ringing forever when the input is released, and the
## driver can catch a big angle with opposite lock.
func _the_car_yaws_and_is_caught(t: TestHarness) -> void:
	var world := _flat_world(t)
	var car := _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, DRIFT_KPH, 0.0)

	# 1. it yaws at all, on the initiating input.
	var onset := await _drive(t, car, 150, 0, func(c: CarBody, _i: int) -> void:
		c.steer = -0.6
		c.throttle = 0.6
		c.handbrake = 0.0)
	t.gt(onset.peak_yaw, 0.15,
		"the car yaws when steered under power (peak yaw rate %.3f rad/s)" % onset.peak_yaw)
	t.gt(onset.peak_wheel_omega, 1.0,
		"and the wheels are turning, not static decoration (peak |omega| %.1f rad/s)" % onset.peak_wheel_omega)
	await t.drop(car)

	# 2. a yaw DISTURBANCE decays. This is the mechanism :216-218 exists for: a
	#    yawing car builds a restoring lateral force that damps the yaw. If that
	#    is ever removed the rate rings instead of settling.
	car = _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, 90.0, 0.0)
	car.angular_velocity = Vector3(0.0, 1.2, 0.0)
	var yaw0 := 0.0
	var yaw_end := 0.0
	for i in 180:
		await t.ticks(1)
		car.auto_shift()
		car.steer = 0.0
		car.throttle = 0.25
		car.handbrake = 0.0
		if i == 0:
			yaw0 = absf(car.angular_velocity.y)
		yaw_end = absf(car.angular_velocity.y)
	t.ok(yaw_end < yaw0 * 0.5,
		"a 1.2 rad/s yaw disturbance decays instead of ringing (%.3f rad/s -> %.3f rad/s in 3.0 s)" % [
			yaw0, yaw_end])
	await t.drop(car)

	# 3. the driver can catch a big angle. Armed sideways at 40 deg, then full
	#    opposite lock: the car must come back, not spin or stay stuck.
	car = _spawn(world)
	for i in 8:
		await t.ticks(1)
	_arm(car, DRIFT_KPH, 40.0)
	var caught := -1.0
	var peak := 0.0
	for i in 300:
		await t.ticks(1)
		car.auto_shift()
		car.steer = -1.0
		car.throttle = 0.4
		car.handbrake = 0.0
		peak = maxf(peak, rad_to_deg(absf(car.slip_angle_body)))
		if caught < 0.0 and rad_to_deg(absf(car.slip_angle_body)) < 12.0:
			caught = i / 60.0
	t.ok(caught > 0.0,
		"full opposite lock catches a %.0f deg slide (peak %.1f deg, %s)" % [
			40.0, peak, ("recovered in %.2f s" % caught) if caught > 0.0 else "NEVER recovered"])
	await t.drop(world)