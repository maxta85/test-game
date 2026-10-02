extends SceneTree
## MAP-FLIGHT SHOTS - a free-move camera down every route segment of Manunda.
##
##     source /tmp/w9-t61/vkenv.sh
##     godot --path . --rendering-driver vulkan --audio-driver Dummy --resolution 640x360 \
##           --fixed-fps 60 --script res://Tools/map_flight_shots.gd -- --out /tmp/reports/shots
##
## This is the visual half of `Tools/map_flight_audit.gd`. The audit proves, per
## segment, that nothing is inside the lane margin; these frames are what a person
## looks at to check the proof, and to answer the owner's actual complaint - "use the
## free move to fly around and look at the map and make it match manunda". A number
## says the lane is clear; only a picture says whether the street reads like Cairns.
##
## Two frames per segment, because they fail in different ways:
##
## - `aerial` - 26 m up, back and to the side, looking down the segment. Reads the
##   whole run at once: kerb line, footpath, planting, roofline, whether the road
##   goes where the map says it goes. An obstacle 200 m down the street is obvious
##   here and invisible from the driver's seat.
## - `lane` - 1.7 m up, in the middle of the carriageway, looking along it. The
##   driver's view, which is where "does this match manunda" is actually answered.
##
## Deterministic poses only: every camera position is derived from the road graph,
## not from a random seed or a physics step, so re-running this writes byte-identical
## framing and two runs can be compared.

const AERIAL_H := 26.0
const AERIAL_BACK := 22.0
const AERIAL_SIDE := 9.0
const LANE_H := 1.7
## How far along the segment the lane camera sits. Not at the node - the junction
## furniture is there and it hides the carriageway behind it.
const LANE_FRACTION := 0.45

var _cam: Camera3D
var _stage: Node
## Capture happens in a SubViewport of our own, not in the window. Reading the root
## viewport's texture back gave 32 byte-identical PNGs from 32 different poses: the
## swapchain image the window viewport hands out does not update when nothing has the
## window's attention, so every grab returned the first frame the boot sequence ever
## drew - the menu, over the street. A SubViewport we own and mark
## `UPDATE_ALWAYS` redraws on its own schedule and its texture reads back reliably.
var _vp: SubViewport
var _scam: Camera3D


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/reports/shots"
	var tag := "t71"
	var settle := 3
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			"--tag":
				tag = String(args[i + 1]); i += 2
			"--settle":
				settle = int(args[i + 1]); i += 2
			_:
				i += 1
	DirAccess.make_dir_recursive_absolute(out)

	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var segments := _unique_segments(g)
	print("[shots] %d unique route segments" % segments.size())

	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	# The camera does not exist yet when `add_child` returns. `Game/main.tscn` boots
	# asynchronously - the world builds, then the menu goes up, then `ChaseCamera`
	# builds its own child camera - so asking for the camera on the same frame finds
	# nothing, and the harness then cheerfully writes 32 copies of whatever the
	# menu was showing.
	for f in 12:
		await process_frame
	await _prepare(main)

	var n := 0
	for s in segments:
		for pose in ["aerial", "lane"]:
			var shot := _pose(s, String(pose))
			# `await` on the frame, not a bare call. `_frame` is a coroutine; called
			# without `await` it runs to its first `await process_frame` and returns,
			# so the grab below happened before the engine had drawn a single frame of
			# the new pose. All 32 poses were then written from the one frame the boot
			# sequence had already produced - 32 byte-identical PNGs of the menu.
			await _frame(shot, settle)
			var img := _grab()
			if img == null:
				continue
			var path := "%s/%s-edge%03d-%s-%s.png" % [out, tag, int(s["edge"]),
				_slug(String(s["street"])), String(pose)]
			img.save_png(path)
			n += 1
			# Where the camera ended up, not where it was asked to go. The gap between
			# those two numbers is the whole class of bug this harness exists to rule
			# out, and it is invisible in the picture.
			print("[shots] %-6s asked=%s got=%s current=%s fov=%.0f -> %s" % [
				String(pose), str((shot["eye"] as Vector3).round()),
				str(_scam.global_position.round()), str(_vp.get_camera_3d() == _scam),
				float(shot["fov"]), path])
	print("[shots] wrote %d frames to %s" % [n, out])
	quit(0)


## Route edges, deduplicated: a stretch of street crossed by three routes is one
## stretch of street and needs one pair of frames.
func _unique_segments(g: RoadGraph) -> Array:
	var unique: Dictionary = {}
	for d in RaceDef.catalogue(g):
		var path: Array = (d as RaceDef).path
		for k in maxi(path.size() - 1, 0):
			var a := int(path[k])
			var b := int(path[k + 1])
			if a == b:
				continue
			var eid := -1
			for eid2 in (g.nodes[a]["edges"] as Array):
				var e: Dictionary = g.edges[int(eid2)]
				if int(e["a"]) == b or int(e["b"]) == b:
					eid = int(eid2)
					break
			if eid < 0:
				continue
			if not unique.has(eid):
				unique[eid] = {"edge": eid, "street": String(g.street_names.get(eid, "")),
					"class": int(g.edges[eid]["class"])}
	var out: Array = []
	for eid in unique.keys():
		out.append(unique[eid])
	out.sort_custom(func(x, y): return int(x["edge"]) < int(y["edge"]))
	return out


## Menu out of the way, camera out of anybody else's hands, clock stopped.
##
## The camera has to be freed rather than moved: `Player` drives a chase rig every
## physics step, so a position written here is overwritten before the next frame -
## which is how an earlier harness wrote six poses and got six identical PNGs. Same
## reason for `time_scale` rather than `paused`: pausing stops `_process` as well,
## and Godot does not render a paused tree into a fresh viewport image.
func _prepare(main: Node) -> void:
	# `Game/main.gd` parents the world as a node named "World" with the terrain
	# trimesh under it. Without this the height sampler returns 0 for every point,
	# which on the hills puts the lane camera inside a building - which is exactly
	# what the first lane frames showed: a wall of black and a strip of kerb.
	_stage = main.get_node_or_null("World")
	_hide_ui(_stage)
	var flow := _menu_flow(main)
	if flow != null:
		flow.call("close")
	_hide_ui(main)
	_cam = _find_camera(main)
	if _cam == null:
		push_error("[shots] no Camera3D in main.tscn")
		quit(2)
		return
	# Whatever owns the chase rig re-writes its child's transform every frame, so
	# "set the camera and grab" silently renders the rig's pose instead. Detach every
	# `tracking` on the camera's ancestry rather than reaching for one property by
	# name.
	var cur: Node = _cam
	while cur != null:
		if "tracking" in cur:
			cur.set("tracking", false)
		cur = cur.get_parent()
	_cam.current = true
	_freeze(main)
	_vp = SubViewport.new()
	_vp.name = "T71Capture"
	_vp.size = Vector2i(640, 360)
	_vp.transparent_bg = false
	# `own_world_3d` stays false on purpose: a SubViewport that owns its world would
	# render an empty room, because none of Manunda is inside it.
	_vp.own_world_3d = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	_scam = Camera3D.new()
	_vp.add_child(_scam)
	_scam.current = true
	# `Engine.time_scale = 0` and not `paused = true`: both stop the traffic, but a
	# paused tree stops `_process` as well, and a frozen clock leaves the renderer
	# running, which is the part that has to happen for a readback to be a frame of
	# this pose rather than of the menu.
	Engine.time_scale = 0.0


## Stop the game from running underneath the camera.
##
## `visible = false` on its own is not enough, and this cost two runs: the menu's own
## state machine sets it back to visible on the next `_process`, so every frame came
## back with "START RACE" on top of the street, and hiding it again just before the
## readback loses the race for the same reason. Processing is switched off instead,
## which stops the state machine as well as the drawing. Nothing in this scene needs
## `_process` to stand still: the world is static geometry, and the fog, glow and GI
## are resolved on the GPU.
func _freeze(main: Node) -> void:
	for n in _all(main):
		n.set_process(false)
		n.set_process_input(false)
		n.set_process_unhandled_input(false)
		n.set_physics_process(false)


## `MenuFlow`, found by its API rather than by its type. Naming the class pulls
## `UI/menu_flow.gd` in, which uses the `Cfg` autoload, and an autoload is not
## registered when Godot runs a bare `--script`.
func _menu_flow(n: Node) -> Node:
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur.has_method("close") and cur.has_method("races"):
			return cur
		for c in cur.get_children():
			stack.append(c)
	return null


## Any node on the camera's ancestry with a `tracking` flag owns the camera's
## transform every frame. Turning them off is the only way a scripted pose survives.
func _free_tracking(c: Camera3D) -> void:
	var cur: Node = c
	while cur != null:
		for prop in cur.get_property_list():
			if String(prop["name"]) == "tracking":
				cur.set("tracking", false)
		cur = cur.get_parent()


func _all(n: Node) -> Array:
	var out: Array = []
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		out.append(cur)
		for c in cur.get_children():
			stack.append(c)
	return out


func _hide_ui(n: Node) -> void:
	# `_stage` is null whenever the world has not put a Terrain under the menu, and a
	# bare `_hide_ui(null)` is a hard script error, not a no-op.
	if n == null:
		return
	for c in n.get_children():
		# Children freed earlier in the same boot still come back as null here; the
		# menu tears itself down while this harness is walking the tree.
		if c == null:
			continue
		if c is CanvasLayer or c is Control:
			(c as CanvasItem).visible = false
		else:
			_hide_ui(c)


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


func _pose(s: Dictionary, mode: String) -> Dictionary:
	var g := _graph()
	var eid := int(s["edge"])
	var e: Dictionary = g.edges[eid]
	var a: Vector2 = g.node_pos(int(e["a"]))
	var b: Vector2 = g.node_pos(int(e["b"]))
	var d := b - a
	var length := d.length()
	var fwd := Vector3(d.x, 0.0, d.y).normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var y := _terrain_y(a.lerp(b, LANE_FRACTION)) + LANE_H
	if mode == "aerial":
		var mid := a.lerp(b, 0.5)
		var eye := Vector3(mid.x, 0.0, mid.y) - fwd * AERIAL_BACK + side * AERIAL_SIDE
		eye.y = _terrain_y(Vector2(eye.x, eye.z)) + AERIAL_H
		return {"eye": eye, "look": Vector3(mid.x, y - LANE_H, mid.y), "fov": 55.0}
	var at := Vector3(a.x, 0.0, a.y).lerp(Vector3(b.x, 0.0, b.y), LANE_FRACTION)
	at.y = y
	return {"eye": at, "look": at + fwd * 60.0, "fov": 62.0}


var _g: RoadGraph = null


func _graph() -> RoadGraph:
	if _g == null:
		_g = RoadGraph.new()
		_g.build(OSMLayout.corridors())
	return _g


## Ground height, sampled from the built terrain if the world has one. Falling back
## to 0 puts the lane camera underground on the hills and the aerial camera inside
## a roof.
func _terrain_y(p: Vector2) -> float:
	if _stage == null:
		return 0.0
	var t := _stage.find_child("Terrain", true, false)
	if t is Node3D:
		return _height_at(t as Node3D, p)
	return 0.0


func _height_at(t: Node3D, p: Vector2) -> float:
	var m: MeshInstance3D = null
	var stack: Array = [t]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D:
			m = cur as MeshInstance3D
			break
		for c in cur.get_children():
			stack.append(c)
	if m == null or m.mesh == null:
		return 0.0
	return m.mesh.get_height_at(p.x, p.y) + m.global_position.y


## The basis, not `look_at`: `look_at` refuses when the eye is directly above the
## target, which is exactly the aerial pose on a flat street.
func _pose_basis(shot: Dictionary) -> Basis:
	var look: Vector3 = shot["look"]
	var dirv: Vector3 = look - (shot["eye"] as Vector3)
	if dirv.length() <= 0.001:
		dirv = Vector3.FORWARD
	return _basis_towards(dirv.normalized())


func _frame(shot: Dictionary, settle: int) -> void:
	if _cam == null or _vp == null:
		return
	var basis := _pose_basis(shot)
	_cam.global_position = shot["eye"]
	_cam.basis = basis
	_cam.fov = float(shot["fov"])
	_cam.far = 4000.0
	_scam.global_position = shot["eye"]
	_scam.basis = basis
	_scam.fov = float(shot["fov"])
	_scam.far = 4000.0
	# Re-hide the UI every pose, not once at boot. The game's boot sequence puts the
	# menu up *after* the world is built, so a single hide at start-up photographs a
	# menu over the street - which is exactly what the first run of this harness did,
	# 32 times.
	_hide_ui(_stage)
	_hide_ui(root)
	for f in maxi(settle, 1):
		await process_frame
	_hide_ui(_stage)
	_hide_ui(root)
	await RenderingServer.frame_post_draw


func _basis_towards(f: Vector3) -> Basis:
	var up := Vector3.UP
	if absf(f.dot(up)) > 0.999:
		up = Vector3.FORWARD
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


func _grab() -> Image:
	if _vp == null:
		push_error("[shots] no capture viewport")
		return null
	var vp := _vp.get_texture().get_image()
	if vp == null:
		push_error("[shots] viewport readback failed")
		return null
	return vp


func _slug(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif out.length() > 0 and out[-1] != "-":
			out += "-"
	var trimmed := out.trim_suffix("-").substr(0, 24)
	# `road_graph.street_names` is not keyed by edge id in this build, so the label
	# comes back empty for most segments. An empty label must not become a bare `--`
	# in the filename.
	return trimmed if trimmed.length() > 0 else "unnamed"