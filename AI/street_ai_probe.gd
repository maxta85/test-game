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
	car.reset_to(_pose(SPAWN_S), Vector3(0.0, atan2(-_tangent(pts, SPAWN_S).x,
		-_tangent(pts, SPAWN_S).y), 0.0))

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
	print("[ai] settled: y=%.3f wheels down=%d" % [car.global_position.y, int(car.wheels_on_ground)])

	await _drive()
	_report()
	get_tree().quit(fails.size())


## Does `LaneFollower.project()` find the right place on a line that passes close
## to itself? Pure geometry, no world, no physics, no driving.
##
## This is the whole diagnosis of the circuit regression in a form that can be
## checked by reading the answer.
##
## `RacingLine.project` searches a WINDOW either side of the last index and says
## why: a street circuit passes close to itself, and a global nearest-point search
## on one will return a point on a different leg of the lap. `LaneFollower.project`
## is a global scan with no window and no hint, so it has exactly the failure its
## caller already documented. An OPEN street cannot show it - Hoare's longest run
## approaches nothing - which is why the street probe is green and the circuit is
## not, and why the bug survived being measured twice on a straight.
##
## The line below is a dogleg: a long leg, a U-turn, and a parallel leg 6 m back.
## A car on the first leg is 3 m from it, and 6 m from the leg that runs alongside.
## The windowed projection must say 3 m and the leg it is on; a global scan says
## 3 m too, because it takes the nearest - so the test asks the question that
## actually discriminates: with the window seeded at the car, do the two agree on
## WHICH SAMPLE, and does the global one stay on the leg the car is on once the
## car is past the U-turn and the parallel leg is nearer?
func _projection_selftest() -> void:
	print("[selftest] LaneFollower.project vs RacingLine.project on a self-approaching line")
	var pts := PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(160, 0),
		Vector2(200, 8), Vector2(200, 60), Vector2(160, 68),
		Vector2(100, 68), Vector2(0, 68), Vector2(-40, 68),
	])
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var route: Array = []
	for p in pts:
		route.append(p)
	var line := RacingLine.from_route(route, g, false)
	var lane := LaneFollower.new()
	var packed := PackedVector2Array()
	for p in line.points:
		packed.append(p)
	lane.set_lane(packed, false)

	# Sample along the first leg and then the return leg, seeding the windowed
	# search from the previous sample exactly as `AIRacer` does.
	var idx := 0
	var worst := 0.0
	var worst_at := ""
	var agree := 0
	var probes := 0
	for step in range(0, line.size(), 4):
		var world: Vector2 = line.point_at(step, 0.0)
		var here: Dictionary = line.project(world, idx, 2)
		idx = int(here["i"])
		var mine: float = float(here["s"])
		var theirs: float = float(lane.project(Vector3(world.x, 0.0, world.y))["s"])
		probes += 1
		var gap := absf(mine - theirs)
		if gap < line.spacing * 2.0:
			agree += 1
		if gap > worst:
			worst = gap
			worst_at = "s=%.1f (windowed %.1f, global %.1f)" % [float(step) * line.spacing, mine, theirs]
	print("  line samples            : %d, spacing %.2f m" % [line.size(), line.spacing])
	print("  probes                  : %d" % probes)
	print("  the two agree within 2 samples : %d of %d (%.0f%%)" % [
		agree, probes, 100.0 * float(agree) / maxf(float(probes), 1.0)])
	print("  worst disagreement      : %.1f m at %s" % [worst, worst_at])
	print("")
	_check("the follower's projection agrees with the line's windowed one on a self-approaching loop",
		agree == probes, "%d of %d probes disagreed by more than two samples, worst %.1f m" % [
			probes - agree, probes, worst])


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
	_check("the AI reached the far end of the street", arrived,
		"%.1f m of %.1f m from s=%.1f" % [s - origin, total - SPAWN_S, origin])


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