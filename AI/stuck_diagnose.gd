extends Node
##
## Why does the AI car not move? Measure, in this order, and report every number.
##
##   /home/coder/tools/godot --headless --fixed-fps 60 --path . \
##       res://AI/stuck_diagnose.tscn -- --street="Hoare Street" --lane=4.25
##
## THE SYMPTOM, FROM t124
##
## `AI/street_ai_probe.gd` puts an AI car on a named street and reports it driving
## **0.0 m over 240 s** with four wheels down and **3409 N on the rear tyres**,
## while the projection walks 2776 m along the line. Force with no motion.
##
## 3409 N of vertical load with zero motion is the signature of a tyre model making
## force where there is no longitudinal slip, which is what a contact patch that is
## not resolving looks like - and it is the same family as the GEVP defect this
## project shipped past once, where `max_y_force` was derived from applied torque so
## the brakes could not slow an over-spinning wheel. **That is a hypothesis, and it
## is what this probe exists to test rather than believe.**
##
## THE ORDER MATTERS, and it is the lead's order:
##
##   1. Is throttle reaching the car at all, and is it becoming crank torque? If
##      not, nothing downstream matters and the cause is the AI or the harness.
##   2. Wheel angular velocity against road speed. Load without slip is the
##      contact patch failing to resolve.
##   3. Is the car wedged against geometry? Raycast down and sideways.
##   4. Is it even on a surface? The driver's line is 2790.3 m where the street is
##      1407.5 m, so "on the street" and "on the line the AI is following" are
##      different places.
##
## Every quantity is reported as a range over a window of frames, never a single
## frame: a single frame of a wheel model is noise, and a single frame of "throttle
## is 0" is how you conclude the AI is not driving when the real answer is that it
## lifts for 0.4 s on a schedule.
##
## NOTHING HERE CHANGES A FORCE. The point is to find which term is wrong, and
## this project has twice shipped a force increase that changed nothing because slip
## was the real problem. No gain, no force and no torque in this file is touched.

const STREET_NAME := "Hoare Street"
const SPAWN_S := 8.0
const LANE_DEFAULT := 4.25
const SPAWN_Y := 0.60
## Frames to settle the suspension before measuring, and frames to measure over.
const SETTLE_FRAMES := 120
const SAMPLE_FRAMES := 360

var main: Node3D
var racer: AIRacer
var car: Node3D
var follower: LaneFollower
var street_name := STREET_NAME
var lane_offset := LANE_DEFAULT
## Reproduce t124's ordering: `AI/street_ai_probe.gd` runs
## `follower.verify()` BEFORE the drive, and `verify()` calls `project()` 24 times
## with explicit hints. Each call still writes the follower's internal seed, so the
## driver's seed is left somewhere in the middle of a 2790 m line when the car
## starts at s=8. If that is what strands the car, the run with this flag set will
## fail to move and the run without it will drive.
var verify_first := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--street="):
			street_name = a.substr(9)
		elif a.begins_with("--lane="):
			lane_offset = a.substr(7).to_float()
		elif a == "--verify-first":
			verify_first = true

	print("[diag] booting Game/main.tscn")
	main = load("res://Game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await _wait_for_world()

	var pts := _pick(street_name)
	if pts.size() < 2:
		print("DIAG FATAL: no corridor named %s" % street_name)
		get_tree().quit(2)
		return

	car = CarBody.new()
	car.name = "StuckCar"
	car.spec = CarDB.get_spec("kairo_s13")
	main.add_child(car)
	racer = AIRacer.new()
	racer.name = "StuckRacer"
	racer.car = car
	racer.graph = main.graph
	racer.skill = 0.72
	add_child(racer)
	var route: Array = []
	for p in pts:
		route.append(p)
	if not racer.follow_street(route, lane_offset):
		print("DIAG FATAL: the driver refused the street line")
		get_tree().quit(2)
		return
	follower = racer.lane()

	var spawn := follower.aim_at(SPAWN_S, SPAWN_Y)
	var tan0: Vector2 = follower.project(spawn)["t"]
	car.reset_to(spawn, Vector3(0.0, atan2(-tan0.x, -tan0.y), 0.0))

	print("[diag] placed at %.2f, %.2f, %.2f facing the driver line at s=%.1f" % [
		spawn.x, spawn.y, spawn.z, SPAWN_S])
	for f in SETTLE_FRAMES:
		await get_tree().process_frame
	print("[diag] settled after %d frames" % SETTLE_FRAMES)

	if verify_first:
		var v: Dictionary = follower.verify()
		print("[diag] follower.verify() run FIRST, as t124's probe does: ok=%s, aim error %.3f m" % [
			str(bool(v["ok"])), float(v["worst_lat_m"])])

	await _q4_is_it_on_a_surface()
	await _q1_throttle_to_torque()
	await _q2_wheel_versus_road()
	await _q3_wedged()
	print("")
	print("[diag] verdict follows in the next block")
	get_tree().quit(0)


func _wait_for_world() -> void:
	var t := 0.0
	while main.world == null and t < 120.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	if main.world == null:
		print("DIAG FATAL: world never built")
		get_tree().quit(2)


# ------------------------------------------------------------------ Q4 first
## Run BEFORE any driving, because if the car is not on a surface then nothing
## measured afterwards can be read as a tyre problem.
func _q4_is_it_on_a_surface() -> void:
	print("")
	print("=" .repeat(76))
	print("Q4  IS THE CAR ON A SURFACE AT ALL?  (run first: it gates the rest)")
	print("=" .repeat(76))
	var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	print("  car position          : %s" % str(car.global_position.round()))
	print("  wheels on ground      : %d" % int(car.wheels_on_ground))
	print("  colliding bodies      : %d" % int(car.get_contact_count()))
	for b in car.get_colliding_bodies():
		print("      colliding          : %s (%s)" % [String(b.name), b.get_class()])
	print("  global Y of car origin: %.3f" % car.global_position.y)
	# The polyline has no idea where the road is; the car is placed 0.60 m above it
	# and settles. So compare where it settled with where the ROAD is.
	var down := _ray(space, car.global_position + Vector3.UP * 20.0,
		car.global_position - Vector3.UP * 20.0)
	if down.is_empty():
		print("  downward ray          : HIT NOTHING - the car is over a void")
	else:
		print("  downward ray          : %s at y=%.3f (car origin is %.3f, so %.3f m above the surface)" % [
			String((down["collider"] as Node).name), (down["position"] as Vector3).y,
			car.global_position.y,
			car.global_position.y - (down["position"] as Vector3).y])
	# And the line the driver is following versus the street it was built from.
	var here: Dictionary = follower.project(car.global_position)
	var lat := float(here["lat"])
	var street_near := _nearest_street_point(car.global_position)
	print("  offset from driver line: %+.2f m (lane target %+.2f m right of travel)" % [lat, lane_offset])
	print("  distance to the STREET centreline: %.2f m" % street_near)
	print("  driver line length    : %.1f m, street length: %.1f m" % [
		follower.length(), _street_length()])
	var verdict := "on the road"
	if lat > 8.0:
		verdict = "OFF the driver's own line by %.1f m - placement or the line is wrong" % lat
	elif street_near > 8.0:
		verdict = "on the driver's line but %.1f m from the street - the two are not the same place" % street_near
	print("  Q4 VERDICT: %s" % verdict)


# ------------------------------------------------------------------- Q1
## Is the throttle reaching the car, and is it becoming crank torque?
##
## Read from the CAR, not from `Input`. This car is driven by `AIRacer`, which
## writes `car.throttle` directly, so the input map and `PlayerController` are not
## in this chain at all and asking about an input action here would be answering a
## question nobody asked.
func _q1_throttle_to_torque() -> void:
	print("")
	print("=" .repeat(76))
	print("Q1  DOES THROTTLE REACH THE CAR, AND DOES IT BECOME TORQUE?")
	print("=" .repeat(76))
	var t_min := 1.0
	var t_max := 0.0
	var t_sum := 0.0
	var torque_max := 0.0
	var torque_sum := 0.0
	var brake_max := 0.0
	var steer_absmax := 0.0
	var gear_min := 99
	var gear_max := -99
	var throttle_zero := 0
	for i in SAMPLE_FRAMES:
		await get_tree().process_frame
		var th := float(car.throttle)
		t_min = minf(t_min, th)
		t_max = maxf(t_max, th)
		t_sum += th
		torque_max = maxf(torque_max, absf(float(car.engine_torque)))
		torque_sum += absf(float(car.engine_torque))
		brake_max = maxf(brake_max, float(car.brake))
		steer_absmax = maxf(steer_absmax, absf(float(car.steer)))
		gear_min = mini(gear_min, int(car.current_gear))
		gear_max = maxi(gear_max, int(car.current_gear))
		if th < 0.01:
			throttle_zero += 1
	var n := float(SAMPLE_FRAMES)
	print("  frames sampled        : %d" % SAMPLE_FRAMES)
	print("  car.throttle          : min %.3f  max %.3f  mean %.3f  (zero on %d frames, %.0f%%)" % [
		t_min, t_max, t_sum / n, throttle_zero, 100.0 * float(throttle_zero) / n])
	print("  car.engine_torque     : mean %.1f Nm  max %.1f Nm" % [torque_sum / n, torque_max])
	print("  car.brake             : max %.3f" % brake_max)
	print("  car.steer             : max |%.3f|" % steer_absmax)
	print("  car.current_gear      : %d .. %d" % [gear_min, gear_max])
	print("  car.speed_mps         : %.4f m/s   speed_kph %.3f" % [float(car.speed_mps), float(car.speed_kph)])
	print("")
	if t_max < 0.01:
		print("  Q1 VERDICT: NO THROTTLE. The driver is asking for nothing, so no force is")
		print("             expected. This is an AI or harness fault, not a tyre one.")
	elif torque_max < 1.0:
		print("  Q1 VERDICT: throttle is commanded (max %.3f) but engine_torque peaks at" % t_max)
		print("             %.1f Nm. The throttle is not becoming torque - the fault is" % torque_max)
		print("             upstream of the tyres: the engine or the gear.")
	else:
		print("  Q1 VERDICT: throttle reaches the car (max %.3f) and becomes up to %.1f Nm." % [t_max, torque_max])
		print("             So force IS being asked for. Q2 decides whether the tyre delivers it.")


# ------------------------------------------------------------------- Q2
## Wheel angular velocity against road speed.
##
## This is the decisive measurement. A tyre makes longitudinal force from the
## DIFFERENCE between how fast the contact patch is going and how fast the wheel is
## turning. Load with force but no slip means the patch and the wheel agree - which
## on a car that is not moving means either the wheel is not turning (no torque
## reaching it, or the brake is cancelling it) or the model is not reading slip.
func _q2_wheel_versus_road() -> void:
	print("")
	print("=" .repeat(76))
	print("Q2  WHEEL ANGULAR VELOCITY versus ROAD SPEED")
	print("=" .repeat(76))
	print("  %-4s %10s %12s %12s %10s %10s %10s" % [
		"wheel", "load_N", "omega", "surface_kmh", "road_kmh", "slip_ratio", "fx_N"])
	for name in ["FL", "FR", "RL", "RR"]:
		var w: Dictionary = car.get_wheel(name)
		var omega := float(w.get("omega", 0.0))
		var radius := float(w.get("radius", 0.3))
		# Surface speed of the contact patch: omega x radius. Compare with the car's
		# own speed along this wheel's heading, which for a straight is its speed.
		var surface_mps := absf(omega) * radius
		print("  %-4s %10.0f %12.4f %12.2f %10.2f %10.4f %10.0f" % [
			name, float(w.get("load", 0.0)), omega, surface_mps * 3.6,
			float(car.speed_mps) * 3.6, float(w.get("slip_ratio", 0.0)),
			float(w.get("fx", 0.0))])
	print("")
	# And the same thing sampled over a window, because one frame of a wheel is noise.
	var rows := {}
	for name in ["FL", "FR", "RL", "RR"]:
		rows[name] = {"load": 0.0, "omega": 0.0, "slip": 0.0, "fx": 0.0, "mu": 1.0}
	for i in 120:
		await get_tree().process_frame
		for name in ["FL", "FR", "RL", "RR"]:
			var w: Dictionary = car.get_wheel(name)
			var r: Dictionary = rows[name]
			r["load"] = maxf(float(r["load"]), float(w.get("load", 0.0)))
			r["omega"] = maxf(float(r["omega"]), absf(float(w.get("omega", 0.0))))
			r["slip"] = maxf(float(r["slip"]), absf(float(w.get("slip_ratio", 0.0))))
			r["fx"] = maxf(float(r["fx"]), absf(float(w.get("fx", 0.0))))
			r["mu"] = float(w.get("surface_mu", 1.0))
	print("  over 120 frames, the MAXIMUM of each:")
	print("  %-4s %10s %12s %10s %10s %8s" % ["wheel", "load_N", "omega", "slip_ratio", "fx_N", "mu"])
	for name in ["FL", "FR", "RL", "RR"]:
		var r: Dictionary = rows[name]
		print("  %-4s %10.0f %12.4f %10.4f %10.0f %8.3f" % [
			name, float(r["load"]), float(r["omega"]), float(r["slip"]), float(r["fx"]), float(r["mu"])])
	print("")
	var driven: Dictionary = rows["RL"]
	var verdict := ""
	if float(driven["load"]) > 500.0 and float(driven["omega"]) < 0.5:
		verdict = "LOAD WITH NO SPIN: %.0f N on the rear left but it never turns (omega %.4f rad/s). The tyre" % [float(driven["load"]), float(driven["omega"])]
		verdict += "\n             cannot make longitudinal force without slip, so either the drive torque is not"
		verdict += "\n             reaching this wheel or the model is not reading its slip."
	elif float(driven["omega"]) > 1.0:
		verdict = "the rear left WHEEL IS TURNING (omega %.4f rad/s) but the car is not" % float(driven["omega"])
		verdict += "\n             moving. Force is being made and it is not becoming motion - that is a"
		verdict += "\n             contact-patch or geometry problem, not a torque problem."
	else:
		verdict = "rear left: load %.0f N, omega %.4f rad/s, slip %.4f, fx %.0f N" % [
			float(driven["load"]), float(driven["omega"]), float(driven["slip"]), float(driven["fx"])]
	print("  Q2 VERDICT: %s" % verdict)


# ------------------------------------------------------------------- Q3
## Is the car wedged against something?
func _q3_wedged() -> void:
	print("")
	print("=" .repeat(76))
	print("Q3  IS THE CAR RESTING AGAINST SOMETHING?")
	print("=" .repeat(76))
	car.contact_monitor = true
	car.max_contacts_reported = 16
	for _i in 5:
		await get_tree().process_frame
	var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	var centre: Vector3 = car.global_position
	var fwd: Vector3 = -car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	print("  contact bodies reported : %d" % int(car.get_contact_count()))
	for b in car.get_colliding_bodies():
		var where := "somewhere"
		if b is Node3D:
			where = str((b as Node3D).global_position.round())
		print("      %-28s %-16s at %s" % [String(b.name), b.get_class(), where])
	print("  downward ray from the car centre : %s" % _describe(_ray(space, centre + Vector3.UP * 6.0, centre - Vector3.UP * 6.0)))
	print("  2 m LEFT of the car       : %s" % _describe(_ray(space,
		centre - right * 2.0 + Vector3.UP * 1.0, centre - right * 2.0 - Vector3.UP * 1.0)))
	print("  2 m RIGHT of the car      : %s" % _describe(_ray(space,
		centre + right * 2.0 + Vector3.UP * 1.0, centre + right * 2.0 - Vector3.UP * 1.0)))
	print("  2 m AHEAD of the car      : %s" % _describe(_ray(space,
		centre + fwd * 2.0 + Vector3.UP * 1.0, centre + fwd * 2.0 - Vector3.UP * 1.0)))
	print("  2 m BEHIND the car       : %s" % _describe(_ray(space,
		centre - fwd * 2.0 + Vector3.UP * 1.0, centre - fwd * 2.0 - Vector3.UP * 1.0)))
	print("  linear_velocity           : %s m/s" % str(car.linear_velocity.round()))
	print("  angular_velocity          : %s rad/s" % str(car.angular_velocity.round()))
	# Is the body integrating AT ALL? A RigidBody3D that is asleep or frozen ignores
	# every force applied to it, so 3 kN of tyre force and no motion is the expected
	# result rather than a contradiction. `RigidBody3D.sleeping` has no getter
	# property in Godot 4, so it is read off the method that IS exposed.
	print("  can_sleep                 : %s" % str(car.can_sleep))
	print("  freeze / freeze_mode      : %s / %s" % [str(car.freeze), str(car.freeze_mode)])
	print("  is_sleeping()             : %s" % str(car.is_sleeping()))
	print("  mass                      : %.1f kg" % car.mass)
	print("  gravity_scale             : %.3f" % car.gravity_scale)
	# And where the follower is actually aiming, against where the car points.
	var nose: Vector3 = fwd
	var to_aim: Vector3 = follower.last_aim - car.global_position
	to_aim.y = 0.0
	print("  follower aim point       : %s" % str(follower.last_aim.round()))
	print("  car forward               : %s" % str(nose.round()))
	print("  car to aim                : %s  (%.1f m, %+.1f deg off the nose)" % [
		str(to_aim.round()), to_aim.length(),
		rad_to_deg(atan2(to_aim.normalized().cross(nose).y, to_aim.normalized().dot(nose)))])
	print("")
	if int(car.get_contact_count()) == 0:
		print("  Q3 VERDICT: nothing is touching the car. It is not wedged.")
	else:
		print("  Q3 VERDICT: %d bodies in contact - read the names above." % int(car.get_contact_count()))


# ---------------------------------------------------------------- plumbing

func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	return space.intersect_ray(p)


func _describe(hit: Dictionary) -> String:
	if hit.is_empty():
		return "NOTHING"
	return "%s at y=%.3f" % [String((hit["collider"] as Node).name), (hit["position"] as Vector3).y]


func _nearest_street_point(p: Vector3) -> float:
	var pts := _pick(street_name)
	var v := Vector2(p.x, p.z)
	var best := INF
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		best = minf(best, (v - (a + ab * t)).length())
	return best


func _street_length() -> float:
	var pts := _pick(street_name)
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	return total


func _pick(want: String) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_len := 0.0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != want:
			continue
		var p: PackedVector2Array = c["points"]
		var run := 0.0
		for i in p.size() - 1:
			run += p[i].distance_to(p[i + 1])
		if p.size() >= 2 and run > best_len:
			best_len = run
			best = p
	return best