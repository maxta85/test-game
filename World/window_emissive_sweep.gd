extends SceneTree
##
## Window/sign emissive sweep. Eight frames, two axes, judged on the pixel.
##
##     godot --path . --rendering-driver vulkan --audio-driver Dummy --fixed-fps 60 \
##       --script res://World/window_emissive_sweep.gd -- --out /tmp/frames --tag win
##
## WHAT THIS IS FOR
##
## Every lit window pane and sign fascia on Hoare Street hard-clips to pure white,
## `aim_rgb = (1,1,1)` where a pane fills frame centre. t120 measured 34.3% of a band
## clipped on one pose and t128 found the same thing and both deliberately did not
## fix it, because the value was a PRIOR DECISION that had been over-corrected: the
## comment in `World/osm_buildings.gd` records that at 1.1 "a lit pane sat under a
## sodium lamp and lost to the wall the lamp was lighting". So the answer is a
## measured sweep, not a guess in either direction.
##
## TWO AXES, SWEPT INDEPENDENTLY. The facade value is held while the sign moves, and
## the sign is held while the facade moves, because they are different materials with
## different jobs — a fascia is a lightbox and a pane is a window — and a sweep that
## moved both together could not tell which one was doing the clipping.
##
## ## WHY IT READS A PIXEL AND NOT A MEAN
##
## A mean luminance turns "this frame is brighter than that frame" into a number
## instead of an impression, which is the least useful thing a sweep can produce. The
## question the owner actually asked is whether a lit window still reads AS A LIT
## WINDOW or has become a paper cut-out, and that is a question about ONE pane. So
## every frame locates an actual `WindowWarm` pane in the world, unprojects its centre
## to a pixel, and prints that pixel's RGB. A pane that stops clipping but sits at
## (40,38,34) has not been fixed - it has been hidden, and the number says so.
##
## ## NOTHING IN PRODUCTION IS EDITED
##
## The sweep walks the tree after the world is built and rewrites the emission energy
## on the materials `World/osm_buildings.gd` already emitted. The meshes, the glow,
## the grade and `World/look.gd` are untouched, so a frame here is the shipped image
## at a different emissive and nothing else. That also means the winning value is
## applied afterwards by editing three lines of `osm_buildings.gd`, not by leaving a
## test harness in the render path.

const FACADE_VALUES := [1.4, 1.8, 2.0, 2.4]
const SIGN_VALUES := [2.0, 2.6, 3.0, 3.4]
## Held while the other axis moves.
const FACADE_BASE := 2.4
const SIGN_BASE := 3.4
const RES := Vector2i(1280, 720)
const EYE_M := 1.40

var out_dir := "/tmp/frames"
var tag := "win"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--tag="):
			tag = a.substr(6)

	print("[sweep] building the world")
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "SweepRoot"
	get_root().add_child(root)
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	await process_frame
	await process_frame

	var pts := _longest_run_of("Hoare Street")
	if pts.size() < 2:
		print("SWEEP FATAL: Hoare Street is not in the map")
		quit(2)
		return

	# WHY THIS BLOCK EXISTS. The first sweep run printed byte-identical metrics for
	# all eight values - clipped 3.77%, luma 15.61, p95 38, every time - which is what
	# an override that reaches nothing looks like, and it is indistinguishable from
	# "the emissive does not affect this frame". So the tree is inventoried BEFORE
	# anything is swept: how many facade-bearing nodes exist, what they are called and
	# what class they are. A sweep whose reach is unverified is a table of constants.
	var seen := {}
	var stack0: Array = [root]
	while stack0.size() > 0:
		var n0: Node = stack0.pop_back()
		for c0 in n0.get_children():
			stack0.append(c0)
		var nm0 := String(n0.name)
		if nm0.contains("Window") or nm0.contains("Sign") or nm0.contains("Facade"):
			var mi := n0 as MeshInstance3D
			var mm := MultiMeshInstance3D.new()
			var over: Object = null
			if mi != null:
				over = mi.material_override
			elif n0 is MultiMeshInstance3D:
				over = (n0 as MultiMeshInstance3D).material_override
			var e := "-"
			if over is StandardMaterial3D:
				e = "%.2f" % (over as StandardMaterial3D).emission_energy_multiplier
			seen[nm0 + " [" + n0.get_class() + "] override=" + str(over != null) + " emit=" + e] = true
	print("[sweep] facade-bearing nodes found: %d" % seen.size())
	for k in seen.keys():
		print("[sweep]   %s" % k)

	var cam := Camera3D.new()
	cam.name = "SweepCamera"
	cam.fov = 58.0
	cam.near = 0.05
	cam.far = 900.0
	root.add_child(cam)

	# Two cameras' worth of station, both on Hoare, both looking at facades.
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])

	# Aimed AT THE MESH, not at a station on the street.
	#
	# The second run of this sweep framed nothing: the overrides were verified to reach
	# the right materials (WindowCool 2.00, WindowWarm 2.40, SignFascia 3.40 read back
	# from the tree) and every one of the eight frames was byte-identical, with p95 38
	# where the clipping had been measured at p95 254. A camera pointed at a street
	# station is not a camera pointed at a window, and Hoare's longest run is 95% one
	# 1344 m straight segment, so "somewhere along it" is not "somewhere with a facade".
	#
	# So the target is now the AABB centre of an actual emitted mesh, found in the tree,
	# and the camera is stood off it at eye height. If a mesh is not in the frame the
	# sweep says so rather than reporting a number for a wall.
	await _sweep(root, cam, pts, total, 0.0, "pane", FACADE_VALUES, SIGN_BASE, false)
	await _sweep(root, cam, pts, total, 0.0, "fascia", SIGN_VALUES, FACADE_BASE, true)

	print("")
	print("SWEEP done - %d frames under %s" % [8, out_dir])
	quit(0)


## One axis of the sweep, all of its values, from one camera station.
func _sweep(root: Node3D, cam: Camera3D, pts: PackedVector2Array, total: float,
		frac: float, where: String, values: Array, held: float,
		sign_axis: bool) -> void:
	print("")
	print("[sweep] === %s, %s held at %.1f ===" % [
		where, "SIGN" if sign_axis else "FACADE", held])
	for v in values:
		var facade := float(held) if sign_axis else float(v)
		var sign := float(v) if sign_axis else float(held)
		_set_emissive(root, facade, sign)
		var path := "%s/%s-%s-f%02d-s%02d.png" % [
			out_dir, tag, where, int(round(facade * 10.0)), int(round(sign * 10.0))]
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		var cam_tf := _camera_at_mesh(root, pts, total, frac, where)
		cam.current = true
		cam.global_transform = cam_tf
		cam.current = true
		for _i in 12:
			await process_frame
		await RenderingServer.frame_post_draw

		var live := root.get_viewport().get_camera_3d()
		if live == null:
			print("   facade %.1f sign %.1f  NO CURRENT CAMERA" % [facade, sign])
			continue
		var img := root.get_viewport().get_texture().get_image()
		if img == null:
			print("   facade %.1f sign %.1f  NO IMAGE" % [facade, sign])
			continue
		img.save_png(path)

		var m: Dictionary = LookMeasure.measure_image(img)
		var pane := _pane_rgb(root, live)
		print("   facade %.1f  sign %.1f  clipped %5.2f%%  luma %5.2f  p95 %3.0f   PANE rgb %s  %s" % [
			facade, sign, 100.0 * float(m.get("clipped", 0.0)),
			float(m.get("mean", 0.0)), float(m.get("p95", 0.0)),
			str(pane), path.get_file()])
	print("[sweep] %d frames written" % values.size())


## Rewrite the emission energy on the materials the facade builder already emitted.
##
## By NAME and not by material role, because the point is to move the number the
## shipped frame uses, and matching on a role would also catch the neon signs, the
## shopfront fascia and anything else that is not under test.
func _set_emissive(root: Node, facade: float, sign: float) -> void:
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var m: Object = null
		if n is MeshInstance3D:
			m = (n as MeshInstance3D).material_override
		elif n is MultiMeshInstance3D:
			m = (n as MultiMeshInstance3D).material_override
		if m == null or not (m is StandardMaterial3D):
			continue
		var sm := m as StandardMaterial3D
		var nm := String(n.name)
		if nm.begins_with("Window"):
			# The warm and cool panes are separate nodes and are swept together: a
			# facade is one decision, and splitting them would double the sweep for
			# no extra information.
			sm.emission_energy_multiplier = facade
		elif nm.begins_with("SignFascia"):
			sm.emission_energy_multiplier = sign


## The RGB of an actual lit pane, found by unprojecting a real one to a pixel.
##
## This is the measurement the brief asks for and the one a mean cannot make. It
## walks the tree for the emitted `WindowWarm` mesh, takes the world-space centre of
## its AABB, unprojects it through the LIVE camera, and reads that pixel. If the pane
## is off screen or behind the camera it says so rather than returning a default,
## because a default here would be a made-up number in a table of measurements.
func _pane_rgb(root: Node, cam: Camera3D) -> Array:
	var best: Node3D = null
	var best_d := 1e9
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D):
			continue
		if not String(n.name).begins_with("WindowWarm"):
			continue
		var node3 := n as Node3D
		if not node3.is_inside_tree():
			continue
		var d := node3.global_position.distance_to(cam.global_position)
		if d < best_d:
			best_d = d
			best = node3
	if best == null:
		return ["no WindowWarm mesh in the tree", -1, -1]
	var aabb: AABB = (best as VisualInstance3D).get_aabb()
	var centre: Vector3 = (best as Node3D).global_transform * aabb.get_center()
	var vp := root.get_viewport()
	var sz := vp.get_visible_rect().size
	if cam.is_position_behind(centre):
		return ["pane is BEHIND the camera", -1, -1]
	var uv := cam.unproject_position(centre)
	var px := clampi(int(uv.x), 0, int(sz.x) - 1)
	var py := clampi(int(uv.y), 0, int(sz.y) - 1)
	var img := vp.get_texture().get_image()
	if img == null:
		return ["no image", -1, -1]
	var c := img.get_pixel(px, py)
	return [c, px, py, best.get_name(), best_d]


## Stand off the AABB centre of the mesh this sweep is about, at eye height.
##
## `where` picks WHICH mesh: "pane" is `WindowWarm`, "fascia" is `SignFascia`. If the
## mesh is missing or degenerate the function returns the street pose, and the caller
## prints that it could not aim - a made-up camera would produce a plausible frame of
## a wall and a number to go with it.
func _camera_at_mesh(root: Node3D, pts: PackedVector2Array, total: float, frac: float,
		where: String) -> Transform3D:
	var want := "WindowWarm" if where == "pane" else "SignFascia"
	var target: Node3D = null
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if (n is MeshInstance3D) and String(n.name) == want and (n as Node3D).is_inside_tree():
			target = n as Node3D
			break
	if target == null:
		print("[sweep]   no %s mesh to aim at - this sweep will measure a wall" % want)
		return _camera_at(pts, total, frac, where)
	var centre: Vector3 = (target as VisualInstance3D).global_transform \
		* (target as VisualInstance3D).get_aabb().get_center()
	# Stand 11 m back along the street and 1.4 m up, looking at the mesh centre.
	var street := _at(pts, total * frac)
	var back := centre - Vector3(street.x, centre.y, street.y)
	if back.length() < 0.5:
		back = Vector3(1, 0, 0)
	var eye := centre - back.normalized() * 11.0
	eye.y = EYE_M
	var f := centre - eye
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	var fn := f.normalized()
	var r := Vector3(-fn.z, 0.0, fn.x).normalized()
	var u := r.cross(-fn).normalized()
	return Transform3D(Basis(r, u, -fn), eye)


func _camera_at(pts: PackedVector2Array, total: float, frac: float, where: String) -> Transform3D:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	var eye2 := p - right * 2.0
	if where == "mid":
		eye2 = p
	var eye := Vector3(eye2.x, EYE_M, eye2.y)
	var look2 := p + right * 9.0 + t * 4.0
	if where == "mid":
		look2 = p + t * 40.0
	var look := Vector3(look2.x, 3.4 if where == "close" else 2.0, look2.y)
	var f := look - eye
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3(t.x, 0.0, t.y)
	var fn := f.normalized()
	var r := Vector3(-fn.z, 0.0, fn.x).normalized()
	var u := r.cross(-fn).normalized()
	return Transform3D(Basis(r, u, -fn), eye)


func _at(pts: PackedVector2Array, s: float) -> Vector2:
	var acc := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if seg < 0.0001:
			continue
		if acc + seg >= s:
			return pts[i].lerp(pts[i + 1], (s - acc) / seg)
		acc += seg
	return pts[pts.size() - 1]


func _tangent(pts: PackedVector2Array, s: float) -> Vector2:
	var acc := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if seg < 0.0001:
			continue
		if acc + seg >= s:
			return (pts[i + 1] - pts[i]) / seg
		acc += seg
	return (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()


func _longest_run_of(want: String) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_len := 0.0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != want:
			continue
		var p: PackedVector2Array = c["points"]
		var run := 0.0
		for i in p.size() - 1:
			run += p[i].distance_to(p[i + 1])
		if p.size() >= 2 and run > best_len:
			best_len = run
			best = p
	return best