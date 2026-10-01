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
			_sample(car, name_s)
			if elapsed >= next_frame_at:
				next_frame_at = elapsed + FRAME_EVERY
				await _grab("%s_%02d" % [name_s, int(elapsed / FRAME_EVERY)])
		_hold({})

	_report(car)
	get_tree().quit(0)


func _sample(car: Node, phase: String) -> void:
	samples += 1
	max_speed = maxf(max_speed, float(car.speed_kph))
	max_gear = maxi(max_gear, int(car.current_gear))
	max_slip = maxf(max_slip, absf(float(car.slip_angle_body)))
	min_wheels_ground = mini(min_wheels_ground, int(car.wheels_on_ground))
	for wn in ["FL", "FR", "RL", "RR"]:
		var w: Dictionary = car.get_wheel(wn)
		if w.has("spin_vis"):
			max_spin = maxf(max_spin, absf(float(w["spin_vis"])))
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


func _report(car: Node) -> void:
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
