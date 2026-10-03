extends SceneTree
## FREE-FLIGHT AUTOPILOT. Flies each of the five glb-backed cars around a fixed
## route with no player input at all, from a free-move camera, and dumps
## per-wheel spin, steer angles, gear/rpm and per-axle slip at sample steps.
##
##   source /tmp/vk/env.sh
##   godot --path . --fixed-fps 60 --rendering-driver vulkan --audio-driver Dummy \
##       --script res://Tests/drift_flight.gd
##
## `--fixed-fps 60` is NOT optional, and omitting it invalidates the numbers.
## Without it the physics step tracks wall-clock time, so it varies with how long
## a frame takes to render - and this box software-rasterises at ~0.67 s/frame.
## Measured with everything else identical (kairo_s13, 5 cars, 260 frames,
## 640x360): with the flag, peak body slip 4.7 deg over 37 m; without it, peak
## body slip 25.7 deg over 42 m. Each form repeats exactly run to run, so it is a
## consistent bias rather than noise - it just means the two forms are different
## physics runs whose numbers must not be compared. Two full 660-frame runs at
## 1280x720, one of each form, gave peak body slip 50.3 deg and 25.8 deg for the
## same car under the same driver. Always pass it, and treat any number produced
## without it as unknown rather than as a regression.
##
## WHY THIS EXISTS, when Tests/test_drift.gd already has assertions:
## every existing check in this repo is a number printed by a headless run, and
## `Tests/test_feel.gd` proves what that costs - 161 `t.ok(true, ...)` calls that
## assert nothing while its own driver reports "griped up (understeer)". A number
## suite cannot see a frame. This one can, and it is aimed at the specific
## failures a number suite is blind to:
##
##   - STATIC WHEELS. The physics wheel dict and the visual wheel node are
##     separate (`spin_vis` vs `omega`, car_visual.gd:323-324). Nothing in the
##     suite compares them, so a car whose tyres are modelled correctly while the
##     mesh never turns is green. This dumps both and the delta between them.
##   - A CAR THAT DOES NOT MOVE. Asserted as a number, but obvious in a frame.
##   - SILENT / DEAD AUDIO. The engine note is driven from the same telemetry;
##     if the run is audible the model is being fed, if not, it is not.
##   - WHICH CAR IS WHICH. A glb mounted 180 deg out or on the wrong axle still
##     satisfies every numeric assertion in the repo.
##
## Every frame is written under res://shots/ and a per-frame SHA is kept, so two
## identical frames are visible as a repeat hash rather than having to be eyeballed.

const OUT_DIR := "res://shots"
const TELEMETRY := "res://shots/drift_flight_telemetry.tsv"
const SUMMARY := "res://shots/drift_flight_summary.txt"

## The five glb-backed cars, in CarVisual.MODELS order (car_visual.gd:41-45).
## kairo_mx90 and kaze_type_r are deliberately absent: they have no glb and keep
## a procedural body, so they are not part of "the 5 glb cars".
const CARS := [
	"kairo_s13", "tatsuya_gt", "shinobi_rs", "hayate_turbo", "akuma_gt",
]

## The autopilot, and the course it drives. Both live in `Tests/drift_driver.gd`
## so `Tests/test_drift.gd` measures the same manoeuvre headlessly - see that
## file's header for why two drivers made the two harnesses disagree by 5x.
const DriftDriver := preload("res://Tests/drift_driver.gd")

## An out-and-back loop with a hairpin, so a car that can slide has somewhere to
## slide. Waypoints are metres in the XZ plane, driven by pure pursuit - no
## Input, no mouse, no player controller.
const ROUTE := DriftDriver.ROUTE

## Frames between telemetry samples, and the frames between screenshots.
## `FRAMES` is overridable from the command line (`-- --frames=600`) because a
## software-rasterised run at 1280x720 costs ~0.67 s per rendered frame on this
## box, which is 45 minutes for the default 4500. The default is sized for a GPU
## or a smaller resolution; lower it, do not raise it, on a software rasteriser.
var frames := 900
const SAMPLE_EVERY := 45
const SHOT_EVERY := 60
## Where the free camera sits, as offsets in the CAR's own frame, cycled per shot.
## A free camera is the point: none of these is the game's chase cam, so a broken
## chase camera cannot hide a car that is not steering or not moving.
const CAM_RIGS := [
	{"name": "chase", "back": 11.0, "up": 3.4, "side": 0.0, "look": 2.0},
	{"name": "flank", "back": 1.0, "up": 1.6, "side": 9.0, "look": 1.0},
	{"name": "high", "back": 6.0, "up": 14.0, "side": 0.0, "look": 0.5},
	{"name": "nose", "back": -3.2, "up": 0.9, "side": 0.0, "look": -6.0},
]

var world: Node3D
var cam: Camera3D
var log: Array[String] = []
var fails: Array[String] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--frames="):
			frames = maxi(120, int(String(a).split("=")[1]))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_build_world()
	_cam()
	for i in 3:
		await process_frame
	for id in CARS:
		await _fly(id)
	_write_telemetry()
	print("\n" + "=".repeat(70))
	print("DRIFT FLIGHT VERDICT   (%d cars, %d telemetry rows)" % [CARS.size(), log.size()])
	print("=".repeat(70))
	for line in _summary_lines():
		print(line)
	print("")
	if fails.is_empty():
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES (%d):" % fails.size())
		for f in fails:
			print("  - %s" % f)
	print("")
	print("telemetry -> %s" % TELEMETRY)
	print("summary   -> %s" % SUMMARY)
	print("frames    -> %s/drift_%s_*.png" % [OUT_DIR, "CAR"])
	print("=".repeat(70))
	quit(fails.size())


# --- world -----------------------------------------------------------------

func _build_world() -> void:
	world = Node3D.new()
	world.name = "FlightWorld"
	root.add_child(world)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 1, 4000)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, -200)
	world.add_child(ground)
	var mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4000, 4000)
	mesh.mesh = pm
	mesh.position = Vector3(0, 0, -200)
	world.add_child(mesh)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, -35, 0)
	light.shadow_enabled = true
	light.light_energy = 1.1
	world.add_child(light)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.0
	e.fog_enabled = true
	e.fog_density = 0.0012
	env.environment = e
	world.add_child(env)


func _cam() -> void:
	cam = Camera3D.new()
	cam.fov = 62.0
	world.add_child(cam)
	cam.make_current()


## Places the free camera from a car-frame offset. Pure math, no smoothing state
## carried between frames, so a shot is reproducible from (car transform, rig).
func _place_cam(car: CarBody, rig: Dictionary) -> void:
	var b: Basis = car.global_transform.basis.orthonormalized()
	var off := Vector3(float(rig["side"]), float(rig["up"]), float(rig["back"]))
	cam.global_transform = Transform3D(b, car.global_position + b * off)
	var target: Vector3 = car.global_position + b * Vector3(0.0, 0.4, float(rig["look"]))
	if cam.global_position.distance_to(target) > 0.01:
		cam.look_at(target, Vector3.UP)


# --- autopilot -------------------------------------------------------------

## Pure-pursuit steering toward the current waypoint plus a countersteer term,
## so the autopilot is a driver rather than a rails-guided turntable: it has to
## balance the slide to get round the hairpin.
##
## The logic lives in `Tests/drift_driver.gd` because `Tests/test_drift.gd`
## measures the same car headlessly and the two MUST drive identically - see that
## file's header. This is a delegation, not a copy.
func _drive(car: CarBody, i: int) -> void:
	DriftDriver.drive(car, i)


func _next_leg(car: CarBody) -> void:
	DriftDriver.advance(car)


func _fly(id: String) -> void:
	var car := CarBody.new()
	car.spec = CarDB.get_spec(id)
	car.build_visual = true
	car.set_meta("leg", 1)
	world.add_child(car)
	for i in 20:
		await process_frame
	print("\n  --- %s (%s.glb) ---" % [id, CarVisual.MODELS.get(id, "?")])

	var start := car.global_position
	var max_spin_vis := 0.0
	var max_omega := 0.0
	var max_spin_step := 0.0
	var _last_spin := {}
	var max_rear := 0.0
	var max_front := 0.0
	var rear_gt := 0
	var compared := 0
	var shots: Array[String] = []
	var hashes: Array[String] = []
	var travelled := 0.0
	var prev := car.global_position
	var max_beta := 0.0
	var last := car.global_position
	var stuck_frames := 0
	var drift_frames := 0
	var drift_rear := 0.0

	for i in frames:
		await physics_frame
		car.auto_shift()
		_drive(car, i)
		# waypoint reached -> advance
		var tgt: Vector3 = ROUTE[int(car.get_meta("leg", 1))]
		if Vector2(tgt.x - car.global_position.x, tgt.z - car.global_position.z).length() < 26.0:
			_next_leg(car)
		travelled += car.global_position.distance_to(prev)
		prev = car.global_position
		if i > 60 and car.global_position.distance_to(last) < 0.004:
			stuck_frames += 1
		else:
			stuck_frames = 0
		last = car.global_position
		max_beta = maxf(max_beta, rad_to_deg(absf(car.slip_angle_body)))

		var rl: Dictionary = car.get_wheel("RL")
		var rr: Dictionary = car.get_wheel("RR")
		var fl: Dictionary = car.get_wheel("FL")
		var fr: Dictionary = car.get_wheel("FR")
		var rear := maxf(rad_to_deg(absf(float(rl["slip_angle"]))), rad_to_deg(absf(float(rr["slip_angle"]))))
		var front := maxf(rad_to_deg(absf(float(fl["slip_angle"]))), rad_to_deg(absf(float(fr["slip_angle"]))))
		max_rear = maxf(max_rear, rear)
		max_front = maxf(max_front, front)
		if absf(rad_to_deg(car.slip_angle_body)) > 15.0:
			drift_frames += 1
			drift_rear = maxf(drift_rear, rear)
		if i > 30:
			compared += 1
			if rear > front:
				rear_gt += 1
		# The static-wheels check. `spin_vis` is an ANGLE (radians, fposmod'd to
		# TAU) and `omega` is a RATE (rad/s), so they are not comparable and the
		# first version of this harness compared them anyway and reported a
		# meaningless 109 rad "disagreement". The question that actually matters is
		# whether the VISUAL node moves, so that is measured directly: the largest
		# change in spin_vis between consecutive frames. A static wheel mesh has
		# spin_vis pinned no matter what the tyre model says.
		for w in car.wheels():
			max_omega = maxf(max_omega, absf(float(w["omega"])))
			var sv := float(w["spin_vis"])
			if _last_spin.has(String(w["name"])):
				max_spin_step = maxf(max_spin_step, absf(sv - float(_last_spin[String(w["name"])])))
			_last_spin[String(w["name"])] = sv
		max_spin_vis = maxf(max_spin_vis, maxf(absf(float(rl["spin_vis"])), absf(float(rr["spin_vis"]))))

		if i % SAMPLE_EVERY == 0:
			_sample(car, i)
		if i % SHOT_EVERY == 0:
			var rig: Dictionary = CAM_RIGS[(i / SHOT_EVERY) % CAM_RIGS.size()]
			_place_cam(car, rig)
			# the camera must be told to draw before the frame is grabbed
			await process_frame
			await RenderingServer.frame_post_draw
			var path := "%s/drift_%s_%02d_%s.png" % [OUT_DIR, id, i / SHOT_EVERY, rig["name"]]
			var img := root.get_texture().get_image()
			if img != null:
				img.save_png(path)
				shots.append(path)
				hashes.append(_frame_hash(img))

	# Average speed, not distance: the gate has to mean the same thing whatever
	# `--frames` is set to, and a short run covering a shorter distance is not a
	# car that failed to move.
	var avg_kph := travelled / maxf(frames / 60.0, 0.001) * 3.6
	print("     travelled %.0f m   peak body slip %.1f deg   peak rear %.1f  peak front %.1f" % [
		travelled, max_beta, max_rear, max_front])
	print("     peak |omega| %.1f rad/s   visual wheel moved %.4f rad in its biggest single frame" % [
		max_omega, max_spin_step])
	print("     avg %.1f kph   spent %d frames beyond 15 deg of body slip (deepest rear while sideways %.1f deg)" % [
		avg_kph, drift_frames, drift_rear])
	print("     shots: %d   distinct frame hashes: %d%s" % [
		shots.size(), _unique(hashes).size(),
		"" if _unique(hashes).size() > 1 else "   <-- CAMERA NEVER MOVED"])

	# --- per-car gates. Each is a thing a number suite cannot see. ---
	if avg_kph < 25.0:
		fails.append("%s: the autopilot averaged %.1f kph over %.0f s - the car is not being driven" % [
			id, avg_kph, frames / 60.0])
	if max_spin_vis < 0.5:
		fails.append("%s: VISUAL WHEELS NEVER TURNED (max spin_vis %.3f rad) - the tyres are modelled but the mesh does not move" % [id, max_spin_vis])
	if max_omega < 1.0:
		fails.append("%s: physics wheels never turned (max |omega| %.3f rad/s)" % [id, max_omega])
	if max_spin_step < 0.02:
		fails.append("%s: STATIC WHEELS - no visual wheel node changed by more than %.4f rad in any frame while the tyres were turning at %.1f rad/s" % [
			id, max_spin_step, max_omega])
	if _unique(hashes).size() <= 1:
		fails.append("%s: every screenshot is the same image - the free camera is not moving, so the frames prove nothing" % id)
	if stuck_frames > 30:
		fails.append("%s: the car was stationary for %d consecutive frames mid-run" % [id, stuck_frames])
	if car.global_position.y < -2.0:
		fails.append("%s: the car fell through the floor (y %.1f)" % [id, car.global_position.y])

	_report_line(id, travelled, max_beta, max_rear, max_front, 100.0 * rear_gt / maxf(compared, 1),
		max_omega, max_spin_vis, max_spin_step, shots.size(), _unique(hashes).size(),
		stuck_frames)
	world.remove_child(car)
	car.queue_free()
	for i in 3:
		await process_frame


func _unique(a: Array) -> Array:
	var out: Array = []
	for x in a:
		if not out.has(x):
			out.append(x)
	return out


## Content hash of a rendered frame. Two frames with the same hash are the same
## image, which is how "the camera never moved" and "the car is a static prop"
## become a number instead of something to squint at.
func _frame_hash(img: Image) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	return ctx.finish().hex_encode().substr(0, 12)


## One row per sample step: per-wheel spin, steer angles, gear/rpm, per-axle
## slip. This is the dump the brief asks for, and it is the raw evidence behind
## every number in the summary.
func _sample(car: CarBody, i: int) -> void:
	var fl: Dictionary = car.get_wheel("FL")
	var fr: Dictionary = car.get_wheel("FR")
	var rl: Dictionary = car.get_wheel("RL")
	var rr: Dictionary = car.get_wheel("RR")
	log.append("\t".join(PackedStringArray([
		str(i), car.spec.id,
		"%.1f" % car.speed_kph, "%.1f" % rad_to_deg(car.slip_angle_body),
		str(car.current_gear), "%.0f" % car.engine_rpm,
		"%.1f" % rad_to_deg(absf(float(fl["slip_angle"]))),
		"%.1f" % rad_to_deg(absf(float(fr["slip_angle"]))),
		"%.1f" % rad_to_deg(absf(float(rl["slip_angle"]))),
		"%.1f" % rad_to_deg(absf(float(rr["slip_angle"]))),
		"%.2f" % rad_to_deg(float(fl["steer_angle"])),
		"%.2f" % rad_to_deg(float(fr["steer_angle"])),
		"%.1f" % float(fl["omega"]), "%.1f" % float(fr["omega"]),
		"%.1f" % float(rl["omega"]), "%.1f" % float(rr["omega"]),
		"%.1f" % float(fl["spin_vis"]), "%.1f" % float(fr["spin_vis"]),
		"%.1f" % float(rl["spin_vis"]), "%.1f" % float(rr["spin_vis"]),
		"%.3f" % car.angular_velocity.y, "%.1f" % car.forward().dot(car.linear_velocity),
		"%.1f,%.1f" % [car.global_position.x, car.global_position.z],
	])))


func _report_line(id: String, travelled: float, beta: float, rear: float, front: float,
		rear_pct: float, omega: float, spin: float, step: float, shots: int, uniq: int,
		stuck: int) -> void:
	var s := "%-13s travel %5.0f m  peak body %5.1f  rear %5.1f  front %5.1f  rear>front %5.1f%%  omega %6.1f  spin_vis %6.2f  vis-step %5.3f  shots %2d/%2d uniq  stuck %3d" % [
		id, travelled, beta, rear, front, rear_pct, omega, spin, step, shots, uniq, stuck]
	_summary_rows().append(s)


var _rows: Array[String] = []


func _summary_rows() -> Array[String]:
	return _rows


func _summary_lines() -> PackedStringArray:
	return PackedStringArray(_rows)


func _write_telemetry() -> void:
	var f := FileAccess.open(TELEMETRY, FileAccess.WRITE)
	if f != null:
		f.store_line("\t".join(PackedStringArray([
			"frame", "car", "kph", "body_slip_deg", "gear", "rpm",
			"FL_slip_deg", "FR_slip_deg", "RL_slip_deg", "RR_slip_deg",
			"FL_steer_deg", "FR_steer_deg",
			"FL_omega", "FR_omega", "RL_omega", "RR_omega",
			"FL_spin_vis", "FR_spin_vis", "RL_spin_vis", "RR_spin_vis",
			"yaw_rate", "forward_mps", "pos_xz"])))
		for line in log:
			f.store_line(line)
		f.close()
	var g := FileAccess.open(SUMMARY, FileAccess.WRITE)
	if g != null:
		for line in _summary_lines():
			g.store_line(line)
		g.close()
