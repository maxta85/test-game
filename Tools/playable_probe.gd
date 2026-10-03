extends Node
##
## Human-playability probe: can a person drive this street?
##
##   /home/coder/tools/godot --headless --fixed-fps 60 --path . \
##       res://Tools/playable_probe.tscn -- --drive --street="Aumuller Street"
##
## TWO EXPERIMENTS, DELIBERATELY SEPARATE, AND THE SEPARATION IS THE POINT.
##
## A: THE BOOT. Instantiate the real entry point (`Game/main.tscn`) with the
##    `--drive` flag and measure what the player is actually left looking at:
##    is a menu over the street, is there a chase camera, and is the road ahead
##    inside the frame. These are the claims that are cheap to assert and easy to
##    get wrong, because a chase camera that is not `current` renders nothing and
##    one that is pointed the wrong way renders the inside of the car - and both
##    look identical in the source.
##
##    `--drive` must be on THIS process's own command line, not handed to the
##    child. `Game/main.gd` reads `OS.get_cmdline_user_args()`, which is a
##    process-wide list a child does not inherit: a probe that instantiates
##    main.tscn and tucks `--drive` into its own args would measure the DEFAULT
##    boot wearing the flag's name - which is exactly what the first run of this
##    probe did, and it reported a menu wall on a drivable build.
##
## B: THE DRIVE. Put the car at the near end of the anchor street and drive it to
##    the far end on INPUT ALONE - `Input.action_press` / `action_release`, never
##    a car method. A previous harness set `car.throttle` and `car.steer`
##    directly, which proves the physics works and proves nothing at all about
##    whether a human can play: the input map, `PlayerController` and the action
##    strengths are the whole chain, and driving the car bypasses every one of
##    them.
##
## A and B are not the same experiment. A car can be perfectly drivable from the
## grid and the street still be blocked 47 m in, which is exactly the state this
## project is in. Reporting one verdict for both would hide that.
##
## Steering is assisted, and the demand it places on the car is reported as
## `peak |steer|`. The assist cannot create tyre force, drive torque or ground
## contact, so it cannot make an undrivable car drivable - but a demand pinned at
## 1.00 means the assist is saturated and the driver is the thing being measured,
## not the road.

const OUT_DIR := "res://shots"
const STREET_NAME := "Aumuller Street"
const SPAWN_S := 8.0
const DRIVE_SECONDS := 240.0
const SETTLE_FRAMES := 90
## 0.30 m above the tarmac. The polyline is a centreline with no idea where the
## road surface is, so the car has to start above the collider and settle onto it;
## spawned inside the surface the tyre load is zero and the car free-spins.
const SPAWN_Y := 0.60
## Proportional steering. Disclosed, not hidden: see the file header.
const HEAD_GAIN := 2.4
## Below this yaw rate the heading term is faded out, because at a standstill any
## integral of it is noise and dividing by it would be a division by zero.
const YAW_FLOOR := 0.13
## Steer per metre of cross-track error. Overridable with `--gain=`.
##
## 0.25 is not a tuning knob anyone should turn, and that was measured rather than
## assumed: at 0.25 the loop DIVERGES. Aumuller's polyline is THREE points over
## 824.5 m, so the line being tracked is a chord and cross-track error swings hard
## as the car moves along it; 0.25 steer per metre is enough lag to turn that into
## a growing oscillation. The run at 0.25 finished 44.04 m off the centreline,
## mean |lat| 28.90 m, and stopped at s=420 m of 824.5 m - worse than the 0.10 run
## it was meant to improve on. 0.10 reaches the far end; 0.25 does not.
const LAT_GAIN := 0.10
## Where the driver holds across the carriageway, in metres on THIS file's `lat`
## axis. Overridable with `--lane=<m>`, and the default is the clear side of the
## street, derived from `Tools/street_blockers.gd` rather than chosen by feel:
##
##   survey offset +2.5 .. +6.0 m   a whole 1.90 m car fits at every station
##   survey offset -0.5 .. +2.0 m   something is in the way at some station
##
## and `survey offset = -this file's lat` (the two tools walk the polyline with
## opposite handedness, which is exactly the sort of thing that makes two
## measurements of one street disagree), so the clear band is lat -6.0 .. -2.5 and
## its middle is -4.25.
##
## Running BOTH is the point. A centreline tracker (`--lane=0`) drives into every
## one of the street's obstructions, because a pure pursuit controller aims at the
## middle of a road and this road's middle is not where the free space is.
const LANE_DEFAULT := -4.25
## Frames to let the chase camera converge before measuring it.
const CAMERA_SETTLE_FRAMES := 150

var main: Node3D
var pts := PackedVector2Array()
var total := 0.0
var street_name := STREET_NAME
var lane_offset := LANE_DEFAULT
var lat_gain := LAT_GAIN

var fails: Array[String] = []
var notes: Array[String] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--street="):
			street_name = a.substr(9)
		elif a.begins_with("--lane="):
			lane_offset = a.substr(7).to_float()
		elif a.begins_with("--gain="):
			lat_gain = a.substr(7).to_float()

	print("[probe] booting Game/main.tscn with --drive")
	main = load("res://Game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await _wait_for_world()

	var picked := _pick(street_name)
	if picked.is_empty():
		print("PROBE FATAL: no corridor named %s" % street_name)
		get_tree().quit(2)
		return
	pts = picked
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	print("[probe] %s: %.1f m of centreline" % [street_name, total])

	await _experiment_a_the_boot()
	await _experiment_b_the_drive()
	_report()
	get_tree().quit(fails.size())


func _wait_for_world() -> void:
	var t := 0.0
	while main.world == null and t < 120.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	if main.world == null:
		print("PROBE FATAL: world never built")
		get_tree().quit(2)


# =============================================================== A: the boot

## The claims a player makes about the game the moment it opens. Each one is a
## measurement with its own number, not a check that a boolean is still false.
func _experiment_a_the_boot() -> void:
	print("")
	print("=" .repeat(76))
	print("A: THE BOOT  -  what the player is left looking at")
	print("=" .repeat(76))

	# Let the lights go out and the camera catch up BEFORE measuring the camera.
	#
	# `ChaseCamera` starts at the car's own position (`Game/main.gd` builds it at
	# `player_car.position`) and eases out to its offset over about 30 frames, and
	# the director puts the car on the grid a frame or two after the race starts, so
	# the car moves again after that. Measuring earlier reports a camera sitting
	# exactly on the car looking wherever the default transform points - which is a
	# true reading of that instant and a completely false reading of the camera.
	# A harness that measures a settling rig concludes the rig is broken.
	var race_early: Object = main.get("race")
	var guard := 0.0
	while race_early != null and String(race_early.call("state_name")) != "racing" \
			and guard < 30.0:
		await get_tree().process_frame
		guard += get_process_delta_time()
	await _settle_camera()

	var menus: Node = main.get("menus")
	var hud: Node = main.get("hud")
	var race: Object = main.get("race")
	var car: Node3D = main.get("player_car")

	# The menu wall. `menu_visible()` is the flow's own answer, so this is not a
	# proxy: it reads the same state the screens themselves read.
	var wall: bool = false if menus == null else bool(menus.call("menu_visible"))
	_check("no menu wall in front of the street", not wall,
		"MenuFlow.menu_visible()=%s, screen=%s" % [
			str(wall), str(menus.call("screen_name")) if menus != null else "n/a"])
	_check("the HUD is up where the menu was", hud != null and bool(hud.visible),
		"RaceHUD.visible=%s" % str(hud.visible if hud != null else "n/a"))

	var state := "n/a" if race == null else String(race.call("state_name"))
	_check("a race is under way", state == "countdown" or state == "racing",
		"RaceDirector.state_name()=%s" % state)

	if car == null:
		_fail("the player has a car", "player_car is null")
		return
	_check("the player has a car", true,
		"%s (%s) at %s" % [car.name, car.get("spec").id, str(car.global_position.round())])

	# The camera. `Camera3D.current` defaults to FALSE in Godot 4, so a chase
	# camera that is built, parented, tracked and given a transform every frame
	# still renders nothing if nobody promoted it. The viewport's own answer is
	# the only one that counts, so it is asked.
	var vp := get_viewport()
	var live: Camera3D = vp.get_camera_3d()
	_check("there is a camera the viewport is actually rendering from", live != null,
		"Viewport.get_camera_3d()=%s" % str(live))
	if live == null:
		return
	# `is_ancestor_of`, not `is_descendant_of`: the question is whether the camera
	# the viewport picked hangs off the ChaseCamera node, and Node spells that
	# direction as `ancestor.is_ancestor_of(descendant)`. There is no
	# `is_descendant_of` on Node, so asking for it is a runtime error.
	_check("and it is the chase camera's own",
		(main.get("camera") as Node).is_ancestor_of(live),
		"live camera parent=%s, ChaseCamera holds %d child camera(s)" % [
			live.get_parent().name, (main.get("camera") as Node).get_child_count()])

	var holder: Node3D = main.get("camera")
	var fwd: Vector3 = -car.global_transform.basis.z
	var back := (live.global_position - car.global_position).dot(fwd)
	_check("the camera is BEHIND the car, not in it", back < -2.0,
		"%.2f m behind along the car's own forward axis (CHASE wants about -6.4)" % back)
	var gap := live.global_position.distance_to(car.global_position)
	_check("the camera is outside the car body", gap > 3.0,
		"%.2f m from the car centre (a 4.4 m long car needs more than 3)" % gap)

	var looking: float = (-live.global_transform.basis.z).dot(fwd)
	_check("the camera looks the way the car is going", looking > 0.5,
		"camera forward . car forward = %+.3f" % looking)

	# The claim that actually matters, in the only form that can be measured: is a
	# piece of the ROAD AHEAD inside the frame? Eyeballing a screenshot cannot tell
	# a road from a wall; unprojecting a point in front of the car and asking where
	# it lands on screen can.
	#
	# The point is taken from the CAR's own forward axis, not from the anchor
	# street's tangent. At this moment the car is on the race grid, which is on a
	# different part of the map from the anchor street - an earlier version of this
	# check built the point from `OSMLayout` and correctly reported "the point is
	# BEHIND the camera", because the anchor street is most of a kilometre away.
	# A correct measurement of the wrong point is still the wrong measurement.
	var ahead: Vector3 = car.global_position + fwd * 30.0
	ahead.y = LookDev.TARMAC_Y
	# And it has to be road rather than sky: a downward ray at that point has to
	# find ground, or the camera is aimed at the void.
	var space := car.get_world_3d().direct_space_state
	var rp := PhysicsRayQueryParameters3D.create(ahead + Vector3(0.0, 10.0, 0.0),
		ahead - Vector3(0.0, 10.0, 0.0))
	var hit := space.intersect_ray(rp)
	_check("there is road 30 m in front of the car", not hit.is_empty(),
		"downward ray hit %s at y=%.3f" % [
			"nothing" if hit.is_empty() else String((hit["collider"] as Node).name),
			(hit["position"] as Vector3).y if not hit.is_empty() else -99.0])

	var sz := vp.get_visible_rect().size
	var on_screen := false
	var why := "no unproject"
	if live.is_position_behind(ahead):
		why = "the point is BEHIND the camera"
	else:
		var uv := live.unproject_position(ahead)
		# The centre of the frame is what "looking down the road" means; a point in
		# the corner of the viewport is inside the frame and still means the camera
		# is not pointing where the car is going, so the centre is the test.
		var cx := sz.x * 0.5
		var cy := sz.y * 0.5
		var off := Vector2(uv.x - cx, uv.y - cy).length()
		var diag := sz.length()
		on_screen = off < diag * 0.35
		why = ("unprojected to (%.0f, %.0f), frame centre is (%.0f, %.0f): %.1f%% of "
			+ "the diagonal off centre (the limit is 35%)") % [
			uv.x, uv.y, cx, cy, 100.0 * off / maxf(diag, 1.0)]
	_check("the road ahead is at the CENTRE of the frame, not in a corner", on_screen, why)


## Frames until the chase camera stops moving, or the cap.
##
## Convergence, not a fixed wait, is the honest test: the camera's position eases
## toward its wanted offset every frame and the car's speed is what decides how
## long that takes.
func _settle_camera() -> void:
	var holder: Node3D = main.get("camera")
	if holder == null:
		return
	var last := holder.global_position
	var still := 0
	for i in CAMERA_SETTLE_FRAMES:
		await get_tree().process_frame
		if holder.global_position.distance_to(last) < 0.002:
			still += 1
			if still >= 10:
				print("[probe] camera settled after %d frames at %s" % [
					i, str(holder.global_position.round())])
				return
		else:
			still = 0
		last = holder.global_position
	print("[probe] camera did NOT settle in %d frames; last at %s" % [
		CAMERA_SETTLE_FRAMES, str(holder.global_position.round())])


# ============================================================== B: the drive

## The anchor street, near end to far end, on input alone.
func _experiment_b_the_drive() -> void:
	print("")
	print("=" .repeat(76))
	print("B: THE DRIVE  -  %s, s=%.1f m to the far end, INPUT ONLY" % [street_name, SPAWN_S])
	print("=" .repeat(76))
	print("B: driving line target = %+.2f m off the centreline on this file's lat axis" % lane_offset)
	print("B: lateral gain = %.2f steer per metre of cross-track error" % lat_gain)

	var car: Node3D = main.player_car
	if car == null:
		_fail("the drive ran at all", "no player_car")
		return

	# Take the director out of the run before measuring the street.
	#
	# Two separate reasons, both about not letting the host move the car under
	# the measurement. `RaceDirector.tick` writes `entrants[i].position` directly
	# every frame during the countdown, which teleports the car through the
	# suspension integrators; and `main._recover_from_stuck` teleports it back to
	# the nearest road after three seconds wedged. A recovery that fires mid-run
	# would report as "the street drove fine, the car came back by itself", which
	# is exactly the answer this probe exists not to give.
	var race: Object = main.get("race")
	if race != null:
		# `RaceDirector.reset()` returns void, so nothing may be read off its return
		# value - `String(null)` is a runtime error, not an empty string.
		race.call("reset")
		notes.append("race reset before the street drive -> state is now %s"
			% String(race.call("state_name")))
	await get_tree().process_frame

	var pose := _pose(SPAWN_S)
	var dir: Vector2 = pose["t"]
	car.reset_to(pose["pos"], Vector3(0.0, atan2(-dir.x, -dir.y), 0.0))
	# RigidBody3D reports nothing about collisions unless asked, and
	# max_contacts_reported defaults to zero.
	car.contact_monitor = true
	car.max_contacts_reported = 8
	print("[probe] placed at %.1f, %.1f facing %.3f, %.3f" % [
		pose["pos"].x, pose["pos"].z, dir.x, dir.y])
	for f in SETTLE_FRAMES:
		await get_tree().process_frame
	var rl: Dictionary = car.get_wheel("RL")
	print("[probe] settled: y=%.3f rear load=%.0f N contact=%s" % [
		car.global_position.y, float(rl.get("load", -1.0)), str(rl.get("contact", false))])
	var load_n := float(rl.get("load", -1.0))
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
	var max_steer := 0.0
	var contacts: Array = []
	var path := 0.0
	var arrived := false
	var lat_sum := 0.0
	var lat_n := 0

	_hold({})
	print("[probe] --- go ---")
	while t < DRIVE_SECONDS:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		if dt <= 0.0:
			continue
		t += dt

		var here := _at(car.global_position)
		s = float(here["s"])
		lat = float(here["lat"])
		var tan: Vector2 = here["t"]
		var hw := _half_width(car.global_position)

		# A proportional controller on the SAME throttle/brake/steer surface a
		# human uses, fed in through Input. `Tools/playtest.gd` reaches past this
		# by writing `car.throttle` and `car.steer` directly; that proves the
		# physics and nothing about the input path, which is the thing that is
		# actually being asked here.
		#
		# The lateral term steers toward LANE_OFFSET, not toward 0. Every
		# obstruction on this street stands within about 1.5 m of one kerb, so a
		# controller aiming at the centreline drives into all of them; the sign of
		# the offset is read off the survey (`Tools/street_blockers.gd`) rather than
		# guessed, because the two tools use opposite handedness on the same axis and
		# `A_PROBE_LANE` records which way this run went.
		var err := _head_err(-car.global_transform.basis.z, tan)
		var yaw: float = car.angular_velocity.y
		var eff := err if absf(yaw) > YAW_FLOOR else err * minf(1.0, absf(yaw) / YAW_FLOOR)
		var lat_err := lat - lane_offset
		var steer := clampf(HEAD_GAIN * eff + lat_gain * lat_err, -1.0, 1.0)
		_hold({"throttle": 1.0, "steer": steer})
		max_steer = maxf(max_steer, absf(steer))
		max_lat = maxf(max_lat, absf(lat))
		lat_sum += absf(lat)
		lat_n += 1

		var is_off := absf(lat) > hw
		if is_off:
			if not off_now:
				off += 1
				off_now = true
				off_time = 0.0
				print("[probe] OFF ROAD #%d at %.1f s, s=%.1f m, lat=%+.2f m (half width %.2f)" % [
					off, t, s, lat, hw])
			off_time += dt
			off_worst_time = maxf(off_worst_time, off_time)
			off_worst = maxf(off_worst, absf(lat))
		elif off_now:
			off_now = false
			print("[probe] back on the road at %.1f s, s=%.1f m, off for %.2f s" % [
				t, s, off_time])

		path += car.linear_velocity.length() * dt
		top = maxf(top, float(car.get("speed_kph")))

		if int(car.get_contact_count()) > 0 and contacts.size() < 24:
			var names: Array = []
			for b in car.get_colliding_bodies():
				names.append(String(b.name))
			if names.size() > 0:
				contacts.append("s=%.1f m  t=%.1f s  lat=%+.2f m  %+.1f km/h  %s" % [
					s, t, lat, float(car.get("speed_kph")), ", ".join(names)])

		if s >= total - SPAWN_S - 0.5:
			arrived = true
			print("[probe] reached the far end at %.1f s, s=%.1f m of %.1f m" % [t, s, total])
			break
	_hold({})
	# Divided by the sample count, not by t / delta: get_process_delta_time() is
	# the CURRENT frame's delta, so using it as a divisor makes the mean depend on
	# which frame the loop happened to stop on.
	var mean_abs_lat := lat_sum / maxf(float(lat_n), 1.0)

	print("")
	print("B: distance from s=%.1f      : %.1f m of %.1f m (%.0f%%)" % [
		origin, s - origin, maxf(total - SPAWN_S, 0.001), 100.0 * (s - origin) / maxf(total - SPAWN_S, 0.001)])
	print("B: reached s               : %.1f m of %.1f m of centreline" % [s, total])
	print("B: path distance driven    : %.1f m" % path)
	print("B: top speed               : %.1f km/h" % top)
	print("B: times off carriageway   : %d (worst %.2f m off the centreline, %.2f s)" % [
		off, off_worst, off_worst_time])
	print("B: peak lateral offset     : %.2f m" % max_lat)
	print("B: peak |steer| demanded   : %.2f of 1.00%s" % [
		max_steer, "  <-- ASSIST SATURATED" if max_steer >= 0.999 else ""])
	print("B: mean |lat| held         : %.2f m off the centreline" % mean_abs_lat)
	print("B: stopped at              : x=%.1f z=%.1f s=%.1f m speed=%.1f km/h" % [
		car.global_position.x, car.global_position.z, s, float(car.get("speed_kph"))])
	print("")
	print("B: contacts (first %d)" % contacts.size())
	if contacts.is_empty():
		print("  (none)")
	for c in contacts:
		print("  %s" % c)

	# The headline the owner asked for, as a claim so it cannot be quietly lost.
	_check("the car reached the far end of the street", arrived,
		"%.1f m of %.1f m from s=%.1f" % [s - origin, total - SPAWN_S, origin])

	# And the run has to END rather than hang. A street you can drive into scenery
	# and never come out of is not playable; neither is one that loops forever.
	notes.append("race state after the drive: %s (a race cannot conclude while the"
		% String(main.get("race").call("state_name")) + " car is off its route)")


# ------------------------------------------------------------------ plumbing

## Press and release real input actions. Nothing on the car is touched here: this
## is the whole surface the probe is allowed to use, and if a car does not move
## under it then a person holding W would not move it either.
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


func _at(p: Vector3) -> Dictionary:
	var best_s := 0.0
	var best_lat := 0.0
	var best_t := Vector2(1, 0)
	var best_d := INF
	var acc := 0.0
	var v := Vector2(p.x, p.z)
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		var proj := a + ab * t
		var w := v - proj
		var d := w.length()
		if d < best_d:
			best_d = d
			best_s = acc + sqrt(len2) * t
			best_t = ab / sqrt(len2)
			best_lat = best_t.x * w.y - best_t.y * w.x
		acc += sqrt(len2)
	return {"s": best_s, "lat": best_lat, "t": best_t}


func _pose(d: float) -> Dictionary:
	var acc := 0.0
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			return {"pos": Vector3(a.lerp(b, (d - acc) / seg).x, SPAWN_Y, a.lerp(b, (d - acc) / seg).y),
				"t": (b - a) / seg}
		acc += seg
	var p := pts[pts.size() - 1]
	return {"pos": Vector3(p.x, SPAWN_Y, p.y), "t": (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()}


## Positive means "yaw left to match the tangent". Positive steer on CarBody yaws
## from -Z toward -X, so a positive correction needs a positive steer. Derived from
## the source rather than from a remembered sign, because the opposite convention
## reads as an undrivable car and not as a sign error.
func _head_err(f: Vector3, t: Vector2) -> float:
	return wrapf(atan2(-t.x, -t.y) - atan2(-f.x, -f.z), -PI, PI)


func _half_width(p: Vector3) -> float:
	var graph: RoadGraph = main.graph
	if graph == null:
		return 7.0
	var near: Dictionary = graph.nearest_road(p)
	var eid := int(near["edge"])
	if eid < 0:
		return 7.0
	return float(graph.edges[eid]["width"]) * 0.5


## The longest run of that street name. `OSMLayout.anchor()` is not a substitute:
## it scores by centrality with the length worth 0.01 m per metre, so it returns a
## different and much shorter street and every number here would be about a road
## nobody looked at.
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


# --------------------------------------------------------------------- report

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