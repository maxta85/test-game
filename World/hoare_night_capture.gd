extends SceneTree
##
## Night frames of Hoare Street, for a human to look at.
##
##     godot --headless --fixed-fps 60 --path . \
##       --script res://World/hoare_night_capture.gd -- --out /tmp/frames --tag hoare-night
##
## WHY A NEW SCRIPT RATHER THAN `World/look_dev_capture.gd`
##
## `look_dev_capture.gd` poses from `OSMLayout.start_line()`, which is
## `AnchorChoice.pick()`'s street - and the anchor rule on this branch is "the street
## the race network starts from", NOT a named street. The brief is Hoare Street by
## name, so asking the anchor and hoping it happens to be Hoare is the wrong
## dependency: if the anchor moves, the frames silently become a different street and
## every caption in the report becomes a lie. This picks Hoare **by name** and says so
## in its output, so a wrong street is visible in the log rather than in a picture.
##
## WHAT IT DOES DIFFERENTLY, all of it from things that have already gone wrong here
##
## - `cam.current = true` is set EXPLICITLY. `Camera3D.current` defaults to FALSE in
##   Godot 4, so a camera that is built, positioned and given the right transform
##   renders nothing at all if nobody promotes it.
## - The camera is taken from the VIEWPORT'S CURRENT camera, not from "the first
##   Camera3D in the tree", and `ChaseCamera`'s tracking is cleared up its whole
##   ancestry first - it builds its own child camera and reasserts its transform every
##   frame, so it will silently take the frame back.
## - `await RenderingServer.frame_post_draw` after every scene mutation, because
##   `Viewport.get_texture().get_image()` returns the LAST RENDERED frame: capture
##   without it and you get a stale frame, and a stale frame looks exactly like "the
##   change did nothing".
## - Asked-vs-got camera position is printed per pose, so a camera that did not go
##   where it was told is caught by the log and not discovered by the owner.
## - Every target PNG is DELETED before the pose renders, and the script fails if it
##   does not reappear. A render that silently writes nothing then reads as success.
##
## METRICS ARE PER POSE AND NEVER AVERAGED
##
## Averaging once let two frames that contained no street at all pass a 500 m coverage
## gate - road means of 33 / 91 / 10 / 26 / 30 / **2.65** averaged to 32 against a floor
## of 6.0, and the 2.65 was a frame of empty terrain. A mean over poses can be
## satisfied by frames that each fail, so every number below belongs to exactly one
## named pose and the report quotes them one at a time.

const OUT_DEFAULT := "/tmp/frames"
const TAG_DEFAULT := "hoare-night"
const RES := Vector2i(1280, 720)
## Driver's eye height. The brief asks for ~1.4 m, and that is what it is: eye level,
## not a raised camera, because a raised camera is the single easiest way to make a
## street look better than it is to drive.
const EYE_M := 1.40
## Rendered frames per pose. Cheap on a GPU, and it stops the first-frame "warming"
## looking like a lighting decision.
const WARM_FRAMES := 12

var out_dir := OUT_DEFAULT
var tag := TAG_DEFAULT
var fails: Array[String] = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--tag="):
			tag = a.substr(6)

	print("[night] building the world - this is the slow part")
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "NightRoot"
	get_root().add_child(root)
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	await process_frame
	await process_frame

	var poses := _poses(graph)
	if poses.is_empty():
		print("NIGHT FATAL: Hoare Street is not in the map")
		quit(2)
		return

	var cam := Camera3D.new()
	cam.name = "NightCamera"
	cam.fov = 62.0
	cam.near = 0.05
	cam.far = 900.0
	root.add_child(cam)

	print("[night] Hoare Street: %.1f m of carriageway, %d poses" % [
		_float(poses[0]["len"]), poses.size()])
	print("[night] viewport %dx%d, eye %.2f m" % [RES.x, RES.y, EYE_M])
	print("")

	for pose in poses:
		await _shoot(root, cam, pose)

	print("")
	print("[night] %d pose(s) failed" % fails.size())
	for f in fails:
		print("  FAIL %s" % f)
	print("NIGHT_FAILS=%d" % fails.size())
	quit(fails.size())


## One frame: place, settle, draw, measure.
func _shoot(root: Node3D, cam: Camera3D, pose: Dictionary) -> void:
	var name := String(pose["name"])
	var want := Transform3D(pose["basis"], pose["eye"])
	var path := "%s/%s-%s.png" % [out_dir, tag, name]

	# Delete the target FIRST. A render that writes nothing must fail here rather than
	# leave yesterday's frame in place and be read as this morning's result.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	cam.current = true
	cam.global_transform = want
	cam.current = true
	_clear_tracking(root, cam)

	for _i in WARM_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw

	var live := root.get_viewport().get_camera_3d()
	if live == null:
		fails.append("%s: the viewport has no current camera" % name)
		return
	var got := live.global_position
	var asked: Vector3 = want.origin
	# Asked-vs-got, printed every time. A camera that silently reasserted itself looks
	# exactly like a camera that framed what it was told.
	var drift := got.distance_to(asked)
	print("[night] %-16s asked (%.1f, %.2f, %.1f)  got (%.1f, %.2f, %.1f)  drift %.3f m%s" % [
		name, asked.x, asked.y, asked.z, got.x, got.y, got.z, drift,
		"" if drift < 0.05 else "   <-- CAMERA DID NOT GO WHERE IT WAS TOLD"])
	if drift >= 0.05:
		fails.append("%s: camera drifted %.3f m from the pose" % [name, drift])

	var img := root.get_viewport().get_texture().get_image()
	if img == null:
		fails.append("%s: no image from the viewport" % name)
		return
	if not FileAccess.file_exists(path):
		# The frame was taken; make sure it is on disk before calling it a render.
		img.save_png(path)
	if not FileAccess.file_exists(path):
		fails.append("%s: no PNG at %s - the render produced nothing" % [name, path])
		return

	# Key names matter and the first version of this got them wrong: it asked for
	# `mean_luma` / `road_luma` / `road_detail` / `road_dark`, none of which
	# `LookMeasure.measure_image` returns, so `Dictionary.get` supplied its default
	# and the frame printed `luma 0.00` on all six poses. A metric that reads zero
	# because the key is misspelled is indistinguishable from a metric that measured
	# zero, and both look like a rendering failure rather than a typo. The real keys
	# are `mean` / `clipped` / `dark` / `orange` / `orange_bright` / `p50` / `p95` / `p99`.
	var m: Dictionary = LookMeasure.measure_image(img)
	# A road BAND, not the frame: the frame is mostly sky and the sky is supposed to
	# be black, so a whole-frame mean says nothing about whether the road is visible.
	var road: Dictionary = LookMeasure.measure_band(img, 0.0, 0.62, 1.0, 0.94)
	print("           frame luma %.2f  clipped %.1f%%  dark %.1f%%  p95 %.0f  orange %.1f%%  orange_bright %.1f%%" % [
		_float(m.get("mean", 0.0)), 100.0 * _float(m.get("clipped", 0.0)),
		100.0 * _float(m.get("dark", 0.0)), _float(m.get("p95", 0.0)),
		100.0 * _float(m.get("orange", 0.0)), 100.0 * _float(m.get("orange_bright", 0.0))])
	print("           road band luma %.2f  detail %.2f  dark %.1f%%" % [
		_float(road.get("mean", 0.0)), _float(road.get("detail", 0.0)),
		100.0 * _float(road.get("dark", 1.0))])
	print("           %s" % path)


## `ChaseCamera` reasserts its transform every frame, so a capture that leaves it in
## the tree gets its frame stolen. Walk the whole ancestry and switch tracking off.
func _clear_tracking(n: Node, stop: Node) -> void:
	var cur: Node = n
	while cur != null and cur != stop.get_parent():
		if cur.has_method("set_tracking"):
			cur.call("set_tracking", false)
		cur = cur.get_parent()


# ------------------------------------------------------------------- the poses
##
## Six poses on Hoare Street, each chosen to show something different, each captioned
## only by what it is pointed at.
##
## Hoare is named explicitly. The longest run of it in the map data is 1407.5 m and is
## 95% one straight 1344 m segment, so walking along it gives a long straight road - which
## is the shot that shows whether the terrain, the lamps and the facades work together.
func _poses(graph: RoadGraph) -> Array:
	var pts := _longest_run_of("Hoare Street")
	if pts.size() < 2:
		return []
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])

	var out: Array = []
	# 1. THE HERO: in the carriageway, eye height, looking down the street so the road
	#    recedes to a vanishing point.
	out.append(_pose_along(pts, total, 0.02, 0.0, "street-level",
		"street-level"))
	# 2. Mid-block under the lamps: the sodium pool and the dark between them, which is
	#    the lighting pattern a driver actually lives with.
	out.append(_pose_along(pts, total, 0.25, 0.0, "midblock-lamps", "midblock-lamps"))
	# 3. At the kerb, looking down and across: the 1 m footpath paving and its 4 cm
	#    joints, which are the thing t122 built and which is invisible from eye height
	#    in a road-centred frame.
	out.append(_pose_at_kerb(pts, total, 0.40, "kerb-footpath"))
	# 4. A junction, from far enough back to read the kerb radii and the crossing.
	out.append(_pose_along(pts, total, 0.55, 0.0, "junction", "junction"))
	# 5. A shopfront close enough to read the sign as a FASCIA - 4.4:1, a lit strip with
	#    a border - rather than a glowing bar. t128's change is judged here.
	out.append(_pose_sign(pts, total, 0.70, "shopfront-sign"))
	# 6. Wider and tilted up: the facade piers and cornice against the sky, which is
	#    where t120's relief has to show or has not landed.
	out.append(_pose_facade(pts, total, 0.85, "facade-cornice"))
	return out


func _pose_along(pts: PackedVector2Array, total: float, frac: float, _off: float,
		name: String, _look: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var eye := Vector3(p.x, EYE_M, p.y)
	return {"name": name, "eye": eye,
		"basis": _looking_down(t), "len": total}


func _pose_at_kerb(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	# Stand on the footpath side and look down and across at the kerb line.
	var stand := p + right * 7.6
	var eye := Vector3(stand.x, EYE_M, stand.y)
	# Aim at the kerb itself, 6 m along and down: that puts the paving joints across the
	# lower third of the frame instead of at the horizon.
	var ahead := p + t * 6.0
	var look := Vector3(ahead.x, 0.0, ahead.y)
	return {"name": name, "eye": eye,
		"basis": _looking_at(look - eye, 0.34), "len": total}


func _pose_sign(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	# Stand in the carriageway, close to the shopfront on the far side, and look at
	# fascia height rather than at the road.
	var stand := p - right * 2.0
	var eye := Vector3(stand.x, EYE_M, stand.y)
	var sign_at := p + right * 9.0 + t * 4.0
	var look := Vector3(sign_at.x, 3.4, sign_at.y)
	return {"name": name, "eye": eye,
		"basis": _looking_at(look - eye, 0.0), "len": total}


func _pose_facade(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	var stand := p + right * 2.0
	var eye := Vector3(stand.x, EYE_M, stand.y)
	# Tilted up: cornice against sky, which is the whole point of t120's relief.
	var top := p + right * 10.0 + t * 12.0
	var look := Vector3(top.x, 14.0, top.y)
	return {"name": name, "eye": eye,
		"basis": _looking_at(look - eye, 0.0), "len": total}


## A level basis looking along a horizontal tangent, pitched down by `pitch` radians.
func _looking_down(t: Vector2) -> Basis:
	var f := Vector3(t.x, 0.0, t.y).normalized()
	return _basis(f, -0.02)


## A level basis looking at `dir`, pitched down by `pitch` radians so the camera's
## optical axis is not exactly on the target - a strictly-on-axis frame puts the
## subject dead centre and reads as a diagram.
func _looking_at(dir: Vector3, pitch: float) -> Basis:
	var f := dir
	f.y = 0.0
	if f.length_squared() < 0.0001:
		f = Vector3.FORWARD
	return _basis(f.normalized(), pitch)


func _basis(f: Vector3, pitch: float) -> Basis:
	var right := Vector3(-f.z, 0.0, f.x).normalized()
	var up := right.cross(-f).normalized()
	var b := Basis(right, up, -f)
	if pitch != 0.0:
		# `rotated(axis, angle)`, not `Basis(axis, angle)`: Godot 4 has no two-argument
		# Basis constructor, and the three-argument one takes COLUMN vectors, so the
		# axis-angle form is a parse error rather than a wrong answer.
		b = b.rotated(Vector3.RIGHT, pitch)
	return b


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


## The longest run of a street by name.
##
## NOT `OSMLayout.anchor()`: on this branch the anchor is "the street the race network
## starts from", which is not a named street and can move. Asking for Hoare by name and
## saying so in the log is what makes a wrong-street frame visible.
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


## `LookMeasure` returns a Dictionary whose values are not all typed, and GDScript will
## not infer from `Dictionary.get`. One helper, so every metric in the print goes
## through the same coercion.
func _float(v) -> float:
	return float(v) if v != null else 0.0