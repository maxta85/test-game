extends SceneTree

## JOB 1 probe for t128. Reproduces the `walk3` camera of
## `World/look_dev_capture.gd` EXACTLY (it calls that script's own `_pose_spec`,
## so there is no second copy of the pose maths to drift), then:
##
##   1. finds the saturated vertical strips in the framebuffer itself, rather
##      than trusting coordinates someone typed into a brief;
##   2. for every rendered mesh in the tree, projects its world AABB to screen
##      and reports which ones can cover those strips;
##   3. prints node name, mesh resource, material, world position, AABB and the
##      material's emission colour/energy for each.
##
## Physics rays are no use here: the facades are rendered geometry with no
## collider, so `intersect_ray` passes straight through the thing being asked
## about.

const SAT_MIN := 55
const SAT_VAL_MIN := 90
const BAND_Y0 := 120
const BAND_Y1 := 360
const MIN_BAND_PX := 25
const PROBE := "res://World/look_dev_capture.gd"


func _initialize() -> void:
	var out := "/tmp/bars"
	var only := "walk3"
	var settle := 10
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			"--only":
				only = String(args[i + 1]); i += 2
			"--settle":
				settle = int(args[i + 1]); i += 2
			_:
				i += 1
	DirAccess.make_dir_recursive_absolute(out)

	var rig = load(PROBE).new()
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var street := OSMLayout.start_line()
	var at: Vector3 = street["pos"]
	var d: Vector2 = street["dir"]
	var fwd := Vector3(d.x, 0.0, d.y).normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x)

	print("[Bar] booting world (settle=%d frames)" % settle)
	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	for f in settle:
		await process_frame

	var flow: Node = rig.call("_menu_flow", main)
	if flow != null:
		flow.call("close")
	rig.call("_hide_ui", main)

	var cam: Camera3D = rig.call("_camera", main)
	if cam == null:
		push_error("[Bar] no Camera3D")
		quit(1)
		return
	for n in rig.call("_ancestry", cam):
		if "tracking" in n:
			n.set("tracking", false)
	cam.current = true
	Engine.time_scale = 0.0

	var spec: Dictionary = rig.call("_pose_spec", only, at, fwd, side, g)
	cam.global_position = spec["at"]
	cam.look_at(spec["look"], Vector3.UP)
	cam.fov = float(spec["fov"])
	for f in 3:
		await process_frame
	await RenderingServer.frame_post_draw

	print("[Bar] pose %s asked=%s got=%s current=%s fov=%.0f" % [
		only, str(spec["at"].round()), str(cam.global_position.round()),
		str(cam.current), float(spec["fov"])])

	var img: Image = get_root().get_texture().get_image()
	var vp := get_root().get_visible_rect().size
	print("[Bar] framebuffer %dx%d" % [int(vp.x), int(vp.y)])
	img.save_png("%s/%s-probe.png" % [out, only])

	var bands := _saturated_bands(img)
	print("[Bar] %d saturated vertical strip(s) found in the framebuffer:" % bands.size())
	for b in bands:
		print("   x%d-%d (w=%d) n=%d" % [b["x0"], b["x1"], b["x1"] - b["x0"] + 1, b["n"]])

	print("\n[Bar] ==== identification ====")
	for b in bands:
		_identify(b, cam, img, main)

	quit(0)


## Saturated columns in the upper-middle of the frame, grouped into strips. This
## is the same test that was run offline on the reference frame; running it here
## means the coordinates come from the render, not from a brief.
func _saturated_bands(img: Image) -> Array:
	var w := img.get_width()
	var counts := {}
	for x in w:
		var n := 0
		for y in range(BAND_Y0, BAND_Y1):
			var c := img.get_pixel(x, y)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			var mn: float = minf(c.r, minf(c.g, c.b))
			if mx * 255.0 > SAT_VAL_MIN and (mx - mn) * 255.0 > SAT_MIN:
				n += 1
		if n >= 8:
			counts[x] = n
	var cols: Array = counts.keys()
	cols.sort()
	var bands: Array = []
	if cols.is_empty():
		return bands
	var run: Array = [cols[0]]
	for x in cols.slice(1):
		if int(x) - int(run[run.size() - 1]) <= 2:
			run.append(x)
		else:
			_bands_push(bands, run, counts)
			run = [x]
	_bands_push(bands, run, counts)
	return bands


func _bands_push(bands: Array, run: Array, counts: Dictionary) -> void:
	var peak := 0
	var n := 0
	for x in run:
		peak = maxi(peak, int(counts[x]))
		n += int(counts[x])
	if peak < MIN_BAND_PX:
		return
	run.sort()
	bands.append({"x0": int(run[0]), "x1": int(run[run.size() - 1]), "n": n, "peak": peak})


## Which rendered meshes can possibly cover this strip, and what are they.
func _identify(b: Dictionary, cam: Camera3D, img: Image, main: Node) -> void:
	var x0: int = int(b["x0"])
	var x1: int = int(b["x1"])
	var xc := int(round((x0 + x1) * 0.5))
	print("\n--- strip x%d-%d ---" % [x0, x1])
	# the colour actually on screen at the strip, sampled down its length
	var rs := 0.0
	var gs := 0.0
	var bs := 0.0
	var cnt := 0
	var best_y := BAND_Y0
	var best_lum := -1.0
	for y in range(BAND_Y0, BAND_Y1):
		var c := img.get_pixel(xc, y)
		var lum: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		rs += c.r; gs += c.g; bs += c.b; cnt += 1
		if lum > best_lum:
			best_lum = lum
			best_y = y
	if cnt > 0:
		print("   mean on screen rgb(%d,%d,%d)   brightest px at (%d,%d) rgb%s" % [
			int(rs / cnt * 255.0), int(gs / cnt * 255.0), int(bs / cnt * 255.0),
			xc, best_y, str(img.get_pixel(xc, best_y))])

	var hits: Array = []
	_walk(main, cam, x0, x1, hits)
	# nearest first: the strip's own surface is the closest thing to the camera
	hits.sort_custom(func(p, q): return float(p["dist"]) < float(q["dist"]))
	print("   %d candidate mesh(es), nearest first:" % hits.size())
	for h in hits:
		print("     %s" % JSON.stringify(h))


func _walk(n: Node, cam: Camera3D, x0: int, x1: int, hits: Array) -> void:
	for c in n.get_children():
		if c is MultiMeshInstance3D:
			_mm(c, cam, x0, x1, hits)
		elif c is MeshInstance3D and c.mesh != null:
			_mi(c, cam, x0, x1, hits)
		_walk(c, cam, x0, x1, hits)


func _screen_rect(xf: Transform3D, aabb: AABB, cam: Camera3D) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var any := false
	for i in 8:
		var corner := aabb.get_endpoint(i)
		var w := xf * corner
		if cam.is_position_behind(w):
			continue
		var p := cam.unproject_position(w)
		lo.x = minf(lo.x, p.x); lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x); hi.y = maxf(hi.y, p.y)
		any = true
	if not any:
		return Rect2()
	return Rect2(lo, hi - lo)


func _overlaps_x(r: Rect2, x0: int, x1: int) -> bool:
	if r.size.x <= 0.0:
		return false
	return r.position.x <= float(x1) and r.position.x + r.size.x >= float(x0)


func _mi(mi: MeshInstance3D, cam: Camera3D, x0: int, x1: int, hits: Array) -> void:
	var aabb: AABB = mi.mesh.get_aabb()
	var world := mi.global_transform * aabb
	var r := _screen_rect(mi.global_transform, aabb, cam)
	if not _overlaps_x(r, x0, x1):
		return
	hits.append(_describe(mi, mi.global_transform, world, r, cam))


func _mm(mm: MultiMeshInstance3D, cam: Camera3D, x0: int, x1: int, hits: Array) -> void:
	if mm.multimesh == null:
		return
	var xf := mm.global_transform
	var aabb: AABB = mm.multimesh.mesh.get_aabb() if mm.multimesh.mesh != null else AABB()
	if aabb.size == Vector3.ZERO:
		aabb = mm.multimesh.custom_aabb
	var world := xf * aabb
	var r := _screen_rect(xf, aabb, cam)
	if not _overlaps_x(r, x0, x1):
		return
	hits.append(_describe(mm, xf, world, r, cam))


func _describe(n: Node3D, xf: Transform3D, world: AABB, r: Rect2, cam: Camera3D) -> Dictionary:
	var centre := world.get_center()
	var mats: Array = []
	var mesh_name := "-"
	var emission := "-"
	if n is MeshInstance3D and n.mesh != null:
		mesh_name = n.mesh.resource_path if n.mesh.resource_path != "" else n.mesh.resource_name
		for si in n.mesh.get_surface_count():
			var m: Material = n.mesh.surface_get_material(si)
			mats.append(_mat_name(m))
			if m != null and m is StandardMaterial3D and m.emission_enabled:
				emission = "%s x%.2f" % [str(m.emission), m.emission_energy_multiplier]
	if n is MultiMeshInstance3D:
		var mo: Material = n.material_override
		if mo != null:
			mats.append(_mat_name(mo))
			if mo is StandardMaterial3D and mo.emission_enabled:
				emission = "%s x%.2f" % [str(mo.emission), mo.emission_energy_multiplier]
		if n.multimesh != null and n.multimesh.mesh != null:
			mesh_name = n.multimesh.mesh.resource_path if n.multimesh.mesh.resource_path != "" else n.multimesh.mesh.resource_name
	return {
		"node": String(n.get_path()),
		"mesh": mesh_name,
		"material": mats,
		"emission": emission,
		"world_centre": str(centre.round()),
		"aabb_size": str(world.size.round()),
		"screen_rect": "x%.0f..%.0f y%.0f..%.0f" % [r.position.x, r.position.x + r.size.x, r.position.y, r.position.y + r.size.y],
		"dist": cam.global_position.distance_to(centre),
	}


func _mat_name(m: Material) -> String:
	if m == null:
		return "<null>"
	if m.resource_path != "":
		return m.resource_path
	return "%s(%s)" % [m.get_class(), m.resource_name]
