extends Node
##
## The racing AI on a long straight. Does `AIRacer` hold its lane?
##
##   /home/coder/tools/godot --headless --fixed-fps 60 --path . \
##       res://AI/street_ai_probe.tscn -- --street="Hoare Street" --lane=4.25
##
## WHY THIS EXISTS
##
## `./test.sh ai` cannot answer the question t123 asks. It laps a 1578 m closed
## circuit, which curves at every junction, and it was already green and unchanged
## before and after the `LaneFollower` swap - lap 136.7 s, worst road ratio 0.56, 0
## of 932 samples over the kerb. That is a regression guard passing, not evidence
## of anything.
##
## The case the old controller provably cannot handle is a STRAIGHT. t119 measured
## a 1344 m dead straight (95% of Hoare Street in one segment) defeating the
## heading-error + cross-track loop: 3.07 m of drift by t=4.2 s, a 0.05 m clip
## into a prop at 115 km/h, off the road by s=453 and into a building by s=464.
## t121 replaced that loop with `LaneFollower` and the same street went to 99% of
## 1399.5 m with zero contacts.
##
## But t121 drove the PLAYER, on input. This drives the AI, with no input at all,
## on the same street, and reports whether the racing driver holds the lane where
## the old controller could not. It also runs `LaneFollower.verify()` while the AI
## is at the wheel, because those invariants were written against a street probe
## and have never been checked with a car being driven by `AIRacer`.
##
## Note the lane offset is a caller-supplied MEASUREMENT, not something the driver
## works out. `Tools/street_blockers.gd` found the clear band at +2.5 .. +6.0 m
## right of travel on both streets because every prop batch stands on the other
## kerb; `--lane=0` is the centreline, which is the occupied side, and running it
## is the control.

const STREET_NAME := "Hoare Street"
const SPAWN_S := 8.0
const DRIVE_SECONDS := 240.0
const SETTLE_FRAMES := 90
const SPAWN_Y := 0.60
## The measured clear band on both streets, mid-band. Overridable with `--lane=`.
const LANE_DEFAULT := 4.25

var main: Node3D
var racer: AIRacer
var car: Node3D
var follower: LaneFollower
var street_name := STREET_NAME
var lane_offset := LANE_DEFAULT
var fails: Array[String] = []
var notes: Array[String] = []


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--selftest"):
		_projection_selftest()
		get_tree().quit(fails.size())
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--street="):
			street_name = a.substr(9)
		elif a.begins_with("--lane="):
			lane_offset = a.substr(7).to_float()

	print("[ai] booting Game/main.tscn")
	main = load("res://Game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await _wait_for_world()

	var pts := _pick(street_name)
	if pts.size() < 2:
		print("AI PROBE FATAL: no corridor named %s" % street_name)
		get_tree().quit(2)
		return

	# The director is taken out before the measurement, for the same two reasons
	# t119 gave: it writes entrant positions every frame during the countdown, and
	# `main._recover_from_stuck` teleports the car to the nearest road after three
	# seconds wedged. Either would report the recovery instead of the driver.
	var race: Object = main.get("race")
	if race != null:
		race.call("reset")
		notes.append("race reset before the drive -> state is now %s"
			% String(race.call("state_name")))
	await get_tree().process_frame

	# A car of our own, so the measurement is about the driver and not about the
	# race it was built for.
	car = CarBody.new()
	car.name = "AIProbeCar"
	car.spec = CarDB.get_spec("kairo_s13")
	main.add_child(car)

	racer = AIRacer.new()
	racer.name = "AIProbeRacer"
	racer.car = car
	racer.graph = main.graph
	racer.skill = 0.72
	add_child(racer)

	var route: Array = []
	for p in pts:
		route.append(p)
	if not racer.follow_street(route, lane_offset):
		print("AI PROBE FATAL: the driver refused the street line")
		get_tree().quit(2)
		return
	follower = racer.lane()

	# Place the car ON THE DRIVER'S OWN LINE, not on the street polyline the line was
	# built from. Those are not the same thing and the difference is not small:
	# `RacingLine.from_route` resamples, smooths and apex-biases, so the driver's
	# line is 2790 m where the street is 1407.5 m and the two diverge by metres at
	# any given station. Spawning on the street put the car 8.24 m from the lane it
	# was immediately asked to hold, at full lock from the first frame - and it then
	# drove 0.1 m in 240 s while the projection walked 2778 m along the line and
	# every downstream number read as a result.
	var here0: Dictionary = follower.project(follower.aim_at(SPAWN_S, SPAWN_Y))
	var tan0: Vector2 = here0["t"]
	car.reset_to(follower.aim_at(SPAWN_S, SPAWN_Y),
		Vector3(0.0, atan2(-tan0.x, -tan0.y), 0.0))

	var street_len := 0.0
	for i in pts.size() - 1:
		street_len += pts[i].distance_to(pts[i + 1])
	print("[ai] %s: street %.1f m, driver's line %d samples / %.1f m, lane %+.2f m right" % [
		street_name, street_len, racer.line().size(), follower.length(), lane_offset])
	# The line the driver is on and the street it was meant to be are DIFFERENT
	# lengths, and every percentage below is a fraction of the LINE. Reported as a
	# claim, not a footnote, because a "67% of the street" headline computed against
	# the wrong denominator is exactly the kind of number that survives into a
	# summary and outlives the run that produced it.
	_check("the driver's line is the same length as the street",
		absf(follower.length() - street_len) < 1.0,
		"street %.1f m, driver line %.1f m (%.2fx) - every distance below is a fraction of the LINE, not of the street" % [
			street_len, follower.length(), follower.length() / maxf(street_len, 0.001)])

	# The follower's own invariants, asked while the AI is driving rather than
	# from a probe. `verify()` needs a lane_offset to mean anything, and the driver
	# owns the one in force, so read it back rather than passing the request's.
	var v: Dictionary = follower.verify()
	print("[ai] LaneFollower.verify() while the AI drives it: %s" % [
		"OK (aim-point error %.3f m, tangent length error %.4f, steer on straight %.3f, %d straight / %d curving samples)" % [
			float(v["worst_lat_m"]), float(v["worst_tangent_len_err"]),
			float(v["worst_steer_on_straight"]), int(v["straight_samples"]),
			int(v["curving_samples"])]])
	_check("LaneFollower.verify()'s invariants still hold under the AI, not just the probe",
		bool(v["ok"]), "; ".join(v["fails"]) if not bool(v["ok"])
			else "aim points still land on the lane the driver is being asked to hold")

	for f in SETTLE_FRAMES:
		await get_tree().process_frame
	print("[ai] placed on the driver's own line: lat %+.2f m (lane %+.2f), y=%.2f" % [
		float(follower.project(car.global_position)["lat"]), lane_offset, car.global_position.y])
	for f in SETTLE_FRAMES:
		await get_tree().process_frame
	var rl: Dictionary = car.get_wheel("RL")
	print("[ai] settled: y=%.3f rear load=%.0f N contact=%s wheels down=%d" % [
		car.global_position.y, float(rl.get("load", -1.0)), str(rl.get("contact", false)),
		int(car.wheels_on_ground)])
	_check("the car is on the carriageway before the driver is asked to drive",
		float(rl.get("load", -1.0)) > 500.0,
		"rear load %.0f N (a car spawned inside the surface has no tyre load and cannot move)" % float(rl.get("load", -1.0)))

	await _drive()
	_report()
	get_tree().quit(fails.size())


## Does `LaneFollower.project()` find the right place on a line that passes close
## to itself? Pure geometry, no world, no physics, no driving.
##
## THE TEST IS A ROUND TRIP, not a comparison of two implementations.
##
## The first version of this compared the follower's `s` against
## `RacingLine.project`'s `s` and reported 4 of 36 in agreement both before and
## after the window was added - which is what a person debugging that would call a
## fix that did nothing. It was the TEST that was broken: the two use different
## `s` scales. `RacingLine` derives `s` from a `spacing` that includes the closing
## segment, so its `s` grows about 1.38x faster per sample than the follower's
## sum of consecutive distances. Measured, the follower advanced 16.0 m per probe
## where the line advanced 11.6 m - a constant ratio, not a search failure. Put a
## point ON the lane and ask where it is: the follower's answer must be that same
## point, which is scale-free and needs no second implementation to agree with.
##
## The window is what makes the round trip hold at all on a self-approaching line:
## a global nearest-point scan returns the near point on the OTHER leg, which for
## this dogleg is the pair of legs 6 m apart, and the round trip then reports the
## wrong station while every number looks plausible.
func _projection_selftest() -> void:
	print("[selftest] LaneFollower.project on a self-approaching line (dogleg, two legs ~6 m apart)")
	var pts := PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(160, 0), Vector2(200, 8),
		Vector2(200, 60), Vector2(160, 68), Vector2(100, 68), Vector2(0, 68),
		Vector2(-40, 68),
	])
	var lane := LaneFollower.new()
	lane.set_lane(pts, false)
	lane.lane_offset = 0.0
	print("  lane: %d points, %.1f m" % [pts.size(), lane.length()])

	# 1. WINDOWED, walking forward: every station must round-trip to itself.
	#    Probed a whole segment at a time - much coarser than the window - so the
	#    follower is genuinely out of the window at each probe and has to advance.
	var worst := 0.0
	var worst_s := 0.0
	var probes := 0
	var s := 0.0
	while s < lane.length() - 2.0:
		var p: Vector3 = lane.aim_at(s, 0.0)
		var got: float = float(lane.project(p)["s"])
		probes += 1
		if absf(got - s) > worst:
			worst = absf(got - s)
			worst_s = s
		s += 16.0
	print("  windowed round trip     : %d probes, worst %.2f m at s=%.1f" % [probes, worst, worst_s])
	_check("a point on the lane projects back to where it is", worst < 1.0,
		"%d probes walking forward in 16 m steps (wider than the %.0f m window), worst %.2f m at s=%.1f" % [
			probes, 26.0, worst, worst_s])

	# 2. GLOBAL, the control: the same question asked without a seed. On this line
	#    it is expected to FAIL, and it is the whole point of the window.
	var global_lane := LaneFollower.new()
	global_lane.set_lane(pts, false)
	global_lane.lane_offset = 0.0
	# Re-seed it at each station so nothing carries over: this asks only about a
	# single global scan from an arbitrary seed, which is what a fresh follower or
	# a teleporting car does.
	var g_worst := 0.0
	var g_worst_s := 0.0
	s = 0.0
	while s < lane.length() - 2.0:
		var g := LaneFollower.new()
		g.set_lane(pts, false)
		var p2: Vector3 = g.aim_at(s, 0.0)
		var got2: float = float(g.project(p2)["s"])
		if absf(got2 - s) > g_worst:
			g_worst = absf(got2 - s)
			g_worst_s = s
		s += 16.0
	print("  global, fresh follower  : worst %.2f m at s=%.1f  (the control)" % [g_worst, g_worst_s])
	notes.append("global scan from a fresh follower is off by %.1f m on this line; the windowed one is off by %.2f m" % [g_worst, worst])

	# 3. A point that genuinely lives on the OTHER leg must still be found there.
	#    Not by magic: the window is bounded, so this is found only if it is
	#    reachable - which it is not from an arbitrary seed, and should not be.
	var near_second_leg := Vector3(100.0, 0.0, 65.0)
	var seeded := LaneFollower.new()
	seeded.set_lane(pts, false)
	# Seed it ON that leg first, the way a driver that is already there would be.
	seeded.project(near_second_leg)
	var second: float = float(seeded.project(near_second_leg)["s"])
	print("  a point on the second leg, follower already seeded there: s=%.1f" % second)
	_check("a point on the second leg is found on the second leg once seeded there",
		absf(second - 353.6) < 3.0, "s=%.1f, expected about 353.6 m" % second)


func _wait_for_world() -> void:
	var t := 0.0
	while main.world == null and t < 120.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	if main.world == null:
		print("AI PROBE FATAL: world never built")
		get_tree().quit(2)


func _drive() -> void:
	print("")
	print("=".repeat(76))
	print("AI ON A LONG STRAIGHT  -  %s, s=%.1f m, lane %+.2f m right" % [
		street_name, SPAWN_S, lane_offset])
	print("=".repeat(76))
	car.contact_monitor = true
	car.max_contacts_reported = 8

	var origin := SPAWN_S
	var total := follower.length()
	var s := 0.0
	var lat := 0.0
	var t := 0.0
	var top := 0.0
	var off := 0
	var off_worst := 0.0
	var off_worst_time := 0.0
	var off_now := false
	var lat_sum := 0.0
	var lat_n := 0
	var max_abs := 0.0
	var contacts: Array = []
	var recover_time := 0.0
	var arrived := false
	var path := 0.0

	print("[ai] --- go ---")
	while t < DRIVE_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		if dt <= 0.0:
			continue
		t += dt

		var here: Dictionary = follower.project(car.global_position)
		s = float(here["s"])
		lat = float(here["lat"])
		var hw := _half_width(car.global_position)
		lat_sum += absf(lat)
		lat_n += 1
		max_abs = maxf(max_abs, absf(lat))
		path += car.linear_velocity.length() * dt
		top = maxf(top, float(car.speed_kph))
		if racer.mode == AIRacer.Mode.RECOVER:
			recover_time += dt

		var is_off := absf(lat) > hw
		if is_off:
			if not off_now:
				off += 1
				off_now = true
				off_worst_time = 0.0
				print("[ai] OFF ROAD #%d at %.1f s, s=%.1f m, lat=%+.2f m (half width %.2f)" % [
					off, t, s, lat, hw])
			off_worst_time = maxf(off_worst_time, off_worst_time + dt)
			off_worst = maxf(off_worst, absf(lat))
		elif off_now:
			off_now = false
			print("[ai] back on the road at %.1f s, s=%.1f m, off for %.2f s" % [
				t, s, off_worst_time])

		if int(car.get_contact_count()) > 0 and contacts.size() < 24:
			var names: Array = []
			for b in car.get_colliding_bodies():
				names.append(String(b.name))
			if names.size() > 0:
				contacts.append("s=%.1f m  t=%.1f s  lat=%+.2f m  %+.1f km/h  %s" % [
					s, t, lat, float(car.speed_kph), ", ".join(names)])

		if s >= total - SPAWN_S - 0.5:
			arrived = true
			print("[ai] reached the far end at %.1f s, s=%.1f m of %.1f m" % [t, s, total])
			break

	var mean_lat := lat_sum / maxf(float(lat_n), 1.0)
	print("")
	print("AI: distance from s=%.1f      : %.1f m of %.1f m (%.0f%%)" % [
		origin, s - origin, maxf(total - SPAWN_S, 0.001),
		100.0 * (s - origin) / maxf(total - SPAWN_S, 0.001)])
	print("AI: reached s               : %.1f m of %.1f m" % [s, total])
	print("AI: path distance driven    : %.1f m" % path)
	print("AI: top speed               : %.1f km/h" % top)
	print("AI: times off carriageway   : %d (worst %.2f m off, longest %.2f s)" % [
		off, off_worst, off_worst_time])
	print("AI: mean |lat| held         : %.2f m (target %+.2f m right of travel)" % [mean_lat, lane_offset])
	print("AI: peak |lat|              : %.2f m" % max_abs)
	print("AI: peak |steer| demanded   : %.2f of 1.00" % follower.peak_steer)
	print("AI: time in RECOVER         : %.2f s" % recover_time)
	print("AI: scripted mistakes       : %d (skill 0.72)" % racer.errors)
	print("AI: stopped at              : x=%.1f z=%.1f s=%.1f m speed=%.1f km/h" % [
		car.global_position.x, car.global_position.z, s, float(car.speed_kph)])
	print("")
	print("AI: contacts (first %d)" % contacts.size())
	if contacts.is_empty():
		print("  (none)")
	for c in contacts:
		print("  %s" % c)

	_check("the AI held the lane: mean |lat| within 1.0 m of the target", absf(mean_lat - lane_offset) < 1.0,
		"mean |lat| %.2f m against a %+.2f m target" % [mean_lat, lane_offset])
	# Internal consistency, before any of the above is believed.
	#
	# A projection can ADVANCE ALONG THE LINE without the car moving, and then every
	# number downstream reads as a result. This run reported 100% of a 2782 m line
	# at a top speed of 19.9 km/h, which is 5.5 m/s: over 240 s that is at most
	# 1327 m of car travel, so `s` was sliding roughly twice as fast as the car
	# drove and the completion was the projection's, not the driver's. Caught only
	# by dividing one measured number by another.
	var travelled: float = path
	var slide: float = (s - origin) - travelled
	_check("progress along the line is the car actually moving, not the projection sliding",
		absf(slide) < 0.35 * maxf(travelled, 1.0),
		"line says %.1f m travelled, car drove %.1f m of path, difference %.1f m (%.0f%%)" % [
			s - origin, travelled, slide, 100.0 * slide / maxf(travelled, 1.0)])

	_check("the AI reached the far end of the street", arrived,
		"%.1f m of %.1f m from s=%.1f%s" % [s - origin, total - SPAWN_S, origin,
			"" if absf(slide) < 0.35 * maxf(travelled, 1.0) else "  <- DO NOT TRUST, see the projection-slide claim"])


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


func _pose(d: float) -> Vector3:
	var pts := _pick(street_name)
	var acc := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			var q := pts[i].lerp(pts[i + 1], (d - acc) / seg)
			return Vector3(q.x, SPAWN_Y, q.y)
		acc += seg
	var q2 := pts[pts.size() - 1]
	return Vector3(q2.x, SPAWN_Y, q2.y)


func _tangent(pts: PackedVector2Array, d: float) -> Vector2:
	var acc := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			return (pts[i + 1] - pts[i]) / seg
		acc += seg
	return (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()


func _check(claim: String, ok: bool, detail: String) -> void:
	if not ok:
		fails.append("%s - %s" % [claim, detail])
	print("  [%s] %s\n         %s" % ["PASS" if ok else "FAIL", claim, detail])


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
	print("AI_HOLDS_LANE=%s" % ("YES" if fails.is_empty() else "NO"))
	print("=" .repeat(76))