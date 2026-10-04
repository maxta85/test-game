extends SceneTree
## Deterministic look-dev frame grab. Run it, and it renders the same frames every
## time from the same camera, and it measures them.
##
##     godot --headless --path . --script res://World/look_dev_capture.gd -- \
##           --out /tmp/frames --tag before --measure
##
## `--measure` re-reads `<out>/<tag>-<pose>.png` off disk and rewrites the report
## without rendering. The frames are the expensive part - about three minutes of
## llvmpipe each - so a measurement fix should never cost another render, and a
## before/after pair stays valid even when the threshold in `LookDev` changes
## after the pictures were taken.
##
## Why this exists instead of `./render.sh`: that path waits 40 frames for a race
## to start and then poses the camera *relative to the car*, so two runs are two
## different frames and "the kerbs look better" is not a measurable claim. This
## poses from `OSMLayout.start_line()` with fixed offsets, freezes the tree, and
## grabs one frame per pose, so a before/after pair is the same camera on two
## different builds.
##
## It also prints the `LookDev` statistics next to the PNGs. The thresholds those
## statistics are held to are in `World/look_dev.gd`, and they are the machine
## half of the rubric `docs/decisions/0001-art-director.md` says a vision model
## should be asked about; `World/look_dev_test.gd` is what makes them checkable
## by assertion instead of by opinion.

const HERO_POSES := ["kerb", "street", "junction"]
## Walk poses, at these distances back along the anchor street. Spaced 250 m
## apart so the three together are the 500 m stretch the decision document says
## has to be good before the map is allowed to grow.
const WALK_BACK_M := [0.0, 250.0, 500.0]

## The residential poses, deliberately NOT in the default list.
##
## Every pose above is on the anchor street, which is a commercial strip: it
## frames shopfronts, kerbs and junctions and never a house. The building detail
## that `World/osm_buildings.gd` spends 1,659 verandas on lives on side streets
## that nothing here could see, so `resi` and `resi_detail` were written to look
## at one - and they are opt-in (`--only resi`) rather than added to
## `HERO_POSES`, because `World/look_dev_test.gd::_image_gate` asserts every
## rubric point in `World/look_measure.gd` over every pose in the report, and
## those thresholds were calibrated on kerb/street/junction. Adding a fifth
## subject nobody calibrated would hand the next agent a red gate for a scene
## that is fine.
const RESI_POSES := ["resi", "resi_detail"]
## The shortest wall that gets a veranda, summed from `OSMBuildings`' own constants
## rather than copied as a number, so a change to any of the three cannot leave
## this quietly picking walls the builder would skip.
const RESI_MIN_SPAN := OSMBuildings.VERANDA_OUT + OSMBuildings.CORNER_MARGIN * 2.0 + 0.6
## Eye heights. `resi` is 1.65 m, a standing adult on the footpath.
##
## `resi_detail` is the same eye height and looks at the same building; only the
## standoff changes.
##
## Three attempts at this pose, and the two that failed are the useful part. In the
## near lane for a steep 3/4 angle, the view went through a parked car; raised to
## 2.4 m to clear it, through a tree instead - a faceted `(0, 0, 0)` artkit canopy
## that did not move when the camera rose 0.8 m, which is what said "not a car".
## Moved onto the footpath it went through a *second* tree, bigger, because these
## footpaths have trees on them. The conclusion is not "raise it higher": it is that
## eye level on this street is inside the canopy, so the detail pose crosses the
## road and shoots back, where the only thing between camera and wall is air.
const RESI_EYE := 1.65
const RESI_EYE_DETAIL := 1.65
## A house-sized frontage, for the pose that has to show one veranda rather than a
## whole street. The longest street-facing wall in this map is 26.1 m, which is
## two shops or a small block: a 26 m veranda is a veranda on nothing anybody
## lives in. The detail pose takes the longest frontage inside this band instead.
const RESI_HOUSE_SPAN := Vector2(7.0, 14.0)

var _resi: Dictionary = {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/lookdev"
	var tag := "frame"
	var settle := 10
	var only := ""
	var remeasure := false
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			"--tag":
				tag = String(args[i + 1]); i += 2
			"--settle":
				settle = int(args[i + 1]); i += 2
			"--only":
				only = String(args[i + 1]); i += 2
			"--measure":
				remeasure = true; i += 1
			_:
				i += 1
	DirAccess.make_dir_recursive_absolute(out)

	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var street := OSMLayout.start_line()
	var at: Vector3 = street["pos"]
	var d: Vector2 = street["dir"]
	var fwd := Vector3(d.x, 0.0, d.y).normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var pts: Array = []
	var poses := _pose_list(only)

	if remeasure:
		for pose in poses:
			var spec: Dictionary = _pose_spec(String(pose), at, fwd, side, g)
			var path := "%s/%s-%s.png" % [out, tag, pose]
			var img := Image.new()
			if img.load(path) != OK:
				push_error("[LookDev] no frame at %s - render it first" % path)
				quit(1)
				return
			var m := _measure(img, spec)
			pts.append(m)
			print("[LookDev] %s  %s" % [pose, JSON.stringify(m)])
		_write_report(pts, out, tag)
		quit(0)
		return

	print("[LookDev] booting world (settle=%d frames)" % settle)
	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	for f in settle:
		await process_frame

	# The game opens on its main menu, which is a full-screen Control tree over the
	# whole viewport: 70% of the frame is "START RACE" and the measurements below
	# were reading a menu. `MenuFlow.close()` first, because it also un-pauses the
	# tree, then hide whatever is left so two runs cannot differ by a lap counter.
	var flow := _menu_flow(main)
	if flow != null:
		flow.call("close")
	_hide_ui(main)

	var cam: Camera3D = _camera(main)
	if cam == null:
		push_error("[LookDev] no Camera3D in the scene")
		quit(1)
		return
	# Whatever owns the chase rig re-writes its child's transform every frame, so
	# "set the camera and grab" silently renders the rig's pose instead. Detach
	# every `tracking` in the ancestry rather than reaching for one property by
	# name: the first version of this reached for `main.camera`, and when that
	# lookup missed, all six poses came back byte-identical.
	for n in _ancestry(cam):
		if "tracking" in n:
			n.set("tracking", false)
	cam.current = true

	# `Engine.time_scale = 0` and not `paused = true`: both stop the cars, but a
	# paused tree is also what a half-initialised menu fights over, and a frozen
	# clock leaves the renderer running, which is the part that has to happen.
	Engine.time_scale = 0.0

	for pose in poses:
		var spec: Dictionary = _pose_spec(String(pose), at, fwd, side, g)
		cam.global_position = spec["at"]
		cam.look_at(spec["look"], Vector3.UP)
		cam.fov = float(spec["fov"])
		for f in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := get_root().get_texture().get_image()
		var path := "%s/%s-%s.png" % [out, tag, pose]
		img.save_png(path)
		var m := _measure(img, spec)
		pts.append(m)
		# Print where the camera *ended up*, not where it was asked to go: the
		# gap between those two numbers is the whole class of bug this harness
		# exists to rule out, and it is invisible in the picture.
		print("[LookDev] %s  asked=%s got=%s current=%s fov=%.0f  -> %s" % [
			pose, str(spec["at"].round()), str(cam.global_position.round()),
			str(cam.current), float(spec["fov"]), path])
		print("           %s" % JSON.stringify(m))

	Engine.time_scale = 1.0
	_write_report(pts, out, tag)
	quit(0)


## The camera the viewport is actually drawing with, in preference to the first
## Camera3D in the tree. `ChaseCamera` builds its own child camera, so "the first
## one in the tree" and "the one in charge" only agree until something else
## claims `current`.
func _camera(n: Node) -> Camera3D:
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


func _ancestry(n: Node) -> Array:
	var out: Array = []
	var cur := n
	while cur != null:
		out.append(cur)
		cur = cur.get_parent()
	return out


## `MenuFlow`, found by its API rather than by its type. Naming the class pulls
## `UI/menu_flow.gd` in, which uses the `Cfg` autoload, and an autoload is not
## registered when Godot runs a bare `--script` - so the type reference makes this
## file fail to compile in exactly the mode used to check that it compiles.
func _menu_flow(n: Node) -> Node:
	if n.has_method("menu_visible") and n.has_method("show_main_menu"):
		return n
	for c in n.get_children():
		var found := _menu_flow(c)
		if found != null:
			return found
	return null


func _write_report(pts: Array, out: String, tag: String) -> void:
	var report := "%s/%s-lookdev.json" % [out, tag]
	var f := FileAccess.open(report, FileAccess.WRITE)
	f.store_string(JSON.stringify({"poses": pts}, "  "))
	f.close()
	print("[LookDev] wrote %s" % report)


## The pose list, in a fixed order so two runs write the same filenames.
func _pose_list(only: String) -> Array:
	var out: Array = []
	if only != "":
		return [only]
	for p in HERO_POSES:
		out.append(p)
	for i in WALK_BACK_M.size():
		out.append("walk%d" % (i + 1))
	return out


## Camera poses, derived from the anchor street so they are map-independent and
## stable, and expressed as offsets rather than literals so a rotated map still
## frames the same thing.
##
## `run_m` is the stretch of street the pose is on the record for: it is the
## camera-to-aim distance plus the half-width the horizontal fov covers at that
## distance, which is the visible run of carriageway. `LookDev.COVERAGE_M` is
## asserted against the sum, so the 500 m gate is measured from the frames rather
## than asserted about them.
func _pose_spec(pose: String, at: Vector3, fwd: Vector3, side: Vector3, g: RoadGraph) -> Dictionary:
	var edge := float(g.nearest_road(at + fwd * 20.0)["lateral"])
	var out := {"name": pose}
	match pose:
		"kerb":
			# On the footpath, a car roof above the camera, looking down the kerb
			# line. The pose the kerb and channel were designed for.
			#
			# It was at 1.05 m - eye height, edge-on to a 0.14 m kerb face, which
			# is the right idea - and it framed the *underside of a car*: the
			# player's car is parked near `OSMLayout.start_line()` and at eye
			# height 18 m back the whole right half of the frame was bodywork and
			# a wheel. A kerb you judge from inside a wheel arch is not judged. 2.4
			# m clears the tallest thing on this street and still looks down the
			# kerb at a shallow enough angle to see the face and the channel.
			out = {"at": at - fwd * 24.0 + side * (edge + 2.6) + Vector3(0.0, 2.4, 0.0),
				"look": at + fwd * 40.0 + Vector3(0.0, 0.15, 0.0), "fov": 45.0,
				"run_m": 64.0,
				"road": Rect2(0.05, 0.86, 0.90, 0.12),
				"paint": Rect2(0.30, 0.62, 0.40, 0.10)}
		"street":
			# The chase-camera height, so this is the frame a player actually
			# sees: two lanes, an edge line each side, kerbs and footpaths.
			out = {"at": at - fwd * 120.0 + Vector3(0.0, 3.2, 0.0),
				"look": at + fwd * 40.0 + Vector3(0.0, 1.0, 0.0), "fov": 52.0,
				"run_m": 160.0,
				"road": Rect2(0.10, 0.74, 0.80, 0.20),
				"paint": Rect2(0.25, 0.80, 0.50, 0.06)}
		"junction":
			# Back off a three-way junction, which is where paint seams live: the
			# stop bar, the give-way row, the edge lines and the kerb all meet.
			var n := _junction_ahead(at, fwd, g)
			out = {"at": n - fwd * 46.0 + Vector3(0.0, 5.0, 0.0),
				"look": n + fwd * 26.0 + Vector3(0.0, 0.6, 0.0), "fov": 55.0,
				"run_m": 96.0,
				"road": Rect2(0.15, 0.66, 0.70, 0.26),
				"paint": Rect2(0.30, 0.52, 0.40, 0.10)}
		_:
			if RESI_POSES.has(pose):
				return _residential_spec(String(pose), g)
			# walk1..3: the same pose, walked back along the street.
			#
			# Snapped to the road network, because walking a fixed 500 m back
			# along the anchor street's *direction* walks straight off the end of
			# it: the first version put the camera in empty terrain and counted 90 m
			# of covered street for a frame of black. Both the before and the after
			# build measured that pose identically - road mean 2.65, road dark
			# 1.000 - because there was no road in it to measure. So the pose is
			# built from the edge the camera actually lands on and looks at that
			# street's far junction.
			var k := int(pose.replace("walk", ""))
			var back: float = WALK_BACK_M[clampi(k - 1, 0, WALK_BACK_M.size() - 1)]
			var snap := g.nearest_road(at - fwd * back)
			var base: Vector3 = snap["point"]
			var eid := int(snap["edge"])
			if eid >= 0:
				var na: Vector2 = g.node_pos(int(g.edges[eid]["a"]))
				var nb: Vector2 = g.node_pos(int(g.edges[eid]["b"]))
				var toward_a: float = base.distance_squared_to(
					Vector3(na.x, base.y, na.y))
				var far: Vector2 = nb if toward_a > base.distance_squared_to(
					Vector3(nb.x, base.y, nb.y)) else na
				var near: Vector2 = na if toward_a > base.distance_squared_to(
					Vector3(nb.x, base.y, nb.y)) else nb
				var d := (base - Vector3(near.x, 0.0, near.y))
				d = d.normalized() if d.length() > 0.1 else -fwd
				out = {"at": base - d * 18.0 + Vector3(0.0, 2.2, 0.0),
					"look": Vector3(far.x, 1.0, far.y), "fov": 55.0,
					"run_m": 90.0,
					"road": Rect2(0.10, 0.78, 0.80, 0.16),
					"paint": Rect2(0.28, 0.70, 0.44, 0.08)}
			else:
				out = {"at": at - fwd * back + Vector3(0.0, 2.2, 0.0),
					"look": at + fwd * 60.0 + Vector3(0.0, 1.0, 0.0), "fov": 55.0,
					"run_m": 0.0,
					"road": Rect2(0.10, 0.78, 0.80, 0.16),
					"paint": Rect2(0.28, 0.70, 0.44, 0.08)}
	# Every branch above replaces `out` wholesale, which is how the pose name got
	# dropped once already: `_measure` read `spec["name"]`, the lookup threw, and
	# six poses came back as `{}` - a report that measured nothing and looked
	# like a report that passed. Stamp it on once, here, where it cannot be lost.
	out["name"] = pose
	return out


## The residential poses: a house with a veranda on it, found in the data.
##
## Everything else in this file is anchored to `OSMLayout.start_line()`, which is
## a shopfront strip, so no pose here can frame a Queenslander. The subject is
## therefore looked up rather than written down, and it is looked up in
## `OSMBuildings.plan()` - the same `faces` array the builder glazes the veranda
## from - so "this camera is pointed at a veranda" is true by construction. A
## literal coordinate would drift onto the wrong house the first time
## `Tools/osm_cairns.py` re-cut a footprint, and nothing would say so.
##
## The `gap <= FRONTAGE_M` test is load-bearing and is why this pose is also the
## evidence for a defect: `OSMBuildings._street_faces()` hands back one face for
## a building that has *no* frontage at all, so of the 1,659 verandas the builder
## emits, only 21 are on a wall a person on the street can see. A camera that
## picks its subject by span alone would frame a backland wall nine times out of
## ten, which is exactly the mistake this function refuses to make.
func _residential_spec(pose: String, g: RoadGraph) -> Dictionary:
	var s := _resi_subject(g, "street")
	if s.is_empty():
		push_error("[LookDev] no street-facing veranda in the map - the resi poses need one")
		return {"name": pose, "at": Vector3.ZERO, "look": Vector3(0.0, 1.0, -1.0),
			"fov": 50.0, "run_m": 0.0, "road": Rect2(0.1, 0.7, 0.8, 0.2),
			"paint": Rect2(0.3, 0.8, 0.4, 0.06)}
	var wall: Vector2 = s["mid"]
	var along: Vector2 = s["dir"]
	var out: Vector2 = s["nrm"]
	var hw: float = g.width_for(int(s["cls"])) * 0.5
	var span: float = s["span"]
	var ground: float = s["lift"]
	var gap: float = s["gap"]
	# Where the camera stands, measured out from the wall along `out` and then
	# along the frontage.
	#
	# `resi` is the shot the anchor-street poses cannot make: 21 m down its own
	# frontage, on the footpath, so the veranda recedes and the street is in frame.
	# Across the road it cannot work - a 9 m street puts the far kerb 11.5 m from
	# the wall, which at fov 50 crops a 26 m frontage to ten metres of it.
	#
	# `resi_detail` crosses the carriageway and shoots back at the same veranda
	# from the far footpath, which is the only sightline on this street with
	# nothing in it: the near lane is parked cars and the near footpath is trees.
	var detail := pose == "resi_detail"
	var standoff := (hw + gap + 1.8) if detail else (gap - 0.6)
	var along_m := span * (0.80 if not detail else 0.34)
	var stand := wall + out * standoff + along * along_m
	var look_at := wall + along * (span * 0.30) - out * (0.3 if detail else 0.0)
	# The camera has to be on the road network, or it is inside a block looking at
	# the back of a wall - which is a frame that renders fine and measures fine and
	# is worth nothing. `nearest_road` is the same call the layout uses, so this is
	# the real carriageway and not a guess at it.
	var nr := g.nearest_road(Vector3(stand.x, 0.0, stand.y))
	var eid := int(nr["edge"])
	# `nearest_road()` answers `{edge, dist_along, point, lateral}` - there is no
	# "class" on it. The width of the carriageway it found lives on the edge, which
	# is the same two-step Tests/test_osm_buildings.gd takes.
	var off_road := 9999.0
	if eid >= 0:
		var hw_here := g.width_for(int(g.edges[eid]["class"])) * 0.5
		off_road = float(nr["lateral"]) - hw_here
		# Past the footpath is the failure, not past the kerb: standing on the
		# footpath is the whole point of `resi`, and warning about it trained me to
		# ignore the warning. `FOOTPATH_W` is the project's own number for how far
		# back the footpath goes, so this threshold is not one I picked.
		if off_road > LookDev.FOOTPATH_W:
			push_warning("[LookDev] %s camera is %.1f m past the footpath, not on the street (lateral %.1f m, half-width %.1f m)" % [
				pose, off_road - LookDev.FOOTPATH_W, float(nr["lateral"]), hw_here])
	var eye := RESI_EYE if not detail else RESI_EYE_DETAIL
	# The pose to two decimals, not the rounded one the generic print below shows.
	# This harness's own argument is that a camera nobody can check is a camera
	# nobody can trust, and `Systems/camera/shot_poser.gd` carries a copy of these
	# numbers for `./render.sh residential` - a copy needs a source worth copying.
	print("[LookDev] %s pose: at=(%.2f, %.2f, %.2f) look=(%.2f, %.2f, %.2f) fov=%.0f standoff=%.2f along=%.2f" % [
		pose, stand.x, eye, stand.y, look_at.x, ground + (1.40 if not detail else 1.45),
		look_at.y, 50.0 if detail else 55.0, standoff, along_m])
	# The veranda occupies deck (0.85 m here) to roof edge (~3.1 m), so the detail
	# pose aims into the middle of it rather than at the windows above.
	var aim_y := ground + (1.40 if not detail else 1.45)
	return {
		"name": pose,
		"at": Vector3(stand.x, eye, stand.y),
		"look": Vector3(look_at.x, aim_y, look_at.y),
		"fov": 50.0 if detail else 55.0,
		"run_m": span,
		# The bands the rubric reads. The road is the bottom of the frame in both,
		# and `resi` is the wider one so its band sits lower.
		"road": Rect2(0.06, 0.74, 0.88, 0.22) if pose == "resi" else Rect2(0.02, 0.80, 0.96, 0.18),
		"paint": Rect2(0.30, 0.86, 0.40, 0.08),
	}


## The wall a resi pose looks at, chosen from the map and cached per subject.
##
## `street` takes the longest street-facing frontage in the map, because a 5 m
## wall gives a camera nothing to stand back from and a long one gives it a run
## of veranda receding down the street. `detail` takes the longest one inside
## RESI_HOUSE_SPAN instead, because the point of that pose is one readable
## veranda and the longest wall on the map is a 26 m block nobody would give a
## veranda to.
func _resi_subject(g: RoadGraph, key: String) -> Dictionary:
	if _resi.has(key):
		return _resi[key]
	var house := key == "detail"
	var plan := OSMBuildings.plan(g)
	var longest := 0.0
	var pick: Dictionary = {}
	for e in plan["buildings"]:
		# A shop has an awning, not a veranda; `flat` is the same test the builder
		# uses to decide which of the two it is drawing.
		if bool(e["flat"]):
			continue
		var ring: PackedVector2Array = e["ring"]
		for f in e["faces"]:
			if float(f["gap"]) > OSMBuildings.FRONTAGE_M:
				continue
			var i := int(f["i"])
			var a := ring[i]
			var b := ring[(i + 1) % ring.size()]
			var span := a.distance_to(b)
			if span < RESI_MIN_SPAN or span <= longest:
				continue
			if house and span > RESI_HOUSE_SPAN.y:
				continue
			longest = span
			var dir := (b - a) / span
			pick = {
				"mid": (a + b) * 0.5,
				# Same outward normal as `OSMBuildings._band`: rings are wound so
				# the outward normal of a -> b is (dy, -dx).
				"dir": dir,
				"nrm": Vector2(dir.y, -dir.x),
				"span": span,
				"gap": float(f["gap"]),
				"cls": int(f["cls"]),
				"id": int(e["id"]),
				"lift": float(e["lift"]),
				"wall": float(e["wall"]),
			}
	_resi[key] = pick
	if not pick.is_empty():
		print("[LookDev] resi/%s subject: osm %d, %.1f m frontage, %.1f m off the kerb, class %d, deck %.2f m, wall %.2f m"
			% [key, int(pick["id"]), float(pick["span"]), float(pick["gap"]),
				int(pick["cls"]), float(pick["lift"]), float(pick["wall"])])
	return pick


## The first three-way junction ahead of `at` along `fwd`, or `at` itself.
func _junction_ahead(at: Vector3, fwd: Vector3, g: RoadGraph) -> Vector3:
	var best := -1.0
	for ni in g.nodes.size():
		var n: Dictionary = g.nodes[ni]
		if int(n["edges"].size()) < 3:
			continue
		var p: Vector2 = g.node_pos(ni)
		var v := Vector3(p.x, 0.0, p.y)
		var along := (v - at).dot(fwd)
		if along < 40.0:
			continue
		if best < 0.0 or along < best:
			best = along
	if best < 0.0:
		return at + fwd * 60.0
	return at + fwd * best


func _measure(img: Image, spec: Dictionary) -> Dictionary:
	var r: Rect2 = spec["road"]
	var p: Rect2 = spec["paint"]
	return {
		"name": String(spec["name"]),
		"report": LookMeasure.measure_image(img),
		"road": LookMeasure.measure_band(img, r.position.x, r.position.y,
			r.position.x + r.size.x, r.position.y + r.size.y),
		"paint": LookMeasure.measure_band(img, p.position.x, p.position.y,
			p.position.x + p.size.x, p.position.y + p.size.y),
		"covered_m": float(spec["run_m"]),
	}


func _hide_ui(n: Node) -> void:
	for c in n.get_children():
		if c is CanvasLayer or c is Control:
			(c as CanvasItem).visible = false
		else:
			_hide_ui(c)



