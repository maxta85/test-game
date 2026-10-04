extends SceneTree
## Slab capture: stand on the footpath at eye height and look down it, then measure
## the paving rhythm.
##
##     godot --path . --rendering-driver vulkan --audio-driver Dummy \
##       --resolution 1280x720 \
##       --script res://World/slab_capture.gd -- --out /tmp/slab --tag before
##
## Why its own rig rather than `./render.sh`: the `ShotPoser` presets aim at the
## carriageway and none of them puts a camera ON a footpath looking down it, which
## is the only view in which paving slabs are legible - a slab is identified by the
## joint lines receding towards the vanishing point, and from a car you see them
## edge-on as a texture, not as slabs. `ShotPoser` is also in `Systems/`, which
## this worktree does not own.
##
## THE POSES COME FROM THE BUILT SCENE, NOT FROM THE BUILDER'S ARITHMETIC.
##
## Three earlier versions of this rig computed the footpath position with the same
## formula `WorldBuilder._kerbs_and_footpaths()` uses - carriageway half-width plus
## kerb top plus half the footpath - and every one of them was confidently wrong.
## The formula agrees with itself by construction, so `off_centre=5.60 hw=4.50` was
## printed as proof that the camera stood on paving while the frame showed bare
## sand. It was wrong because the builder DROPS the kerb and the footpath wherever
## `_blocked_by_junction()` is true, while `_streetlights()` slides its lamp along
## the street to escape that same test, so a lamp can stand on a side that has no
## paving under it at all. Asking `_blocked_by_junction()` directly did not fix it
## either: it disagreed with what was rendered.
##
## So the rig reads what was actually built: the instance transforms out of the
## `Batch_footpaths` MultiMesh, and the positions of the `OmniLight3D` nodes the
## builder added. Standing on a slab origin puts the camera on paving by
## construction, and standing 6.5 m from a real light puts it in real light.
##
## `--tint` paints the footpath batch flat magenta. It is the positive control for
## all of the above: geometry-derived claims cannot disagree with themselves, but
## magenta paving either is or is not under the camera.
##
## `--measure` re-reads the PNGs in `<out>` against the poses recorded by the
## render, so re-thresholding never costs another render - and never silently
## measures a different camera than the one that drew the picture.

## Eye height above the kerb top.
const EYE := 1.75
const FOV := 55.0
## How many poses. Three well-separated streets, because a footpath's joint rhythm
## has to survive a narrow residential street and a wide arterial equally - and
## three frames of the same 40 m of pavement is one opinion, not three.
const POSE_COUNT := 3
## How far apart two chosen streetlights have to be, in metres.
const LAMP_SPREAD := 240.0
## A slab is only worth standing on if it is lit but not directly under the pole.
const STAND_NEAR_LAMP := 6.5
const STAND_BAND := Vector2(2.0, 13.0)
## How far down the footpath the aim point sits, and how much lateral drift is
## still "the same footpath".
const LOOK_AHEAD := Vector2(4.5, 11.0)
const LOOK_MAX_LATERAL := 0.5
## Sight-line clutter test: how far off the line a drawn instance may sit and still
## count as blocking, and the square size of the buckets it is indexed into.
const CLUTTER_R := 1.3
const CLUTTER_Y := 2.2
const BLOCKER_MIN_Y := 0.25
const CLUTTER_CELL := 20.0
## How much darker than its neighbours a transverse joint line has to be to count.
const JOINT_DIP := 0.02
var _clutter: Dictionary = {}
var _clutter_flat: PackedFloat32Array = PackedFloat32Array()
var _clutter_bid: PackedInt32Array = PackedInt32Array()
var _clutter_names: PackedStringArray = PackedStringArray()
var _clutter_count := 0
var _why := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/slab"
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

	var tint := args.has("--tint")
	_why = args.has("--why")
	# `--poses <json>` re-renders cameras a previous run recorded. Without it the
	# before build would pick its OWN poses - but the before footpath is one 4 m box
	# per piece, so its MultiMesh holds a sixth as many instances at different
	# positions, and the two renders would be of different places. A before/after
	# has to be the same two square metres of pavement or the numbers mean nothing.
	var pose_file := ""
	var pf := args.find("--poses")
	if pf >= 0 and pf + 1 < args.size():
		pose_file = String(args[pf + 1])

	DirAccess.make_dir_recursive_absolute(out)
	print("[Slab] building Cairns (OSM)...")
	var t0 := Time.get_ticks_msec()

	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	print("[Slab] road graph: %d edges, %.0f m" % [
		int(graph.stats()["edges"]), float(graph.stats()["length_m"])])

	# Exactly the boot `Game/main.gd:_ready()` does, minus the car and the menus.
	# A footpath judged under different lighting than the game ships is a footpath
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
	print("[Slab] world built in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))

	if tint:
		_tint_footpaths(world)

	for f in 8:
		await physics_frame

	var space := root.get_world_3d().direct_space_state
	var poses: Array = []
	if pose_file != "":
		poses = _load_poses(pose_file)
		print("[Slab] %d poses loaded from %s" % [poses.size(), pose_file])
		if poses.is_empty():
			return
	else:
		_index_clutter(world)
		poses = _poses(world, space)
	# `--tint` renders EVERY pose, not just the first: the control is only worth
	# anything if it is asked about each camera in turn, and an earlier run that
	# answered the question for pose 00 and stayed silent about the other two was
	# the reason a missing footpath went unnoticed for a whole cycle.
	if tint:
		print("[Slab] TINT: %d poses rendered in magenta" % poses.size())
	print("[Slab] %d poses" % poses.size())
	# Always recorded, including when the poses were loaded rather than computed:
	# `--measure` looks for `<out>/<tag>_poses.json`, and the before tag would
	# otherwise have no file for it to find.
	_dump_poses("%s/%s_poses.json" % [out, tag], poses)

	var cam := Camera3D.new()
	cam.fov = FOV
	# `Camera3D.current` defaults to FALSE in Godot 4. Left alone, a capture saves
	# the last frame anything else drew and the PNG comes back byte-identical
	# between two builds that differ - which reads as "no effect".
	cam.current = true
	root.add_child(cam)

	for n in poses.size():
		var p: Dictionary = poses[n]
		var name := "%s-%02d" % [tag, n]
		cam.global_position = p["eye"]
		cam.look_at(p["look"], Vector3.UP)
		var got := cam.global_position
		var live := root.get_camera_3d()
		var walk := Vector3(p["walk"])
		var stand := Vector2(p["stand"])
		var g_stand := _ground_y(stand)
		var g_walk := _ground_y(Vector2(walk.x, walk.z))
		print("[Slab] STAND %s on_slab=yes lamp_d=%.2f ahead=%.2f ground_stand=%.3f ground_walk=%.3f buried=%s" % [
			name, float(p["lamp_d"]), float(p["slab_ahead"]), g_stand, g_walk,
			str(g_walk > WorldBuilder.KERB_HEIGHT + 0.01)])
		print("[Slab] %s asked=%s got=%s live=%s current_is_mine=%s look=%s fov=%.0f" % [
			name, str(Vector3(p["eye"]).round()), str(got.round()),
			str(live.global_position.round() if live != null else Vector3.ZERO),
			str(live == cam), str(Vector3(p["look"]).round()), FOV])
		# The image is the LAST RENDERED frame, so a scene change is not in it until
		# a draw has happened. `process_frame` advances logic only.
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png("%s/%s.png" % [out, name])

		# Does the frame actually contain lit paving? Unproject a point on it and
		# read THAT pixel, then four more down the footpath. A rig framing the
		# carriageway instead still saves a plausible-looking street.
		var vp := cam.get_viewport().get_visible_rect().size
		var sx := float(img.get_width()) / maxf(1.0, vp.x)
		var sy := float(img.get_height()) / maxf(1.0, vp.y)
		var uv := cam.unproject_position(walk)
		var px := Vector2i(int(uv.x * sx), int(uv.y * sy))
		var inside := px.x >= 0 and px.y >= 0 and px.x < img.get_width() and px.y < img.get_height()
		var probe_c := img.get_pixel(px.x, px.y) if inside else Color(0, 0, 0, 1)
		var hits := 0
		var lumas := PackedFloat32Array()
		for k in [2.0, 5.0, 9.0, 14.0]:
			var q2 := cam.unproject_position(walk + Vector3(p["dir"]).normalized() * k)
			var p2 := Vector2i(int(q2.x * sx), int(q2.y * sy))
			if p2.x < 0 or p2.y < 0 or p2.x >= img.get_width() or p2.y >= img.get_height():
				continue
			var cc := img.get_pixel(p2.x, p2.y)
			var l := 0.2126 * cc.r + 0.7152 * cc.g + 0.0722 * cc.b
			lumas.append(snappedf(l, 0.0001))
			# A threshold high enough that a BLACK footpath fails. The first version
			# used a sum-of-channels > 0.02, which near-black clears, so a pose
			# framing an unlit stretch of road reported 4/4 "hits" and passed as a
			# good frame. The raw lumas are printed too, so "lit enough to judge" is
			# a number in the log and not a judgement call.
			if l >= 0.05:
				hits += 1
		print("[Slab] %s wrote %dx%d  aim_px=%s in_frame=%s aim_rgb=%s walk_probe_hit=%d/4 luma=%s" % [
			name, img.get_width(), img.get_height(), str(px), str(inside),
			str(Color(probe_c.r, probe_c.g, probe_c.b, 1.0)), hits, str(lumas)])

	_report(out, tag, poses)
	quit(0)


## Poses: stand on a real paving slab, lit by a real streetlight, look down the
## footpath at more real paving slab.
##
## Ground truth only. `_slabs()` reads the built MultiMesh and `_lamps()` reads the
## built lights, so nothing here depends on reproducing the builder's placement
## arithmetic - which is the thing that was wrong three times.
func _poses(world: WorldBuilder, space: PhysicsDirectSpaceState3D) -> Array:
	var out: Array = []
	var slabs := _slabs(world)
	var lamps := _lamps(world)
	print("[Slab] ground truth: %d footpath slabs, %d lights" % [slabs.size(), lamps.size()])
	if slabs.is_empty() or lamps.is_empty():
		return out

	# Well-separated lamps: three frames of the same 40 m of pavement is one
	# opinion, not three.
	var picks: Array = []
	for lp in lamps:
		var v := Vector2(lp.x, lp.z)
		var ok := true
		for q in picks:
			if Vector2(q.x, q.z).distance_to(v) < LAMP_SPREAD:
				ok = false
				break
		if ok:
			picks.append(lp)
		if picks.size() >= POSE_COUNT:
			break
	print("[Slab] %d lamps spread >= %.0f m" % [picks.size(), LAMP_SPREAD])

	for n in picks.size():
		var lp: Vector3 = picks[n]
		var l2 := Vector2(lp.x, lp.z)
		# Slabs within reach of this lamp. One linear pass over the whole city per
		# chosen lamp; `near` is a handful of entries, so the passes below are free.
		var near: Array = []
		for s in slabs:
			var sp: Vector2 = s["pos"]
			var d := sp.distance_to(l2)
			if d >= STAND_BAND.x and d <= STAND_BAND.y:
				near.append([s, d])
		if near.is_empty():
			continue

		# Candidates ordered by how near they are to STAND_NEAR_LAMP, so the first
		# one with a clear view ahead is the one the rig stands on. Ordering matters:
		# picking the closest first and giving up when it is blocked throws away a
		# lamp that has a perfectly good standing spot 8 m along.
		near.sort_custom(func(a, b): return absf(a[1] - STAND_NEAR_LAMP) < absf(b[1] - STAND_NEAR_LAMP))
		if _why:
			var cand: Dictionary = near[0][0]
			var bl := _sight_blockers(cand["pos"], cand["dir"])
			print("[Slab] WHY lamp %.0f,%.0f: %d blockers within %.1f m of the first candidate's sight line" % [
				lp.x, lp.z, bl.size(), CLUTTER_R])
			for e in bl.slice(0, 8):
				print("[Slab] WHY   %s  d=%.2f along=%.1f dy=%.2f" % [
					String(e["batch"]), float(e["d"]), float(e["along"]), float(e["dy"])])
		var chosen: Dictionary = {}
		var chosen_d := 0.0
		var sdir := Vector2.ZERO
		var spos := Vector2.ZERO
		var rejected := 0
		for c in near:
			var cs: Dictionary = c[0]
			var cp: Vector2 = cs["pos"]
			var cd: Vector2 = cs["dir"]
			if _blocked_ahead(space, cp, cd):
				rejected += 1
				continue
			chosen = cs
			chosen_d = c[1]
			sdir = cd
			spos = cp
			break
		if chosen.is_empty():
			print("[Slab] lamp at %.0f,%.0f: every standing spot is blocked, skipping" % [lp.x, lp.z])
			continue
		print("[Slab] lamp %.0f,%.0f stand %.1f m from it, %d blocked spots skipped" % [
			lp.x, lp.z, chosen_d, rejected])
		var lateral := Vector2(-sdir.y, sdir.x)

		# Aim at real paving further along the SAME footpath, so the frame is filled
		# with slabs that exist rather than slabs that should. Aiming at the paving
		# also pitches the camera down ~15 deg: aimed at the vanishing point, the
		# paving a camera stands on falls below the frame and the picture is road.
		var look_slab: Dictionary = chosen
		var ahead := -1.0
		for c in near:
			var cs2: Dictionary = c[0]
			var cp2: Vector2 = cs2["pos"]
			var rel := cp2 - spos
			var a := rel.dot(sdir)
			var l := absf(rel.dot(lateral))
			if a > ahead and a >= LOOK_AHEAD.x and a <= LOOK_AHEAD.y and l <= LOOK_MAX_LATERAL:
				ahead = a
				look_slab = cs2
		if ahead < 0.0:
			continue

		var lpos: Vector2 = look_slab["pos"]
		out.append({
			"eye": Vector3(spos.x, WorldBuilder.KERB_HEIGHT + EYE, spos.y),
			"look": Vector3(lpos.x, WorldBuilder.KERB_HEIGHT + 0.05, lpos.y),
			"walk": Vector3(lpos.x, WorldBuilder.KERB_HEIGHT, lpos.y),
			"dir": Vector3(sdir.x, 0.0, sdir.y),
			"stand": spos,
			"lamp_d": chosen_d,
			"slab_ahead": ahead,
		})
	return out


## Is the footpath ahead of a standing spot obstructed? Hedges, bins and palms are
## placed on the footpath itself, and a camera 6.5 m behind one photographs a shrub:
## pose 01 of the first ground-truth render stood directly behind a hedge and the
## frame was 60% foliage, with the paving - the thing being judged - a strip along
## the bottom.
##
## Two tests, because neither alone is enough. Rays find COLLIDERS - that caught 4
## obstructed spots on pose 02 - but they are blind to the hedge on pose 01, which
## is render-only geometry with no body, so a collider-only check passed it twice.
## Clutter instances find anything the builder DREW. The paving, kerbs and road
## surfaces are excluded from the clutter index: they are what is being judged, and
## their instance origins sit within a metre or two of the sight line.
func _blocked_ahead(space: PhysicsDirectSpaceState3D, at: Vector2, dir: Vector2) -> bool:
	var eye := Vector3(at.x, WorldBuilder.KERB_HEIGHT + EYE, at.y)
	var fwd := Vector3(dir.x, 0.0, dir.y)
	for k in [2.5, 5.0, 8.0]:
		var q := PhysicsRayQueryParameters3D.create(eye, eye + fwd * k)
		if space.intersect_ray(q).has("position"):
			return true
	return not _sight_blockers(at, dir).is_empty()


## Everything drawn within CLUTTER_R of the sight line, nearest first, with the
## batch it came from. `--why` prints this for each lamp's first candidate, which is
## how CLUTTER_R and CLUTTER_Y were chosen: at 1.3 m and a 2.2 m height band the
## test rejected ALL THREE poses, because Cairns has 164575 drawn instances and a
## footpath runs past a hedge every few metres. A threshold nobody has looked at is
## a threshold that blocks everything.
func _sight_blockers(at: Vector2, dir: Vector2) -> Array:
	var out: Array = []
	var eye := Vector3(at.x, WorldBuilder.KERB_HEIGHT + EYE, at.y)
	var fwd := Vector3(dir.x, 0.0, dir.y)
	var steps := 12
	var reach := 9.0
	for s in range(1, steps + 1):
		var along := reach * float(s) / float(steps)
		var p := eye + fwd * along
		var cx := int(floor(p.x / CLUTTER_CELL))
		var cz := int(floor(p.z / CLUTTER_CELL))
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var key := Vector2i(cx + dx, cz + dz)
				if not _clutter.has(key):
					continue
				var arr: PackedInt32Array = _clutter[key]
				for idx in arr:
					var j := idx * 3
					var oy := _clutter_flat[j + 1]
					# Height above the paving, not distance below the eye. The first
					# version measured dy from the camera, which every ground-level
					# instance satisfies by definition, so kerb-height drainage
					# channels rejected two poses in three while occluding nothing.
					# A hedge's origin sits at its base too, so origins are a
					# FLOOR on height, not the height - hence BLOCKER_MIN_Y. That
					# floor sits just above the paving so a mound whose MultiMesh
					# origin is at its base still counts; at 0.5 the 2 m bush on
					# pose 01 (origin y = 0.14) slipped under the test and the frame
					# was two thirds foliage.
					var dy := oy - p.y
					if absf(dy) > CLUTTER_Y or oy < BLOCKER_MIN_Y:
						continue
					var ox := _clutter_flat[j] - p.x
					var oz := _clutter_flat[j + 2] - p.z
					var d2 := ox * ox + oz * oz
					if d2 < CLUTTER_R * CLUTTER_R:
						out.append({"d": sqrt(d2), "along": along, "dy": dy,
							"batch": _clutter_names[_clutter_bid[idx]]})
	out.sort_custom(func(a, b): return a["d"] < b["d"])
	return out


## Instance origins of every drawn batch EXCEPT the paving and the road surface
## under it, bucketed into CLUTTER_CELL squares. Positions only - no radius, no
## shape - because a sight line is a 1D test and an origin is the only thing a
## MultiMesh reliably exposes.
func _index_clutter(world: WorldBuilder) -> void:
	_clutter.clear()
	_clutter_flat = PackedFloat32Array()
	_clutter_bid = PackedInt32Array()
	_clutter_names = PackedStringArray()
	_clutter_count = 0
	_index_node(world, "")
	print("[Slab] clutter index: %d drawn instances in %d batches near the footpaths" % [
		_clutter_count, _clutter_names.size()])


## `batch` is the enclosing `Batch_<key>` name, carried down the walk. Testing the
## node's own name is not enough and was not enough here: the builder leaves each
## per-material `MultiMeshInstance3D` auto-named (`@MultiMeshInstance3D@1671`), so
## every paving instance was indexed as clutter and the occlusion test then rejected
## every pose on the strength of the paving it was standing on.
func _index_node(n: Node, batch: String) -> void:
	var nm := String(n.name)
	if nm.begins_with("Batch_"):
		batch = nm
	if n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh != null and not _is_paving(batch):
			var bid := _clutter_names.size()
			_clutter_names.append(batch if batch != "" else nm)
			var mm: MultiMesh = mmi.multimesh
			for i in mm.instance_count:
				var o := mm.get_instance_transform(i).origin
				var idx := _clutter_bid.size()
				_clutter_flat.append(o.x)
				_clutter_flat.append(o.y)
				_clutter_flat.append(o.z)
				_clutter_bid.append(bid)
				var key := Vector2i(int(floor(o.x / CLUTTER_CELL)),
					int(floor(o.z / CLUTTER_CELL)))
				var arr: PackedInt32Array = _clutter.get(key, PackedInt32Array())
				arr.append(idx)
				_clutter[key] = arr
				_clutter_count += 1
	for c in n.get_children():
		_index_node(c, batch)


func _is_paving(node_name: String) -> bool:
	var nm := node_name.to_lower()
	# Drainage sits in the gutter at ground level and blocks nothing, but its
	# instances sit within 0.1 m of the sight line, so leaving it in rejected
	# 2 poses in 3 on its own.
	for s in ["footpath", "kerb", "road", "channel", "lane", "mark", "drain", "gutter"]:
		if nm.contains(s):
			return true
	return false


## Every footpath slab the builder actually emitted: where it is, and which way it
## runs. `basis.z` is the slab's long axis, because each slab is the unit walk mesh
## scaled by `(FOOTPATH_WIDTH, 1.0, slab_len)`.
func _slabs(world: WorldBuilder) -> Array:
	var out: Array = []
	var holder := world.get_node_or_null("Batch_footpaths")
	if holder == null:
		print("[Slab] no Batch_footpaths node - the world has no footpaths")
		return out
	for ch in holder.get_children():
		var mmi := ch as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null:
			continue
		var mm: MultiMesh = mmi.multimesh
		for i in mm.instance_count:
			var xf := mm.get_instance_transform(i)
			var along := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z)
			if along.length() < 0.001:
				continue
			along = along.normalized()
			out.append({"pos": Vector2(xf.origin.x, xf.origin.z),
				"dir": Vector2(along.x, along.z)})
	return out


## Every lit `OmniLight3D` the builder added, wherever it hangs in the tree.
func _lamps(n: Node) -> Array:
	var out: Array = []
	if n is OmniLight3D:
		var o := n as OmniLight3D
		if o.light_energy > 0.0:
			out.append(o.global_position)
	for c in n.get_children():
		out.append_array(_lamps(c))
	return out


## Paint every footpath multimesh flat magenta: the positive control.
func _tint_footpaths(world: WorldBuilder) -> void:
	var holder := world.get_node_or_null("Batch_footpaths")
	if holder == null:
		print("[Slab] TINT: Batch_footpaths not found - cannot run the control")
		return
	var flat := StandardMaterial3D.new()
	flat.albedo_color = Color(1.0, 0.0, 1.0)
	flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var n := 0
	for ch in holder.get_children():
		(ch as MultiMeshInstance3D).material_override = flat
		n += 1
	print("[Slab] TINT: magenta on %d footpath multimeshes" % n)


func _ground_y(p: Vector2) -> float:
	## Terrain height under a ground-plane point, via the terrain collider. -999 if
	## the ray misses, which reads as "no terrain here" rather than "sea level".
	var space := root.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(p.x, 60.0, p.y), Vector3(p.x, -20.0, p.y))
	var hit := space.intersect_ray(q)
	return float((hit as Dictionary)["position"].y) if hit.has("position") else -999.0


## Poses are recorded by the render and reloaded by `--measure`, so the measurement
## is always of the frames the recorded camera actually drew. Recomputing them would
## be one more formula that can disagree with itself.
func _dump_poses(path: String, poses: Array) -> void:
	var rows: Array = []
	for p in poses:
		var e: Vector3 = p["eye"]
		var l: Vector3 = p["look"]
		var w: Vector3 = p["walk"]
		var d: Vector3 = p["dir"]
		var s: Vector2 = p["stand"]
		rows.append({
			"eye": [e.x, e.y, e.z],
			"look": [l.x, l.y, l.z],
			"walk": [w.x, w.y, w.z],
			"dir": [d.x, d.y, d.z],
			"stand": [s.x, s.y],
			"lamp_d": float(p["lamp_d"]),
			"slab_ahead": float(p["slab_ahead"]),
		})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[Slab] could not write poses to %s" % path)
		return
	f.store_string(JSON.stringify(rows))
	f.close()
	print("[Slab] poses -> %s" % path)


func _load_poses(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_ARRAY:
		return []
	var out: Array = []
	for row in parsed:
		var r: Dictionary = row
		var e: Array = r["eye"]
		var l: Array = r["look"]
		var w: Array = r["walk"]
		var d: Array = r["dir"]
		var s: Array = r["stand"]
		out.append({
			"eye": Vector3(e[0], e[1], e[2]),
			"look": Vector3(l[0], l[1], l[2]),
			"walk": Vector3(w[0], w[1], w[2]),
			"dir": Vector3(d[0], d[1], d[2]),
			"stand": Vector2(s[0], s[1]),
			"lamp_d": float(r["lamp_d"]),
			"slab_ahead": float(r["slab_ahead"]),
		})
	return out


func _report(out: String, tag: String, poses: Array) -> void:
	var lines := ["# slab capture %s" % tag, ""]
	for n in poses.size():
		var p: Dictionary = poses[n]
		var file := "%s/%s-%02d.png" % [out, tag, n]
		var img := Image.load_from_file(file)
		if img == null:
			print("[Slab] MISSING %s - the render did not produce a frame" % file)
			lines.append("## %02d - NO FRAME" % n)
			continue
		lines.append("## %02d  lamp %.1f m  slab %.1f m ahead" % [
			n, float(p["lamp_d"]), float(p["slab_ahead"])])
		lines.append("  " + str(_band_stats(img)))
	print("\n".join(lines))
	var f := FileAccess.open("%s/%s.md" % [out, tag], FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()


func _measure_only(out: String, tag: String) -> void:
	var poses := _load_poses("%s/%s_poses.json" % [out, tag])
	if poses.is_empty():
		print("[Slab] no poses recorded for tag '%s' at %s/%s_poses.json - rerun the render" % [
			tag, out, tag])
		return
	_report(out, tag, poses)


## The paving band is the lower-middle of the frame: from a camera at eye height
## on the footpath, that is where the paving is. Sky, shopfronts and the road above
## the kerb are excluded on purpose - a footpath that reads well while the rest of
## the frame is black is still a footpath that reads.
##
##   - `joint_lines` is the headline: dark transverse lines per pixel column of
##     paving. See `_joint_lines`.
##   - `depth_gradient` is the row-mean peak-to-trough, and it is the lamp's
##     falloff rather than anything about the paving. Kept because the falloff is
##     worth watching - slabs catch less sheen down the footpath than a continuous
##     ribbon - but it must not be read as rhythm.
##   - `col_rhythm` is the column-mean peak-to-trough, i.e. the LONGITUDINAL joints
##     between slab courses. The slabs here are one course wide, so this is expected
##     to stay flat; it is reported so that "no longitudinal joint was added" is on
##     the record rather than assumed.
## Per-row means are printed as well, because a scalar over a band can hide one
## street cancelling another - which is how a 2.65-luma pose once averaged into a
## passing report.
func _band_stats(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(w * 0.30)
	var x1 := int(w * 0.70)
	var y0 := int(h * 0.55)
	var y1 := int(h * 0.95)
	var total := 0.0
	var n := 0
	var clipped := 0
	var dark := 0
	var peak := 0.0
	var rows := PackedFloat32Array()
	rows.resize(24)
	var rown := PackedInt32Array()
	rown.resize(24)
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
			var rb := int(float(y - y0) / float(maxi(1, y1 - y0)) * 24.0)
			rows[rb] = rows[rb] + l
			rown[rb] = rown[rb] + 1
			var cb := int(float(x - x0) / float(maxi(1, x1 - x0)) * 16.0)
			cols[cb] = cols[cb] + l
			coln[cb] = coln[cb] + 1
	var mean := total / maxf(1.0, float(n))
	var rlo := 1.0
	var rhi := 0.0
	var rowprof := PackedFloat32Array()
	for b in 24:
		if rown[b] == 0:
			continue
		var v := rows[b] / float(rown[b])
		rowprof.append(snappedf(v, 0.0001))
		rlo = minf(rlo, v)
		rhi = maxf(rhi, v)
	var clo := 1.0
	var chi := 0.0
	var colprof := PackedFloat32Array()
	for b in 16:
		if coln[b] == 0:
			continue
		var v := cols[b] / float(coln[b])
		colprof.append(snappedf(v, 0.0001))
		clo = minf(clo, v)
		chi = maxf(chi, v)
	return {
		"mean": snappedf(mean, 0.0001),
		"p95": snappedf(_pct(img, x0, x1, y0, y1, 0.95), 0.0001),
		"peak": snappedf(peak, 0.0001),
		"clipped%": snappedf(100.0 * float(clipped) / maxf(1.0, float(n)), 0.01),
		"dark%": snappedf(100.0 * float(dark) / maxf(1.0, float(n)), 0.01),
		"joint_lines": snappedf(_joint_lines(img), 0.001),
		"depth_gradient": snappedf(rhi - rlo, 0.0001),
		"col_rhythm": snappedf(chi - clo, 0.0001),
		"rows": rowprof,
	}


## Mean number of dark transverse lines crossing one pixel column of paving in the
## near band - i.e. joints per metre of width, counted, not asserted.
##
## `depth_gradient` (the old `row_rhythm`) was the first attempt and it was wrong in
## the dangerous direction: on the unbroken ribbon it scored HIGHER (0.2909) than
## the slabs did (0.1604). Row means are dominated by the streetlight's falloff
## along the footpath, and a continuous slab carries a smooth specular sheen the
## whole way down while 4 cm gaps interrupt it - so the metric rewarded the defect.
## A metric that goes the wrong way is worse than no metric.
##
## This one counts what the change actually adds, and it is structurally blind to
## the gradient: a smooth ramp has no local minima, so it scores zero whatever its
## slope. A slab joint does, once per slab.
func _joint_lines(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(w * 0.34)
	var x1 := int(w * 0.66)
	var y0 := int(h * 0.62)
	var y1 := int(h * 0.94)
	var total := 0
	var cols := 0
	for x in range(x0, x1):
		var hist := PackedFloat32Array()
		for y in range(y0, y1):
			var c := img.get_pixel(x, y)
			hist.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
		var hits := 0
		for i in range(1, hist.size() - 1):
			if hist[i] < hist[i - 1] and hist[i] <= hist[i + 1] \
					and hist[i - 1] - hist[i] > JOINT_DIP:
				hits += 1
		total += hits
		cols += 1
	return float(total) / maxf(1.0, float(cols))


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
