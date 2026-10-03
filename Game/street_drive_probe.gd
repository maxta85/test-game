extends Node
##
## Street drive measurement, using `Systems/race/lane_follower.gd`.
##
##   /home/coder/tools/godot --headless --fixed-fps 60 --path . \
##       res://Game/street_drive_probe.tscn -- --drive --street="Hoare Street"
##
## WHY THIS LIVES IN `Game/` AND NOT IN `Tools/`
##
## t121's scope is `Systems/race/**` and `Game/**` only, so the follower it adds
## cannot be measured by the tool that measured the thing it replaces
## (`Tools/playable_probe.gd` keeps its own hard-coded controller and is out of
## scope to change). The measurement therefore has to sit next to the controller it
## exercises, and `Game/` is where the entry point lives, which is also where a
## drivable boot lives. Its telemetry lines are byte-for-byte the ones t119 produced
## so the before and after are comparable by eye and not by paraphrase.
##
## TWO EXPERIMENTS, DELIBERATELY SEPARATE
##
## The drive here is NOT a race. `RaceDirector.tick` writes `entrants[i].position`
## every frame during the countdown, which teleports the car through the suspension
## integrators, and `main._recover_from_stuck` teleports it back to the nearest road
## after three seconds wedged. Either would report the recovery instead of the
## street. The director is therefore reset to idle first, and that is stated in the
## output rather than assumed.
##
## Driving is on INPUT ALONE - `Input.action_press` / `action_release`, never a car
## method. A harness that writes `car.throttle` and `car.steer` directly proves the
## physics and proves nothing about whether a person can play, because it bypasses
## the input map, `PlayerController` and the action strengths entirely.

const STREET_NAME := "Hoare Street"
const SPAWN_S := 8.0
const DRIVE_SECONDS := 240.0
const SETTLE_FRAMES := 90
## Spawn height above the corridor polyline. Not 0: the polyline is a centreline
## with no idea where the road surface is, and a car spawned inside the surface has
## zero tyre load, which `TyreModel.longitudinal()` answers with zero thrust.
const SPAWN_Y := 0.60
## Default lane, metres right of travel. The measured clear band on both streets
## run so far is +2.5 .. +6.0 m right of travel (`Tools/street_blockers.gd`, on the
## same handedness); 4.25 is the middle of it.
const LANE_DEFAULT := 4.25
## The longest run of that name in the map data. `OSMLayout.anchor()` is NOT a
## substitute: it scores by centrality with the length worth 0.01 m per metre, so it
## returns a different and usually much shorter street, and every number here would
## be about a road nobody looked at.
const GROUND := ["RoadCollision", "TerrainCollision", "OuterFloor"]

var main: Node3D
var follower: LaneFollower
var street_name := STREET_NAME
var lane_offset := LANE_DEFAULT
var fails: Array[String] = []
var notes: Array[String] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--street="):
			street_name = a.substr(9)
		elif a.begins_with("--lane="):
			lane_offset = a.substr(7).to_float()

	print("[drive] booting Game/main.tscn with --drive")
	main = load("res://Game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await _wait_for_world()

	var picked := _pick(street_name)
	if picked.is_empty():
		print("DRIVE FATAL: no corridor named %s" % street_name)
		get_tree().quit(2)
		return

	follower = LaneFollower.new()
	follower.set_lane(picked)
	follower.lane_offset = lane_offset
	print("[drive] %s: %.1f m of lane, target %+.2f m right of travel" % [
		street_name, follower.length(), lane_offset])

	# The follower's own geometry, checked before it is asked to drive anything.
	# A controller with a broken aim point does not look broken, it looks like a
	# driver having a bad time, so this runs first and is a claim like any other.
	var v: Dictionary = follower.verify()
	print("[drive] follower self-check: %s" % [
		"OK (worst aim-point error %.3f m, worst tangent length error %.4f, worst steer on straight %.3f)"
			% [float(v["worst_lat_m"]), float(v["worst_tangent_len_err"]),
				float(v["worst_steer_on_straight"])]])
	print("[drive]   %d straight samples, %d curving (a cornering lane is SUPPOSED to steer)" % [
		int(v["straight_samples"]), int(v["curving_samples"])])
	print("[drive]   straight-steer bound %.2f of lock, lane-turn tolerance %.3f rad" % [
		float(v["straight_steer_bound"]), float(v["straight_tol_rad"])])
	_check("the follower's aim point is on the lane it is supposed to hold",
		bool(v["ok"]), "; ".join(v["fails"]) if not bool(v["ok"])
			else "every sampled station's aim point projects back to %+.2f m right of travel" % lane_offset)

	# Two separate reasons to take the director out, both about not letting the
	# host move the car under the measurement.
	var race: Object = main.get("race")
	if race != null:
		race.call("reset")
		notes.append("race reset before the drive -> state is now %s"
			% String(race.call("state_name")))
	await get_tree().process_frame

	await _drive()
	_report()
	get_tree().quit(fails.size())


func _wait_for_world() -> void:
	var t := 0.0
	while main.world == null and t < 120.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	if main.world == null:
		print("DRIVE FATAL: world never built")
		get_tree().quit(2)


func _drive() -> void:
	print("")
	print("=".repeat(76))
	print("B: THE DRIVE  -  %s, s=%.1f m to the far end, INPUT ONLY" % [street_name, SPAWN_S])
	print("=".repeat(76))
	print("B: controller              : LaneFollower (pure pursuit + yaw damping)")
	var tl: Dictionary = follower.telemetry()
	for k in ["aim_gain", "yaw_damp", "lookahead_min_m", "lookahead_max_m"]:
		print("B:   %-20s: %s" % [k, str(tl[k])])

	var car: Node3D = main.player_car
	if car == null:
		_fail("the drive ran at all", "no player_car")
		return

	var pose := _pose(SPAWN_S)
	var dir: Vector2 = pose["t"]
	# ON THE LANE, not on the centreline. The follower is about to be asked to hold
	# a lane `lane_offset` metres to the right of travel, and starting the car
	# 4.25 m to the left of it means the very first command is a full-lock lunge
	# across the road: measured, that left the carriageway 2.4 s after the start.
	# The aim angle is now bounded as well, but the transient is not a property of
	# the controller, it is a property of dropping a car in the wrong place, and a
	# measurement of a controller should not start with a fault of its own.
	var spawn: Vector3 = follower.aim_at(SPAWN_S, SPAWN_Y)
	var spawn_dir := Vector2(dir.x, dir.y)
	if (Vector2(spawn.x, spawn.z) - Vector2(pose["pos"].x, pose["pos"].z)).length() > 0.5:
		# `aim_at` already offset the point, so face the same way the lane runs.
		spawn_dir = dir
	car.reset_to(spawn, Vector3(0.0, atan2(-spawn_dir.x, -spawn_dir.y), 0.0))
	car.contact_monitor = true
	car.max_contacts_reported = 8
	var here0: Dictionary = follower.project(spawn)
	print("[drive] placed at %.1f, %.1f, lat %+.2f m (lane target %+.2f right), facing %.3f, %.3f" % [
		spawn.x, spawn.z, float(here0["lat"]), lane_offset, dir.x, dir.y])
	for f in SETTLE_FRAMES:
		await get_tree().process_frame
	var rl: Dictionary = car.get_wheel("RL")
	var load_n := float(rl.get("load", -1.0))
	print("[drive] settled: y=%.3f rear load=%.0f N contact=%s" % [
		car.global_position.y, load_n, str(rl.get("contact", false))])
	_check("the suspension loaded on the carriageway", load_n > 500.0,
		"rear load %.0f N (a tyre model returns 0 thrust below 0 N, so a car spawned"
			% load_n + " inside the road surface can never move)")

	var origin := SPAWN_S
	var s := 0.0
	var lat := 0.0
	var t := 0.0
	var top := 0.0
	var off := 0
	var off_worst := 0.0
	var off_time := 0.0
	var off_worst_time := 0.0
	var off_now := false
	var max_lat := 0.0
	var contacts: Array = []
	var path := 0.0
	var arrived := false
	var lat_sum := 0.0
	var lat_n := 0

	_hold({})
	print("[drive] --- go ---")
	while t < DRIVE_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		if dt <= 0.0:
			continue
		t += dt

		var here: Dictionary = follower.project(car.global_position)
		s = float(here["s"])
		lat = float(here["lat"])
		# `lat` here is positive RIGHT of travel, the sign `LaneFollower.lane_offset`
		# is measured on. The telemetry below reports it on the SAME axis and says
		# so, because t119's probe used the opposite one and two reports that
		# disagree about a sign are worse than one that never had it.
		var hw := _half_width(car.global_position)

		var steer := follower.steer_for(car.global_position, -car.global_transform.basis.z,
			car.angular_velocity.y, float(car.speed_mps))
		_hold({"throttle": 1.0, "steer": steer})
		max_lat = maxf(max_lat, absf(lat))
		lat_sum += absf(lat)
		lat_n += 1

		var is_off := absf(lat) > hw
		if is_off:
			if not off_now:
				off += 1
				off_now = true
				off_time = 0.0
				print("[drive] OFF ROAD #%d at %.1f s, s=%.1f m, lat=%+.2f m (half width %.2f)" % [
					off, t, s, lat, hw])
			off_time += dt
			off_worst_time = maxf(off_worst_time, off_time)
			off_worst = maxf(off_worst, absf(lat))
		elif off_now:
			off_now = false
			print("[drive] back on the road at %.1f s, s=%.1f m, off for %.2f s" % [
				t, s, off_time])

		path += car.linear_velocity.length() * dt
		top = maxf(top, float(car.speed_kph))

		if int(car.get_contact_count()) > 0 and contacts.size() < 24:
			var names: Array = []
			for b in car.get_colliding_bodies():
				names.append(String(b.name))
			if names.size() > 0:
				contacts.append("s=%.1f m  t=%.1f s  lat=%+.2f m  %+.1f km/h  %s" % [
					s, t, lat, float(car.speed_kph), ", ".join(names)])

		if s >= follower.length() - SPAWN_S - 0.5:
			arrived = true
			print("[drive] reached the far end at %.1f s, s=%.1f m of %.1f m" % [
				t, s, follower.length()])
			break
	_hold({})
	var total := follower.length()
	# Divided by the sample count, not by t/delta: get_process_delta_time() is the
	# CURRENT frame's delta, so using it as a divisor makes the mean depend on which
	# frame the loop happened to stop on.
	var mean_abs_lat := lat_sum / maxf(float(lat_n), 1.0)

	print("")
	print("B: distance from s=%.1f      : %.1f m of %.1f m (%.0f%%)" % [
		origin, s - origin, maxf(total - SPAWN_S, 0.001),
		100.0 * (s - origin) / maxf(total - SPAWN_S, 0.001)])
	print("B: reached s               : %.1f m of %.1f m of centreline" % [s, total])
	print("B: path distance driven    : %.1f m" % path)
	print("B: top speed               : %.1f km/h" % top)
	print("B: times off carriageway   : %d (worst %.2f m off the centreline, %.2f s)" % [
		off, off_worst, off_worst_time])
	print("B: peak lateral offset     : %.2f m" % max_lat)
	print("B: peak |steer| demanded   : %.2f of 1.00%s" % [
		follower.peak_steer, "  <-- SATURATED" if follower.peak_steer >= 0.999 else ""])
	print("B: mean |lat| held         : %.2f m off the centreline (target %+.2f m right)" % [
		mean_abs_lat, lane_offset])
	print("B: stopped at              : x=%.1f z=%.1f s=%.1f m speed=%.1f km/h" % [
		car.global_position.x, car.global_position.z, s, float(car.speed_kph)])
	print("")
	print("B: contacts (first %d)" % contacts.size())
	if contacts.is_empty():
		print("  (none)")
	for c in contacts:
		print("  %s" % c)

	_check("the car reached the far end of the street", arrived,
		"%.1f m of %.1f m from s=%.1f" % [s - origin, total - SPAWN_S, origin])


## Press and release real input actions. The whole surface the probe is allowed to
## use: if a car does not move under it, a person holding W would not move it.
func _hold(actions: Dictionary) -> void:
	for k in ["throttle", "steer_left", "steer_right", "handbrake", "brake"]:
		if Input.is_action_pressed(k):
			Input.action_release(k)
	if float(actions.get("throttle", 0.0)) > 0.0:
		Input.action_press("throttle", float(actions["throttle"]))
	if float(actions.get("steer", 0.0)) < 0.0:
		Input.action_press("steer_right", absf(float(actions["steer"])))
	if float(actions.get("steer", 0.0)) > 0.0:
		Input.action_press("steer_left", absf(float(actions["steer"])))


func _pose(d: float) -> Dictionary:
	var acc := 0.0
	var p := follower.pts
	for i in p.size() - 1:
		var seg := p[i].distance_to(p[i + 1])
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			var u := (d - acc) / seg
			var q := p[i].lerp(p[i + 1], u)
			return {"pos": Vector3(q.x, SPAWN_Y, q.y), "t": (p[i + 1] - p[i]) / seg}
		acc += seg
	var q2 := p[p.size() - 1]
	return {"pos": Vector3(q2.x, SPAWN_Y, q2.y),
		"t": (p[p.size() - 1] - p[p.size() - 2]).normalized()}


func _half_width(p: Vector3) -> float:
	var graph: RoadGraph = main.graph
	if graph == null:
		return 7.0
	var near: Dictionary = graph.nearest_road(p)
	var eid := int(near["edge"])
	if eid < 0:
		return 7.0
	return float(graph.edges[eid]["width"]) * 0.5


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


func _check(claim: String, ok: bool, detail: String) -> void:
	if not ok:
		fails.append("%s - %s" % [claim, detail])
	print("  [%s] %s\n         %s" % ["PASS" if ok else "FAIL", claim, detail])


func _fail(claim: String, detail: String) -> void:
	_check(claim, false, detail)


func _report() -> void:
	print("")
	print("=" .repeat(76))
	print("CLAIMS (%d failed)" % fails.size())
	print("=" .repeat(76))
	for f in fails:
		print("  FAIL  %s" % f)
	for n in notes:
		print("  note  %s" % n)
	print("")
	print("PLAYABLE=%s" % ("YES" if fails.is_empty() else "NO"))
	print("=" .repeat(76))