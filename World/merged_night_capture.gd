extends SceneTree
##
## The MERGED street at night, on the 3060 box.
##
##     godot --path . --rendering-driver vulkan --audio-driver Dummy --fixed-fps 60 \
##       --script res://World/merged_night_capture.gd -- --out /tmp/frames --tag merged-night
##
## ## WHY THIS SCRIPT EXISTS RATHER THAN REUSING t135's
##
## t135 rendered chain B alone and the frames came back with the camera UNDER the
## terrain: the street's corridor polyline is a centreline with no idea where the road
## surface is, so "1.40 m above the polyline" put the eye underground on the merged
## geometry. **The eye here is placed by RAYCASTING DOWN onto the surface** and then
## adding the driver's eye height to whatever that surface turns out to be, so the
## camera is 1.40 m above the tarmac by construction rather than by assumption.
##
## The camera's Y is printed asked-vs-got every pose. That single number is the whole
## point of this render: on t135 the same six poses put the eye below the road, and a
## street frame from under the terrain is not evidence about the street.
##
## ## NOTHING IS ASSUMED ABOUT BEING DETERMINISTIC
##
## Each target PNG is DELETED before its pose renders and the script fails if it does
## not reappear, so a render that writes nothing cannot pass silently and a
## measurement step cannot re-read the previous frame. md5 is reported per frame FOR
## THIS RUN ONLY. Renders on this box are not byte-deterministic - measured p95
## jitter under 0.1% - so a differing md5 between runs is expected and is never
## evidence of a change.

const OUT_DIR := "/tmp/frames"
const TAG := "merged-night"
const RES := Vector2i(1280, 720)
## Driver's eye height above whatever surface the ray finds.
const EYE_M := 1.40
## How far below the road to ray from. Generous, because the merged carve puts the
## corridor floor below the tarmac and a short ray can miss it.
const RAY_FROM := 30.0
const WARM_FRAMES := 12

var out_dir := OUT_DIR
var tag := TAG
var fails: Array[String] = []
var rows: Array = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--tag="):
			tag = a.substr(6)

	print("[merged] building the world")
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "MergedNightRoot"
	get_root().add_child(root)
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	await process_frame
	await process_frame

	var cam := Camera3D.new()
	cam.name = "MergedNightCamera"
	cam.fov = 62.0
	cam.near = 0.05
	cam.far = 900.0
	root.add_child(cam)

	var pts := _longest_run_of(graph)
	if pts.size() < 2:
		print("MERGED FATAL: Hoare Street is not in the map")
		quit(2)
		return
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	print("[merged] Hoare Street: %.1f m of carriageway" % total)

	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	for pose in _poses(pts, total):
		await _shoot(root, cam, space, pts, total, pose)

	print("")
	print("[merged] %d pose(s) failed" % fails.size())
	for f in fails:
		print("  FAIL %s" % f)
	print("")
	print("MERGED_NIGHT_FAILS=%d" % fails.size())
	quit(fails.size())


## Place by raycasting onto the surface, then raise by the driver's eye height.
##
## Returns the eye position AND what it was placed on, because "1.4 m above the
## tarmac" and "1.4 m above whatever the first thing below was" are different claims
## and only the second is true.
func _eye_on_surface(space: PhysicsDirectSpaceState3D, xz: Vector2,
		up: Vector3 = Vector3.UP) -> Dictionary:
	var from := Vector3(xz.x, RAY_FROM, xz.y)
	var p := PhysicsRayQueryParameters3D.create(from, from - up * (RAY_FROM * 2.0))
	p.collide_with_areas = false
	var hit := space.intersect_ray(p)
	if hit.is_empty():
		return {"y": RAY_FROM, "what": "NOTHING BELOW", "ok": false}
	var col := hit["collider"] as Node
	var y := (hit["position"] as Vector3).y
	return {"y": y, "what": String(col.name) if col != null else "?", "ok": true}


func _shoot(root: Node3D, cam: Camera3D, space: PhysicsDirectSpaceState3D,
		pts: PackedVector2Array, total: float, pose: Dictionary) -> void:
	var name := String(pose["name"])
	var xz: Vector2 = pose["xz"]
	var look: Vector2 = pose["look"]
	var hit := _eye_on_surface(space, xz)
	if not bool(hit["ok"]):
		fails.append("%s: nothing below the camera" % name)
		return
	var eye := Vector3(xz.x, float(hit["y"]) + EYE_M, xz.y)

	var path := "%s/%s-%s.png" % [out_dir, tag, name]
	# Delete FIRST. A render that writes nothing must fail here, and a later step
	# must not be able to re-read the previous frame.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var f := Vector3(look.x - eye.x, 0.0, look.y - eye.z)
	if f.length_squared() < 0.01:
		f = Vector3.FORWARD
	var fn := f.normalized()
	var r := Vector3(-fn.z, 0.0, fn.x).normalized()
	var u := r.cross(-fn).normalized()
	var tf := Transform3D(Basis(r, u, -fn), eye)
	if float(pose.get("pitch", 0.0)) != 0.0:
		tf.basis = tf.basis.rotated(Vector3.RIGHT, float(pose["pitch"]))

	cam.current = true
	cam.global_transform = tf
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
	# Asked-vs-got INCLUDING Y. This is the number that proves the eye is above the
	# road rather than under it, which is what went wrong last time.
	print("[merged] %-16s eye asked y=%+.3f  got y=%+.3f  standing on %s  drift %.3f m" % [
		name, eye.y, got.y, String(hit["what"]), got.distance_to(eye)])
	if absf(got.y - eye.y) > 0.05:
		fails.append("%s: camera drifted %.3f m" % [name, got.distance_to(eye)])

	var img := root.get_viewport().get_texture().get_image()
	if img == null:
		fails.append("%s: no image from the viewport" % name)
		return
	img.save_png(path)
	if not FileAccess.file_exists(path):
		fails.append("%s: no PNG at %s - the render produced nothing" % [name, path])
		return

	var m: Dictionary = LookMeasure.measure_image(img)
	var road: Dictionary = LookMeasure.measure_band(img, 0.0, 0.62, 1.0, 0.94)
	print("           frame luma %5.2f  clipped %5.2f%%  dark %5.1f%%  p95 %3.0f  orange %5.1f%%" % [
		_f(m.get("mean", 0.0)), 100.0 * _f(m.get("clipped", 0.0)),
		100.0 * _f(m.get("dark", 0.0)), _f(m.get("p95", 0.0)), 100.0 * _f(m.get("orange", 0.0))])
	print("           road band luma %5.2f  detail %5.2f  dark %5.1f%%" % [
		_f(road.get("mean", 0.0)), _f(road.get("detail", 0.0)), 100.0 * _f(road.get("dark", 1.0))])
	print("           md5 %s  %s" % [md5(path), path])
	rows.append({"pose": name, "eye_y": got.y, "on": String(hit["what"]),
		"luma": _f(m.get("mean", 0.0)), "clipped": 100.0 * _f(m.get("clipped", 0.0)),
		"dark": 100.0 * _f(m.get("dark", 0.0)), "p95": _f(m.get("p95", 0.0)),
		"road_luma": _f(road.get("mean", 0.0)), "road_detail": _f(road.get("detail", 0.0)),
		"road_dark": 100.0 * _f(road.get("dark", 1.0)), "path": path})


func _clear_tracking(n: Node, stop: Node) -> void:
	var cur: Node = n
	while cur != null and cur != stop.get_parent():
		if cur.has_method("set_tracking"):
			cur.call("set_tracking", false)
		cur = cur.get_parent()


## Five poses on Hoare. `xz` is where the eye goes in plan, `look` is where it points.
func _poses(pts: PackedVector2Array, total: float) -> Array:
	var out: Array = []
	# 1. Driver's eye, mid-block, looking down the street to a vanishing point.
	var a := _at(pts, total * 0.30)
	var ta := _tangent(pts, total * 0.30)
	out.append({"name": "street-eye", "xz": a, "look": a + ta * 200.0, "pitch": -0.02})
	# 2. Kerb close-up: the 1 m footpath paving and its 4 cm joints, across the lower third.
	var b := _at(pts, total * 0.45)
	var tb := _tangent(pts, total * 0.45)
	var rb := Vector2(tb.y, -tb.x)
	out.append({"name": "kerb-footpath", "xz": b + rb * 7.4, "look": b + tb * 7.0, "pitch": 0.34})
	# 3. Junction, far enough back to read the kerb radii.
	var c := _at(pts, total * 0.60)
	var tc := _tangent(pts, total * 0.60)
	out.append({"name": "junction", "xz": c, "look": c + tc * 120.0, "pitch": -0.03})
	# 4. Shopfront close: is the sign a 4.4:1 fascia or a glowing bar?
	var d := _at(pts, total * 0.75)
	var td := _tangent(pts, total * 0.75)
	var rd := Vector2(td.y, -td.x)
	out.append({"name": "shopfront-sign", "xz": d - rd * 2.0, "look": d + rd * 9.0 + td * 4.0, "pitch": -0.10})
	# 5. Facade piers and cornice against the sky.
	var e := _at(pts, total * 0.88)
	var te := _tangent(pts, total * 0.88)
	var re := Vector2(te.y, -te.x)
	out.append({"name": "facade-cornice", "xz": e + re * 2.0, "look": e + re * 11.0 + te * 14.0, "pitch": -0.30})
	return out


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


## Hoare by name and the LONGEST run of it, so the street and its length are
## printed rather than assumed.
func _longest_run_of(graph: RoadGraph) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_len := 0.0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != "Hoare Street":
			continue
		var p: PackedVector2Array = c["points"]
		var run := 0.0
		for i in p.size() - 1:
			run += p[i].distance_to(p[i + 1])
		if p.size() >= 2 and run > best_len:
			best_len = run
			best = p
	return best


func md5(path: String) -> String:
	return FileAccess.get_md5(path)


func _f(v) -> float:
	return float(v) if v != null else 0.0