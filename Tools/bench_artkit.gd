extends SceneTree
## What the artkit integration will cost, measured in one boot.
##
##   godot --path . --rendering-driver vulkan --resolution 1280x720 \
##         --script res://Tools/bench_artkit.gd -- [--preset=street] [--frames=150]
##
## --------------------------------------------------------------------------------
## WHY ONE BOOT, TWO MEASUREMENTS
## --------------------------------------------------------------------------------
##
## The obvious way to get "what artkit adds" is to run the game, then run the game
## with artkit, and subtract. On this box that subtraction is worth about 1 ms of
## noise (three agents share the machine; p95 frame times move by 10 ms between
## runs on their own), and the delta being measured here is of that order. So
## both numbers are taken in the SAME process, from the SAME scene instance, with
## the same preset and the same frozen world - the only thing between them is the
## `ArtKitScatter` node. Whatever it moves, it moved because of artkit.
##
## --------------------------------------------------------------------------------
## WHAT IS ACTUALLY FED IN
## --------------------------------------------------------------------------------
##
## Not a synthetic grid. The footprints are the real 2198 OSM rings, taken from
## the same `OSMBuildings.plan()` the world uses, so the wrapped-building cost is
## the cost of the city as it exists. The props are placed the way the world
## builder places them - along street edges, alternating kerbs, at a fixed
## spacing - because a scatter of props in a field frustum-culls away and would
## measure nothing. Both are what the integration would hand over.
##
## The kit claims 400 wrapped footprints -> 15 draw calls and 1650 placements ->
## 126. Those are the kit's own numbers from its own check, on its own rig. This
## script does not take them on trust: it prints what the scatter actually
## produced inside the real scene, with the real lights, at the real presets.

const PRESETS := ["street", "aerial", "carhero", "carfront"]
const PROP_MIX := [
	"palm_coco", "palm_alexandrine", "palm_areca", "palm_fan",
	"tree_rain_tree", "tree_cedar", "tree_fern",
	"bush_scrub", "grass_tuft", "power_pole", "sign_post",
]
const WARMUP := 40


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var preset := _arg(args, "--preset=", PRESETS[0])
	var frames := maxi(int(_arg(args, "--frames=", "120")), 10)
	var prop_step := float(_arg(args, "--prop-step=", "18.0"))

	print("=".repeat(78))
	print("  ARTKIT COST BENCH - one boot, scatter added between two measurements")
	print("  preset=%s frames=%d adapter='%s'" % [
		preset, frames, RenderingServer.get_video_adapter_name()])
	print("=".repeat(78))

	var main: Node = (load("res://Game/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in WARMUP:
		await process_frame

	if main.has_method("_auto_start_race"):
		main.call("_auto_start_race")
	for i in 24:
		await process_frame

	var camera: Node = main.get("camera")
	if "tracking" in camera:
		camera.set("tracking", false)
	ShotPoser.apply(camera, preset)
	for i in 6:
		await process_frame
	paused = true
	# Same ablation flags as bench_scene, so "what does the probe cost" is a
	# measurement here too rather than an inference from the primitive count.
	var off := _arg(args, "--off=", "")
	print("  off: %s" % (off if off != "" else "(nothing)"))
	_ablate(main, off)

	var before: Dictionary = await _measure(frames)
	_counters("BEFORE (no artkit)", before)

	# --- the thing being measured -------------------------------------------
	var graph: RoadGraph = main.get("graph")
	var world: Node3D = main.get("world")
	var plan := OSMBuildings.plan(graph)
	var placements: Array = []
	for e in plan["buildings"]:
		# The dictionary form rather than a bare polygon: storeys and the lit
		# fraction are what make a wrapped building look like a house instead of
		# a shoebox, and the integration will pass them too.
		placements.append({
			"footprint": e["ring"],
			"storeys": 1 if e["flat"] else 2,
			"lit": 0.4,
			"seed": int(e["id"]),
		})
	var n_foot := placements.size()
	var n_prop := 0
	for p in _prop_placements(graph, prop_step):
		placements.append(p)
		n_prop += 1

	var t0 := Time.get_ticks_usec()
	var scatter := ArtKitScatter.attach(world, placements)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("")
	print("  ARTKIT BUILD")
	print("    %d OSM footprints + %d props = %d placements" % [n_foot, n_prop, placements.size()])
	print("    built in %.0f ms (one-off, at load)" % build_ms)
	var st: Dictionary = scatter.stats
	var skipped: Array = st.get("skipped", [])
	var brief := {}
	for k in st:
		if k != "skipped":
			brief[k] = st[k]
	print("    scatter says: %s" % str(brief))
	if not skipped.is_empty():
		print("    SKIPPED %d (first 5): %s" % [skipped.size(), str(skipped.slice(0, 5))])

	for i in 20:
		await process_frame
	var after: Dictionary = await _measure(frames)
	_counters("AFTER (+artkit)", after)

	print("")
	print("  DELTA")
	print("    frame time   %.2f ms -> %.2f ms   (%+.2f ms, x%.2f)" % [
		before["median"], after["median"], after["median"] - before["median"],
		after["median"] / maxf(before["median"], 0.001)])
	print("    fps          %.1f -> %.1f" % [1000.0 / before["median"], 1000.0 / after["median"]])
	print("    draw calls   %d -> %d   (%+d)" % [before["draws"], after["draws"], after["draws"] - before["draws"]])
	print("    primitives   %d -> %d   (%+d)" % [before["prims"], after["prims"], after["prims"] - before["prims"]])
	print("    the kit's claim: 400 footprints -> 15 draws, 1650 placements -> 126 draws.")
	print("    scatter's own nodes here: %d. Measured delta above is what it costs in THIS scene." % int(st["nodes"]))
	quit(0)


## Props along the street, the way the world builder scatters them: every
## `step` metres along a street-class edge, alternating kerbs, snapped to the
## footpath. Deterministic - same graph, same list, every run.
func _prop_placements(graph: RoadGraph, step: float) -> Array:
	var out: Array = []
	var i := 0
	for ei in graph.edges.size():
		var e: Dictionary = graph.edges[ei]
		if int(e["class"]) < RoadGraph.RoadClass.STREET:
			continue
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < step:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var n := int(length / step)
		for k in n:
			var mid: Vector2 = a.lerp(b, (float(k) + 0.5) / float(n))
			var side := 1.0 if (ei + k) % 2 == 0 else -1.0
			var off := float(e["width"]) * 0.5 + 1.4
			var p := mid + nrm * off * side
			out.append({
				"prop": String(PROP_MIX[i % PROP_MIX.size()]),
				"pos": Vector3(p.x, 0.0, p.y),
				"yaw": atan2(dir.y, dir.x) + (0.3 if side > 0.0 else -0.3),
				"scale": 1.0,
				"seed": i,
			})
			i += 1
	return out


func _ablate(main: Node, spec: String) -> void:
	if spec.strip_edges() == "":
		return
	var world: Node = main.get("world") if "world" in main else null
	var done: Array[String] = []
	for w in spec.split(",", false):
		match String(w).strip_edges():
			"probe":
				# update_mode=0 is not enough: measured, the draw-call count did
				# not move by one. The node has to leave the tree, because what the
				# counter sees is the cubemap render being submitted, not the mode
				# flag on the node that owns it.
				var probes := _all_of(root, "ReflectionProbe")
				for n in probes:
					var mode_before: int = n.get("update_mode")
					print("  [probe] update_mode was %d" % mode_before)
					n.get_parent().remove_child(n)
					n.queue_free()
				done.append("%d reflection probes REMOVED" % probes.size())
			"lights":
				var omni := _all_of(world, "OmniLight3D")
				for n in omni:
					n.set("visible", false)
				done.append("%d omni lights off" % omni.size())
			"fog":
				for n in _all_of(root, "WorldEnvironment"):
					var e := n as WorldEnvironment
					if e != null and e.environment != null:
						e.environment = e.environment.duplicate()
						e.environment.volumetric_fog_enabled = false
				done.append("volumetric fog off")
	print("[ablate] %s" % ", ".join(done))


func _all_of(from: Node, cls: String) -> Array:
	var out: Array = []
	var stack: Array = [from]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.is_class(cls):
			out.append(n)
	return out


func _measure(frames: int) -> Dictionary:
	var s: Array[float] = []
	for i in frames:
		var a := Time.get_ticks_usec()
		await process_frame
		s.append((Time.get_ticks_usec() - a) / 1000.0)
	s.sort()
	await RenderingServer.frame_post_draw
	return {
		"median": s[int(s.size() * 0.5)],
		"p95": s[mini(int(s.size() * 0.95), s.size() - 1)],
		"min": s[0],
		"draws": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objs": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)),
		"prims": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
	}


func _counters(label: String, m: Dictionary) -> void:
	print("")
	print("  %s" % label)
	print("    frame time   median %.2f ms | p95 %.2f | min %.2f   (%.1f fps median)" % [
		m["median"], m["p95"], m["min"], 1000.0 / maxf(m["median"], 0.001)])
	print("    draw calls   %d" % int(m["draws"]))
	print("    objects      %d" % int(m["objs"]))
	print("    primitives   %d" % int(m["prims"]))


func _arg(args: Array, prefix: String, fallback: String) -> String:
	for a in args:
		var s := String(a)
		if s.begins_with(prefix):
			return s.substr(prefix.length())
	return fallback