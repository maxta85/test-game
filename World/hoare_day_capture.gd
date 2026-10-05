extends SceneTree
##
## t191: DAYTIME frames of Hoare Street, before and after the verge screen.
##
##     godot --path . --rendering-driver vulkan --resolution 1280x720 \
##       --script res://World/hoare_day_capture.gd -- --out shots/t191 --tag day-fixed
##     godot --path . --rendering-driver vulkan --resolution 1280x720 \
##       --script res://World/hoare_day_capture.gd -- --out shots/t191 --tag day-obstructed --unfixed
##
## BEFORE AND AFTER IN ONE TREE, NOT TWO BUILDS
##
## The pair that matters is "same day, same cameras, props screened vs props not
## screened", and the only way to get that is to build the same world twice with one
## flag between them. Two separate exports would differ in a hundred ways nobody
## wrote down, and a difference in a frame would then be unattributable. So
## `--unfixed` sets `WorldBuilder.verge_screening = false` - the world is byte-for-byte
## the promoted build - and every other number on the page is identical.
##
## WHY IT BUILDS ITS OWN ENVIRONMENT
##
## `World/hoare_night_capture.gd` builds a `WorldBuilder` and nothing else, so the
## night frames it produced had no `NightEnv` in the tree at all: no sky, no ambient,
## no grade - the lamps in the world lighting an undefined black. That is exactly the
## failure `NightPass`'s own header warns about, committed as a capture harness. This
## one adds `DayEnv` and its sun explicitly, because a "daytime" frame of a world with
## no daylight in it is a frame of the night, mislabelled.
##
## The rig traps are the ones `hoare_night_capture.gd` already lists, and they are
## inherited deliberately: `cam.current = true` set explicitly, the camera taken from
## the viewport's CURRENT camera with `ChaseCamera` tracking cleared up its ancestry,
## `await RenderingServer.frame_post_draw` after every mutation, the target PNG deleted
## before the render and its absence treated as a failure, and asked-vs-got printed per
## pose. A camera that silently reasserts itself, or a capture taken before the frame
## was drawn, both look exactly like "the change did nothing".

const OUT_DEFAULT := "shots/t191"
const TAG_DEFAULT := "day-fixed"
const RES := Vector2i(1280, 720)
## Driver's eye height. 1.40 m, not a raised camera: a raised camera is the easiest
## way to make a street look better than it is to drive.
const EYE_M := 1.40
const WARM_FRAMES := 12
const HOARE := "Hoare Street"

var out_dir := OUT_DEFAULT
var tag := TAG_DEFAULT
var unfixed := false
var only := ""
var fails: Array[String] = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--tag="):
			tag = a.substr(6)
		elif a == "--unfixed":
			unfixed = true
		elif a.begins_with("--only="):
			only = a.substr(7)

	print("[day] renderer=%s  api=%s  driver-args=%s" % [
		str(RenderingServer.get_video_adapter_name()),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")),
		" ".join(OS.get_cmdline_args())])

	WorldBuilder.verge_screening = not unfixed
	print("[day] verge_screening=%s (t191 %s)" % [
		"off" if unfixed else "on", "BEFORE / obstructed" if unfixed else "AFTER / screened"])

	print("[day] building the world - this is the slow part")
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "DayRoot"
	get_root().add_child(root)

	# The daylight, explicitly. See the header: without this the frames are the night.
	var env := DayEnv.new()
	env.name = "DayEnvironment"
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.name = "DaySun"
	sun.light_color = DayEnv.SUN_COLOUR
	sun.light_energy = DayEnv.SUN_ENERGY
	sun.transform = DayEnv.sun_transform()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	root.add_child(sun)

	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	await process_frame
	await process_frame

	var poses := _poses()
	if poses.is_empty():
		print("DAY FATAL: %s is not in the map" % HOARE)
		quit(2)
		return
	if only != "":
		var keep: Array = []
		for p in poses:
			if String(p["name"]) == only:
				keep.append(p)
		poses = keep

	var cam := Camera3D.new()
	cam.name = "DayCamera"
	cam.fov = 62.0
	cam.near = 0.05
	cam.far = 900.0
	root.add_child(cam)

	print("[day] %s: %.1f m of carriageway, %d pose(s)" % [HOARE, _float(poses[0]["len"]), poses.size()])
	print("[day] viewport %dx%d, eye %.2f m, sun (%.0f,%.0f,%.0f) energy %.2f" % [
		RES.x, RES.y, EYE_M, DayEnv.SUN_ROTATION_DEG.x, DayEnv.SUN_ROTATION_DEG.y,
		DayEnv.SUN_ROTATION_DEG.z, DayEnv.SUN_ENERGY])
	print("")

	for pose in poses:
		await _shoot(root, cam, pose)

	print("")
	print("[day] %d pose(s) failed" % fails.size())
	for f in fails:
		print("  FAIL %s" % f)
	print("DAY_FAILS=%d" % fails.size())
	print("FRAMES_WRITTEN=%d" % (poses.size() - fails.size()))
	quit(fails.size())


## One frame: delete the target, place, settle, draw, measure, prove it is new.
func _shoot(root: Node3D, cam: Camera3D, pose: Dictionary) -> void:
	var name := String(pose["name"])
	var want := Transform3D(pose["basis"], pose["eye"])
	var path := "%s/%s-%s.png" % [out_dir, tag, name]

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
	var drift := got.distance_to(asked)
	print("[day] %-18s asked (%.1f, %.2f, %.1f)  got (%.1f, %.2f, %.1f)  drift %.3f m%s" % [
		name, asked.x, asked.y, asked.z, got.x, got.y, got.z, drift,
		"" if drift < 0.05 else "   <-- CAMERA DID NOT GO WHERE IT WAS TOLD"])
	if drift >= 0.05:
		fails.append("%s: camera drifted %.3f m from the pose" % [name, drift])

	var img := root.get_viewport().get_texture().get_image()
	if img == null:
		fails.append("%s: no image from the viewport" % name)
		return
	img.save_png(path)
	if not FileAccess.file_exists(path):
		fails.append("%s: no PNG at %s - the render produced nothing" % [name, path])
		return

	# Daylight metrics. The frame-wide numbers are reported for the record, but the
	# one that decides whether the day reads is the SKY band: a street frame is mostly
	# buildings and road, so a whole-frame mean says the exposure is right while the
	# sky - the thing that makes it a day - is invisible.
	var m: Dictionary = LookMeasure.measure_image(img)
	# `measure_band(img, x0, y0, x1, y1)` - the ORIGIN FIRST. The first version of this
	# passed (0.0, 0.30, 0.0, 0.12), which is x0=0, y0=0.30, x1=0.0, y1=0.12: a band
	# zero pixels wide, so `measure_band` returned {"ok": false} with no "mean" key at
	# all and the report printed "sky band luma 0.00" on all six poses of a frame whose
	# sky is unmistakably blue. A metric that cannot run must not read as a metric that
	# measured zero, so both bands are checked and a failed band says so.
	var sky := LookMeasure.measure_band(img, 0.0, 0.0, 1.0, 0.18)
	var road := LookMeasure.measure_band(img, 0.0, 0.62, 1.0, 0.94)
	if not bool(sky.get("ok", false)):
		sky = {"mean": -1.0, "detail": -1.0}
	if not bool(road.get("ok", false)):
		road = {"mean": -1.0, "detail": -1.0}
	print("           frame luma %.2f  clipped %.2f%%  dark %.2f%%  p95 %.0f  orange_bright %.2f%%" % [
		_float(m.get("mean", 0.0)), 100.0 * _float(m.get("clipped", 0.0)),
		100.0 * _float(m.get("dark", 0.0)), _float(m.get("p95", 0.0)),
		100.0 * _float(m.get("orange_bright", 0.0))])
	print("           sky band luma %.2f  detail %.2f   road band luma %.2f  detail %.2f  dark %.2f%%" % [
		_float(sky.get("mean", 0.0)), _float(sky.get("detail", 0.0)),
		_float(road.get("mean", 0.0)), _float(road.get("detail", 0.0)),
		100.0 * _float(road.get("dark", 1.0))])
	print("           %s" % path)


func _clear_tracking(n: Node, stop: Node) -> void:
	var cur: Node = n
	while cur != null and cur != stop.get_parent():
		if cur.has_method("set_tracking"):
			cur.call("set_tracking", false)
		cur = cur.get_parent()


# ------------------------------------------------------------------- the poses
##
## Six poses on Hoare Street by NAME. Not `OSMLayout.anchor()`: the anchor rule on
## this branch is "the street the race network starts from", which is not a named
## street and can move, and a frame that silently became a different street is a lie
## in every caption above it.
func _poses() -> Array:
	var pts := _longest_run_of(HOARE)
	if pts.size() < 2:
		return []
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])

	var out: Array = []
	# 1. THE HERO: in the carriageway, eye height, looking down the street. This is the
	#    frame that shows whether a palm is standing in the lane.
	out.append(_pose_along(pts, total, 0.02, "street-level"))
	# 2. Mid-block, where the verge planting is densest.
	out.append(_pose_along(pts, total, 0.25, "midblock"))
	# 3. At the kerb, looking down and across at the kerb line and the footpath.
	out.append(_pose_at_kerb(pts, total, 0.40, "kerb-footpath"))
	# 4. A junction, from far enough back to read the kerb radii.
	out.append(_pose_along(pts, total, 0.55, "junction"))
	# 5. Across the carriageway at the far-side frontage - the angle that puts a
	#    trunk between the camera and the road.
	out.append(_pose_sign(pts, total, 0.70, "frontage-across"))
	# 6. Tilted up: facade and canopy against the sky.
	out.append(_pose_facade(pts, total, 0.85, "facade-cornice"))
	return out


func _pose_along(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var eye := Vector3(p.x, EYE_M, p.y)
	return {"name": name, "eye": eye, "basis": _looking_down(t), "len": total}


func _pose_at_kerb(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	var stand := p + right * 7.6
	var eye := Vector3(stand.x, EYE_M, stand.y)
	var ahead := p + t * 6.0
	var look := Vector3(ahead.x, 0.0, ahead.y)
	return {"name": name, "eye": eye, "basis": _looking_at(look - eye, 0.34), "len": total}


func _pose_sign(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	var stand := p - right * 2.0
	var eye := Vector3(stand.x, EYE_M, stand.y)
	var sign_at := p + right * 9.0 + t * 4.0
	var look := Vector3(sign_at.x, 3.4, sign_at.y)
	return {"name": name, "eye": eye, "basis": _looking_at(look - eye, 0.0), "len": total}


func _pose_facade(pts: PackedVector2Array, total: float, frac: float, name: String) -> Dictionary:
	var s: float = total * frac
	var p := _at(pts, s)
	var t := _tangent(pts, s)
	var right := Vector2(t.y, -t.x)
	var stand := p + right * 2.0
	var eye := Vector3(stand.x, EYE_M, stand.y)
	var top := p + right * 10.0 + t * 12.0
	var look := Vector3(top.x, 14.0, top.y)
	return {"name": name, "eye": eye, "basis": _looking_at(look - eye, 0.0), "len": total}


func _looking_down(t: Vector2) -> Basis:
	return _basis(Vector3(t.x, 0.0, t.y).normalized(), -0.02)


## Look along a full 3D direction, `pitch` added on top.
##
## NOT flattened to the horizontal plane. The version this replaces did `f.y = 0.0`,
## which quietly meant the `facade-cornice` pose - whose look target is 12.6 m above the
## camera - framed the cornice edge-on at street level and put no sky in the frame at all.
func _looking_at(dir: Vector3, pitch: float) -> Basis:
	if dir.length_squared() < 0.0001:
		return _looking_down(Vector2(0.0, 1.0))
	return _basis(dir.normalized(), pitch)


## A camera basis that looks along `f`.
##
## Godot's Basis columns are (right, up, back) and a Camera3D looks down its own -Z, so
## back = -f and the triple has to be RIGHT-handed. The first version of this file had
## `up = right.cross(-f)`, which is `up.cross(back)` and comes out as (0, -1, 0) for a
## forward of (0, 0, -1) - a 180 degree roll. Every frame came out upside down with the
## sky at the bottom and the trees hanging, and the sky-band metric read 0.00 on all six
## poses because the thing it called sky was the terrain. Correct order is
## `up = right.cross(f)`.
func _basis(f: Vector3, pitch: float) -> Basis:
	var fwd := f.normalized()
	if fwd.length_squared() < 0.5:
		fwd = Vector3.FORWARD
	# right = fwd x world_up. Looking straight up or down degenerates, so fall back to
	# world +X rather than producing a zero-length basis.
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() < 0.000001:
		right = Vector3(1, 0, 0)
	right = right.normalized()
	var up := right.cross(fwd).normalized()
	var b := Basis(right, up, -fwd)
	if pitch != 0.0:
		# Post-multiply: rotate about the camera's OWN x axis, which is where a pitch
		# belongs. `b.rotated(Vector3.RIGHT, ...)` rotated about world +X, which is
		# only the same thing when the camera happens to be facing along an axis.
		b = b * Basis(Vector3(1, 0, 0), pitch)
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


func _float(v) -> float:
	return float(v) if v != null else 0.0