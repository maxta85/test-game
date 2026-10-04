extends SceneTree
## Facade capture: frame a real street-facing wall and measure it.
##
##     /home/coder/tools/godot --path . --rendering-driver vulkan \
##       --audio-driver Dummy --resolution 1280x720 -- \
##       --script res://World/facade_capture.gd --out /tmp/fac --tag before
##
## Why not `./render.sh`: none of the `ShotPoser` presets frames a building at
## human scale. `street` and `kerb` are aimed at the carriageway, `aerial` is at
## 420 m, and `ShotPoser` is in `Systems/`, which this worktree does not own. A
## verdict about facade relief needs a camera that looks AT a facade, and it needs
## the SAME camera on both builds - a frame that frames something different is not
## a comparison (see `World/look_dev_capture.gd` for the same argument about the
## road).
##
## The poses come from `OSMBuildings.plan()`, not from coordinates typed here, so
## the rig keeps framing a facade after the map data changes. Poses are printed
## with their numbers so a bad frame is attributable.
##
## `--measure` re-reads the PNGs already in `<out>` and rewrites the report without
## rendering, so fixing a threshold never costs another render.

## out: Vector2i - how wide a slice of wall, in metres, each pose frames.
const FACADE_W := 26.0
## Back off the wall, and how high, looking at the middle of the framed slice.
const STANDOFF := 17.0
const EYE := 5.4
const FOV := 52.0
## How many poses. Three is the smallest set that shows a house, a shopfront and a
## taller block, which is the whole range the frontages come in.
const POSE_COUNT := 3

const RES := Vector2i(1280, 720)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/fac"
	var tag := "before"
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out = String(args[i + 1])
	i = args.find("--tag")
	if i >= 0 and i + 1 < args.size():
		tag = String(args[i + 1])

	if args.has("--measure"):
		_measure_only(out, tag)
		quit(0)
		return

	DirAccess.make_dir_recursive_absolute(out)

	print("[Facade] building Cairns (OSM)...")
	var t0 := Time.get_ticks_msec()

	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	print("[Facade] road graph: %d edges, %.0f m" % [
		int(graph.stats()["edges"]), float(graph.stats()["length_m"])])

	# Exactly the boot `Game/main.gd:_ready()` does, minus the car and the menus.
	# A facade judged under different lighting than the game ships is a facade
	# judged under the wrong light.
	var night := NightEnv.new()
	night.name = "NightEnvironment"
	root.add_child(night)

	var sun := DirectionalLight3D.new()
	sun.light_color = MatLib.MOON
	sun.light_energy = 0.55
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 180.0
	sun.rotation_degrees = Vector3(-52, -128, 0)
	root.add_child(sun)

	var probe := ReflectionProbe.new()
	probe.name = "WetProbe"
	probe.size = Vector3(180, 90, 180)
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	probe.intensity = 0.9
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	probe.origin_offset = Vector3(0, 8, 0)
	probe.position = Vector3(0, 12, 40)
	root.add_child(probe)

	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	print("[Facade] world built in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))

	# The colliders have to be REGISTERED, not merely parented, before anything
	# can be checked against them - and a physics query needs a physics tick, so
	# `process_frame` is not enough. A sightline test run before this hits nothing,
	# reports every pose clear, and the occlusion filter silently does nothing.
	for f in 8:
		await physics_frame

	var poses := _poses(graph)
	print("[Facade] %d poses" % poses.size())

	var cam := Camera3D.new()
	cam.fov = FOV
	# `Camera3D.current` defaults to FALSE in Godot 4. Leaving it alone is how a
	# capture saves the last frame anything else drew, and the PNG comes back
	# identical between two builds that differ - which reads as "no effect".
	cam.current = true
	root.add_child(cam)

	if args.has("--probe"):
		await _probe(graph, poses)
		quit(0)
		return

	for n in poses.size():
		var p: Dictionary = poses[n]
		var name := "%s-%02d-%s" % [tag, n, String(p["kind"])]
		# Asked vs got, always. A camera whose transform was reset by something
		# else in the tree still renders a plausible frame, and a pose that was
		# silently ignored reads as "the change did nothing".
		cam.global_position = p["eye"]
		cam.look_at(p["look"], Vector3.UP)
		var got := cam.global_position
		var got_target: Vector3 = p["look"]
		var live := root.get_camera_3d()
		print("[Facade] %s asked=%s got=%s live=%s current_is_mine=%s look=%s fov=%.0f" % [
			name, str(Vector3(p["eye"]).round()), str(got.round()),
			str(live.global_position.round() if live != null else Vector3.ZERO),
			str(live == cam), str(Vector3(p["look"]).round()), FOV])
		# The image is the LAST RENDERED frame, so a scene change is not in it
		# until a draw has happened. `process_frame` advances logic only.
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png("%s/%s.png" % [out, name])
		# Does the frame actually contain the facade? Unproject the point the
		# camera was aimed at and read THAT pixel. Eyeballing the frame is how a
		# rig that has quietly framed a neighbouring blank wall gets approved,
		# because the picture still looks like a street.
		var wall_pt := Vector3(got_target.x, float(p["ground"]) + float(p["wall"]) * 0.55, got_target.z)
		# `unproject_position` answers in VIEWPORT pixels, while the image just
		# saved is in WINDOW pixels, and with a stretch mode those differ. At
		# `--resolution 1280x720` on a 1280x720 project they are the same and the
		# factor is 1; render smaller and every probe reads out of frame, which
		# looks like "the facade is not in the picture" and is not.
		var vp := cam.get_viewport().get_visible_rect().size
		var sx := float(img.get_width()) / maxf(1.0, vp.x)
		var sy := float(img.get_height()) / maxf(1.0, vp.y)
		var uv := cam.unproject_position(wall_pt)
		var px := Vector2i(int(uv.x * sx), int(uv.y * sy))
		var inside := px.x >= 0 and px.y >= 0 and px.x < img.get_width() and px.y < img.get_height()
		var probe_c := img.get_pixel(px.x, px.y) if inside else Color(0, 0, 0, 1)
		# Four more probes along the wall, so a wall that is in frame at one point
		# and occluded at the rest is visible as a number.
		var along := Vector3(-(got_target.z - got.x), 0.0, got_target.x - got.z).normalized() * 7.0
		var hits := 0
		for k in [-1.0, -0.5, 0.5, 1.0]:
			var q2 := cam.unproject_position(wall_pt + along * k)
			var p2 := Vector2i(int(q2.x * sx), int(q2.y * sy))
			if p2.x >= 0 and p2.y >= 0 and p2.x < img.get_width() and p2.y < img.get_height():
				var cc := img.get_pixel(p2.x, p2.y)
				if cc.r + cc.g + cc.b > 0.03:
					hits += 1
		print("[Facade] %s wrote %dx%d  aim_px=%s in_frame=%s aim_rgb=%s wall_probe_hit=%d/4" % [
			name, img.get_width(), img.get_height(), str(px), str(inside),
			str(Color(probe_c.r, probe_c.g, probe_c.b, 1.0)), hits])
		print("[Facade] wrote %s/%s.png (frame %d)" % [out, name, n])

	_report(out, tag, poses)
	quit(0)


## Counts by RETURNING, not by accumulating into parameters: GDScript passes
## ints by value, so a tally helper that writes to its arguments reports zero for
## every node it walks - and a "0 colliders" reading looks exactly like a world
## with no collision.
func _collect_physics(n: Node) -> Vector2i:
	var bodies := 0
	var shapes := 0
	for c in n.get_children():
		if c is CollisionObject3D:
			bodies += 1
		if c is CollisionShape3D:
			shapes += 1
		var sub := _collect_physics(c)
		bodies += sub.x
		shapes += sub.y
	return Vector2i(bodies, shapes)


## Is the facade the first thing this camera would see? Two rays: one at the
## middle of the wall and one at each end of the framed slice. A single centre ray
## clears a corner and misses the obstruction at the edge of frame.
func _sightline_clear(eye: Vector3, look: Vector3, ground: float, wall: float) -> bool:
	var w3d := root.get_world_3d()
	if w3d == null:
		return false
	var space := w3d.direct_space_state
	# The wall itself, at three heights and across the slice.
	var c := Vector3(look.x, 0.0, look.z)
	var half := minf(FACADE_W * 0.42, 9.0)
	# Perpendicular to the sightline, in the ground plane. `Vector3.orthogonal()`
	# does not exist in Godot 4.3, and the sightline is horizontal anyway.
	var fwd := c - Vector3(eye.x, 0.0, eye.z)
	if fwd.length() < 0.01:
		return false
	var along := Vector3(-fwd.z, 0.0, fwd.x).normalized()
	for hf in [0.28, 0.55, 0.85]:
		for ox in [-half, 0.0, half]:
			var target: Vector3 = c + along * float(ox)
			target.y = ground + wall * float(hf)
			var q := PhysicsRayQueryParameters3D.create(eye, target)
			q.collide_with_areas = false
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				# Anything hit before the wall itself blocks the frame.
				if eye.distance_to(hit["position"]) < eye.distance_to(target) - 0.6:
					return false
	return true


## Real street-facing walls, spread across the height range. Taken from the plan
## rather than from coordinates so a data change moves the poses with it.
func _poses(graph: RoadGraph) -> Array:
	var plan := OSMBuildings.plan(graph)
	# Tallest first, then thinned out, so the three poses are not three neighbours
	# on the same street.
	var sorted: Array = plan["buildings"].duplicate()
	sorted.sort_custom(func(a, b): return float(a["wall"]) > float(b["wall"]))
	var out: Array = []
	var seen_rings: Array = []
	for e in sorted:
		if out.size() >= POSE_COUNT:
			break
		var faces: Array = e["faces"]
		if faces.is_empty():
			continue
		# The widest street-facing edge on the building: a 3 m flank does not
		# frame 26 m of wall, and the facade is the whole subject here.
		var best: Dictionary = faces[0]
		var best_span := 0.0
		var ring: PackedVector2Array = e["ring"]
		for f in faces:
			var i := int(f["i"])
			var span := ring[i].distance_to(ring[(i + 1) % ring.size()])
			if span > best_span:
				best_span = span
				best = f
		if best_span < FACADE_W * 0.55:
			continue
		# Two poses on the same wall are one pose measured twice.
		var mid := Vector2.ZERO
		var fi := int(best["i"])
		mid = (ring[fi] + ring[(fi + 1) % ring.size()]) * 0.5
		if seen_rings.has(mid.snapped(Vector2(1.0, 1.0))):
			continue
		seen_rings.append(mid.snapped(Vector2(1.0, 1.0)))

		var a := ring[fi]
		var b := ring[(fi + 1) % ring.size()]
		var dir := (b - a) / best_span
		# Same outward normal as `_band()` and `_face()`: rings are wound so the
		# outward normal of a -> b is (dy, -dx).
		var nrm := Vector3(dir.y, 0.0, -dir.x)
		var wall: float = e["wall"]
		var ground: float = e["lift"]
		# Stand off along the outward normal, so the camera is in the street and
		# the wall faces it. Sliced to FACADE_W so every pose frames the same
		# amount of wall and the numbers compare.
		var half := minf(best_span * 0.5, FACADE_W * 0.5)
		var c := (a + b) * 0.5
		var eye := Vector3(c.x, ground + EYE, c.y) + nrm * STANDOFF
		# Aim at the middle of the wall's height, biased up a little: the top of
		# the facade and the roofline against the sky are what has to read.
		var look := Vector3(c.x, ground + wall * 0.55, c.y)
		# The standoff point is in the street, and the street is full of things:
		# the first three candidates when this check was added were all standing
		# inside a neighbouring building, so the render showed a blank flank and
		# the numbers measured it happily. A pose is only usable if the wall is
		# the FIRST thing the camera can see.
		if not _sightline_clear(eye, look, ground, wall):
			continue
		out.append({
			"kind": "flat" if bool(e["flat"]) else "pitched",
			"span": best_span, "wall": wall, "cls": int(best["cls"]),
			"shop": bool(e["flat"]) and wall > 3.2 + 1.2,
			"eye": eye, "look": look, "half": half, "ground": ground,
		})
	return out


# ------------------------------------------------------------------ measurement

## Facade-band statistics, read back off the PNG.
##
## The interesting number is the COLUMN PROFILE: mean luma of each column of the
## facade band, sampled down to a handful of buckets. A flat wall with rectangles
## pasted on it has one bright run per window and smooth falloff between; a wall
## with proud vertical relief alternates light and dark in the pier zones between
## those windows, and that alternation is the thing being judged. Printed as
## numbers because an averaged index over the whole facade hides it - one blown
## corner cancels one flat one, which is the same averaging error as averaging a
## per-street metric.
# ------------------------------------------------------------------- diagnosis

## What is actually in front of each camera, with no frame rendered.
##
## A frame that does not contain a facade is the most expensive mistake available
## here - ten minutes per render, and the number that comes back measures whatever
## the camera happened to be looking at. This asks the scene directly: cast from
## the eye to the wall, report what was hit, how far, and whether the face it hit
## points back at the camera. All of it before a single pixel is drawn.
func _probe(graph: RoadGraph, poses: Array) -> void:
	var space := root.get_world_3d().direct_space_state if root.get_world_3d() != null else null
	if space == null:
		print("[Facade] no world3d - cannot probe")
		return
	# Does this scene have ANY registered collision? If it does not, every
	# sightline test above passes vacuously and the occlusion filter is
	# decoration - which is worse than not having one, because the poses it
	# selects look checked.
	var counted := _collect_physics(root)
	print("[Facade] collision: %d CollisionObject3D, %d CollisionShape3D in the tree" % [counted.x, counted.y])
	# One vertical ray onto a footprint centre, as a positive control that the
	# physics server can see anything at all.
	if poses.size() > 0:
		var c0: Vector3 = poses[0]["look"]
		var down := PhysicsRayQueryParameters3D.create(
			Vector3(c0.x, 120.0, c0.z), Vector3(c0.x, -60.0, c0.z))
		down.collide_with_areas = false
		var dhit := space.intersect_ray(down)
		print("[Facade] control: ray down onto a footprint centre -> %s%s" % [
			("NOTHING (the physics server cannot see this scene - sightline checks are void)"
				if dhit.is_empty() else "%s at y=%.2f" % [String(dhit["collider"].name), float(dhit["position"].y)]),
			""])
	for n in poses.size():
		var p: Dictionary = poses[n]
		var eye: Vector3 = p["eye"]
		var look: Vector3 = p["look"]
		var to_wall := (look - eye)
		# Aim at the wall, not at the middle of its height: if the camera can only
		# see the wall by looking through the building, that is the finding.
		var wall_pt := Vector3(look.x, float(p["ground"]) + float(p["wall"]) * 0.5, look.z)
		var dir := (wall_pt - eye)
		var q := PhysicsRayQueryParameters3D.create(eye, wall_pt)
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		var gap := -1.0
		var what := "NOTHING (the wall is not solid - a render here shows the facade through it)"
		var facing := ""
		if not hit.is_empty():
			what = String(hit.get("collider", "?").name)
			var hp: Vector3 = hit["position"]
			gap = eye.distance_to(hp)
			var hn: Vector3 = hit["normal"]
			facing = "  face_normal=%s points_at_camera=%s" % [
				str(hn.round()), str(hn.dot(-to_wall.normalized()) > 0.0)]
		print("[Facade] %02d %s" % [n, String(p["kind"])])
		print("  eye=%s look=%s span=%.1f wall=%.2f ground=%.2f" % [
			str(eye.round()), str(look.round()), float(p["span"]),
			float(p["wall"]), float(p["ground"])])
		print("  standoff=%.1f m  look_dir=%s" % [
			eye.distance_to(look), str(dir.normalized().round())])
		print("  first_hit=%s  gap=%.2f m%s" % [what, gap, facing])
		print("  facade centre=%s  wants_to_see=%s" % [
			str(Vector3(look.x, 0, look.z).round()),
			str((wall_pt - eye).normalized().round())])


func _report(out: String, tag: String, poses: Array) -> void:
	var lines := ["# facade capture %s" % tag, ""]
	for n in poses.size():
		var p: Dictionary = poses[n]
		var file := "%s/%s-%02d-%s.png" % [out, tag, n, String(p["kind"])]
		var img := Image.load_from_file(file)
		if img == null:
			print("[Facade] MISSING %s - the render did not produce a frame" % file)
			lines.append("## %02d %s - NO FRAME" % [n, String(p["kind"])])
			continue
		var m := _band_stats(img)
		lines.append("## %02d %s  span %.1f m  wall %.2f m  %s  road %s" % [
			n, String(p["kind"]), float(p["span"]), float(p["wall"]),
			"shopfront" if bool(p["shop"]) else "house",
			_cls_name(int(p["cls"]))])
		lines.append("  " + str(m))
	print("\n".join(lines))
	var f := FileAccess.open("%s/%s.md" % [out, tag], FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()


func _measure_only(out: String, tag: String) -> void:
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	_report(out, tag, _poses(graph))


## The facade band is the middle 44% of the frame horizontally and the middle
## half vertically - the slice a camera at STANDOFF off a wall actually puts the
## wall in. Sky and tarmac are excluded on purpose: a facade that reads well while
## the sky is black is still a facade that reads.
func _band_stats(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(w * 0.28)
	var x1 := int(w * 0.72)
	var y0 := int(h * 0.24)
	var y1 := int(h * 0.76)
	var total := 0.0
	var n := 0
	var clipped := 0
	var dark := 0
	var peak := 0.0
	# 16 column buckets across the band.
	var cols := PackedFloat32Array()
	cols.resize(16)
	var coln := PackedInt32Array()
	coln.resize(16)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			total += l
			n += 1
			peak = maxf(peak, l)
			if l >= 0.96:
				clipped += 1
			elif l < 0.02:
				dark += 1
			var b := int(float(x - x0) / float(maxi(1, x1 - x0)) * 16.0)
			cols[b] = cols[b] + l
			coln[b] = coln[b] + 1
	var mean := total / maxf(1.0, float(n))
	var profile := PackedFloat32Array()
	# Peak-to-trough across the buckets: the vertical rhythm. A flat wall scores
	# low, a wall with relief between its windows scores high.
	var lo := 1.0
	var hi := 0.0
	for b in 16:
		if coln[b] == 0:
			continue
		var v := cols[b] / float(coln[b])
		profile.append(v)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return {
		"mean": snappedf(mean, 0.0001),
		"p95": snappedf(_pct(img, x0, x1, y0, y1, 0.95), 0.0001),
		"peak": snappedf(peak, 0.0001),
		"clipped%": snappedf(100.0 * float(clipped) / maxf(1.0, float(n)), 0.01),
		"dark%": snappedf(100.0 * float(dark) / maxf(1.0, float(n)), 0.01),
		"col_rhythm": snappedf(hi - lo, 0.0001),
		"cols": profile,
	}


func _pct(img: Image, x0: int, x1: int, y0: int, y1: int, q: float) -> float:
	var all := PackedFloat32Array()
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			var c := img.get_pixel(x, y)
			all.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
	if all.is_empty():
		return 0.0
	all.sort()
	return all[int(clampf(q * float(all.size() - 1), 0.0, float(all.size() - 1)))]


func _cls_name(c: int) -> String:
	match c:
		RoadGraph.RoadClass.HIGHWAY: return "highway"
		RoadGraph.RoadClass.ARTERIAL: return "arterial"
		RoadGraph.RoadClass.STREET: return "street"
		RoadGraph.RoadClass.LANE: return "lane"
	return "class %d" % c
