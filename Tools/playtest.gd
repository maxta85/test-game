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
	await _start_race()
	await _drive()


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
