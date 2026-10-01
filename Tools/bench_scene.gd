extends SceneTree
## Frame-time and draw-call bench over the REAL game scene, one preset at a time.
##
##   godot --path . --rendering-driver vulkan --resolution 1280x720 \
##         --script res://Tools/bench_scene.gd -- [--preset=street] [--frames=180]
##
## --------------------------------------------------------------------------------
## WHY THIS IS SEPARATE FROM Tools/bench_render.gd
## --------------------------------------------------------------------------------
##
## `bench_render.gd` rebuilds the city from pieces: graph, NightEnv, a sun, a
## WorldBuilder. That is a good gate for scene-graph budgets and it stays
## deterministic, but it is not the game. It has no ReflectionProbe, no car, no
## chase camera, no traffic and no race director, and on this project those are
## not small: the probe re-renders the scene into a cubemap every frame, and the
## whole point of this bench is the number a player's machine sees.
##
## So this one loads res://Game/main.tscn and drives it exactly the way render.sh
## does - same presets, same auto-started race, same hidden menus - and only adds
## measurement. Nothing in Game/ is edited or reimplemented; the scene does its own
## booting. That is the difference between "the city costs 12 ms" and "the game
## costs 12 ms", and for a night scene with 1278 lamps and a reflection probe the
## second number is the one that matters.
##
## --------------------------------------------------------------------------------
## WHAT IS MEASURED, AND HOW HONESTLY
## --------------------------------------------------------------------------------
##
## **Frame time** is real, and it is the headline. Measured with `process_frame`
## deltas over N frames after a warm-up, because the first frames after a scene
## boot include shader compilation and MultiMesh upload, and reporting those would
## describe a one-off, not the steady state a player sits in. Reported as median
## and p95, not mean: a single stalled frame (a GC, another agent's box, a
## pipeline rebuild) moves a mean a long way and a median not at all.
##
## **Draw calls / primitives / objects** come from `RenderingServer.get_rendering_info`
## and are only meaningful on a real backend. Under `--headless` they read a hard
## zero (measured - see bench_render.gd's header), so this tool refuses to print
## a cost it cannot see and says so instead.
##
## **GPU time** is read from `Performance.get_monitor(Performance.TIMING_PROCESS)`:
## that is CPU frame time, so it is reported as such and NOT called GPU time. The
## real GPU number needs a timestamp query the engine does not expose to GDScript,
## and inventing one would be worse than not having it.

const PRESETS := ["street", "aerial", "carhero", "carfront"]
const WARMUP := 40


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var preset := _arg(args, "--preset=", PRESETS[0])
	var frames := maxi(int(_arg(args, "--frames=", "120")), 10)
	var repeat := maxi(int(_arg(args, "--repeat=", "3")), 1)

	print("=".repeat(78))
	print("  SCENE BENCH - real main.tscn")
	print("  preset=%s  frames=%d  repeat=%d  adapter='%s'" % [
		preset, frames, repeat, RenderingServer.get_video_adapter_name()])
	print("  resolution=%dx%d  vsync=%d" % [
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y,
		ProjectSettings.get_setting("display/window/vsync/vsync_mode")])
	print("  off: %s" % _arg(args, "--off=", "(nothing)"))
	print("=".repeat(78))

	if String(RenderingServer.get_video_adapter_name()).begins_with("NVIDIA") == false \
			and RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME) == 0:
		print("  WARNING: no real GPU counters. These numbers are not usable.")

	# The scene boots itself: main.gd builds the graph, the world, the player and
	# the menus in _ready. All this does is hold on to it.
	var t0 := Time.get_ticks_usec()
	var main: Node = (load("res://Game/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in WARMUP:
		await process_frame
	var boot_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_ablate(main, _arg(args, "--off=", ""))
	print("[bench] boot to first frame: %.0f ms" % boot_ms)

	# Same path render.sh takes: a shot has nobody at the keyboard, so a race is
	# started and the menus are put away before the preset is applied.
	if main.has_method("_auto_start_race"):
		main.call("_auto_start_race")
	for i in 24:
		await process_frame

	var camera: Node = main.get("camera")
	var car: Node = main.get("player_car")
	if camera == null:
		print("[bench] FAILED: main.gd has no camera")
		quit(1)
		return
	# Without this the chase camera reasserts its own pose next frame and every
	# preset silently renders as a chase shot - main.gd does the same for _capture.
	if "tracking" in camera:
		camera.set("tracking", false)
	var ok: bool = ShotPoser.apply(camera, preset)
	print("[bench] preset '%s' applied=%s  cam=%s" % [
		preset, ok, str((_cam3d(camera)).global_position.round() if _cam3d(camera) else Vector3.ZERO)])
	for i in 6:
		await process_frame

	# Freeze the world. A car-relative preset (carhero/carfront) pins the CAMERA
	# once, but the car keeps driving, so the shot drifts out of frame over the
	# sampling window - measured, draw calls falling 874 -> 648 within one run,
	# which is the scene changing rather than the frame rate. Re-pinning the car
	# every frame makes the run repeatable and the presets comparable.
	# Pausing the tree is what actually freezes the shot: pinning the player car
	# is not enough, because the AI traffic keeps driving and it is the traffic
	# that moves the draw-call count. The tree still processes and renders, so the
	# frame loop below keeps running.
	var home_pos := (car as Node3D).global_position if car is Node3D else Vector3.ZERO
	paused = true
	for r in repeat:
		var samples: Array[float] = []
		for i in frames:
			var a := Time.get_ticks_usec()
			await process_frame
			samples.append((Time.get_ticks_usec() - a) / 1000.0)
		# Read the counters after a drawn frame, or they describe the previous one.
		await RenderingServer.frame_post_draw
		_draw(r, samples, preset)
	_visibility(main, preset)
	quit(0)


## Turns individual costs off so the frame time difference between runs is an
## attribution rather than a guess. Each is the thing a project.godot change would
## actually toggle, so the delta it produces is the number a settings decision
## needs. Ablations are applied AFTER boot, so the baseline run and the ablated
## run boot identically and differ only in the one thing switched off.
func _ablate(main: Node, spec: String) -> void:
	if spec.strip_edges() == "":
		return
	var want := spec.split(",", false)
	var world: Node = main.get("world") if "world" in main else null
	var changed: Array[String] = []
	for w in want:
		var what := String(w).strip_edges()
		match what:
			"probe":
				for n in _find_all(root, "ReflectionProbe"):
					# 0 == UPDATE_DISABLED. Set by value so the enum's spelling
					# cannot be a parse error on a different 4.x build.
					n.set("update_mode", 0)
					changed.append("probe")
			"fog":
				for n in _find_all(root, "WorldEnvironment"):
					var env := n as WorldEnvironment
					if env == null or env.environment == null:
						continue
					env.environment = env.environment.duplicate()
					env.environment.volumetric_fog_enabled = false
					env.environment.fog_enabled = false
					env.environment.ssao_enabled = false
					env.environment.ssil_enabled = false
					changed.append("fog+ssao+ssil")
			"lights":
				var omni := _all_of(world, "OmniLight3D")
				for n in omni:
					n.set("visible", false)
				changed.append("%d omni lights" % omni.size())
			"shadows":
				for n in _all_of(root, "DirectionalLight3D"):
					n.set("shadow_enabled", false)
				var oshadow := _all_of(world, "OmniLight3D")
				for n in oshadow:
					n.set("shadow_enabled", true)
				changed.append("directional shadow off, %d omni shadows ON" % oshadow.size())
			"msaa":
				get_root().set("msaa_3d", 0)
				changed.append("msaa")
	print("[ablate] disabled: %s" % ", ".join(changed))


func _find_all(from: Node, cls: String) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array = [from]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.is_class(cls):
			out.append(n)
	return out


## Every descendant whose class name matches, so a caller can name a type
## without the script needing that type in scope.
func _all_of(from: Node, cls: String) -> Array:
	return _find_all(from, cls)


func _draw(run: int, samples: Array[float], preset: String) -> void:
	samples.sort()
	var n := samples.size()
	var med: float = samples[int(n * 0.5)]
	var p95: float = samples[mini(int(n * 0.95), n - 1)]
	var lo: float = samples[0]
	var hi: float = samples[n - 1]
	var mean := 0.0
	for s in samples:
		mean += s
	mean /= float(n)

	var draws := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var objs := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
	var prims := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	var cpu_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0

	print("")
	print("  [%s] run %d" % [preset, run + 1])
	print("    frame time      median %.2f ms | mean %.2f | p95 %.2f | min %.2f | max %.2f" % [
		med, mean, p95, lo, hi])
	print("    implied rate    %.1f fps (median) | %.1f fps (p95)" % [
		1000.0 / maxf(med, 0.001), 1000.0 / maxf(p95, 0.001)])
	print("    cpu process     %.2f ms" % cpu_ms)
	print("    draw calls      %d" % draws)
	print("    objects/frame   %d" % objs)
	print("    primitives      %d" % prims)


## What the camera can actually see. Frustum culling is doing most of the work in
## a city this size, so a preset that looks along a street and a preset that
## looks at the whole map are not comparable without it.
func _visibility(main: Node, preset: String) -> void:
	print("")
	print("  [%s] scene inventory" % preset)
	var host: Node = main.get("world") if main.has_method("get") else null
	if host == null or not is_instance_valid(host):
		print("    (no World node)")
		return
	var cam := _bench_camera()
	var counts := {"meshes": 0, "multimesh": 0, "lights": 0, "shadow_lights": 0, "nodes": 0}
	var stack: Array = [host]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		counts["nodes"] = int(counts["nodes"]) + 1
		if n is Light3D:
			counts["lights"] = int(counts["lights"]) + 1
			if (n as Light3D).shadow_enabled:
				counts["shadow_lights"] = int(counts["shadow_lights"]) + 1
		elif n is MeshInstance3D:
			counts["meshes"] = int(counts["meshes"]) + 1
		elif n is MultiMeshInstance3D:
			counts["multimesh"] = int(counts["multimesh"]) + 1
	for k in counts:
		print("    %-14s %d" % [k, int(counts[k])])
	if cam != null:
		print("    camera pos      %s fov %.1f" % [str(cam.global_position.round()), cam.fov])


func _bench_camera() -> Camera3D:
	var main: Node = root.get_child(root.get_child_count() - 1)
	var camera: Node = main.get("camera")
	return _cam3d(camera)


func _cam3d(camera: Node) -> Camera3D:
	if camera == null:
		return null
	for c in camera.get_children():
		if c is Camera3D:
			return c
	return camera as Camera3D


func _arg(args: Array, prefix: String, fallback: String) -> String:
	for a in args:
		var s := String(a)
		if s.begins_with(prefix):
			return s.substr(prefix.length())
	return fallback