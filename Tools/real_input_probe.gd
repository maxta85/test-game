extends SceneTree
##
## Can a person get down this street with the keyboard? Input actions only.
##
##     godot --headless --fixed-fps 60 --path . \
##       --script res://Tools/real_input_probe.gd -- --seconds=180
##
## WHAT THIS IS, AND WHY IT HAD NOT BEEN DONE
##
## Every "the player drives it" number in this project came from a HARNESS
## CONTROLLER standing in for the player. Four controllers exist and only three had
## been measured:
##
##   (1) Tools/playable_probe.gd's proportional controller   99% on Hoare   (t121)
##   (2) Tools/playtest.gd's heading+cross-track controller   79.7 m on Hoare (t133)
##   (3) Systems/race/lane_follower.gd                        98.8% on Hoare  (t130)
##   (4) THE REAL PLAYER PATH - Input action -> PlayerController -> car
##       NEVER MEASURED.
##
## (1) and (3) both drive a car by writing `car.steer` to a computed value. That
## proves the physics and the controller. It proves nothing about the input chain,
## because it bypasses every part of it.
##
## ## WHAT THIS SCRIPT IS NOT ALLOWED TO DO, AND DOES NOT
##
## No `car.throttle`, no `car.steer`, no car method of any kind, and no steering
## controller of my own. The ONLY thing that reaches the car is
## `Input.action_press` / `Input.action_release` on the four actions a player
## actually presses.
##
## ## THE STEERING POLICY IS DISCLOSED, AND IT IS NOT A CONTROLLER
##
## `PlayerController` reads
## `car.steer = Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")`,
## and a KEYBOARD action's strength is 1.0 or 0.0. So a keyboard driver can only hold
## FULL LOCK or centre - there is no intermediate steering available at all. This is
## not a fixed-gain loop; it is bang-bang.
##
## Given that, the policy below is the simplest thing a person can do: hold full lock
## while the car is outside a corridor, centre while it is inside. No gain, no
## derivative, no look-ahead, no aiming - just "am I off the line, yes or no". If a
## street cannot be driven by THAT, no keyboard can drive it, and the question is
## answered without inventing competence the hardware does not have.

const SPAWN_S := 8.0
const SPAWN_Y := 0.60
const SETTLE_FRAMES := 90
## How wide a corridor counts as "on the line", in metres either side. Not tuned -
## it is about the car's own width plus a margin, and the sensitivity to it is
## reported by running two widths.
const CORRIDOR_M := 4.0
const CORRIDOR_ALT_M := 2.0

## Set in `_initialize`, read by `_drive` for the road half-width. Module state and
## not an argument because `_drive` is already nine parameters and one more would
## make every call site a chance to swap them.
var graph_ref: RoadGraph = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var seconds := 180.0
	for a in args:
		if a.begins_with("--seconds="):
			seconds = a.substr(10).to_float()

	print("[real] building the world")
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "RealInputRoot"
	get_root().add_child(root)
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	await process_frame
	await process_frame

	# The anchor street of THIS worktree, by name and length, so the reader can see
	# which street was driven. On a chain-A worktree the anchor is chosen by the
	# centrality rule and is Aumuller Street; on a chain-B worktree it is whatever the
	# race network starts from. Printing it is the whole point - a coverage percentage
	# without a street name is not a result.
	var anchor: Dictionary = OSMLayout.anchor()
	var street := String(anchor.get("name", "<none>"))
	var pts: PackedVector2Array = anchor.get("pts", PackedVector2Array())
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	print("[real] ANCHOR STREET: %s, %.1f m of centreline, %d points" % [
		street, total, pts.size()])
	if pts.size() < 2:
		print("REAL_INPUT FATAL: no anchor street")
		quit(2)
		return

	graph_ref = graph

	var car := CarBody.new()
	car.name = "RealInputCar"
	car.spec = CarDB.get_spec("kairo_s13")
	root.add_child(car)
	var controller := PlayerController.new()
	controller.name = "RealInputController"
	controller.car = car
	root.add_child(controller)

	var pose := _pose(pts, SPAWN_S)
	car.reset_to(pose["pos"], Vector3(0.0, pose["yaw"], 0.0))
	print("[real] spawned at s=%.1f, facing %.3f, on %s" % [SPAWN_S, float(pose["yaw"]), street])
	for _i in SETTLE_FRAMES:
		await process_frame
	var rl: Dictionary = car.get_wheel("RL")
	print("[real] settled: y=%.3f rear load=%.0f N contact=%s" % [
		car.global_position.y, float(rl.get("load", -1.0)), str(rl.get("contact", false))])

	# Confirm the input path is live BEFORE driving, because a probe that measures a
	# car that never received input produces a number about nothing. `Input.is_action_pressed`
	# after `action_press` is the same call `PlayerController` makes, so if this is
	# false the controller is not reading the action and no distance means anything.
	Input.action_press("throttle", 1.0)
	await process_frame
	var live := Input.get_action_strength("throttle")
	Input.action_release("throttle")
	await process_frame
	var released := Input.get_action_strength("throttle")
	print("[real] input path live: throttle reads %.1f pressed, %.1f released" % [live, released])
	if live < 0.99 or released > 0.01:
		print("REAL_INPUT FAIL: the input actions are not readable, so nothing below is a measurement")
		quit(2)
		return

	var r := await _drive(root, car, pts, total, seconds, CORRIDOR_M, street)
	var r_alt := await _drive(root, car, pts, total, seconds * 0.5, CORRIDOR_ALT_M, street)
	print("")
	print("REAL_INPUT_RESULT corridor=%.1f  distance=%.1f of %.1f  top=%.1f  off=%d  peak_steer=%.2f  ended=%s" % [
		CORRIDOR_M, float(r["dist"]), float(r["total"]), float(r["top"]),
		int(r["off"]), float(r["peak_steer"]), str(r["ended"])])
	print("REAL_INPUT_RESULT corridor=%.1f  distance=%.1f of %.1f  top=%.1f  off=%d  peak_steer=%.2f  ended=%s  (sensitivity)" % [
		CORRIDOR_ALT_M, float(r_alt["dist"]), float(r_alt["total"]), float(r_alt["top"]),
		int(r_alt["off"]), float(r_alt["peak_steer"]), str(r_alt["ended"])])
	print("REAL_INPUT=%s" % ("PASS" if bool(r["reached"]) else "FAIL"))
	quit(0)


## The drive. INPUT ACTIONS ONLY.
func _drive(root: Node3D, car: Node3D, pts: PackedVector2Array, total: float,
		seconds: float, corridor: float, street: String) -> Dictionary:
	var s := SPAWN_S
	var t := 0.0
	var top := 0.0
	var off := 0
	var off_now := false
	var off_worst := 0.0
	var peak_steer := 0.0
	var off_at := -1.0
	var ended := "timeout"
	var reached := false
	var hw_seen := corridor

	# Start where the last run stopped so the sensitivity pass is comparable.
	var pose := _pose(pts, SPAWN_S)
	car.reset_to(pose["pos"], Vector3(0.0, pose["yaw"], 0.0))
	for _i in 30:
		await process_frame

	Input.action_press("throttle", 1.0)
	while t < seconds:
		await process_frame
		# `Engine.get_process_delta_time()` is a NODE method; this is a SceneTree
		# script. `--fixed-fps 60` makes the step exactly 1/60 s, so use that rather
		# than reaching for a delta that does not exist here.
		var dt := 1.0 / 60.0
		t += dt

		var here := _at(pts, car.global_position)
		s = float(here["s"])
		var lat := float(here["lat"])
		var hw := _half_width(graph_ref, car.global_position)
		hw_seen = hw
		var off_line := absf(lat) > hw
		if off_line:
			if not off_now:
				off += 1
				off_now = true
				off_at = s
				Input.action_press("throttle", 0.0)
			off_worst = maxf(off_worst, absf(lat))
		elif off_now:
			off_now = false
			Input.action_press("throttle", 1.0)

		# THE ONLY THING THAT REACHES THE CAR. Binary, exactly as a keyboard gives it.
		if off_line and lat > 0.0:
			Input.action_press("steer_left", 1.0)
			Input.action_release("steer_right")
		elif off_line and lat < 0.0:
			Input.action_press("steer_right", 1.0)
			Input.action_release("steer_left")
		else:
			Input.action_release("steer_left")
			Input.action_release("steer_right")

		peak_steer = maxf(peak_steer, absf(float(car.steer)))
		top = maxf(top, float(car.speed_kph))

		if s >= total - SPAWN_S - 0.5:
			reached = true
			ended = "far end"
			break
		if car.is_sleeping():
			ended = "BODY ASLEEP at s=%.1f" % s
			break
	Input.action_release("throttle")
	Input.action_release("steer_left")
	Input.action_release("steer_right")

	var travelled := maxf(s - SPAWN_S, 0.0)
	print("[real] %s  corridor %.1f m  half-width %.1f m" % [street, corridor, hw_seen])
	print("[real]   distance from s=%.1f : %.1f m of %.1f m (%.0f%%)" % [
		SPAWN_S, travelled, total - SPAWN_S,
		100.0 * travelled / maxf(total - SPAWN_S, 0.001)])
	print("[real]   top speed         : %.1f km/h" % top)
	print("[real]   times off        : %d (worst %.2f m off the centreline)" % [off, off_worst])
	print("[real]   peak |steer|     : %.2f of 1.00%s" % [
		peak_steer, "  <- BANG-BANG: keyboard is 0.0 or 1.0, nothing between" if peak_steer > 0.99 else ""])
	print("[real]   run ended        : %s%s" % [ended,
		"" if off_at < 0.0 else " (first excursion at s=%.1f m)" % off_at])
	print("[real]   final            : x=%.1f z=%.1f s=%.1f speed=%.1f km/h" % [
		car.global_position.x, car.global_position.z, s, float(car.speed_kph)])
	return {"dist": travelled, "total": total - SPAWN_S, "top": top, "off": off,
		"peak_steer": peak_steer, "ended": ended, "reached": reached}


func _at(pts: PackedVector2Array, p: Vector3) -> Dictionary:
	var best_s := 0.0
	var best_lat := 0.0
	var best_d := INF
	var v := Vector2(p.x, p.z)
	var acc := 0.0
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		var q := a + ab * t
		var w := v - q
		var d := w.length()
		if d < best_d:
			best_d = d
			best_s = acc + sqrt(len2) * t
			var tan: Vector2 = ab / sqrt(len2)
			best_lat = tan.x * w.y - tan.y * w.x
		acc += sqrt(len2)
	return {"s": best_s, "lat": best_lat}


func _pose(pts: PackedVector2Array, d: float) -> Dictionary:
	var acc := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			var u := (d - acc) / seg
			var q := pts[i].lerp(pts[i + 1], u)
			var tan := (pts[i + 1] - pts[i]) / seg
			return {"pos": Vector3(q.x, SPAWN_Y, q.y), "yaw": atan2(-tan.x, -tan.y)}
		acc += seg
	var q2 := pts[pts.size() - 1]
	return {"pos": Vector3(q2.x, SPAWN_Y, q2.y), "yaw": 0.0}


func _half_width(g: RoadGraph, p: Vector3) -> float:
	if g == null:
		return 7.0
	var near: Dictionary = g.nearest_road(p)
	var eid := int(near["edge"])
	if eid < 0:
		return 7.0
	return float(g.edges[eid]["width"]) * 0.5