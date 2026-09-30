class_name PerfProbe
extends SceneTree
## Renders the real Cairns city and reports what it costs.
##
##   godot --headless --path . --script res://Tools/bench_render.gd -- [--buildings]
##   godot --path . --rendering-driver vulkan --script res://Tools/bench_render.gd -- [--buildings]
##
## --------------------------------------------------------------------------------
## WHY THESE NUMBERS COME FROM THE SCENE GRAPH AND NOT FROM RenderingServer
## --------------------------------------------------------------------------------
##
## `RenderingServer.get_rendering_info()` is the obvious way to ask "how many draw
## calls is this?" and it is exactly the number that is missing here. Measured on
## this machine, same scene, same frames:
##
##   --headless (dummy rasteriser)         -> draw calls 0, objects 0, primitives 0
##   --rendering-driver vulkan (llvmpipe)  -> draw calls 5, objects 5, primitives 60
##
## `--headless` installs a rasteriser with no mesh storage and no render list, so
## every per-frame counter reads a hard zero - not a small number, a zero, for a
## scene that plainly has geometry in it. A gate on those counters would pass
## forever while measuring nothing, which is worse than no gate because it looks
## like coverage.
##
## Two engine helpers are unusable for the same reason and were measured, not
## assumed:
##
##   Camera3D.is_position_in_frustum()  returns false for a point dead ahead and
##                                       true for a point behind the camera. It
##                                       delegates to the dummy RenderingServer.
##   MultiMeshInstance3D.get_aabb()     reads back as a zero-size AABB, because
##                                       the dummy has no mesh storage. The
##                                       builder sets `custom_aabb` explicitly,
##                                       so that is read instead.
##
## What does survive is plain resource metadata - `Mesh.get_surface_count()`,
## `Mesh.surface_get_arrays()`, `MultiMesh.instance_count`, node types, light
## flags - plus the camera's own basis. So the counts below are built from those:
## nodes, surfaces, vertices, triangles, lights, shadow casters, and a draw-call
## model of how the forward+ renderer issues passes. They are properties of the
## scene, not of the frame, so they survive the dummy rasteriser and they are
## deterministic: same graph in, same numbers out, on any machine, no matter what
## else is competing for the CPU. Tests/test_perf.gd gates on these.
##
## The draw-call figure is named `draw_calls_est` because it models the renderer
## rather than reporting it. The report prints the model beside llvmpipe's real
## number whenever a real backend is present, so the error is visible rather than
## assumed.
##
## Frame time is measured and printed and is deliberately NOT gated: llvmpipe is a
## software rasteriser on a shared box with other agents running, so milliseconds
## here mostly measure CPU contention.

const SHOT_PRESET := "street"
## Shadow map faces a shadow-casting light pushes geometry through. A shadowed
## omni is a cubemap. In the city as built this term is 0, because the
## streetlights are shadow-disabled on purpose - worth asserting, not assuming.
const SHADOW_FACES := {"OmniLight3D": 6, "SpotLight3D": 1, "DirectionalLight3D": 1}


## Builds the city the way Game/main.gd does - same graph, same builder, same
## night and moon - so the numbers describe the game rather than a test rig.
## `with_buildings` additionally hangs OSMBuildings off the world: it is the one
## system in the brief that exists in the tree but is wired into nothing.
static func build_city(tree: SceneTree, with_buildings: bool = false) -> Dictionary:
	var host := Node3D.new()
	host.name = "BenchWorld"
	tree.root.add_child(host)

	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())

	# NightEnv and the moon are main.gd's, not WorldBuilder's. Without them the
	# probe would count a scene with no key light and understate the shadow pass.
	var night := NightEnv.new()
	night.name = "NightEnvironment"
	host.add_child(night)

	var sun := DirectionalLight3D.new()
	sun.light_color = MatLib.MOON
	sun.light_energy = 0.55
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	sun.rotation_degrees = Vector3(-52, -128, 0)
	host.add_child(sun)

	var world := WorldBuilder.new()
	world.name = "World"
	host.add_child(world)
	world.build(graph)

	var osm_report := {}
	if with_buildings:
		osm_report = OSMBuildings.build(world, graph)

	return {"host": host, "world": world, "graph": graph, "osm": osm_report}


## Camera on the project's own standard street shot, via ShotPoser so this bench
## and render.sh frame the same view. A bench pointed somewhere else measures the
## wrong frustum and reports it as the wrong frustum.
static func add_camera(host: Node3D) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "BenchCamera"
	host.add_child(cam)
	if not ShotPoser.apply(host, SHOT_PRESET):
		cam.global_position = Vector3(0.0, 3.2, -60.0)
		cam.look_at(Vector3(0.0, 1.0, 30.0), Vector3.UP)
		cam.fov = 52.0
	cam.current = true
	return cam


## Walks a subtree and counts what the renderer would have to touch.
##
## `camera` is optional. With it, the counts are frustum-culled the way the
## renderer culls and describe one frame from one seat. Without it they cover the
## whole city and describe what the world costs to exist. The gate uses the
## second form: a budget on the world does not move when someone re-poses a
## camera, and does not stop guarding because a preset changed.
static func count(host: Node, camera: Camera3D = null) -> Dictionary:
	var c := {
		"mesh_nodes": 0, "multimesh_nodes": 0, "surfaces": 0,
		"vertices": 0, "triangles": 0, "multimesh_instances": 0, "line_segments": 0,
		"draw_calls_est": 0,
		"lights": 0, "omni": 0, "spot": 0, "directional": 0,
		"lights_shadow": 0, "shadow_faces": 0, "mesh_shadow_casters": 0,
		"culled_nodes": 0, "holder_nodes": 0, "nodes": 0,
		"by_bucket": {},
	}
	var planes: Array = _frustum_planes(camera) if camera != null else []

	var stack: Array = [host]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		c["nodes"] = int(c["nodes"]) + 1

		if n is Light3D:
			c = _count_light(c, n as Light3D)
			continue

		var vi := n as VisualInstance3D
		var casts: bool = vi != null and vi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if casts:
			c["mesh_shadow_casters"] = int(c["mesh_shadow_casters"]) + 1

		var mesh: Mesh = null
		var instances := 0
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
			c["mesh_nodes"] = int(c["mesh_nodes"]) + 1
		elif n is MultiMeshInstance3D:
			var mmi := n as MultiMeshInstance3D
			# _flush_batches() makes `Batch_<name>` a holder MultiMeshInstance3D
			# with no multimesh of its own, holding the real MultiMeshes as
			# children. A holder is not a batch that lost its geometry.
			if mmi.multimesh == null:
				c["holder_nodes"] = int(c["holder_nodes"]) + 1
				continue
			mesh = mmi.multimesh.mesh
			instances = mmi.multimesh.instance_count
			c["multimesh_nodes"] = int(c["multimesh_nodes"]) + 1
			c["multimesh_instances"] = int(c["multimesh_instances"]) + instances
		if mesh == null:
			continue

		if not planes.is_empty() and not _in_frustum(planes, _aabb_of(n)):
			c["culled_nodes"] = int(c["culled_nodes"]) + 1
			continue

		var verts := 0
		var tris := 0
		var segs := 0
		for s in mesh.get_surface_count():
			c["surfaces"] = int(c["surfaces"]) + 1
			var arrays: Array = mesh.surface_get_arrays(s)
			# An unindexed surface arrives with null index and normal arrays, so
			# every one of these has to be a variant read, not a typed one.
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			verts += v.size()
			var count := idx.size() if idx.size() > 0 else v.size()
			match mesh.surface_get_primitive_type(s):
				Mesh.PRIMITIVE_LINES:
					segs += count / 2
				Mesh.PRIMITIVE_LINE_STRIP:
					segs += maxi(count - 1, 0)
				Mesh.PRIMITIVE_POINTS:
					segs += count
				_:
					tris += count / 3
		c["vertices"] = int(c["vertices"]) + verts
		c["triangles"] = int(c["triangles"]) + tris
		c["line_segments"] = int(c["line_segments"]) + segs

		# A MultiMesh is ONE draw call per surface however many instances it
		# holds. That is the whole reason the builder batches, so the multiplier
		# is per surface and never per instance.
		c["draw_calls_est"] = int(c["draw_calls_est"]) + mesh.get_surface_count()

		var b := _tally(c["by_bucket"], _bucket(n))
		b["nodes"] += 1
		b["surfaces"] += mesh.get_surface_count()
		b["triangles"] += tris
		b["line_segments"] += segs
		b["vertices"] += verts
		b["instances"] += instances

	return c


static func _count_light(c: Dictionary, l: Light3D) -> Dictionary:
	c["lights"] = int(c["lights"]) + 1
	if l is OmniLight3D:
		c["omni"] = int(c["omni"]) + 1
	elif l is SpotLight3D:
		c["spot"] = int(c["spot"]) + 1
	elif l is DirectionalLight3D:
		c["directional"] = int(c["directional"]) + 1
	var faces := 0
	if l.shadow_enabled:
		c["lights_shadow"] = int(c["lights_shadow"]) + 1
		faces = int(SHADOW_FACES.get(l.get_class(), 0))
		c["shadow_faces"] = int(c["shadow_faces"]) + faces
	var b := _tally(c["by_bucket"], _bucket(l))
	b["lights"] += 1
	if l.shadow_enabled:
		b["shadow_lights"] += 1
	b["shadow_faces"] += faces
	return c


static func _tally(by: Dictionary, key: String) -> Dictionary:
	if not by.has(key):
		by[key] = {"nodes": 0, "surfaces": 0, "triangles": 0, "vertices": 0,
			"line_segments": 0, "instances": 0, "lights": 0, "shadow_lights": 0,
			"shadow_faces": 0}
	return by[key]


## Total draw calls the forward+ pass issues: one per visible surface, repeated
## once per shadow face of every shadowed light.
static func total_draw_calls(c: Dictionary) -> int:
	return int(c["draw_calls_est"]) * (1 + int(c["shadow_faces"]))


## Nearest meaningful ancestor name. Godot auto-names unparented nodes
## "@MultiMeshInstance3D@1234" and unparented geometry "@MeshInstance3D@88", and
## both the builder's batches and its un-batched geometry are exactly that, so
## auto names and the SceneTree's own "root" are skipped in favour of whatever
## real owner sits above them. Anything with no real owner above it is
## unattributed, and saying so is more useful than filing it under the city.
static func _bucket(n: Node) -> String:
	var cur: Node = n
	while cur != null:
		var nm := String(cur.name)
		if nm != "" and not nm.begins_with("@") and nm != "root" and nm != "BenchWorld" \
				and nm != "World" and nm != "NightEnvironment" and nm != "BenchCamera":
			return nm
		cur = cur.get_parent()
	return "(unattributed)"


## The six frustum planes in world space, built from the camera's own axes.
##
## Hand-built rather than read out of `get_camera_projection()` because Godot's
## projection matrix is not a plain [-1,1] NDC z range, and picking the near and
## far rows out of it correctly is a sign-error trap. From the basis there is
## nothing to misread: a point p is inside when |p.right| <= p.fwd * tan_x, and
## so on. Godot's Plane is positive on the side the normal points at, so every
## normal below points INWARD and "inside" is distance >= 0. The four side planes
## pass through the camera, which is why their distance is just -n . cam_pos.
static func _frustum_planes(cam: Camera3D) -> Array[Plane]:
	var out: Array[Plane] = []
	if cam == null:
		return out
	var b := cam.global_transform.basis
	var fwd := -b.z
	var right := b.x
	var up := b.y
	var ty := tan(deg_to_rad(cam.fov) * 0.5)
	var aspect := 16.0 / 9.0
	var vp_size := Vector2.ZERO
	if cam.get_viewport() != null:
		vp_size = cam.get_viewport().get_visible_rect().size
	if vp_size.x > 0.0 and vp_size.y > 0.0:
		aspect = vp_size.x / vp_size.y
	var tx := ty * aspect
	var origin := cam.global_position
	var locals: Array[Vector3] = []
	locals.append(fwd * tx - right)   # the frustum's right edge, facing inward
	locals.append(fwd * tx + right)   # the left edge
	locals.append(fwd * ty - up)      # the top edge
	locals.append(fwd * ty + up)      # the bottom edge
	for l in locals:
		var n: Vector3 = l.normalized()
		out.append(Plane(n, -n.dot(origin)))
	out.append(Plane(fwd, cam.near - fwd.dot(origin)))
	out.append(Plane(-fwd, fwd.dot(origin) - cam.far))
	return out


## Conservative AABB-vs-frustum test: a node counts as visible unless every
## corner is outside the same plane, which is how the renderer culls - on
## bounds, not on exact triangles.
static func _in_frustum(planes: Array, aabb: AABB) -> bool:
	if aabb.size == Vector3.ZERO:
		return true   # no bounds to test: never cull what cannot be measured
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(aabb.get_endpoint(i))
	for p in planes:
		var all_out := true
		for cpt in corners:
			if p.distance_to(cpt) >= 0.0:
				all_out = false
				break
		if all_out:
			return false
	return true


## World-space bounds of a geometry node, without asking the dummy rasteriser.
##
## `get_aabb()` and `MultiMesh.custom_aabb` are both in the node's LOCAL space, so
## they have to be pushed through the global transform before they mean anything
## to a world-space frustum.
static func _aabb_of(n: Node) -> AABB:
	var local := AABB()
	if n is MeshInstance3D:
		local = (n as MeshInstance3D).get_aabb()
	elif n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh == null:
			return AABB()
		# MMI.get_aabb() reads back as a zero-size box under the dummy renderer.
		# The builder sets custom_aabb on every batch, so read that instead - it
		# is the same box the renderer would use.
		if mmi.multimesh.custom_aabb.size != Vector3.ZERO:
			local = mmi.multimesh.custom_aabb
		else:
			local = mmi.get_aabb()
	else:
		return AABB()
	if local.size == Vector3.ZERO:
		return AABB()
	return (n as Node3D).global_transform * local


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var with_buildings := args.has("--buildings")
	var n_frames := 60

	print("=".repeat(72))
	print("  CAIRNS AFTER DARK - render bench")
	print("  method: %s | adapter: '%s'" % [
		ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		RenderingServer.get_video_adapter_name()])
	if String(RenderingServer.get_video_adapter_name()) == "":
		print("  DUMMY RASTERISER: no video adapter, so per-frame counters are dead")
		print("  (all zero) and is_position_in_frustum is wrong. Scene-graph counts")
		print("  below are unaffected and are what the gate uses.")
	print("=".repeat(72))

	var t0 := Time.get_ticks_usec()
	var built := build_city(self, with_buildings)
	var host: Node3D = built["host"]
	var world: WorldBuilder = built["world"]
	var graph: RoadGraph = built["graph"]
	print("[bench] world build: %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	print("[bench] road graph: %s" % str(graph.stats()))
	var osm: Dictionary = built["osm"]
	if not osm.is_empty():
		# The report carries a `buildings` array holding every footprint ring, so
		# printing the whole thing writes a megabyte of JSON into the log. Only
		# the counters are interesting here.
		var summary := {}
		for k in osm:
			if k != "buildings":
				summary[k] = osm[k]
		print("[bench] osm_buildings: %s" % str(summary))

	for i in 8:
		await process_frame
	var cam := add_camera(host)
	for i in 4:
		await process_frame
	print("[bench] standard shot '%s': camera at %s fov=%.1f" % [
		SHOT_PRESET, str(cam.global_position.round()), cam.fov])

	# Whole city, no frustum: what the gate asserts on.
	var t1 := Time.get_ticks_usec()
	var whole := count(world, null)
	var walk_ms := (Time.get_ticks_usec() - t1) / 1000.0
	# Standard shot, frustum-culled: what a player actually sees.
	var shot := count(world, cam)
	print("[bench] scene-graph walk: %.1f ms for %d nodes" % [walk_ms, int(whole["nodes"])])

	var t2 := Time.get_ticks_usec()
	for i in n_frames:
		await process_frame
	var elapsed: float = (Time.get_ticks_usec() - t2) / 1000000.0
	print("[bench] frame time: %.2f ms/frame over %d frames (%.1f fps) - SOFTWARE RASTER, reported not gated"
		% [elapsed * 1000.0 / n_frames, n_frames, n_frames / maxf(elapsed, 0.001)])

	_report("WHOLE CITY (uncounted by camera - what the gate asserts)", whole)
	_report("STANDARD SHOT '%s' (frustum-culled - what a player sees)" % SHOT_PRESET, shot)

	var n_cars := 0
	for a in args:
		if String(a).begins_with("--cars="):
			n_cars = int(String(a).split("=")[1])
	if n_cars > 0:
		# One CarBody is the unit the whole vehicle roster multiplies: player,
		# rival, AI traffic and parked cars are all instances of it. Measuring
		# one and reporting the marginal cost per car is more useful than
		# guessing at how many will be on screen at once.
		var car_root := Node3D.new()
		car_root.name = "CarCostProbe"
		root.add_child(car_root)
		for i in n_cars:
			var cb := CarBody.new()
			cb.name = "ProbeCar%d" % i
			cb.spec = CarDB.get_spec(CarDB.ALL_IDS[i % CarDB.ALL_IDS.size()])
			car_root.add_child(cb)
		for i in 4:
			await process_frame
		var one := count(car_root, null)
		print("  %d x CarBody (roster is %d ids)" % [n_cars, CarDB.ALL_IDS.size()])
		print("    per car: nodes %d, surfaces %d, triangles %d, draw calls est %d, lights %d" % [
			int(one["nodes"]) / n_cars, int(one["surfaces"]) / n_cars,
			int(one["triangles"]) / n_cars, int(one["draw_calls_est"]) / n_cars,
			int(one["lights"]) / n_cars])
		print("    %d cars total: surfaces %d, triangles %d, draw calls est %d" % [
			n_cars, int(one["surfaces"]), int(one["triangles"]), int(one["draw_calls_est"])])

	print("  RENDERING SERVER")
	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var prims := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	print("    draw calls %d | objects %d | primitives %d" % [int(draws), int(objs), int(prims)])
	if int(draws) > 0:
		print("    model check on the shot: est main pass %d, est all passes %d, real %d (error %+.0f%%)" % [
			int(shot["draw_calls_est"]), total_draw_calls(shot), int(draws),
			100.0 * (float(int(shot["draw_calls_est"])) - float(draws)) / maxf(float(draws), 1.0)])
	else:
		print("    all zero: dummy rasteriser, nothing to compare against. This is the")
		print("    reason the gate counts the scene graph rather than the renderer.")

	quit(0)


static func _report(title: String, c: Dictionary) -> void:
	var tris := int(c["triangles"])
	print("")
	print("  %s" % title)
	print("    geometry")
	print("      mesh nodes / multimesh nodes   %d / %d" % [int(c["mesh_nodes"]), int(c["multimesh_nodes"])])
	print("      multimesh instances            %d" % int(c["multimesh_instances"]))
	print("      surfaces                      %d" % int(c["surfaces"]))
	print("      vertices                      %d" % int(c["vertices"]))
	print("      triangles                     %d  (%.1fk)" % [tris, tris / 1000.0])
	print("      line segments                 %d" % int(c["line_segments"]))
	print("      nodes culled by frustum       %d" % int(c["culled_nodes"]))
	print("    lighting")
	print("      lights (omni/spot/dir)        %d (%d/%d/%d)" % [
		int(c["lights"]), int(c["omni"]), int(c["spot"]), int(c["directional"])])
	print("      shadow-casting lights         %d  -> %d shadow map faces" % [
		int(c["lights_shadow"]), int(c["shadow_faces"])])
	print("      mesh shadow casters           %d" % int(c["mesh_shadow_casters"]))
	print("    draw calls (modelled, not measured)")
	print("      est. main pass                %d" % int(c["draw_calls_est"]))
	print("      est. incl. shadow passes      %d" % total_draw_calls(c))

	var rows: Array = c["by_bucket"].keys()
	rows.sort_custom(func(a, b):
		return _rank(c, a) > _rank(c, b))
	print("    cost by subsystem, ranked")
	for k in rows:
		var e: Dictionary = c["by_bucket"][k]
		print("      %-22s tris=%-8d v=%-8d seg=%-6d surf=%-4d inst=%-6d lights=%-5d shadowf=%d" % [
			str(k), int(e["triangles"]), int(e["vertices"]), int(e["line_segments"]),
			int(e["surfaces"]), int(e["instances"]), int(e["lights"]), int(e["shadow_faces"])])


## Ranks a bucket by what actually costs: shadow faces first (each one redraws
## every caster), then triangles, then lights.
static func _rank(c: Dictionary, key: String) -> int:
	var e: Dictionary = c["by_bucket"][key]
	return int(e["shadow_faces"]) * 1000000000 + int(e["triangles"]) * 10 \
		+ int(e["line_segments"]) + int(e["lights"])
