extends SceneTree
## What the road surface costs, in a real frame.
##
## Chunking the carriageway turns one draw call into N, so the claim "that is a
## fair trade for correct light assignment" has to be a number, not an opinion.
## This builds the same world the game builds, from the same layout, under the
## same night environment, samples a frame, then hides the tarmac and samples
## again: the difference is what the road surface alone costs.
##
## Autoloads are not registered under --script, so Game/main.gd (which reads
## Cfg) cannot be instantiated here. The boot below is the same as main.gd's
## minus the car, the race and the HUD, which is a cleaner isolation anyway.
##
## Run with:
##   xvfb-run -a godot --path . --rendering-driver opengl3 --audio-driver Dummy \
##     --script res://Systems/road_render/draw_calls.gd [PRESET]
## PRESET defaults to "street". Use "aerial" to see what culling is worth: from
## 420 m up, one city-sized mesh is either fully drawn or not drawn at all.

const WARMUP := 60
const SETTLE := 21


func _initialize() -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())

	var night := NightEnv.new()
	root.add_child(night)

	# main.gd's fill light, verbatim - the road's own lighting is the thing under
	# test, so the ambient conditions have to be the real ones.
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

	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(g)

	# Framed exactly as the beauty shot's "street" preset frames it, so the
	# number describes the frame a human actually looks at. Posed after the
	# warmup: during _initialize() root is not in the tree yet and look_at
	# refuses to run, which silently leaves the camera at the origin.
	var holder := Node3D.new()
	root.add_child(holder)
	var cam := Camera3D.new()
	holder.add_child(cam)

	for i in WARMUP:
		await process_frame
	var preset := "street"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		preset = String(args[0])
	if not ShotPoser.apply(holder, preset):
		push_error("draw_calls: could not pose the camera at the %s preset" % preset)
		quit(1)
		return
	print("MEAS preset=%s camera=%s fov=%.1f" % [preset, str(cam.global_position.round()), cam.fov])

	var road: Array[MeshInstance3D] = []
	for c in world.get_children():
		if c is MeshInstance3D and (String(c.name).begins_with("RoadSurface")
				or String(c.name).begins_with("Intersections")):
			road.append(c)
	var tris := 0
	for m in road:
		if m.mesh != null:
			tris += m.mesh.get_faces().size() / 3
	print("ROAD road_meshes=%d tarmac_triangles=%d" % [road.size(), tris])

	var with_road := await _sample()
	for m in road:
		m.visible = false
	var without_road := await _sample()
	for m in road:
		m.visible = true

	print("DRAWCALLS with_road=%d without_road=%d road_costs=%d" % [
		with_road["draws"], without_road["draws"],
		with_road["draws"] - without_road["draws"]])
	print("DRAWCALLS objects=%d/%d tris=%d/%d" % [
		with_road["objects"], without_road["objects"],
		with_road["tris"], without_road["tris"]])
	quit(0)


## Median over SETTLE frames. One frame is one sample of one, and a single
## reflection-probe update can swing the count on its own.
func _sample() -> Dictionary:
	var draws: Array[int] = []
	var objs: Array[int] = []
	var tris: Array[int] = []
	for i in SETTLE:
		await process_frame
		draws.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		objs.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
		tris.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
	draws.sort()
	objs.sort()
	tris.sort()
	var m := SETTLE / 2
	return {"draws": draws[m], "objects": objs[m], "tris": tris[m]}
