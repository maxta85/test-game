extends SceneTree
##
## Window/sign emissive sweep, measured on a PANE and not on a clipped percentage.
##
##     godot --path . --rendering-driver vulkan --audio-driver Dummy --fixed-fps 60 \
##       --script res://World/window_emissive_sweep.gd -- --out /tmp/frames2 --tag win
##
## WHY NOT SWEEP THE CLIPPED PERCENTAGE
##
## t137 tried, and got a flat table: facade and sign both reported clipped 3.77%,
## luma 15.61, p95 38 for every value on both axes. **p95 38 where the clipping is
## total is the tell.** Once a surface is blown to 1.0 it cannot get more blown, so the
## clipped share stops responding to the parameter - and a sweep on that metric
## produces a confident "no value fixes it" that means nothing at all. A metric that
## cannot tell 0.0 from 2.4 is not a measurement, and the whole job here is to build
## one that can.
##
## WHAT THIS MEASURES INSTEAD
##
## The RGB of **one identified lit pane**, found by taking real triangles out of the
## emitted `WindowWarm` mesh, projecting them into the camera, and standing the camera
## on the one that lands on screen. Then the same pixel is read at every sweep value.
##
## Two things fall out of that and neither is available from a clipped share:
##
##   - it RESPONDS. Pane RGB at facade 0.0 versus 2.4 is printed and the two differ,
##     which is the proof the metric is alive. A saturated share cannot do that.
##   - it answers the question that matters. The pane is either a lit window - warm,
##     above the wall around it, still holding its colour - or it is a cut-out: not
##     clipping, but sitting at a dead grey where you read a hole rather than a room.
##
## ## AIMING, WHICH IS WHERE t137 WENT WRONG TWICE
##
## `WindowWarm` is ONE merged mesh for every window pane in the city, so its AABB
## centre is the centroid of all of them - inside a city block, not on a street. t137
## aimed there and got p95 5. And a camera pointed at a station on the street is not a
## camera pointed at a window. So the target here is a real triangle: sample the
## emitted surface's vertices, project each to the viewport, and choose the nearest one
## that lands ON SCREEN. If none does, the sweep says so instead of reporting a number
## for a wall.

const FACADE_VALUES := [1.4, 1.8, 2.0, 2.4]
const SIGN_VALUES := [2.0, 2.6, 3.0, 3.4]
const FACADE_BASE := 2.4
const SIGN_BASE := 3.4
## The frame that proves the metric responds. 0.0 is not a candidate value; it is the
## control, and without it a flat sweep cannot be told from a dead metric.
const CONTROL := 0.0
const EYE_M := 1.40
const STAND_OFF := 9.0

var out_dir := "/tmp/frames2"
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

	var cam := Camera3D.new()
	cam.name = "SweepCamera"
	cam.fov = 55.0
	cam.near = 0.05
	cam.far = 900.0
	root.add_child(cam)

	# Pick a real pane and stand in front of it. Done ONCE: the camera is fixed for
	# the whole sweep so every value is the same pane in the same pixel, which is the
	# only way two numbers are comparable.
	var pane: Vector3 = await _find_pane(root, cam)
	if pane == Vector3.INF:
		print("[sweep] FATAL: no WindowWarm triangle lands on screen from any street station")
		quit(2)
		return
	var aim := _stand_at(root, cam, pane)
	cam.current = true
	cam.global_transform = aim
	cam.current = true
	for _i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var px := _project(cam, root, pane)
	print("[sweep] pane at %s, camera at %s, pixel %s" % [
		str(pane.round()), str(cam.global_position.round()), str(px)])
	if px.x < 0:
		print("[sweep] FATAL: the chosen pane is not on screen after standing off it")
		quit(2)
		return

	print("")
	print("[sweep] ===== THE METRIC RESPONDS (control) =====")
	var control := await _shoot(root, cam, pane, "control", CONTROL, SIGN_BASE, false)
	print("")
	print("[sweep] ===== FACADE sweep, sign held at %.1f =====" % SIGN_BASE)
	var facade_rows: Array = []
	for v in FACADE_VALUES:
		facade_rows.append(await _shoot(root, cam, pane, "facade", float(v), SIGN_BASE, false))
	print("")
	print("[sweep] ===== SIGN sweep, facade held at %.1f =====" % FACADE_BASE)
	for v in SIGN_VALUES:
		await _shoot(root, cam, pane, "sign", FACADE_BASE, float(v), true)

	print("")
	print("[sweep] done")
	quit(0)


## One frame at one value, with the pane pixel measured.
func _shoot(root: Node3D, cam: Camera3D, pane: Vector3, axis: String, facade: float,
		sign: float, sign_axis: bool) -> Dictionary:
	_set_emissive(root, facade, sign)
	var name := "%s-%s-f%02d-s%02d.png" % [tag, axis, int(round(facade * 10.0)),
		int(round(sign * 10.0))]
	var path := "%s/%s" % [out_dir, name]
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for _i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	if img == null:
		print("   facade %.1f sign %.1f  NO IMAGE" % [facade, sign])
		return {}
	img.save_png(path)
	var m: Dictionary = LookMeasure.measure_image(img)
	var px := _project(cam, root, pane)
	var col: Color = px["rgb"]
	# 0-255 sRGB-ish, because the brief's standard is written in those units.
	var r := int(round(col.r * 255.0))
	var g := int(round(col.g * 255.0))
	var b := int(round(col.b * 255.0))
	print("   facade %.1f  sign %.1f  PANE rgb(%3d,%3d,%3d)  max %3d  clipped %5.2f%%  luma %5.2f  %s" % [
		facade, sign, r, g, b, maxi(r, maxi(g, b)),
		100.0 * float(m.get("clipped", 0.0)), float(m.get("mean", 0.0)), name])
	return {"r": r, "g": g, "b": b, "facade": facade, "sign": sign}


## Rewrite emission energy on the three facade materials by node name.
func _set_emissive(root: Node, facade: float, sign: float) -> void:
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MeshInstance3D):
			continue
		var mi := n as MeshInstance3D
		var over: Object = mi.material_override
		if not (over is StandardMaterial3D):
			continue
		var nm := String(n.name)
		if nm.begins_with("Window"):
			(over as StandardMaterial3D).emission_energy_multiplier = facade
		elif nm.begins_with("SignFascia"):
			(over as StandardMaterial3D).emission_energy_multiplier = sign


## A real vertex of the emitted `WindowWarm` mesh, in world space, chosen by
## projecting candidates into a provisional camera and taking the nearest that lands
## ON SCREEN. The AABB centre is useless here - that mesh is every window in the city,
## so its centre is the middle of a block.
func _find_pane(root: Node, cam: Camera3D) -> Vector3:
	var node: MeshInstance3D = null
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if (n is MeshInstance3D) and String(n.name) == "WindowWarm":
			node = n as MeshInstance3D
			break
	if node == null:
		return Vector3.INF
	var mesh: Mesh = node.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return Vector3.INF
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return Vector3.INF
	# Provisional camera, SWEPT AROUND.
	#
	# t137's failure and this first failure are the same mistake: a camera pointed
	# ALONG the street. Facade window panes are set into the building faces, which
	# line the street PERPENDICULAR to it, so a camera looking down the carriageway
	# sees every pane edge-on and none of them lands in the middle of the frame. So
	# the look direction is swept through 360 degrees in 15 degree steps and every
	# candidate vertex is tested against every one of them.
	var pts := _longest_run_of("Hoare Street")
	var eye := Vector3(pts[0].x, EYE_M, pts[0].y)
	var vp := root.get_viewport()
	var sz := vp.get_visible_rect().size
	var best := Vector3.INF
	var best_d := 1e9
	var step := maxi(1, verts.size() / 6000)
	for deg in range(0, 360, 15):
		var a := deg_to_rad(float(deg))
		var f := Vector3(cos(a), 0.0, sin(a)).normalized()
		var r := Vector3(-f.z, 0.0, f.x).normalized()
		var u := r.cross(-f).normalized()
		cam.current = true
		cam.global_transform = Transform3D(Basis(r, u, -f), eye)
		var i := 0
		while i < verts.size():
			var w: Vector3 = node.global_transform * verts[i]
			if not cam.is_position_behind(w) and w.distance_to(eye) < 60.0:
				var uv := cam.unproject_position(w)
				if uv.x > sz.x * 0.30 and uv.x < sz.x * 0.70 and uv.y > sz.y * 0.30 and uv.y < sz.y * 0.70:
					var d := w.distance_to(eye)
					if d < best_d:
						best_d = d
						best = w
			i += step
	return best


## Stand `STAND_OFF` metres back from the pane, at eye height, looking at it.
func _stand_at(root: Node, cam: Camera3D, pane: Vector3) -> Transform3D:
	var away := pane - Vector3(0.0, EYE_M, 0.0)
	# Push back along the direction from the street to the pane, so the camera ends up
	# over the carriageway rather than inside the building.
	var street := _street_point(root, pane)
	var dir := pane - street
	dir.y = 0.0
	if dir.length_squared() < 0.5:
		dir = Vector3(1, 0, 0)
	var eye := pane - dir.normalized() * STAND_OFF
	eye.y = EYE_M
	var f := pane - eye
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	var fn := f.normalized()
	var r := Vector3(-fn.z, 0.0, fn.x).normalized()
	var u := r.cross(-fn).normalized()
	return Transform3D(Basis(r, u, -fn), eye)


## Nearest point on Hoare's polyline to `p`, used only to decide which way to back off.
func _street_point(root: Node, p: Vector3) -> Vector3:
	var pts := _longest_run_of("Hoare Street")
	var v := Vector2(p.x, p.z)
	var best := Vector3.ZERO
	var bd := INF
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		var q := a + ab * t
		var d := (v - q).length_squared()
		if d < bd:
			bd = d
			best = Vector3(q.x, p.y, q.y)
	return best


## Project a world point and read that pixel. This is the measurement; everything
## else in this file exists to make it land on a pane.
func _project(cam: Camera3D, root: Node, pane: Vector3) -> Dictionary:
	if cam.is_position_behind(pane):
		return {"x": -1, "rgb": Color(0, 0, 0)}
	var vp := root.get_viewport()
	var sz := vp.get_visible_rect().size
	var uv := cam.unproject_position(pane)
	var px := clampi(int(uv.x), 0, int(sz.x) - 1)
	var py := clampi(int(uv.y), 0, int(sz.y) - 1)
	var img := vp.get_texture().get_image()
	if img == null:
		return {"x": -1, "rgb": Color(0, 0, 0)}
	return {"x": px, "y": py, "uv": uv, "rgb": img.get_pixel(px, py)}


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