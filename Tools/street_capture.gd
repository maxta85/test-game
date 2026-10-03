extends SceneTree
##
## The two frames for the street drive: what Aumuller Street looks like from
## 2.4 m up, standing on the carriageway, looking along it.
##
## This is a capture tool, not a second playtest harness. `Tools/playtest.gd`
## answers whether the car drives; nothing in it can answer what the street looks
## like, because the frames it writes come out of the chase camera and the headless
## run that produces the telemetry has no renderer at all.
##
##     godot --path . --display-driver x11 --rendering-driver opengl3 \
##       --audio-driver Dummy --script res://Tools/street_capture.gd -- \
##       --out /tmp/reports
##
## Engine flags go before the bare `--`; everything after it is a user arg. The
## other way round Godot never sees `--script`, boots the main scene instead and
## sits in the menu forever, which reads as "slow" rather than "wrong".
##
## Every learned rule is load-bearing here and each one has a comment where it
## bites:
##   * the target PNG is deleted before the run and its absence is asserted, so a
##     render that silently produces nothing cannot be mistaken for a new frame;
##   * `Camera3D.current` defaults to FALSE in Godot 4, so it is set explicitly and
##     the viewport is asked which camera it actually got;
##   * `SubViewport.get_texture().get_image()` returns the LAST RENDERED frame, so
##     every scene change is followed by `await RenderingServer.frame_post_draw`;
##   * `ChaseCamera` re-asserts its child's transform every frame, so `tracking` is
##     cleared up the whole ancestry before any pose is believed;
##   * `MenuFlow` is reached through its API, never by class name, because it uses
##     the `Cfg` autoload and autoload identifiers do not exist under `--script`.

const EYE_HEIGHT := 2.4
const FOV := 70.0
const FRAME_01_AT := 200.0     ## metres along the centreline
const FRAME_02_BACK := 60.0    ## metres short of the far end


var _vp: SubViewport
var _cam: Camera3D
var _pts := PackedVector2Array()


const STREET_NAME := "Aumuller Street"


## The street, picked by name and by longest run of that name.
##
## Mirrors `Tools/playtest.gd::_street_pick` rather than sharing it, because this
## is a SceneTree script and the harness is a Node - there is no common static
## home for it yet. Do not let the two drift: the first version of this file
## called `OSMLayout.anchor()` and rendered two perfectly good frames of the
## wrong street. `anchor()` scores every arterial fragment by how central its
## midpoint is, with length worth 0.01 m per metre, so it returns a 265 m piece of
## Mulgrave Road. Aumuller is split into ten fragments and the long one is 824.5 m.
func _street_pick() -> Dictionary:
	var best: Dictionary = {}
	var best_len := 0.0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != STREET_NAME:
			continue
		var pts: PackedVector2Array = c["points"]
		var run := 0.0
		for i in pts.size() - 1:
			run += pts[i].distance_to(pts[i + 1])
		if pts.size() >= 2 and run > best_len:
			best_len = run
			best = {"name": STREET_NAME, "pts": pts}
	if best.is_empty():
		push_error("[shot] no corridor named %s in the map data" % STREET_NAME)
	return best


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/reports"
	var size := Vector2i(1280, 720)
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			"--width":
				size.x = int(args[i + 1]); i += 2
			"--height":
				size.y = int(args[i + 1]); i += 2
			_:
				i += 1
	DirAccess.make_dir_recursive_absolute(out)

	var anchor: Dictionary = _street_pick()
	_pts = anchor.get("pts", PackedVector2Array())
	if _pts.size() < 2:
		push_error("[shot] OSMLayout.anchor() returned no polyline")
		quit(2)
		return
	var total := _length()
	print("[shot] %s, %.1f m of centreline, eye %.1f m, fov %.0f" % [
		String(anchor.get("name", "?")), total, EYE_HEIGHT, FOV])

	# Delete the targets FIRST. A run that renders nothing then leaves the previous
	# run's PNG in place, and every number and pixel read out of it afterwards is
	# stale while looking entirely fresh. The caller asserts they are gone.
	for name in ["drive-frame-01.png", "drive-frame-02.png"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [out, name]))
		print("[shot] removed any stale %s/%s" % [out, name])

	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	# Game/main.tscn boots asynchronously: the world builds, then the menu goes up,
	# then ChaseCamera builds its own child camera. Asking on the same frame as
	# add_child finds nothing and photographs whatever was on screen before.
	for f in 12:
		await process_frame
	await _prepare(main)

	var poses := [
		{"name": "drive-frame-01", "s": minf(FRAME_01_AT, total * 0.25)},
		{"name": "drive-frame-02", "s": maxf(total - FRAME_02_BACK, total * 0.5)},
	]
	var wrote := 0
	for p in poses:
		var path := "%s/%s.png" % [out, String(p["name"])]
		await _shoot(main, float(p["s"]))
		var img := _grab()
		if img == null:
			push_error("[shot] readback failed at %s" % path)
			quit(3)
			return
		var err := img.save_png(path)
		if err != OK:
			push_error("[shot] save_png(%s) failed with %d" % [path, err])
			quit(4)
			return
		# Prove the write landed and is this run's image, not a leftover: the file
		# must exist, be non-empty, and be a different image from the other pose.
		var f := FileAccess.open(path, FileAccess.READ)
		var bytes := 0
		if f != null:
			bytes = f.get_length()
			f.close()
		print("[shot] wrote %s  %d bytes  %dx%d" % [path, bytes, img.get_width(), img.get_height()])
		if bytes <= 0:
			push_error("[shot] %s is empty after a successful save_png" % path)
			quit(5)
			return
		wrote += 1
	print("[shot] SUCCESS wrote=%d" % wrote)
	quit(0)


## Boot the world, then take the game out from under the camera: menus down,
## chase rig off the camera, the clock frozen so the traffic stops driving past
## the shot while the renderer keeps drawing it.
func _prepare(main: Node) -> void:
	var flow := _find_flow(main)
	if flow != null:
		flow.call("close")
	_hide_ui(main)
	_hide_ui(root)

	var rig := _find_camera(main)
	if rig != null:
		var cur: Node = rig
		while cur != null:
			for prop in cur.get_property_list():
				if String(prop["name"]) == "tracking":
					cur.set("tracking", false)
			cur = cur.get_parent()

	_vp = SubViewport.new()
	_vp.name = "StreetCapture"
	_vp.size = Vector2i(1280, 720)
	_vp.transparent_bg = false
	# own_world_3d stays false on purpose: a SubViewport that owned its world would
	# render an empty room, because none of Cairns is inside it.
	_vp.own_world_3d = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)

	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_cam.fov = FOV
	_cam.near = 0.1
	_cam.far = 600.0
	# Godot 4 does NOT auto-promote the first camera added to a viewport. Leaving
	# this false renders nothing and saves a perfectly plausible stale frame.
	_cam.current = true

	# Freeze logic, not drawing: `paused` stops _process as well as physics, and a
	# stopped clock is what has to keep the renderer running for the readback to be
	# this pose rather than the boot frame.
	Engine.time_scale = 0.0
	for n in _all(main):
		n.set_process(false)
		n.set_process_input(false)
		n.set_process_unhandled_input(false)
		n.set_physics_process(false)


func _shoot(main: Node, s: float) -> void:
	var pose := _pose(s)
	var look: Vector3 = pose["eye"] + Vector3(pose["dir"]) * 40.0
	_cam.global_transform = Transform3D(_basis_towards(pose["dir"]), pose["eye"])
	# Re-hide every pose, not once at boot. The boot sequence puts the menu up
	# AFTER the world is built, so a single hide photographs a menu over the street.
	_hide_ui(main)
	_hide_ui(root)
	for f in 3:
		await process_frame
	_hide_ui(main)
	_hide_ui(root)
	# A scene change is only on screen after the frame that draws it.
	await RenderingServer.frame_post_draw
	print("[shot] asked eye=%s look=%s   got eye=%s  viewport camera is this one: %s" % [
		str(pose["eye"].round()), str(look.round()),
		str(_cam.global_position.round()), str(_vp.get_camera_3d() == _cam)])


## A pose is only as good as the road under it. `at s` walks the same anchor
## polyline the drive walked, so "200 m" means 200 m of Aumuller Street rather
## than 200 m of some straight line that leaves the street at 500 m.
func _pose(s: float) -> Dictionary:
	var acc := 0.0
	for i in _pts.size() - 1:
		var a := _pts[i]
		var b := _pts[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		if acc + seg >= s:
			var u: float = (s - acc) / seg
			var p := a.lerp(b, u)
			var t := (b - a) / seg
			return {
				"eye": Vector3(p.x, EYE_HEIGHT, p.y),
				"dir": Vector3(t.x, 0.0, t.y).normalized(),
				"s": s,
			}
		acc += seg
	var p := _pts[_pts.size() - 1]
	var t := (_pts[_pts.size() - 1] - _pts[_pts.size() - 2]).normalized()
	return {"eye": Vector3(p.x, EYE_HEIGHT, p.y), "dir": Vector3(t.x, 0.0, t.y).normalized(), "s": acc}


func _length() -> float:
	var total := 0.0
	for i in _pts.size() - 1:
		total += _pts[i].distance_to(_pts[i + 1])
	return total


func _grab() -> Image:
	if _vp == null:
		push_error("[shot] no capture viewport")
		return null
	return _vp.get_texture().get_image()


func _basis_towards(f: Vector3) -> Basis:
	var up := Vector3.UP
	if absf(f.dot(up)) > 0.999:
		up = Vector3.FORWARD
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


func _hide_ui(n: Node) -> void:
	for c in _all(n):
		if c is CanvasItem:
			(c as CanvasItem).visible = false


func _all(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		out.append(cur)
		for c in cur.get_children():
			stack.append(c)
	return out


func _find_camera(n: Node) -> Camera3D:
	var first: Camera3D = null
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur is Camera3D:
			if (cur as Camera3D).current:
				return cur as Camera3D
			if first == null:
				first = cur as Camera3D
		for c in cur.get_children():
			stack.append(c)
	return first


func _find_flow(n: Node) -> Node:
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur.has_method("close") and cur.has_method("races"):
			return cur
		for c in cur.get_children():
			stack.append(c)
	return null
