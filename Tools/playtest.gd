extends Node
##
## Playtest harness: boots the real game and drives it with scripted input.
##
## Unit tests pass on this project while the car drives backwards with dead
## wheels, because a test asserts on numbers and never looks at a frame. This
## exists so "does it drive" is answered by driving it: it captures PNGs at
## each phase and prints a verdict block on the things that are easy to get
## silently wrong (facing vs travelling, wheels spinning, gears engaging, the
## car actually accelerating).
##
##   godot --path . res://Tools/playtest.tscn --fixed-fps 60
##
## Frames land in shots/playtest_*.png and the summary goes to stdout.

const OUT_DIR := "res://shots"
const FRAME_EVERY := 0.5

## Phases in order. Each holds its actions for `hold` seconds.
## steer is signed: the controller documents -1 as full right.
const PHASES := [
	{"name": "grid", "hold": 1.5, "throttle": 0.0, "steer": 0.0, "handbrake": 0.0},
	{"name": "launch", "hold": 4.0, "throttle": 1.0, "steer": 0.0, "handbrake": 0.0},
	{"name": "corner", "hold": 2.5, "throttle": 0.45, "steer": -0.7, "handbrake": 0.0},
	{"name": "drift", "hold": 1.5, "throttle": 0.0, "steer": -0.9, "handbrake": 1.0},
	{"name": "power", "hold": 3.0, "throttle": 1.0, "steer": 0.0, "handbrake": 0.0},
]

## ------------------------------------------------------------------ bounds
##
## Every other check here is one-sided: it proves that something HAPPENED. None
## of them can notice a car that does too much of everything, which is the
## failure this gate exists to catch - a car that slid 83 deg and crossed its
## own nose reported a single failure, which reads like a near-pass.
##
## The ceilings are PER PHASE, not global. The script deliberately does
## different things in different phases, and `drift` is an intended handbrake
## slide. A single global ceiling evaluated over every sample turned that
## designed behaviour into RED, and a gate that cries wolf is worse than the
## one-sided gate it replaced. The harness knows the phase of every sample, so
## the bound a sample is held to depends on the phase it was taken in.
##
## Peak body slip. car_body.gd computes it as
## atan2(sideways, max(|forwards|, 0.8)), and that denominator is never below
## 0.8, so the angle is structurally confined to +/-PI/2 (1.5708 rad). Any
## ceiling at or above that is vacuous by construction: it cannot ever fail.
## SLIP_CEILING is what is left once that hole is removed, applied per phase.
## A phase absent from the table is NOT checked for peak slip.
##
##   grid / launch / corner -> 0.70 rad (40 deg)
##     Tracking phases, so this is the tight bound: a car that is not being
##     asked to drift must never be travelling 40 deg across its own nose. That
##     is above the PI/4 line meaning "as much sideways as forwards" and well
##     below the structural cap. Measured on the car under test: grid 0.00,
##     launch 0.30, corner 0.07 rad, so 2.4x headroom at worst.
##     JUDGEMENT CALL - not yet validated against a known-good car, because no
##     known-good trace exists in this repo.
##
##   drift -> NOT CHECKED
##     Any ceiling here that is not vacuous has to land between the measured
##     1.43 rad and the 1.5708 structural cap, i.e. inside a 10% window, and the
##     only available reference for what a correct drift looks like IS the car
##     being driven. Any number in that window is the measurement rounded up,
##     dressed as a limit. The honest statement is that peak slip does not bound
##     this phase, and its excess is caught by the ratio bound below, which is
##     an integral over the phase and cannot be inflated by a peak. The
##     existing `max_slip < 0.15` check still requires the drift to break the
##     rear away.
##
##   power -> NOT CHECKED, and this one is a measurement rather than a
##     principle. `power` begins while the car is still scrubbing off the
##     handbrake slide: measured, its first 0.54 s has speed falling 15.7 ->
##     3.4 km/h with slip decaying 0.945 -> 0.000, and slip is then exactly
##     0.000 for the remaining 2.3 s of full-throttle acceleration in a
##     straight line. Every over-limit sample in this phase is that tail.
##     A ceiling tight enough to mean anything (anything under about 0.95 rad,
##     i.e. under PI/3) would fail a car accelerating in a straight line from
##     3 km/h, which is correct behaviour, so the phase is exempt rather than
##     handed a number chosen to let it pass. It remains gated below.
##
## Sideways travel, integrated in the car's own frame, as a fraction of forward
## travel integrated the same way. Net displacement is deliberately NOT used:
## the script corners about 90 deg, so a car that tracks correctly ends up
## about as far sideways as forwards, and a net-displacement ratio cannot tell
## that apart from the defect it is meant to catch. Working in the car's frame
## separates them - a clean corner adds no sideways distance, a slide does.
## RATIO_CEILING is per phase:
##
##   1.00 on `drift` is tan(45 deg): measured across the phase, the car may not
##     travel further across its own nose than along it. That is a line with a
##     meaning, not a number fitted to a run. The car under test measures 0.59
##     there and 0.03 / 0.02 / 0.08 on launch / corner / power.
##   0.60 on the tracking phases is tan(31 deg), the stricter reading of the
##     same quantity for a phase where sideways travel should be near zero.
##     An unlisted phase falls back to 0.60, so adding a phase tightens the gate
##     by default instead of silently exempting it.
const SLIP_CEILING := {
	"grid": 0.70,
	"launch": 0.70,
	"corner": 0.70,
}
const RATIO_CEILING := {
	"grid": 0.60,
	"launch": 0.60,
	"corner": 0.60,
	"drift": 1.00,
	"power": 0.60,
}

var main: Node
var log: Array[String] = []
var next_frame_at := 0.0
var elapsed := 0.0

var origin := Vector3.ZERO
var origin_basis := Basis.IDENTITY
var max_speed := 0.0
var max_spin := 0.0
var max_slip := 0.0
var max_gear := 0
var min_wheels_ground := 99
var samples := 0
# Per-phase accumulators for the bounds above: peak |body slip|, and the
# forward / sideways travel integrated in the car's own frame. Keyed by phase
# name so a bound can be looked up per phase at report time.
var phase_slip := {}
var phase_forward := {}
var phase_sideways := {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	main = load("res://Game/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await _wait_for_boot()
	var argv := OS.get_cmdline_user_args()
	if argv.has("--street") or argv.has("--no-assist"):
		# --no-assist is the control for the steering assist, not a mode of its own:
		# same road, same spawn, same full throttle, steer pinned to zero. If the
		# car still will not accelerate with no steering input at all, then the
		# assist is not what is stopping it and the search belongs in the vehicle.
		_street_assist = not argv.has("--no-assist")
		for a in argv:
			# --from=<m> starts the run part way down the street and --seconds=<n>
			# shortens it. Both exist to attribute a stall: the same full throttle
			# from three different places answers "is this car unable to drive" apart
			# from "this one spot on the street is blocked", which a single run from
			# the start line cannot tell apart.
			if a.begins_with("--from="):
				_street_from = maxf(a.substr(7).to_float(), STREET_START_M)
			elif a.begins_with("--seconds="):
				_street_limit = a.substr(10).to_float()
		await _street_drive()
		return
	await _start_race()
	await _drive()


# ================================================================== street drive
##
## Aumuller Street, end to end. The race phases above answer "does the car
## respond"; this answers the question a lap cannot, which is whether there is a
## road under it at all - 825 m of real arterial, from one end to the other, at
## speed, with nothing swapped out and no fallback anywhere.
##
## Deliberately does NOT start a race. A race is not the same experiment:
## `RaceDirector.tick` writes `entrants[i].position` directly every frame while
## the countdown runs, which teleports the car through the suspension
## integrators, and `_conclude_if_over` freezes the session the moment the
## finish line is crossed. Both would corrupt the measurement.
##
## Steering is assisted, and that is disclosed rather than hidden: the car is
## steered by a proportional controller on the same throttle/brake/steer
## surface a human and AIRacer use. The assist cannot make an undrivable car
## drivable - it cannot create tyre force, drive torque or ground contact - but
## the demand it puts on the car is logged (`max |steer|`) so a number near 1.0
## is visible as an assist at its limit rather than passing for a clean drive.

const STREET_TIMEOUT := 300.0
const STREET_NAME := "Aumuller Street"
## Spawn height above the corridor polyline, in metres. Not 0: the polyline is a
## centreline with no idea where the road surface is, and dropping the car onto
## the collider is the only placement that guarantees the suspension is loaded
## before the first throttle input. A spawn embedded in the road surface leaves
## `contact` true with `load` at zero, and TyreModel.longitudinal() returns 0.0
## for load <= 0 - free-spinning wheels, no thrust, no error.
const STREET_SPAWN_Y := 0.60
const STREET_SETTLE_FRAMES := 90        ## seconds of simulated time before giving up
const STREET_START_M := 8.0          ## where along the street the car is placed
const STREET_HEAD_GAIN := 2.4        ## steer per radian of heading error
const STREET_LAT_GAIN := 0.10        ## steer per metre of lateral error
const STREET_YAW_FLOOR := 0.13       ## rad/s; drop the heading term below this

var _street: PackedVector2Array = PackedVector2Array()
var _street_len := 0.0
var _street_off_road := false
var _street_name := STREET_NAME
var _street_max_load := 0.0
var _street_max_sr := 0.0
var _street_assist := true
var _street_speed_prev := 0.0
var _street_reported := false
## km/h lost in a single frame that counts as hitting something rather than
## braking or sliding.
const STREET_IMPACT_KPH := 15.0
## One entry per telemetry column, each already tab-terminated. The header is
## built off this and the row loop writes in the same order, so they cannot drift.
const STREET_COLUMNS := ["t\t", "s\t", "kmh\t", "gear\t", "rpm\t", "slip_rad\t",
	"lat_m\t", "half_width\t", "steer\t", "x\t", "z\t", "wheels_down\t",
	"rl_load_n\t", "rl_fx_n\t", "rl_sr\t", "rl_omega\t", "y\t", "throttle\t",
	"contacts\t"]
var _street_from := STREET_START_M
var _street_limit := STREET_TIMEOUT
var _street_origin := STREET_START_M
var _street_off_count := 0
var _street_off_max := 0.0
var _street_off_time := 0.0
var _street_off_worst_time := 0.0
var _street_max_lat := 0.0
var _street_max_steer := 0.0
var _street_fl := 0.0        ## peak front wheel surface speed, km/h
var _street_rl := 0.0
var _street_min_wheels := 99
var _street_air_frames := 0
var _street_rear_slip := 0.0
var _street_done := false
var _street_had_reverse := false


## Distance along the anchor polyline of `p`, its signed lateral offset from it,
## and the unit tangent there. Walking the same polyline OSMLayout.anchor()
## returns keeps the "825 m" in the report and the 825 m being driven the same
## number, instead of two independent ones that quietly disagree.
func _street_at(p: Vector3) -> Dictionary:
	var best_s := 0.0
	var best_lat := 0.0
	var best_t := Vector2(1, 0)
	var best_d := INF
	var acc := 0.0
	var v := Vector2(p.x, p.z)
	for i in _street.size() - 1:
		var a := _street[i]
		var b := _street[i + 1]
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
			# Signed by the tangent's own right-hand side, so "off to the right"
			# means one thing everywhere in this function.
			best_lat = best_t.x * w.y - best_t.y * w.x
		acc += sqrt(len2)
	return {"s": best_s, "lat": best_lat, "t": best_t, "dist": best_d}


## Half the carriageway, from the graph edge the car is actually on. The
## polyline alone would have to assume the anchor stayed an ARTERIAL, and the
## class is per-edge: Aumuller crosses wider streets and gets upgraded in place.
func _street_half_width(p: Vector3) -> float:
	var graph: RoadGraph = main.graph
	if graph == null:
		return 7.0
	var near: Dictionary = graph.nearest_road(p)
	var eid := int(near["edge"])
	if eid < 0:
		return 7.0
	return float(graph.edges[eid]["width"]) * 0.5


## Heading error in radians, positive meaning "yaw left to match the tangent".
##
## Positive steer on CarBody yaws from -Z toward -X, so the heading angle is read
## as atan2(-x, -z) and a positive correction needs a positive steer. Deriving
## that from the source rather than from a remembered sign is the point: the
## opposite convention is a divergence that looks like an undrivable car.
func _street_head_err(f: Vector3, t: Vector2) -> float:
	var phi_f := atan2(-f.x, -f.z)
	var phi_t := atan2(-t.x, -t.y)
	return wrapf(phi_t - phi_f, -PI, PI)


## The street under test, picked by NAME and by the LONGEST run of that name.
##
## `OSMLayout.anchor()` is not a substitute: it scores every arterial fragment by
## how close its midpoint is to the city centre, with the length worth only
## 0.01 m per metre, so it picks whichever fragment happens to be most central.
## On today's data that is a 265 m piece of Mulgrave Road. Aumuller Street is split
## into seven separate fragments in assets/maps/cairns_map.json and the long one is
## 824.5 m, which is the street the test is about. Driving the anchor instead would
## have quietly measured a different, much shorter street under the same verdict.
func _street_pick() -> Dictionary:
	var best: Dictionary = {}
	var best_len := 0.0
	var fragments := 0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != STREET_NAME:
			continue
		var pts: PackedVector2Array = c["points"]
		var run := 0.0
		for i in pts.size() - 1:
			run += pts[i].distance_to(pts[i + 1])
		if pts.size() < 2 or run <= 0.0:
			continue
		fragments += 1
		if run > best_len:
			best_len = run
			best = {"name": STREET_NAME, "pts": pts}
	if best.is_empty():
		print("STREET FATAL: no corridor named %s in the map data" % STREET_NAME)
		print("  the nearest arterial anchors are:")
		for c in OSMLayout.corridors():
			var p: PackedVector2Array = c["points"]
			var run := 0.0
			for i in p.size() - 1:
				run += p[i].distance_to(p[i + 1])
			if run > 100.0:
				print("    %s  %.1f m" % [String(c.get("name", "?")), run])
		return {}
	print("[street] %s: %d fragments in the map, driving the longest at %.1f m" % [
		STREET_NAME, fragments, best_len])
	return best


func _street_drive() -> void:
	var anchor: Dictionary = _street_pick()
	if anchor.is_empty():
		get_tree().quit(2)
		return
	_street_name = String(anchor.get("name", STREET_NAME))
	_street = anchor["pts"]
	_street_len = 0.0
	for i in _street.size() - 1:
		_street_len += _street[i].distance_to(_street[i + 1])
	print("[street] %s, %d points, %.1f m of centreline, steering assist %s" % [
		_street_name, _street.size(), _street_len, "ON" if _street_assist else "OFF (control)"])

	# The menus own ESC and re-assert their own visibility, and they put a
	# START RACE board over the street. Same reasoning as Tools/map_flight_shots.
	for n in _all_nodes(main):
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var flow := _find_flow(main)
	if flow != null:
		flow.call("close")

	var car: Node = main.player_car
	if car == null:
		print("STREET FATAL: no player_car")
		get_tree().quit(2)
		return

	_street_from = minf(_street_from, maxf(_street_len - 20.0, STREET_START_M))
	_street_origin = _street_from
	_street_limit = minf(_street_limit, STREET_TIMEOUT)
	var at := _street_pose(_street_from)
	var start: Vector3 = at["pos"]
	var dir: Vector2 = at["t"]
	# reset_to() re-seeds every wheel integrator, which is the whole reason the
	# grid teleport went wrong; placing the car through it avoids importing that
	# failure into a measurement of something else.
	car.reset_to(start, Vector3(0, atan2(-dir.x, -dir.y), 0))
	# RigidBody3D reports nothing about collisions unless asked, and
	# max_contacts_reported defaults to zero. Without both of these the impact dump
	# prints "<no body reported>" for a hit it has already detected by speed.
	car.contact_monitor = true
	car.max_contacts_reported = 8
	print("[street] placed at %.1f, %.1f facing %.3f, %.3f" % [
		start.x, start.z, dir.x, dir.y])
	# Let it drop and settle before asking anything of it. Sampled here because
	# "did the suspension load" is the difference between a tyre model that is
	# broken and a car that was spawned inside the road.
	for f in STREET_SETTLE_FRAMES:
		await get_tree().process_frame
		if f % 30 == 0 or f == STREET_SETTLE_FRAMES - 1:
			var probe: Dictionary = car.get_wheel("RL")
			print("[street] settle %3d: y=%.3f  load=%.0f N  fx=%.0f N  contact=%s" % [
				f, car.global_position.y, float(probe.get("load", -1.0)),
				float(probe.get("fx", -1.0)), str(probe.get("contact", false))])

	_hold({"throttle": 0.0})
	var s := 0.0
	var t := 0.0
	var samples := 0
	var speed_sum := 0.0
	var distance := 0.0
	print("[street] --- go ---")
	while t < _street_limit and not _street_done:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		if dt <= 0.0:
			continue
		t += dt

		var pos: Vector3 = car.global_position
		var here: Dictionary = _street_at(pos)
		s = float(here["s"])
		var lat := float(here["lat"])
		var tan: Vector2 = here["t"]
		var hw := _street_half_width(pos)

		var err := _street_head_err(-car.global_transform.basis.z, tan)
		var yaw: float = car.angular_velocity.y
		# Below walking pace the heading term is the only thing that can rescue a
		# wrong way, and near zero speed any integral of it is noise, so it is
		# gated off rather than divided by speed.
		var eff_err := err if absf(yaw) > STREET_YAW_FLOOR else err * minf(1.0, absf(yaw) / STREET_YAW_FLOOR)
		var steer := 0.0
		if _street_assist:
			steer = clampf(STREET_HEAD_GAIN * eff_err + STREET_LAT_GAIN * lat, -1.0, 1.0)

		_hold({"throttle": 1.0, "steer": steer})
		_street_max_steer = maxf(_street_max_steer, absf(steer))
		_street_max_lat = maxf(_street_max_lat, absf(lat))

		var off: bool = absf(lat) > hw
		if off:
			if not _street_off_road:
				_street_off_count += 1
				_street_off_road = true
				_street_off_time = 0.0
				print("[street] OFF ROAD #%d at %.1f m, s=%.1f m, lat=%+.2f m (half width %.2f)" % [
					_street_off_count, t, s, lat, hw])
			_street_off_time += dt
			_street_off_worst_time = maxf(_street_off_worst_time, _street_off_time)
			_street_off_max = maxf(_street_off_max, absf(lat))
		elif _street_off_road:
			_street_off_road = false
			print("[street] back on the road at %.1f m, s=%.1f m, off for %.2f s" % [
				t, s, _street_off_time])

		var vel: Vector3 = car.linear_velocity
		distance += vel.length() * dt
		speed_sum += float(car.speed_kph)
		_street_speed_prev = float(car.speed_kph)
		samples += 1

		max_speed = maxf(max_speed, float(car.speed_kph))
		max_gear = maxi(max_gear, int(car.current_gear))
		max_slip = maxf(max_slip, absf(float(car.slip_angle_body)))
		if int(car.current_gear) < 0:
			_street_had_reverse = true
		var down := int(car.wheels_on_ground)
		_street_min_wheels = mini(_street_min_wheels, down)
		if down < 4:
			_street_air_frames += 1

		# Front and rear are read separately because the two answer different
		# questions: front surface speed says the steering is connected to the
		# road, rear surface speed against body speed says the rear is driving
		# rather than coasting, and rear slip is what a bad assist actually causes.
		var wf: Dictionary = car.get_wheel("FL")
		if not wf.is_empty():
			_street_fl = maxf(_street_fl, absf(float(wf["omega"]) * float(wf["radius"]) * 3.6))
		var wr: Dictionary = car.get_wheel("RL")
		if not wr.is_empty():
			_street_rl = maxf(_street_rl, absf(float(wr["omega"]) * float(wr["radius"]) * 3.6))
			_street_max_load = maxf(_street_max_load, float(wr.get("load", 0.0)))
			_street_max_sr = maxf(_street_max_sr, absf(float(wr.get("sr_smooth", 0.0))))
			_street_rear_slip = maxf(_street_rear_slip, absf(float(wr["slip_angle"])))

		# One value per %-slot, joined by hand. A single format string with twelve
		# values and eleven slots does not fail loudly here: it throws
		# "not all arguments converted" every frame and writes one junk row per
		# frame, which is 18000 rows of nonsense that looks like a finished dataset.
		var dbg: Dictionary = car.get_wheel("RL")
		var cells := PackedStringArray()
		for cell in [
			"%.2f" % t, "%.1f" % s, "%.1f" % float(car.speed_kph),
			"%d" % int(car.current_gear), "%.0f" % float(car.engine_rpm),
			"%.3f" % float(car.slip_angle_body), "%+.2f" % lat, "%.2f" % hw,
			"%+.2f" % steer, "%.1f" % pos.x, "%.1f" % pos.z, "%d" % down,
			"%.0f" % float(dbg.get("load", -1.0)), "%.0f" % float(dbg.get("fx", -1.0)),
			"%+.3f" % float(dbg.get("sr_smooth", 0.0)), "%.0f" % float(dbg.get("omega", 0.0)),
			"%.3f" % car.global_position.y, "%.1f" % float(car.throttle),
			"%d" % int(car.get_contact_count()),
		]:
			cells.append(cell)
		log.append("\t".join(cells))
		# One-off collision dump. Losing 45 km/h in two frames is not a slide, and
		# naming the body that did it is the difference between "there is an
		# obstacle on Aumuller" and a bug report somebody can act on. Fires once.
		# Triggered on "touching something while moving", not on a speed drop: the
		# 45 km/h the car loses at s=54 is shed over four frames at ~11 km/h each,
		# which is below any deceleration threshold you would pick by eye. The
		# contact itself is instantaneous and unambiguous.
		if int(car.get_contact_count()) > 0 and t > 1.0 and not _street_reported:
			_street_reported = true
			var names: Array = []
			for b in car.get_colliding_bodies():
				names.append("%s(%s)" % [String(b.name), str(b.get_class())])
			print("[street] CONTACT at %.2f s, s=%.1f m: %.1f km/h (prev frame %.1f), lateral %+.2f m, hit: %s" % [
				t, s, float(car.speed_kph), _street_speed_prev, lat,
				", ".join(names) if names.size() > 0 else "<no body reported>"])
		_street_speed_prev = float(car.speed_kph)

		if s >= _street_len - STREET_START_M or (s - _street_origin) >= (_street_len - STREET_START_M - _street_origin):
			_street_done = true
			print("[street] reached the far end at %.2f s" % t)
			break
	_hold({})
	_street_report(car, s, t, distance, speed_sum, maxf(float(samples), 1.0))
	get_tree().quit(0)


func _street_pose(d: float) -> Dictionary:
	var acc := 0.0
	for i in _street.size() - 1:
		var a := _street[i]
		var b := _street[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			var u := (d - acc) / seg
			var p := a.lerp(b, u)
			return {"pos": Vector3(p.x, STREET_SPAWN_Y, p.y), "t": (b - a) / seg, "s": d}
		acc += seg
	var p := _street[_street.size() - 1]
	var t := (_street[_street.size() - 1] - _street[_street.size() - 2]).normalized()
	return {"pos": Vector3(p.x, STREET_SPAWN_Y, p.y), "t": t, "s": acc}


func _all_nodes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## `MenuFlow`, found by its API rather than by its type. Naming the class pulls
## in `UI/menu_flow.gd`, which uses the `Cfg` autoload, and an autoload identifier
## is not registered when Godot runs a bare `--script`.
func _find_flow(n: Node) -> Node:
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur.has_method("close") and cur.has_method("races"):
			return cur
		for c in cur.get_children():
			stack.append(c)
	return null


func _street_report(car: Node, s: float, t: float, distance: float,
		speed_sum: float, samples: float) -> void:
	var arrived: bool = s >= _street_len - STREET_START_M - 0.5 or s - _street_origin >= _street_len - STREET_START_M - _street_origin - 0.5
	var mean_speed := speed_sum / maxf(samples, 1.0)
	print("")
	print("=".repeat(58))
	print("STREET VERDICT   (%s, %.0f m of centreline)" % [
		_street_name, _street_len])
	print("=".repeat(58))
	print("started at                       : s=%.1f m" % _street_origin)
	print("reached the far end              : %s (at s=%.1f m of %.1f m)" % [
		"YES" if arrived else "NO", s, _street_len])
	print("time                              : %.2f s" % t)
	print("distance driven (path)           : %.1f m" % distance)
	print("progress along the centreline    : %.1f m of %.1f m (%.0f%%), %.1f m driven of %.1f m to drive" % [
		s, _street_len, 100.0 * s / maxf(_street_len, 0.001), s - _street_origin,
		maxf(_street_len - STREET_START_M - _street_origin, 0.001)])
	print("top speed                         : %.1f km/h" % max_speed)
	print("mean speed                       : %.1f km/h" % mean_speed)
	print("top gear reached                 : %d" % max_gear)
	print("selected reverse at any point    : %s" % _street_had_reverse)
	print("times off the carriageway        : %d" % _street_off_count)
	print("furthest off the centreline      : %.2f m" % _street_off_max)
	print("worst single excursion            : %.2f s off the road" % _street_off_worst_time)
	print("peak lateral offset              : %.2f m" % _street_max_lat)
	print("peak |steer| demanded by assist   : %.2f of 1.00" % _street_max_steer)
	print("peak body slip angle             : %.3f rad (%.1f deg)" % [
		max_slip, rad_to_deg(max_slip)])
	print("peak rear-wheel slip angle        : %.3f rad (%.1f deg)" % [
		_street_rear_slip, rad_to_deg(_street_rear_slip)])
	print("peak front wheel surface speed    : %.1f km/h" % _street_fl)
	print("peak rear wheel surface speed     : %.1f km/h" % _street_rl)
	print("min wheels on ground              : %d" % _street_min_wheels)
	print("physics steps with a wheel off    : %d" % _street_air_frames)
	print("")
	if not arrived:
		print("FAILURES:")
		print("  - DID NOT REACH THE FAR END. It got to %.1f m of %.1f m in %.1f s." % [
			s, _street_len, t])
		if max_speed < 15.0:
			print("  - CAR DID NOT ACCELERATE (top %.1f km/h) - throttle is not reaching the tyre model." % max_speed)
		if _street_max_load < 100.0:
			print("  - THE SUSPENSION NEVER LOADED (peak rear load %.0f N). TyreModel.longitudinal() returns 0.0 for load <= 0, so with no load the wheels free-spin and the car has no thrust at all. This is a spawn or collider problem, not a tyre problem." % _street_max_load)
			print("  - peak rear slip ratio was %+.3f with peak rear surface speed %.1f km/h, i.e. the wheels were turning against a stationary car." % [_street_max_sr, _street_rl])
		if _street_fl < 1.0:
			print("  - FRONT WHEELS NEVER TURNED (peak %.2f km/h of surface speed)." % _street_fl)
		if _street_rl < 1.0:
			print("  - REAR WHEELS NEVER TURNED (peak %.2f km/h of surface speed)." % _street_rl)
		if _street_off_count > 0:
			print("  - LEFT THE CARRIAGEWAY %d time(s), up to %.2f m off the centreline." % [
				_street_off_count, _street_off_max])
		if _street_air_frames > 0:
			print("  - A WHEEL LEFT THE GROUND on %d physics steps (min %d wheels down)." % [
				_street_air_frames, _street_min_wheels])
		print("  STOPPED AT: x=%.1f z=%.1f  s=%.1f m  speed=%.1f km/h" % [
			car.global_position.x, car.global_position.z, s, float(car.speed_kph)])
	else:
		print("the street was driven end to end. see the notes above for the cost.")
	print("")
	print("telemetry -> %s/playtest_street.tsv" % OUT_DIR)
	print("=".repeat(58))
	var f := FileAccess.open("%s/playtest_street.tsv" % OUT_DIR, FileAccess.WRITE)
	if f != null:
		# Built from one list, because a hand-written header that does not match the
		# rows is a file that lies about its own format: an earlier 16-column
		# header shipped against 18-column rows and every column past the
		# sixteenth was silently unlabelled.
		f.store_line("".join(STREET_COLUMNS))
		for line in log:
			f.store_line(line)
		f.close()


func _wait_for_boot() -> void:
	var t := 0.0
	while main.world == null and t < 60.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	if main.world == null:
		print("PLAYTEST FATAL: world never built")
		get_tree().quit(1)
		return
	print("[playtest] world ready after %.1f s" % t)


func _start_race() -> void:
	if main.has_method("_auto_start_race"):
		main.call("_auto_start_race")
	else:
		print("PLAYTEST FATAL: no _auto_start_race on the entry point")
		get_tree().quit(1)
		return
	# let the lights and the field settle
	for i in 60:
		await get_tree().process_frame
	print("[playtest] race started, player car =", main.player_car != null)


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
	if float(actions.get("handbrake", 0.0)) > 0.0:
		Input.action_press("handbrake", float(actions["handbrake"]))


func _drive() -> void:
	var car: Node = main.player_car
	if car == null:
		print("PLAYTEST FATAL: no player_car after race start")
		get_tree().quit(1)
		return

	origin = car.global_position
	origin_basis = car.global_transform.basis

	for phase in PHASES:
		_hold(phase)
		var name_s: String = phase["name"]
		var hold: float = phase["hold"]
		var phase_t := 0.0
		next_frame_at = elapsed
		print("[playtest] --- %s (%.1fs) ---" % [name_s, hold])
		while phase_t < hold:
			await get_tree().process_frame
			var dt := get_process_delta_time()
			elapsed += dt
			phase_t += dt
			_sample(car, name_s, dt)
			if elapsed >= next_frame_at:
				next_frame_at = elapsed + FRAME_EVERY
				await _grab("%s_%02d" % [name_s, int(elapsed / FRAME_EVERY)])
		_hold({})

	get_tree().quit(_report(car))


func _sample(car: Node, phase: String, dt: float) -> void:
	samples += 1
	max_speed = maxf(max_speed, float(car.speed_kph))
	max_gear = maxi(max_gear, int(car.current_gear))
	max_slip = maxf(max_slip, absf(float(car.slip_angle_body)))
	min_wheels_ground = mini(min_wheels_ground, int(car.wheels_on_ground))
	for wn in ["FL", "FR", "RL", "RR"]:
		var w: Dictionary = car.get_wheel(wn)
		if w.has("spin_vis"):
			max_spin = maxf(max_spin, absf(float(w["spin_vis"])))
	# Bounds are per phase, so the per-phase figures have to be accumulated as the
	# drive runs - a report-time maximum cannot tell which phase a peak belongs
	# to. Forward is the car's own -Z, sideways its own +X, taken from an
	# orthonormalised basis so suspension pitch/roll does not leak in.
	var body_basis: Basis = car.global_transform.basis.orthonormalized()
	var vel: Vector3 = car.linear_velocity
	phase_slip[phase] = maxf(float(phase_slip.get(phase, 0.0)), absf(float(car.slip_angle_body)))
	phase_forward[phase] = float(phase_forward.get(phase, 0.0)) + absf(vel.dot(-body_basis.z)) * dt
	phase_sideways[phase] = float(phase_sideways.get(phase, 0.0)) + absf(vel.dot(body_basis.x)) * dt
	log.append("%.2f\t%s\tspd=%.1f\tgear=%d\trpm=%.0f\tslip=%.3f\tspin=%.2f\tpos=%.1f,%.1f\tground=%d" % [
		elapsed, phase, float(car.speed_kph), int(car.current_gear),
		float(car.engine_rpm), float(car.slip_angle_body), max_spin,
		car.global_position.x, car.global_position.z, int(car.wheels_on_ground),
	])


func _grab(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	img.save_png("%s/playtest_%s.png" % [OUT_DIR, tag])


func _report(car: Node) -> int:
	# Travel measured along the car's own forward axis at the start, so a model
	# mounted 180 degrees out shows up as negative travel rather than as a
	# plausible-looking distance.
	var moved: Vector3 = car.global_position - origin
	var forward := -origin_basis.z
	var along := moved.dot(forward)
	var lateral := moved.dot(origin_basis.x)

	print("")
	print("=".repeat(58))
	print("PLAYTEST VERDICT   (%d samples over %.1f s)" % [samples, elapsed])
	print("=".repeat(58))
	print("travel along start-forward : %+.1f m   (sideways %+.1f m)" % [along, lateral])
	print("max speed                  : %.1f km/h" % max_speed)
	print("highest gear reached       : %d" % max_gear)
	print("max wheel spin_vis         : %.2f rad" % max_spin)
	print("max body slip angle        : %.3f rad (%.1f deg)" % [max_slip, rad_to_deg(max_slip)])
	print("min wheels on ground       : %d" % min_wheels_ground)

	var fails: Array[String] = []
	if along <= 1.0:
		fails.append("CAR NOT TRAVELLING FORWARD (%.1f m) - model is backwards or input is inverted" % along)
	if max_speed < 15.0:
		fails.append("CAR DID NOT ACCELERATE (max %.1f km/h) - throttle is not reaching the tyre model" % max_speed)
	if max_spin < 0.5:
		fails.append("WHEELS NEVER SPUN (max spin_vis %.2f rad) - the visual wheel nodes are not being driven" % max_spin)
	if max_gear < 2:
		fails.append("NEVER SHIFTED UP (gear %d) - gearbox is stuck or the engine is not making torque" % max_gear)
	if max_slip < 0.15:
		fails.append("HANDBRAKE PRODUCED NO SLIP (max %.1f deg) - the rear is not breaking away" % rad_to_deg(max_slip))
	if min_wheels_ground < 3:
		fails.append("CAR LEFT THE GROUND (min %d wheels down) - suspension or ride height is wrong" % min_wheels_ground)

	# Bounds, evaluated per phase - see the comment on SLIP_CEILING for which
	# phases are exempt and why. A phase missing from SLIP_CEILING is exempt
	# from the peak-slip bound; every phase is held to RATIO_CEILING.
	for phase in PHASES:
		var pn: String = phase["name"]
		if not phase_slip.has(pn):
			continue
		var peak := float(phase_slip[pn])
		var fwd_m := float(phase_forward[pn])
		var ratio := float(phase_sideways[pn]) / maxf(fwd_m, 0.001)
		if SLIP_CEILING.has(pn) and peak > float(SLIP_CEILING[pn]):
			fails.append("CAR SLID SIDEWAYS IN THE %s PHASE (%.1f deg body slip, limit %.1f deg) - it is travelling across its own nose, not cornering" % [pn, rad_to_deg(peak), rad_to_deg(float(SLIP_CEILING[pn]))])
		if ratio > float(RATIO_CEILING.get(pn, 0.60)):
			fails.append("CAR SPENT THE %s PHASE SIDEWAYS (%.2f m sideways per 1.00 m forwards, limit %.2f) - it is sliding, not driving" % [pn, ratio, float(RATIO_CEILING.get(pn, 0.60))])

	print("")
	if fails.is_empty():
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES (%d):" % fails.size())
		for f in fails:
			print("  - %s" % f)
	print("")
	print("telemetry -> %s/playtest_telemetry.tsv" % OUT_DIR)
	print("frames    -> %s/playtest_*.png" % OUT_DIR)
	print("=".repeat(58))

	var f := FileAccess.open("%s/playtest_telemetry.tsv" % OUT_DIR, FileAccess.WRITE)
	if f != null:
		f.store_line("t\tphase\tspeed_kph\tgear\trpm\tslip_rad\tspin_rad\tx\tz\twheels_down")
		for line in log:
			f.store_line(line)
		f.close()
	return fails.size()
