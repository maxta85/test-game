extends SceneTree
## Frame cost of a rendered preset: draw calls, objects, triangles, frame time.
##
## The numbers that matter for "does this look better" are not the ones a
## screenshot can tell you. Every art asset in this repo is a way of spending
## draw calls, so a facade pass that makes the street read and costs 200 draws is
## a different decision from one that costs 2000, and only a number separates
## them.
##
## The boot below is Game/main.gd's, minus the car, the race and the menus: the
## world under test is the world the game builds, and nothing else in the frame
## moves the numbers. The camera is posed from the same `ShotPoser` presets
## render.sh uses, so a number here describes the shot a human actually looks at.
##
## Run with:
##   GODOT=$HOME/godot ./render.sh-measure street
## or directly:
##   godot --path . --rendering-driver vulkan --audio-driver Dummy \
##     --script res://Tools/frame_stats.gd street

const WARMUP := 90
const SETTLE := 61

var _t_us: Array[float] = []
var _draws: Array[int] = []
var _objs: Array[int] = []
var _tris: Array[int] = []


func _initialize() -> void:
	var preset := "street"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		preset = String(args[0])

	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())

	var night := NightEnv.new()
	root.add_child(night)

	var sun := DirectionalLight3D.new()
	sun.light_color = MatLib.MOON
	sun.light_energy = 0.55
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	sun.rotation_degrees = Vector3(-52, -128, 0)
	root.add_child(sun)

	var probe := ReflectionProbe.new()
	probe.size = Vector3(180, 90, 180)
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	probe.intensity = 0.9
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	probe.origin_offset = Vector3(0, 8, 0)
	probe.position = Vector3(0, 12, 40)
	root.add_child(probe)

	var t0 := Time.get_ticks_msec()
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	var build_ms := Time.get_ticks_msec() - t0

	# The car shots are framed on the car, and a facade or a lane line is exactly
	# what those two presets exist to judge. `ShotPoser` reaches the car through a
	# ChaseCamera, so the rig builds one: same body, same camera rig as the game's
	# _spawn_player, without the race, the menus or the rival.
	var holder := Node3D.new()
	if ShotPoser.CAR_SHOTS.has(preset):
		var spec := CarDB.apply_upgrades(CarDB.get_spec("kairo_s13"), {})
		spec.start_position = OSMLayout.start_grid_position(0)
		spec.start_rotation = Vector3(0, -PI * 0.5, 0)
		var car := CarBody.new()
		car.name = "PlayerCar"
		car.spec = spec
		root.add_child(car)
		car.reset_to(spec.start_position, spec.start_rotation)
		var chase := ChaseCamera.new()
		chase.name = "Camera"
		root.add_child(chase)
		chase.set_car(car)
		chase.tracking = false
		holder = chase
	else:
		root.add_child(holder)
		holder.add_child(Camera3D.new())

	for i in WARMUP:
		await process_frame
	if not ShotPoser.apply(holder, preset):
		push_error("frame_stats: no '%s' preset" % preset)
		quit(1)
		return

	var cam := _camera_of(holder)

	for i in SETTLE:
		var f0 := Time.get_ticks_usec()
		await process_frame
		_t_us.append(float(Time.get_ticks_usec() - f0))
		_draws.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		_objs.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
		_tris.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))

	var ms := _median_f(_t_us) / 1000.0
	print("STATS preset=%s camera=%s fov=%.1f" % [preset, str(cam.global_position.round()), cam.fov])
	print("STATS build_ms=%d" % build_ms)
	print("STATS draws=%d objects=%d tris=%d frame_ms=%.2f fps=%.1f" % [
		_median_i(_draws), _median_i(_objs), _median_i(_tris), ms, 1000.0 / maxf(ms, 0.001)])
	quit(0)


## Median over the settled frames. One frame is one sample of one, and a single
## reflection-probe update can swing any of these on its own.
func _median_i(v: Array[int]) -> int:
	var s := v.duplicate()
	s.sort()
	return s[s.size() / 2]


func _median_f(v: Array[float]) -> float:
	var s := v.duplicate()
	s.sort()
	return s[s.size() / 2]


func _camera_of(node: Node) -> Camera3D:
	for c in node.get_children():
		if c is Camera3D:
			return c
	return null