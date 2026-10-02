extends RefCounted
## TEMPORARY drift instrumentation. Deleted before landing.
##
## Measures the things that decide whether a car feels like a drift car:
## initiation, hold past the grip limit, countersteer recovery time, spin on
## throttle-off, and lap time. Every metric is emitted through the harness so it
## lands in the normal suite output; nothing here is a real assertion yet.
##
## Sign conventions (Godot 3D, car_body.gd:9): +X right, -Z forward, and steer
## -1 is full right. Countersteer into a slide of +slip is therefore NEGATIVE
## steer.

const DT := 1.0 / 60.0
const CAR_ID := "kairo_s13"
## Soft target; RaceDef.circuit overshoots, landing near 1578 m from 700 - the
## same circuit test_ai.gd drives.
const LAP_TARGET := 700.0
## The tyre makes peak grip at this slip, TyreModel.PEAK_SLIP. Past it the tyre is
## sliding and no amount of load gets the grip back, so this is the line "past
## the grip limit" is measured against.
const PEAK_SLIP_DEG := 7.45


func run(t: TestHarness) -> void:
	await t.ticks(1)
	await _scenarios(t)
	await _lap(t)
	Engine.time_scale = 1.0


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


## Puts the car at the origin facing -Z, rolling at `kph` with `slip` degrees of
## body slip already established. This is the "car is sideways at speed" state
## every recovery and hold case starts from.
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


## One telemetry sample. Body slip is what the driver feels; rear wheel slip is
## what says whether the rear is genuinely past its own peak.
func _sample(car: CarBody) -> Dictionary:
	var rl: Dictionary = car.get_wheel("RL")
	var rr: Dictionary = car.get_wheel("RR")
	return {
		"body": rad_to_deg(car.slip_angle_body),
		"rear": maxf(rad_to_deg(absf(float(rl["slip_angle"]))),
			rad_to_deg(absf(float(rr["slip_angle"])))),
		"yaw": absf(car.angular_velocity.y),
		"kph": car.speed_kph,
	}


func _mean(xs: Array) -> float:
	var m := 0.0
	for x in xs:
		m += x
	return m / maxf(float(xs.size()), 1.0)


func _verdict(peak: float, mean: float) -> String:
	if peak > 80.0:
		return "SPUN"
	if mean < 8.0:
		return "gripped up (understeer)"
	if peak > PEAK_SLIP_DEG and mean > 12.0:
		return "HELD"
	return "marginal"


# --- scenarios -------------------------------------------------------------

## INITIATION on throttle: can throttle alone get the car past the grip limit,
## and does it stay there?
func _case_throttle_initiation(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- initiation on throttle (50 kph, full steer into it) --")
	for thr in [0.5, 0.7, 1.0]:
		_arm(car, 50.0, 0.0)
		var peak := 0.0
		var held: Array[float] = []
		for i in 420:
			await t.ticks(1)
			car.auto_shift()
			car.steer = -1.0
			car.throttle = thr
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			if i >= 300:
				held.append(deg)
		t.ok(true, "   thr %.1f -> peak %5.1f deg   held %5.1f deg   %s" % [
			thr, peak, _mean(held), _verdict(peak, _mean(held))])


## INITIATION on the handbrake: steer and yank, then catch it. This is the entry
## a player actually uses.
func _case_handbrake_initiation(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- initiation on handbrake (50 kph, 0.5 s yank, then catch) --")
	for yank in [0.4, 0.7]:
		_arm(car, 50.0, 0.0)
		var peak := 0.0
		var held: Array[float] = []
		for i in 480:
			await t.ticks(1)
			car.auto_shift()
			if i < 30:
				car.steer = -1.0
				car.handbrake = 1.0
				car.throttle = 0.0
			else:
				car.handbrake = 0.0
				car.throttle = yank
				# Catch it: opposite lock in proportion to the angle.
				car.steer = clampf(-rad_to_deg(car.slip_angle_body) / 40.0, -0.9, 0.9)
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			if i >= 330:
				held.append(deg)
		t.ok(true, "   yank %.1f -> peak %5.1f deg   held %5.1f deg   %s" % [
			yank, peak, _mean(held), _verdict(peak, _mean(held))])


## HOLD: armed sideways at 30 deg, then does a driver hold it? `rear` is the
## worst rear wheel slip in the hold window, which is the proof the rear axle is
## genuinely past its own peak rather than the body just being crooked.
func _case_hold(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- hold: armed at 30 deg, swept over countersteer x throttle --")
	for lock in [0.3, 0.5, 0.7, 0.9]:
		for thr in [0.3, 0.5, 0.7]:
			var held: Array[float] = []
			var rear := 0.0
			var peak := 0.0
			_arm(car, 50.0, 30.0)
			for i in 480:
				await t.ticks(1)
				car.auto_shift()
				car.steer = -lock
				car.throttle = thr
				var deg := absf(rad_to_deg(car.slip_angle_body))
				peak = maxf(peak, deg)
				if i >= 360:
					held.append(deg)
					rear = maxf(rear, float(_sample(car)["rear"]))
			t.ok(true, "   lock %.1f thr %.1f -> held %5.1f deg   rear %5.1f deg   %s" % [
				lock, thr, _mean(held), rear, _verdict(peak, _mean(held))])


## RECOVERY: armed at a big angle, then the driver applies opposite lock. How many
## seconds to get back under control? Sweeping the lock answers the question that
## matters - is there ANY input that catches it, not just whether one does.
func _case_recovery(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- recovery: armed at 35 deg, opposite lock swept, throttle 0.5 --")
	for lock in [0.2, 0.4, 0.6, 0.8, 1.0]:
		_arm(car, 50.0, 35.0)
		var recovered := -1.0
		var peak := 0.0
		var elapsed := 0.0
		for i in 300:
			await t.ticks(1)
			car.auto_shift()
			car.steer = -lock
			car.throttle = 0.5
			elapsed += DT
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			if recovered < 0.0 and deg < 10.0:
				recovered = elapsed
		t.ok(true, "   lock %.1f -> time to <10 deg %s   peak %5.1f deg   end %5.1f deg   %s" % [
			lock,
			("%5.2f s" % recovered) if recovered > 0.0 else "  never",
			peak, absf(rad_to_deg(car.slip_angle_body)),
			"caught" if recovered > 0.0 else "LOST"])


## THROTTLE-OFF SPIN: get into a held drift, then lift, the way a driver does when
## the angle gets away from them. A car that spins on lift is undriveable; the
## peak angle after the lift is the number.
func _case_throttle_off(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- throttle-off: hold a drift, then lift --")
	for lock in [0.4, 0.6, 0.8]:
		_arm(car, 50.0, 30.0)
		for i in 240:
			await t.ticks(1)
			car.steer = -lock
			car.throttle = 0.5
		var before := absf(rad_to_deg(car.slip_angle_body))
		car.throttle = 0.0
		var peak := before
		var peak_yaw := absf(car.angular_velocity.y)
		var spun := false
		for i in 240:
			await t.ticks(1)
			car.steer = -lock
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			peak_yaw = maxf(peak_yaw, absf(car.angular_velocity.y))
			if deg > 90.0:
				spun = true
		var end := absf(rad_to_deg(car.slip_angle_body))
		t.ok(true, "   lock %.1f -> in %5.1f deg   lift -> peak %5.1f deg (yaw %.2f)   end %5.1f deg   %s" % [
			lock, before, peak, peak_yaw, end,
			"SPUN" if spun else ("held" if end < 60.0 else "LOST")])


## Does the slide only exist at one speed? A real car drifts at 40-80 kph, so if
## the window is at 180 kph and not at 50, the tuning is answering the wrong
## question. Armed at 30 deg, lock 0.5, throttle 0.5.
func _case_speed_sweep(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- speed sweep: armed 30 deg, lock 0.5, throttle 0.5 --")
	for kph in [30.0, 40.0, 50.0, 60.0, 80.0, 100.0, 140.0, 180.0]:
		var held: Array[float] = []
		var peak := 0.0
		var rear := 0.0
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
				rear = maxf(rear, float(_sample(car)["rear"]))
		t.ok(true, "   %5.0f kph -> peak %5.1f  held %5.1f  rear %5.1f  %s" % [
			kph, peak, _mean(held), rear, _verdict(peak, _mean(held))])


## Is the throttle response a cliff or a plateau? At 50 kph, lock 0.5.
func _case_fine_throttle(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- fine throttle sweep at 50 kph, lock 0.5 --")
	for thr in [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80]:
		var held: Array[float] = []
		var peak := 0.0
		var rear := 0.0
		_arm(car, 50.0, 30.0)
		for i in 480:
			await t.ticks(1)
			car.auto_shift()
			car.steer = -0.5
			car.throttle = thr
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			if i >= 360:
				held.append(deg)
				rear = maxf(rear, float(_sample(car)["rear"]))
		t.ok(true, "   thr %.2f -> peak %5.1f  held %5.1f  rear %5.1f  %s" % [
			thr, peak, _mean(held), rear, _verdict(peak, _mean(held))])


## The same speed sweep with the gear PINNED, so gear selection cannot be what
## makes the car slide at 30 and 80 but not at 50.
func _case_gear_pinned(t: TestHarness, car: CarBody) -> void:
	t.ok(true, "-- speed sweep, gear PINNED to 2 (no auto_shift) --")
	for kph in [30.0, 40.0, 50.0, 60.0, 80.0, 100.0, 140.0]:
		var held: Array[float] = []
		var peak := 0.0
		var rear := 0.0
		_arm(car, kph, 30.0)
		for i in 480:
			await t.ticks(1)
			car.current_gear = 2
			car.steer = -0.5
			car.throttle = 0.5
			var deg := absf(rad_to_deg(car.slip_angle_body))
			peak = maxf(peak, deg)
			if i >= 360:
				held.append(deg)
				rear = maxf(rear, float(_sample(car)["rear"]))
		t.ok(true, "   %5.0f kph -> peak %5.1f  held %5.1f  rear %5.1f  %s" % [
			kph, peak, _mean(held), rear, _verdict(peak, _mean(held))])


## Frame-by-frame trace of a case that grips up against one that holds, so the
## divergence is visible rather than inferred.
func _case_trace(t: TestHarness, car: CarBody) -> void:
	for kph in [50.0, 80.0]:
		_arm(car, kph, 30.0)
		t.ok(true, "-- trace at %.0f kph, lock 0.5, throttle 0.5, gear 2 --" % kph)
		for i in 240:
			await t.ticks(1)
			car.current_gear = 2
			car.steer = -0.5
			car.throttle = 0.5
			if i % 20 != 0 and i != 239:
				continue
			var rl: Dictionary = car.get_wheel("RL")
			var rr: Dictionary = car.get_wheel("RR")
			t.ok(true, "   f%3d  body %6.1f  yaw %5.2f  rear_slip %6.1f  rr_omega %7.1f  rl_omega %7.1f  kph %5.1f  rpm %5.0f" % [
				i, rad_to_deg(car.slip_angle_body), car.angular_velocity.y,
				rad_to_deg(float(rr["slip_angle"])),
				float(rr["omega"]), float(rl["omega"]),
				car.speed_kph, car.engine_rpm])


## If the locked diff is a hard constraint that turns any asymmetry into both
## wheels spinning at once, then a PARTIAL lock should smooth the cliff out and
## open a plateau where the rear sits at a real slip angle. Fresh car per lock,
## because the value is a spec field fixed at construction.
func _case_diff_sweep(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- diff_lock sweep at 50 kph, lock 0.5: is the throttle a cliff or a plateau? --")
	for dl in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var spec := CarDB.get_spec(CAR_ID)
		spec.diff_lock = dl
		var c := CarBody.new()
		c.build_visual = false
		c.spec = spec
		world.add_child(c)
		for i in 8:
			await t.ticks(1)
		var line := ""
		for thr in [0.50, 0.60, 0.70, 0.80]:
			_arm(c, 50.0, 30.0)
			var held: Array[float] = []
			var rear := 0.0
			for i in 480:
				await t.ticks(1)
				c.auto_shift()
				c.steer = -0.5
				c.throttle = thr
				if i >= 360:
					held.append(absf(rad_to_deg(c.slip_angle_body)))
					rear = maxf(rear, float(_sample(c)["rear"]))
			line += " thr%.1f h%4.1f r%5.1f |" % [thr, _mean(held), rear]
		t.ok(true, "   diff %.2f ->%s" % [dl, line])
		await t.drop(c)


## The two tails are the whole balance, and they were never swept against each
## other. In a drift the FRONT slip angle is the rear's plus the opposite lock,
## so the front is always the deeper into the tail - which means the front's
## retained grip, not the rear's, is what sets whether the car pulls straight or
## holds an angle.
func _case_tail_sweep(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- front_tail x rear_tail at 50 kph, lock 0.5, throttle 0.6 --")
	for ft in [0.72, 0.60, 0.50, 0.40, 0.30]:
		var line := ""
		for rt in [0.72, 0.60, 0.50, 0.40, 0.30]:
			var spec := CarDB.get_spec(CAR_ID)
			spec.front_slide_tail = ft
			spec.rear_slide_tail = rt
			var c := CarBody.new()
			c.build_visual = false
			c.spec = spec
			world.add_child(c)
			for i in 8:
				await t.ticks(1)
			_arm(c, 50.0, 30.0)
			var held: Array[float] = []
			var rear := 0.0
			var peak := 0.0
			for i in 480:
				await t.ticks(1)
				c.auto_shift()
				c.steer = -0.5
				c.throttle = 0.6
				var deg := absf(rad_to_deg(c.slip_angle_body))
				peak = maxf(peak, deg)
				if i >= 360:
					held.append(deg)
					rear = maxf(rear, float(_sample(c)["rear"]))
			line += " %4.1f/%4.1f h%4.1f r%5.1f |" % [ft, rt, _mean(held), rear]
			await t.drop(c)
		t.ok(true, "   front %.2f ->%s" % [ft, line])


## A drift is closed-loop. Countersteer has to TRACK the angle: hold a fixed
## lock while the car is at 30 deg and the front tyres simply overpower the rear
## and snap it straight, which is what every fixed-lock case above was actually
## measuring. This is the driver model: countersteer proportional to slip angle
## with yaw-rate damping, throttle to hold the target angle.
## A drift driver in two phases, because that is what a drifter does and what
## the earlier proportional model could not do: it demanded steering proportional
## to the slip angle, so at beta = 0 it asked for no steering at all and could
## never initiate anything.
##
## INITIATE: steer into the corner and apply throttle until the rear lets go.
## HOLD: countersteer into the slide, damped on yaw rate, with the throttle
## trimmed to sit on the target angle.
func _closed_loop(t: TestHarness, car: CarBody, target_deg: float, frames: int,
		initiate_frames: int = 75) -> Dictionary:
	var held: Array[float] = []
	var kph: Array[float] = []
	var peak := 0.0
	var rear := 0.0
	for i in frames:
		await t.ticks(1)
		car.auto_shift()
		var beta := rad_to_deg(car.slip_angle_body)
		if i < initiate_frames:
			car.steer = -0.7
			car.throttle = 1.0
			car.brake = 0.0
		else:
			var err := absf(beta) - target_deg
			car.steer = clampf(-signf(beta) * (absf(beta) / 35.0), -1.0, 1.0) \
				+ clampf(-car.angular_velocity.y / 1.5, -0.5, 0.5)
			car.throttle = clampf(0.5 - 0.012 * err, 0.0, 1.0)
			car.brake = 0.0
		var d := absf(beta)
		peak = maxf(peak, d)
		if i >= frames - 150:
			held.append(d)
			kph.append(car.speed_kph)
			rear = maxf(rear, float(_sample(car)["rear"]))
	return {
		"peak": peak, "held": _mean(held), "kph": _mean(kph), "rear": rear,
		"verdict": _verdict(peak, _mean(held)),
	}


## The tails swept where it matters: a closed-loop driver trying to hold an
## angle. The pairs include rear > front, because the front, countersteered onto
## the direction of travel, sits near its own peak while the rear is deep in its
## tail - so a LOW rear tail guarantees the front out-pulls the rear and the car
## straightens up. That is understeer, and it is what the tuning was doing.
func _case_closed_loop(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- CLOSED LOOP, tails swept: 30 deg target, initiate then hold --")
	t.ok(true, "   f_tail/r_tail |  peak  held   rear    kph   verdict")
	for pair in [[0.72, 0.72], [0.72, 0.80], [0.72, 0.85], [0.72, 0.90], [0.72, 0.95], [0.60, 0.90], [0.85, 0.72]]:
		var spec := CarDB.get_spec(CAR_ID)
		spec.front_slide_tail = float(pair[0])
		spec.rear_slide_tail = float(pair[1])
		var c := CarBody.new()
		c.build_visual = false
		c.spec = spec
		world.add_child(c)
		for i in 8:
			await t.ticks(1)
		c.reset_to(Vector3(0, c.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
		for i in 120:
			await t.ticks(1)
			c.auto_shift()
			c.steer = -0.7
			c.throttle = 0.6
		var r := await _closed_loop(t, c, 30.0, 540)
		t.ok(true, "   %.2f / %.2f      | %5.1f %5.1f %6.1f %6.1f   %s" % [
			pair[0], pair[1], r["peak"], r["held"], r["rear"], r["kph"], r["verdict"]])
		await t.drop(c)


## Per-wheel forces during initiation. The question is whether the rear is
## losing lateral force (a slide starting) or still making it (grip driving).
func _case_force_trace(t: TestHarness, world: Node3D) -> void:
	var c := CarBody.new()
	c.build_visual = false
	c.spec = CarDB.get_spec(CAR_ID)
	world.add_child(c)
	for i in 8:
		await t.ticks(1)
	t.ok(true, "-- force trace: 50 kph, full lock, handbrake 30 frames then throttle --")
	t.ok(true, "   f | body   yaw  | FL fy  slip | FR fy  slip | RL fy  slip sr | RR fy  slip sr | kph")
	_arm(c, 50.0, 0.0)
	for i in 90:
		await t.ticks(1)
		c.auto_shift()
		if i < 30:
			c.steer = -1.0
			c.handbrake = 1.0
			c.throttle = 0.0
		else:
			c.handbrake = 0.0
			c.steer = clampf(-rad_to_deg(c.slip_angle_body) / 35.0, -1.0, 1.0)
			c.throttle = 0.8
		if i % 6 != 0:
			continue
		var fl: Dictionary = c.get_wheel("FL")
		var fr: Dictionary = c.get_wheel("FR")
		var rl: Dictionary = c.get_wheel("RL")
		var rr: Dictionary = c.get_wheel("RR")
		t.ok(true, "  %2d | %5.1f %5.2f | %5.0f %5.1f | %5.0f %5.1f | %5.0f %5.1f %4.1f | %5.0f %5.1f %4.1f | %5.1f" % [
			i, rad_to_deg(c.slip_angle_body), c.angular_velocity.y,
			float(fl["fy"]), rad_to_deg(float(fl["slip_angle"])),
			float(fr["fy"]), rad_to_deg(float(fr["slip_angle"])),
			float(rl["fy"]), rad_to_deg(float(rl["slip_angle"])), float(rl["slip_ratio"]),
			float(rr["fy"]), rad_to_deg(float(rr["slip_angle"])), float(rr["slip_ratio"]),
			c.speed_kph])
	await t.drop(c)


## If the front axle is what refuses to let go, weakening it is what lets the
## car slide at all. Measured two ways: does throttle at full lock initiate
## anything, and can a driver then hold it.
func _case_front_grip(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- front_grip_scale: initiation and hold --")
	for gs in [1.0, 0.85, 0.70, 0.55, 0.40]:
		var spec := CarDB.get_spec(CAR_ID)
		spec.front_grip_scale = gs
		var c := CarBody.new()
		c.build_visual = false
		c.spec = spec
		world.add_child(c)
		for i in 8:
			await t.ticks(1)
		# initiation: full lock, full throttle from 50 kph
		_arm(c, 50.0, 0.0)
		var peak := 0.0
		var rear := 0.0
		for i in 300:
			await t.ticks(1)
			c.auto_shift()
			c.steer = -1.0
			c.throttle = 1.0
			peak = maxf(peak, absf(rad_to_deg(c.slip_angle_body)))
			rear = maxf(rear, float(_sample(c)["rear"]))
		var r := await _closed_loop(t, c, 30.0, 480)
		t.ok(true, "   front %.2f -> throttle-init peak %5.1f (rear %5.1f)  |  hold %5.1f peak %5.1f rear %5.1f %5.1f kph  %s" % [
			gs, peak, rear, r["held"], r["peak"], r["rear"], r["kph"], r["verdict"]])
		await t.drop(c)


## The car cannot countersteer enough to balance a drift. _steer_lock tapers
## steering to 0.872 of max at 50 kph, and max_steer is 0.64 rad, so the most
## lock available is 27.5 deg - while a 35 deg drift needs about 30 deg of
## opposite lock just to sit at the balance point. Below that the front keeps a
## big slip angle, stays near its peak, and out-pulls the rear. How much lock is
## actually needed?
func _case_lock_authority(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- max_steer: lock authority vs holding a drift --")
	for ms in [0.64, 0.80, 0.95, 1.10]:
		var spec := CarDB.get_spec(CAR_ID)
		spec.max_steer = ms
		var c := CarBody.new()
		c.build_visual = false
		c.spec = spec
		world.add_child(c)
		for i in 8:
			await t.ticks(1)
		var lock_at_50: float = ms * (1.0 - 0.68 * pow(clampf(50.0 / 3.6 / 32.0, 0.0, 1.0), 2.0))
		_arm(c, 50.0, 0.0)
		var peak := 0.0
		for i in 300:
			await t.ticks(1)
			c.auto_shift()
			c.steer = -1.0
			c.throttle = 1.0
			peak = maxf(peak, absf(rad_to_deg(c.slip_angle_body)))
		var r := await _closed_loop(t, c, 30.0, 480)
		t.ok(true, "   max_steer %.2f (%4.1f deg of lock at 50 kph) -> init peak %5.1f  |  hold %5.1f peak %5.1f rear %5.1f %5.1f kph  %s" % [
			ms, rad_to_deg(lock_at_50), peak, r["held"], r["peak"], r["rear"], r["kph"], r["verdict"]])
		await t.drop(c)


## The rear is the axle that has to give way. Weakening it directly.
func _case_rear_grip(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- rear grip x lock, front steer ANGLE held fixed --")
	for gs in [0.98, 0.97, 0.96, 0.95]:
		for ms in [0.64, 0.80, 1.00, 1.30]:
			var spec := CarDB.get_spec(CAR_ID)
			spec.rear_grip_scale = gs
			spec.max_steer = ms
			# hold the FRONT STEER ANGLE fixed so lock is the only variable
			var k: float = 0.64 / ms
			var c := CarBody.new()
			c.build_visual = false
			c.spec = spec
			world.add_child(c)
			for i in 8:
				await t.ticks(1)
			_arm(c, 50.0, 0.0)
			var peak := 0.0
			for i in 300:
				await t.ticks(1)
				c.auto_shift()
				c.steer = -0.55 * k
				c.throttle = 1.0
				peak = maxf(peak, absf(rad_to_deg(c.slip_angle_body)))
			var r := await _closed_loop(t, c, 30.0, 480)
			t.ok(true, "   rear %.2f max_steer %.2f -> init peak %5.1f  |  hold %5.1f peak %5.1f rear %5.1f %5.1f kph  %s" % [
				gs, ms, peak, r["held"], r["peak"], r["rear"], r["kph"], r["verdict"]])
			await t.drop(c)


func _scenarios(t: TestHarness) -> void:
	var world := _flat_world(t)
	var spec := CarDB.get_spec(CAR_ID)
	var car := CarBody.new()
	car.build_visual = false
	car.spec = spec
	world.add_child(car)
	for i in 8:
		await t.ticks(1)
	t.ok(true, "=== %s: tail %.2f  diff %.1f  drive %s ===" % [
		CAR_ID, spec.rear_slide_tail, spec.diff_lock, spec.drive])
	await _case_throttle_initiation(t, car)
	await _case_handbrake_initiation(t, car)
	await _case_hold(t, car)
	await _case_recovery(t, car)
	await _case_throttle_off(t, car)
	await _case_speed_sweep(t, car)
	await _case_fine_throttle(t, car)
	await _case_gear_pinned(t, car)
	await _case_trace(t, car)
	await _case_diff_sweep(t, world)
	await _case_tail_sweep(t, world)
	await _case_closed_loop(t, world)
	await _case_force_trace(t, world)
	await _case_front_grip(t, world)
	await _case_lock_authority(t, world)
	await _case_rear_grip(t, world)
	await _case_front_slip_target(t, world)
	await t.drop(world)


# --- lap time --------------------------------------------------------------

class Racer extends RefCounted:
	var body: CarBody
	var position: Vector3:
		get: return body.global_position
		set(v):
			if v.distance_squared_to(body.global_position) > 0.0001:
				body.linear_velocity = Vector3.ZERO
				body.angular_velocity = Vector3.ZERO
			body.global_position = v
	var facing: Vector3:
		get: return body.forward()
		set(v):
			var flat := Vector3(v.x, 0.0, v.z)
			if flat.length_squared() < 0.0001:
				return
			body.global_position.y = v.y
			body.basis = Basis.looking_at(flat.normalized(), Vector3.UP)


## Lap time on the real Manunda Street Circuit, driven by the real AI, timed by
## the race system. No Engine.time_scale, so the race clock and the physics are
## both a plain 1/60 s and cannot drift apart.
func _lap(t: TestHarness) -> void:
	var world := _flat_world(t)
	var g := RoadGraph.new()
	g.build(ManundaLayout.corridors())
	var def := RaceDef.circuit(g, 0, LAP_TARGET, "drift_lap", "Drift Lap", 2)
	def.entry_fee = 0
	var dr := RaceDirector.new()
	dr.try_enter(def)
	var car := CarBody.new()
	car.build_visual = false
	car.spec = CarDB.get_spec(CAR_ID)
	world.add_child(car)
	var racer := Racer.new()
	racer.body = car
	if not dr.start(def, g, [racer]):
		t.ok(false, "the lap race started")
		return
	var ai := AIRacer.new()
	ai.car = car
	ai.graph = g
	ai.skill = 0.9
	ai.director = dr
	ai.rng_seed = 4242
	world.add_child(ai)
	for i in 5:
		await t.ticks(1)
	# 3 s of countdown before the race clock means anything.
	for i in 200:
		await t.ticks(1)
		dr.tick(DT)
		if dr.state_name() == "racing":
			break
	var frames := 0
	while dr.state_name() != "finished" and frames < 40000:
		await t.ticks(1)
		dr.tick(DT)
		frames += 1
		if car.global_position.y < -5.0:
			break
	t.ok(true, "-- lap: %s on a %.0f m circuit --" % [CAR_ID, dr.route_length()])
	t.ok(true, "   laps banked %d   best lap %6.2f s   total %6.2f s   ai errors %d" % [
		dr.laps(0), dr.best_lap(0), dr.race_time, ai.errors])
	await t.drop(world)

## Does a stable drift branch exist at all, and where does the front sit on its
## own curve when it does? Swept at the stock rear grip.
func _case_front_slip_target(t: TestHarness, world: Node3D) -> void:
	t.ok(true, "-- front-slip target: is there a stable drift equilibrium? --")
	for ft in [7.0, 10.0, 13.0, 16.0, 20.0, 26.0]:
		var c := CarBody.new()
		c.build_visual = false
		c.spec = CarDB.get_spec(CAR_ID)
		world.add_child(c)
		for i in 8:
			await t.ticks(1)
		c.reset_to(Vector3(0, c.spec.tyre_radius + 0.04, 0), Vector3.ZERO)
		for i in 90:
			await t.ticks(1)
			c.auto_shift()
			c.steer = -0.6
			c.throttle = 0.55
		var r := await _closed_loop(t, c, 30.0, 600, ft)
		t.ok(true, "   front slip target %4.1f deg -> held %5.1f  peak %5.1f  rear %5.1f  %5.1f kph  %s" % [
			ft, r["held"], r["peak"], r["rear"], r["kph"], r["verdict"]])
		await t.drop(c)
