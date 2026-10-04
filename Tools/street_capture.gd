extends SceneTree
##
## Street-level frames at 2.4 m, four poses along one street, rendered on the GPU
## box by `verify.sh`.
##
##     godot --path . --rendering-driver vulkan --script res://Tools/street_capture.gd -- \
##       --out <dir> --street "Mulgrave Road"
##
## Engine flags go before the bare `--`; everything after it is a user arg. The
## other way round Godot never sees `--script`, boots the main scene instead and
## sits in the menu forever, which reads as "slow" rather than "wrong".
##
## Street identity is PINNED BY NAME, never taken from `OSMLayout.anchor()`.
## `anchor()` scores every arterial *fragment* by how central its midpoint is, with
## length worth 0.01 m per metre, so on this map it returns a 265 m piece of
## Mulgrave Road rather than the 824.5 m Aumuller run - and an earlier version of
## this file rendered two perfectly good frames of the wrong street under a
## caption that said Aumuller. Aumuller itself is ten separate fragments in
## `assets/maps/cairns_map.json`. So: name in, name printed, and every frame logs
## the run_m it was taken at. The claim lives in the log, not in a prose caption.
##
## Every learned rule here is load-bearing and each bites somewhere specific:
##   * each target PNG is deleted before the run and its absence asserted, so a
##     render that silently produces nothing cannot be read as a new frame;
##   * `Camera3D.current` defaults to FALSE in Godot 4, so it is set explicitly and
##     the viewport is asked which camera it actually got;
##   * `SubViewport.get_texture().get_image()` returns the LAST RENDERED frame, so
##     every scene change is followed by `await RenderingServer.frame_post_draw`;
##   * `ChaseCamera` re-asserts its child's transform every frame, so `tracking` is
##     cleared up the whole ancestry before any pose is believed;
##   * `MenuFlow` is reached through its API, never by class name, because it uses
##     the `Cfg` autoload and autoload identifiers do not exist under `--script`.
##
## Renders are NOT byte-deterministic. The md5 that `verify.sh` prints is a
## freshness check within one run, never a determinism claim - two runs of this
## same scene will not produce the same hash.

const EYE_HEIGHT := 2.4
const FOV := 70.0
var _frame_size := Vector2i(1280, 720)
const FRAME_NAMES := ["street-frame-01", "street-frame-02", "street-frame-03", "street-frame-04"]
## Fractions of the street's run length. Spread rather than clustered: three poses
## in the first tenth would all photograph the same corner lamp and would pass a
## duplicate check while telling you nothing about the other 90%.
const FRAME_FRACTIONS := [0.12, 0.37, 0.63, 0.88]
const DEFAULT_STREET := "Aumuller Street"


var _vp: SubViewport
var _cam: Camera3D
var _pts := PackedVector2Array()
var _street := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/ownerqa"
	var size := _frame_size
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			"--street":
				_street = String(args[i + 1]); i += 2
			"--width":
				size.x = int(args[i + 1]); i += 2
			"--height":
				size.y = int(args[i + 1]); i += 2
			_:
				i += 1
	if _street == "":
		_street = DEFAULT_STREET
	DirAccess.make_dir_recursive_absolute(out)

	var pick := _street_pick()
	if pick.is_empty():
		push_error("[shot] FATAL no corridor named %s" % _street)
		quit(2)
		return
	_pts = pick["pts"]
	var total := _length()
	_frame_size = size
	print("[shot] street=%s run_m=%.1f points=%d eye_m=%.1f fov=%.0f" % [
		String(pick["name"]), total, _pts.size(), EYE_HEIGHT, FOV])

	# Delete the targets FIRST. A run that renders nothing leaves the previous run's
	# PNG in place, and everything read out of it afterwards is stale while looking
	# entirely fresh.
	for name in FRAME_NAMES:
		var path := "%s/%s.png" % [out, String(name)]
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		print("[shot] pre-deleted %s (exists now: %s)" % [
			path, str(FileAccess.file_exists(path))])

	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	# main.tscn boots asynchronously: the world builds, then the menu goes up, then
	# ChaseCamera builds its own child camera. Asking on the same frame as
	# add_child finds nothing and photographs whatever was on screen before.
	for f in 12:
		await process_frame
	await _prepare(main)

	var wrote := 0
	for n in FRAME_NAMES.size():
		var run_m: float = total * float(FRAME_FRACTIONS[n])
		var path := "%s/%s.png" % [out, String(FRAME_NAMES[n])]
		await _shoot(main, run_m)
		var img := _grab()
		if img == null:
			push_error("[shot] FATAL readback failed for %s" % path)
			quit(3)
			return
		if img.save_png(path) != OK:
			push_error("[shot] FATAL save_png(%s) failed" % path)
			quit(4)
			return
		var bytes := 0
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			bytes = int(f.get_length())
			f.close()
		if bytes <= 0:
			push_error("[shot] FATAL %s is empty after a successful save_png" % path)
			quit(5)
			return
		wrote += 1
		# The per-frame identity line: street, frame, run_m, and the bytes on disk.
		# A downstream caption built from this line cannot caption a frame with a
		# street or a distance the frame was not taken at.
		print("[shot] wrote street=%s frame=%s run_m=%.1f bytes=%d %dx%d" % [
			_street, String(FRAME_NAMES[n]), run_m, bytes, img.get_width(), img.get_height()])
	print("[shot] SUCCESS wrote=%d street=%s" % [wrote, _street])
	quit(0)


## Boot the world, then take the game out from under the camera: menus down, chase
## rig off the camera, the clock frozen so nothing drives past the shot while the
## renderer keeps drawing it.
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
	_vp.size = _frame_size
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
	# Godot 4 does NOT auto-promote the first camera added to a viewport. Left
	# false, this renders nothing and saves a plausible-looking stale frame.
	_cam.current = true

	# Freeze logic, not drawing: `paused` stops _process as well as physics, and it
	# is the stopped clock that has to keep the renderer running for the readback to
	# be this pose rather than the boot frame.
	Engine.time_scale = 0.0
	for n in _all(main):
		n.set_process(false)
		n.set_process_input(false)
		n.set_process_unhandled_input(false)
		n.set_physics_process(false)


func _shoot(main: Node, run_m: float) -> void:
	var pose := _pose(run_m)
	var eye: Vector3 = pose["eye"]
	var dir: Vector3 = pose["dir"]
	var look := eye + dir * 40.0
	_cam.global_transform = Transform3D(_basis_towards(dir), eye)
	# Re-hide every pose, not once at boot: the boot sequence puts the menu up AFTER
	# the world is built, so a single hide photographs a menu over the street.
	_hide_ui(main)
	_hide_ui(root)
	for f in 3:
		await process_frame
	_hide_ui(main)
	_hide_ui(root)
	# A scene change is only on screen after the frame that draws it.
	await RenderingServer.frame_post_draw
	var got := _cam.global_position
	# Asked next to got. A silently-driven camera produces plausible-looking output,
	# and six byte-identical frames once came from exactly that.
	print("[shot] asked street=%s run_m=%.1f eye=%s look=%s | got eye=%s | viewport camera is this one: %s" % [
		_street, run_m, str(eye.round()), str(look.round()), str(got.round()),
		str(_vp.get_camera_3d() == _cam)])


## A pose is only as good as the road under it. `run_m` walks the pinned street's
## own polyline, so 200 m means 200 m of that street and not 200 m of a straight
## line that leaves it at 500 m - which is what an anchor-relative walk gives you.
func _pose(run_m: float) -> Dictionary:
	var acc := 0.0
	for i in _pts.size() - 1:
		var a := _pts[i]
		var b := _pts[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		if acc + seg >= run_m:
			var u: float = (run_m - acc) / seg
			var p := a.lerp(b, u)
			var t := (b - a) / seg
			return {"eye": Vector3(p.x, EYE_HEIGHT, p.y), "dir": Vector3(t.x, 0.0, t.y).normalized()}
		acc += seg
	var last := _pts.size() - 1
	var p := _pts[last]
	var t := (_pts[last] - _pts[last - 1]).normalized()
	return {"eye": Vector3(p.x, EYE_HEIGHT, p.y), "dir": Vector3(t.x, 0.0, t.y).normalized()}


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


func _all(from: Node) -> Array:
	var out: Array = []
	var stack: Array = [from]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		out.append(cur)
		for c in cur.get_children():
			stack.append(c)
	return out


func _find_camera(from: Node) -> Camera3D:
	var first: Camera3D = null
	var stack: Array = [from]
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


func _find_flow(from: Node) -> Node:
	var stack: Array = [from]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur.has_method("close") and cur.has_method("races"):
			return cur
		for c in cur.get_children():
			stack.append(c)
	return null


## The pinned street: longest run of exactly that name.
##
## Longest, not first. A street name appears in `corridors()` once per OSM way, so
## "Aumuller Street" arrives ten times and the longest of them is the 824.5 m run
## while the shortest is 12 m. Taking the first match photographs a car park.
func _street_pick() -> Dictionary:
	var best: Dictionary = {}
	var best_len := 0.0
	var fragments := 0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != _street:
			continue
		var pts: PackedVector2Array = c["points"]
		if pts.size() < 2:
			continue
		var run := 0.0
		for i in pts.size() - 1:
			run += pts[i].distance_to(pts[i + 1])
		fragments += 1
		if run > best_len:
			best_len = run
			best = {"name": _street, "pts": pts}
	if best.is_empty():
		push_error("[shot] map data has no corridor named %s" % _street)
		return {}
	print("[shot] %s: %d fragments in the map, using the longest" % [_street, fragments])
	return best
