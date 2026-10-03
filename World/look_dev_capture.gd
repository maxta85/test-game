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
		print("[LookDev] %s  asked=%s got=%s current=%s fov=%.0f street=%s run_m=%.0f -> %s" % [
			pose, str(spec["at"].round()), str(cam.global_position.round()),
			str(cam.current), float(spec["fov"]), str(spec.get("street", "")),
			float(spec.get("run_m", 0.0)), path])
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
			#
			# But `nearest_road` is not enough, and that was measured too. It snaps
			# to the nearest edge *of any street*, so at 500 m the straight-line
			# point came back `lateral=68.07 edge=238 len=58` - 68 m off the
			# arterial, on a different 58 m residential street - and at 0 m it came
			# back `lateral=8.86` on a 14 m road, i.e. 1.9 m outside the kerb. The
			# chain walk below follows the anchor's own connected edges instead, so
			# every walk pose is on the anchor street by construction.
			var k := int(pose.replace("walk", ""))
			var back: float = WALK_BACK_M[clampi(k - 1, 0, WALK_BACK_M.size() - 1)]
			var walk := _walk_along(g, at, back)
			var base: Vector3 = walk["point"]
			var weid := int(walk["edge"])
			if weid >= 0:
				var na: Vector2 = g.node_pos(int(g.edges[weid]["a"]))
				var nb: Vector2 = g.node_pos(int(g.edges[weid]["b"]))
				var toward_a: float = base.distance_squared_to(
					Vector3(na.x, base.y, na.y))
				var far: Vector2 = nb if toward_a > base.distance_squared_to(
					Vector3(nb.x, base.y, nb.y)) else na
				var near: Vector2 = na if toward_a > base.distance_squared_to(
					Vector3(nb.x, base.y, nb.y)) else nb
				var d := (base - Vector3(near.x, 0.0, near.y))
				d = d.normalized() if d.length() > 0.1 else -fwd
				out = {"at": base - d * 18.0 + Vector3(0.0, 2.4, 0.0),
					"look": Vector3(far.x, 1.0, far.y), "fov": 55.0,
					"run_m": 90.0,
					"street": walk["name"],
					"road": Rect2(0.10, 0.78, 0.80, 0.16),
					"paint": Rect2(0.28, 0.70, 0.44, 0.08)}
			else:
				out = {"at": at - fwd * back + Vector3(0.0, 2.4, 0.0),
					"look": at + fwd * 60.0 + Vector3(0.0, 1.0, 0.0), "fov": 55.0,
					"run_m": 0.0,
					"street": "",
					"road": Rect2(0.10, 0.78, 0.80, 0.16),
					"paint": Rect2(0.28, 0.70, 0.44, 0.08)}
	# Every branch above replaces `out` wholesale, which is how the pose name got
	# dropped once already: `_measure` read `spec["name"]`, the lookup threw, and
	# six poses came back as `{}` - a report that measured nothing and looked
	# like a report that passed. Stamp it on once, here, where it cannot be lost.
	out["name"] = pose
	# Stamp the street every pose is on, in one place, so the log line can claim
	# it instead of the report having to be trusted. A pose spec that says
	# nothing about which street it is on is a pose spec that can silently be
	# somewhere else - which is exactly what `nearest_road` did at 500 m.
	if String(out.get("street", "")) == "":
		var se := int(g.nearest_road(out["at"] as Vector3)["edge"])
		out["street"] = String(g.edges[se].get("name", "")) if se >= 0 and se < g.edges.size() else ""
	return out


## Walk `back_m` back along the anchor street's OWN edge chain and return where
## that lands. `nearest_road` is the wrong tool for this because it answers
## "what is the closest edge of any street", which is how a pose that is meant
## to be 500 m down a 4-lane arterial ended up 68 m sideways on a 58 m
## residential street.
##
## From the anchor edge's near end, repeatedly take the incident edge that best
## continues the current heading, and stop when the street turns too hard to be
## the same street any more (`MIN_CONTINUE_DOT`) or the budget runs out. Every
## hop is a real connected edge, so the answer is on the anchor by construction
## rather than by hoping the nearest street is the right one.
const MIN_CONTINUE_DOT := 0.55
const MAX_CHAIN_HOPS := 64


func _walk_along(g: RoadGraph, at: Vector3, back_m: float) -> Dictionary:
	var snap := g.nearest_road(at)
	var eid := int(snap["edge"])
	if eid < 0 or eid >= g.edges.size():
		return {"point": at, "edge": -1, "name": ""}
	var base: Vector3 = snap["point"]
	var na: Vector2 = g.node_pos(int(g.edges[eid]["a"]))
	var nb: Vector2 = g.node_pos(int(g.edges[eid]["b"]))
	# Stand on the end of the anchor edge that is behind `at`, and head away
	# from `at`. Everything after this follows real edges.
	var to_a: float = base.distance_squared_to(Vector3(na.x, base.y, na.y))
	var to_b: float = base.distance_squared_to(Vector3(nb.x, base.y, nb.y))
	var cur: int = int(g.edges[eid]["a"]) if to_a < to_b else int(g.edges[eid]["b"])
	var far_node: int = int(g.edges[eid]["b"]) if to_a < to_b else int(g.edges[eid]["a"])
	var cur_pos: Vector2 = g.node_pos(cur)
	var heading: Vector2 = (cur_pos - Vector2(base.x, base.z)).normalized()
	if heading.length() < 0.1:
		heading = Vector2(base.x, base.z) - cur_pos
		heading = heading.normalized() if heading.length() > 0.1 else Vector2(1.0, 0.0)
	var from_eid := eid
	var want_street := String(g.edges[eid].get("name", ""))
	var left := back_m
	var last_from: Vector2 = cur_pos
	var last_to: Vector2 = cur_pos
	var last_len := 1.0
	var last_eid := eid
	var hops := 0
	while left > 0.0 and hops < MAX_CHAIN_HOPS:
		hops += 1
		var best := -1
		var best_dot := MIN_CONTINUE_DOT
		for cand in g.nodes[cur]["edges"]:
			var ce := int(cand)
			if ce == from_eid or ce < 0 or ce >= g.edges.size():
				continue
			# Same street or nothing. A heading test alone is not enough: measured
			# with it, the 500 m pose wandered onto a side street 434 m from the
			# anchor, because at every junction it just took the best-aligned edge
			# and a side street off a bend can be perfectly aligned for one hop.
			# The name is what makes "still on the anchor street" a fact.
			var cn := String(g.edges[ce].get("name", ""))
			if want_street != "" and cn != "" and cn != want_street:
				continue
			var ca: int = int(g.edges[ce]["a"])
			var cb: int = int(g.edges[ce]["b"])
			var other: int = cb if ca == cur else ca
			if other < 0 or other == cur:
				continue
			var op: Vector2 = g.node_pos(other)
			var dir := op - cur_pos
			var l := dir.length()
			if l < 1.0:
				continue
			var d: float = (dir / l).dot(heading)
			if d > best_dot:
				best_dot = d
				best = ce
		if best < 0:
			break
		var ba: int = int(g.edges[best]["a"])
		var bb: int = int(g.edges[best]["b"])
		var other2: int = bb if ba == cur else ba
		var op2: Vector2 = g.node_pos(other2)
		var seg := op2 - cur_pos
		var seg_len := seg.length()
		if seg_len < 1.0:
			break
		last_from = cur_pos
		last_to = op2
		last_len = seg_len
		last_eid = best
		heading = seg / seg_len
		left -= seg_len
		cur = other2
		cur_pos = op2
		far_node = cur
		from_eid = best
	# Slide the leftover budget along the last real segment so the camera lands
	# at the requested distance instead of at the previous junction.
	var t := 1.0
	if left > 0.0 and last_len > 0.0:
		t = clampf(1.0 - left / last_len, 0.0, 1.0)
	var pt: Vector2 = last_from.lerp(last_to, t)
	return {"point": Vector3(pt.x, base.y, pt.y), "edge": last_eid,
		"name": String(g.edges[last_eid].get("name", ""))}


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


## Hide every Control in the tree, so two runs cannot differ by a lap counter or
## a menu still fading out.
##
## The `CanvasLayer` case is the one that matters and the one the first version
## got wrong: a `CanvasLayer` is **not** a `CanvasItem` (it extends `Node`, so it
## has no `visible` and no transform of its own - it is a container that hands
## its children a different camera). `(c as CanvasItem)` on one of those is
## `null`, so the `if c is CanvasLayer or c is Control` branch took the cast and
## the write threw
##
##     Invalid assignment of property or key 'visible' ... on a base object of type 'Nil'
##
## which aborts the function. Because GDScript unwinds the *callee* and hands
## control back to `_initialize`, the capture did not die loudly - it stopped
## posing frames and left a `SceneTree` with nothing to quit it, so the process
## sat there until the timeout and produced zero PNGs and no marker. The
## `CanvasLayer` is recursed into instead: the Control tree that actually draws
## is always one level down from it.
func _hide_ui(n: Node) -> void:
	for c in n.get_children():
		if c is CanvasLayer:
			_hide_ui(c)
		elif c is CanvasItem:
			(c as CanvasItem).visible = false
		else:
			_hide_ui(c)



