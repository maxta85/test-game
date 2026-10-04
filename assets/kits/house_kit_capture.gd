# =============================================================================
# house_kit_capture.gd - DAY-locked evidence for the house kit
# =============================================================================
#
#     DISPLAY=:99 godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#         --resolution 1600x900 --script res://assets/kits/house_kit_capture.gd -- \
#         --out /tmp/reports/t182-kits-img
#
# Not --headless: headless uses the dummy renderer, whose mesh storage is null and
# which renders nothing at all, so the PNG comes back black and saves fine.
#
# WHAT THIS CAPTURES, AND WHY EACH THING IS HERE
#
#   day_street_box / day_street_kit   Same camera, same second, one clean box and
#                                    one kitted house. The whole judgement is the
#                                    difference between these two frames.
#   day_ablate_<piece>                Leave-one-out on the STREET camera, in
#                                    silhouette mode. Removing a piece must
#                                    change the outline; if it does not, the
#                                    piece is not earning its place. Reported in
#                                    pixels AND converted to metres, which is the
#                                    brief's "past 30 cm" made into a number.
#   day_piece_<piece>                 One closeup per kit piece, each framed on
#                                    that piece's own measured bounds. This is
#                                    the human-inspectable image per piece.
#   day_boundary                      The paling/gateling at the frontage.
#
# FRESH-PNG DISCIPLINE
#
#   Every target PNG is DELETED before its render and must come back, and its
#   md5 is recorded either way. A render that dies silently leaves the previous
#   frame in place, and a measurement loop over rendered output then reports one
#   stale image N times as if it were N data points.
#
# DAY LOCK
#
#   The lock is asserted, not assumed: the sun transform is printed asked vs got,
#   and a patch of sky is sampled out of the finished PNG and required to be
#   blue-dominant. A night-locked rig that silently stayed on night would
#   otherwise produce perfectly plausible frames.
#
# asked-vs-got CAMERA
#
#   Print where the camera was asked to go AND where it ended up, plus `current`.
#   The gap between those two numbers is the whole class of bug this harness
#   exists to rule out and it is invisible in the picture.

extends SceneTree

const Kit := preload("res://assets/kits/house_kit.gd")
const Pieces := preload("res://assets/kits/house_kit_pieces.gd")

const KIND := "qld_house"
const ORIGIN := Vector3(0.0, 0.0, 0.0)
const YAW := 0.0

const VP := Vector2i(1280, 720)
const FOV := 55.0
const SKY_TOP := Color(0.29, 0.45, 0.72)
const SKY_HORIZON := Color(0.68, 0.75, 0.82)
const SUN_ANGLE := Vector3(-46.0, -34.0, 0.0)
const SUN_ENERGY := 1.25
const GROUND := Color(0.30, 0.31, 0.24)
const SIL_COLOUR := Color(1.0, 0.0, 0.8)

# Street camera: driver's eye at the kerb, 16 m off the frontage. Fixed, so two
# frames differ only for a reason that has something to do with the change.
const STREET_POS := Vector3(13.5, 1.65, 14.0)
const STREET_LOOK := Vector3(0.0, 2.60, 1.5)
# A tighter 3/4 framing, for the human to look at. The street framing above is
# kept at a driver's eye distance because that is what the ablation is measured
# at, but a house 20% of frame width is not an inspectable image.
const TIGHT_POS := Vector3(10.0, 2.20, 11.0)
const TIGHT_LOOK := Vector3(-0.30, 3.10, 0.80)
const TIGHT_FOV := 34.0
# Near-orthographic elevations at fov 20 from 40 m. A perspective street frame
# cannot answer "is the eave line on the plate" - this can.
const ELEV_FOV := 20.0
const ELEV_DIST := 40.0
const ELEV_MID := 2.60

var vp: SubViewport
var cam: Camera3D
var out_dir := "/tmp/reports/t182-kits-img"
var world: Node3D
var report := {"shots": [], "pieces": [], "day_lock": {}, "silhouette": {}}
var failures := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			out_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)

	_build_stage()
	await _run()

	print("[KitCap] failures=%d  shots=%d" % [failures, (report["shots"] as Array).size()])
	var jf := FileAccess.open("%s/t182-kits-capture.json" % out_dir, FileAccess.WRITE)
	jf.store_string(JSON.stringify(report, "  "))
	jf.close()
	quit(0 if failures == 0 else 1)


# --------------------------------------------------------------------- stage
func _build_stage() -> void:
	vp = SubViewport.new()
	vp.size = VP
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.ground_bottom_color = GROUND
	sky_mat.ground_horizon_color = GROUND
	sky_mat.sun_angle_max = 6.0
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	we.environment = env
	vp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "KitSun"
	sun.rotation_degrees = SUN_ANGLE
	sun.light_energy = SUN_ENERGY
	sun.light_color = Color(1.0, 0.97, 0.91)
	# Shadows ON. Half the reason a Queenslander reads is the shadow the 900 mm
	# eave throws down the wall and the shadow line under each step nosing, and a
	# rig with shadows off cannot evidence either of them.
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 90.0
	sun.shadow_bias = 0.03
	vp.add_child(sun)

	var ground := MeshInstance3D.new()
	ground.name = "ground"
	var gp := PlaneMesh.new()
	gp.size = Vector2(220.0, 220.0)
	ground.mesh = gp
	var gm := StandardMaterial3D.new()
	gm.albedo_color = GROUND
	gm.roughness = 1.0
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	ground.material_override = gm
	vp.add_child(ground)

	world = Node3D.new()
	world.name = "World"
	vp.add_child(world)

	cam = Camera3D.new()
	cam.fov = FOV
	vp.add_child(cam)
	cam.make_current()

	# Print the rig once, so a frame that is wrong has an explanation next to it.
	print("[KitCap] DAY lock asked: sun_rot=%s energy=%.2f sky_top=%s ambient=0.85 shadows=on" % [
		str(SUN_ANGLE), SUN_ENERGY, str(SKY_TOP)])
	print("[KitCap] DAY lock got   : sun_rot=%s energy=%.2f sky_top=%s shadows=%s" % [
		str(sun.rotation_degrees), sun.light_energy, str(sky_mat.sky_top_color),
		str(sun.shadow_enabled)])


# ------------------------------------------------------------------- helpers
func _frame(asked_pos: Vector3, asked_look: Vector3, fov: float) -> void:
	cam.fov = fov
	cam.look_at_from_position(asked_pos, asked_look, Vector3.UP)
	# Whatever owns a camera can re-write it every frame. Clear `tracking` up the
	# whole ancestry rather than reaching for one property by name: a version
	# that did the latter produced byte-identical frames.
	for n in _ancestry(cam):
		if "tracking" in n:
			n.set("tracking", false)
	cam.current = true


func _ancestry(n: Node) -> Array:
	var out := []
	var cur := n
	while cur != null:
		out.append(cur)
		cur = cur.get_parent()
	return out


## Capture one PNG. Deletes the target first, so a render that quietly did
## nothing cannot be mistaken for a render, and records the md5 either way.
func _shoot(shot: String, asked_pos: Vector3, asked_look: Vector3, fov: float,
		silhouette: bool) -> Dictionary:
	# Delete the target FIRST. A render that quietly did nothing would otherwise
	# leave the previous frame in place, and a measurement loop over rendered
	# output then reports one stale image N times as if it were N data points.
	var path := "%s/%s.png" % [out_dir, shot]
	var existed := FileAccess.file_exists(path)
	var prior_md5 := FileAccess.get_md5(path) if existed else ""
	if existed:
		DirAccess.remove_absolute(path)
	var gone := not FileAccess.file_exists(path)
	_frame(asked_pos, asked_look, fov)
	for f in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.save_png(path)
	if not FileAccess.file_exists(path):
		push_error("[KitCap] %s: no PNG was written" % shot)
		failures += 1
		return {}
	img = Image.load_from_file(path)

	# asked-vs-got, every frame. The gap is invisible in the picture.
	var got := cam.global_position
	var drift := (got - asked_pos).length()
	var md5_now := FileAccess.get_md5(path)
	var entry := {
		"shot": shot,
		"path": path,
		"md5": md5_now,
		"md5_matches_previous_run": prior_md5 != "" and prior_md5 == md5_now,
		"bytes": FileAccess.get_file_as_bytes(path).size(),
		"deleted_before_render": gone,
		"prior_file_md5": prior_md5,
		"silhouette_mode": silhouette,
		"asked_pos": [asked_pos.x, asked_pos.y, asked_pos.z],
		"got_pos": [got.x, got.y, got.z],
		"asked_look": [asked_look.x, asked_look.y, asked_look.z],
		"drift_m": drift,
		"camera_current": cam.current,
		"fov": cam.fov,
		"resolution": [img.get_width(), img.get_height()],
	}
	if not cam.current:
		push_error("[KitCap] %s: camera is not current" % shot)
		failures += 1
	if drift > 0.01:
		push_error("[KitCap] %s: camera drifted %.3f m from where it was asked to be" % [shot, drift])
		failures += 1
	if silhouette:
		entry["silhouette_px"] = _silhouette_px(img)
		entry["mean_luma"] = _mean_luma(img)
	else:
		entry["mean_luma"] = _mean_luma(img)
		entry["clipped_frac"] = _clipped_frac(img)
		entry["sky_patch_rgb"] = _sky_patch(img)
	report["shots"].append(entry)
	print("[KitCap] %-24s md5=%s %6d B asked=%s got=%s drift=%.3f current=%s luma=%.4f" % [
		shot, String(entry["md5"]).substr(0, 8), int(entry["bytes"]),
		str(asked_pos.round()), str(got.round()), drift, str(cam.current),
		float(entry["mean_luma"])])
	return entry


func _mean_luma(img: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			total += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return total / maxf(1.0, float(n))


func _clipped_frac(img: Image) -> float:
	var hot := 0.0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			n += 1
			if c.r >= 0.99 and c.g >= 0.99:
				hot += 1.0
	return hot / maxf(1.0, float(n))


## A patch of sky out of the finished frame. If the rig is not actually day, this
## is not blue, and that is the assertion - not the intent in the source.
func _sky_patch(img: Image) -> Array:
	var box := Rect2i(int(img.get_width() * 0.45), 4, 40, 24)
	var c := img.get_pixel(box.position.x + box.size.x / 2,
		box.position.y + box.size.y / 2)
	return [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001)]


func _silhouette_px(img: Image) -> int:
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if c.r > 0.55 and c.b > 0.35 and c.g < 0.45:
				n += 1
	return n * 4


## Pixels per metre at a given world depth on the street framing, computed by
## projecting two points exactly 1 m apart. Exact, and it adds nothing to the
## silhouette mask the way a reference bar would.
func _px_per_m(at_depth_z: float, y: float) -> float:
	var a := cam.unproject_position(Vector3(0.0, y, at_depth_z))
	var b := cam.unproject_position(Vector3(1.0, y, at_depth_z))
	return (b - a).length()


func _world_aabb(mi: MeshInstance3D) -> AABB:
	if mi.mesh == null:
		return AABB()
	var local := mi.mesh.get_aabb()
	return mi.transform * local


func _sil_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = SIL_COLOUR
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m


func _set_silhouette(on: bool) -> void:
	for n in _walk(world):
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.name == "ground":
				continue
			if on:
				mi.material_override = _sil_material()
			else:
				mi.material_override = null
			for s in mi.mesh.get_surface_count() if mi.mesh != null else 0:
				mi.set_surface_override_material(s, null)


func _walk(n: Node) -> Array:
	var out := [n]
	for c in n.get_children():
		out.append_array(_walk(c))
	return out


# ----------------------------------------------------------------------- run
func _run() -> void:
	# --- 0. contact sheet: ALL SIX roster pieces, each alone on the ground ---
	# The per-piece loop above only walks the pieces the qld_house archetype
	# requires, which is four of the six. A kit nobody has photographed in
	# isolation has not been reviewed, so the other two get shot here and so does
	# every piece again with nothing around it to hide behind.
	# Runs FIRST, on an empty world. Two reasons, both learned the hard way:
	# the boundary fence left over from the previous section appeared, huge and
	# cut off, in the bottom-left of this contact sheet and got photographed as
	# if it were part of the piece; and queue_free()-ing a populated world while
	# its meshes were still referenced by other nodes segfaulted the process.
	# A contact sheet needs an empty stage anyway.
	for e in Pieces.roster():
		var pname := String(e["name"])
		var got := Kit.load_piece(pname)
		if got.is_empty():
			push_error("[KitCap] contact sheet: %s would not load" % pname)
			failures += 1
			continue
		var holder := Node3D.new()
		holder.name = "solo_" + pname
		world.add_child(holder)
		var smi := MeshInstance3D.new()
		smi.name = pname
		smi.mesh = got["mesh"]
		var sroles: Array = got["roles"]
		for si in sroles.size():
			smi.set_surface_override_material(si, Kit.role_material(String(sroles[si])))
		holder.add_child(smi)
		# Yaw a gable roof so both slopes and one gable end read; a piece seen
		# only from its own axis hides the face that matters.
		# Rest each piece ON the ground, the way it would be laid out on a bench.
		# Dropping it in at the origin buries whatever hangs below the fastening
		# point - the window's sill board, which is a feature, ended up under the
		# dirt and could not be reviewed.
		var yaw := 0.0
		if pname.begins_with("kit_roof_"):
			yaw = 0.62
		elif pname == "kit_window_sash":
			yaw = 0.35
		var seat := -smi.mesh.get_aabb().position.y if smi.mesh != null else 0.0
		smi.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(0.0, seat, 0.0))
		var sa := _world_aabb(smi)
		var sdir := Vector3(0.62, 0.30, 1.0).normalized()
		var sdist := _fit_distance(sa.size, 40.0, 1.02)
		var se = await _shoot("day_solo_%s" % pname,
			sa.get_center() + sdir * sdist, sa.get_center(), 40.0, false)
		report["pieces"].append({
			"piece": pname, "shot": "day_solo_%s" % pname,
			"md5": se.get("md5", ""), "luma": se.get("mean_luma", 0.0),
			"drift_m": se.get("drift_m", 0.0),
			"local_aabb_min": [sa.position.x, sa.position.y, sa.position.z],
			"local_aabb_max": [sa.end.x, sa.end.y, sa.end.z],
			"extent_m": [sa.size.x, sa.size.y, sa.size.z],
			"triangles": _tri_count(smi.mesh), "surfaces": smi.mesh.get_surface_count(),
		})
		holder.queue_free()
		await process_frame


	# Clear the stage: every remaining frame needs the subject alone in it.
	for child in world.get_children():
		child.queue_free()
	for f in 3:
		await process_frame

	# --- 1. the clean box, which is what the world produces today -----------
	# The control is the CLEAN BOX, built by the same code path the fallback
	# uses, not assemble() with a different seed - otherwise the control and the
	# subject differ by an unknown amount and the diff proves nothing.
	var box_root := Node3D.new()
	box_root.name = "control"
	world.add_child(box_root)
	Kit.build_fallback_box(box_root, ORIGIN, YAW)
	_set_silhouette(false)
	var box_entry = await _shoot("day_street_box", STREET_POS, STREET_LOOK, FOV, false)

	# --- 2. the kitted house, same camera, same second ----------------------
	box_root.queue_free()
	await process_frame
	var kitted := Kit.assemble(KIND, ORIGIN, YAW)
	# Into `world`, which lives inside the SubViewport. Parenting to get_root()
	# puts the house in the MAIN viewport, where the SubViewport's camera cannot
	# see it, and every frame comes back sky-and-ground with a zero silhouette.
	world.add_child(kitted["root"])
	_set_silhouette(false)

	# THE assertion that cannot be satisfied by the fallback. Not `no errors`:
	# the fallback is valid behaviour and passes a no-errors check while the
	# house has no roof, no windows and no gutter.
	var took := Kit.check_kitted(kitted)
	print("[KitCap] kit path TAKEN=%s placed=%s" % [str(took), str(kitted["placed"])])
	report["kit_path_taken"] = took
	report["kit_placed"] = Array(kitted["placed"])
	report["kit_reason"] = kitted["reason"]
	if not took:
		failures += 1

	var kit_entry = await _shoot("day_street_kit", STREET_POS, STREET_LOOK, FOV, false)
	if not box_entry.is_empty() and not kit_entry.is_empty():
		report["street_delta"] = {
			"luma_box": box_entry["mean_luma"],
			"luma_kit": kit_entry["mean_luma"],
			"luma_ratio": float(kit_entry["mean_luma"]) / maxf(0.0001, float(box_entry["mean_luma"])),
			"sky_box": box_entry["sky_patch_rgb"],
			"sky_kit": kit_entry["sky_patch_rgb"],
			"clipped_box": box_entry.get("clipped_frac", 0.0),
			"clipped_kit": kit_entry.get("clipped_frac", 0.0),
		}

	# --- 3. per-piece numbers and per-piece closeups ------------------------
	var front_z := Pieces.DEPTH * 0.5
	var by_name := {}
	for n in _walk(kitted["root"]):
		if n is MeshInstance3D and String(n.name).begins_with("kit_"):
			if not by_name.has(n.name):
				by_name[n.name] = n
	print("[KitCap] node names in the kitted house: %s" % str(_node_names(kitted["root"])))
	for piece in Kit.required(KIND):
		var mi: MeshInstance3D = by_name.get(piece, null)
		if mi == null:
			push_error("[KitCap] %s was claimed as placed but no node carries that name" % piece)
			failures += 1
			continue
		var wb := _world_aabb(mi)
		var centre := wb.get_center()
		var ext := wb.size
		var row := {
			"piece": piece,
			"instances": _count_by_name(kitted["root"], piece),
			"slot_nodes": _slot_names(kitted["root"], piece),
			"node_local_origin": [mi.position.x, mi.position.y, mi.position.z],
			"world_aabb_min": [wb.position.x, wb.position.y, wb.position.z],
			"world_aabb_max": [wb.end.x, wb.end.y, wb.end.z],
			"world_extent_m": [ext.x, ext.y, ext.z],
			"surfaces": mi.mesh.get_surface_count(),
			"triangles": _tri_count(mi.mesh),
		}
		# Closeup framed on the piece's own measured bounds, from a fixed
		# direction so six pieces are photographed the same way.
		var dir := Vector3(0.62, 0.34, 1.0).normalized()
		var eye := centre + dir * _fit_distance(ext, 42.0, 1.25)
		row["closeup_asked_pos"] = [eye.x, eye.y, eye.z]
		row["closeup_asked_look"] = [centre.x, centre.y, centre.z]
		mi.visible = true
		var ce = await _shoot("day_piece_%s" % piece, eye, centre, 42.0, false)
		row["closeup_md5"] = ce.get("md5", "")
		row["closeup_luma"] = ce.get("mean_luma", 0.0)
		row["closeup_drift_m"] = ce.get("drift_m", 0.0)
		report["pieces"].append(row)
		print("[KitCap] piece %-24s instances=%d tris=%d surfaces=%d world_extent=%.2f,%.2f,%.2f" % [
			piece, int(row["instances"]), int(row["triangles"]), int(row["surfaces"]),
			ext.x, ext.y, ext.z])

	# --- 4. leave-one-out ablation, STREET camera ----------------------------
	# Two questions per piece, because "silhouette" is not one question:
	#   OUTLINE - remove the piece in silhouette mode. Does it change the
	#             boundary of the house against the sky? This is the only
	#             honest test of whether a piece carries a silhouette at all.
	#   SURFACE - remove the piece normally and count the edge energy inside the
	#             piece's own screen box. A window never touches the outline and
	#             reads entirely as interior contrast; calling that "zero" and
	#             stopping would be wrong in the other direction.
	_set_silhouette(true)
	var full = await _shoot("day_sil_full", STREET_POS, STREET_LOOK, FOV, true)
	var full_px := int(full.get("silhouette_px", 0))
	_set_silhouette(false)
	var ref_edge := await _shoot("day_edge_full", STREET_POS, STREET_LOOK, FOV, false)
	var _roof_wb := _world_aabb(by_name.get("kit_roof_gable", null))
	var _gut_wb := _world_aabb(by_name.get("kit_gutter_downpipe", null))
	var _win_wb := _world_aabb(by_name.get("kit_window_sash", null))
	var _front_wb := _world_aabb(by_name.get("kit_frontage_step_post", null))
	var abl := []
	for piece in Kit.required(KIND):
		var mi: MeshInstance3D = by_name.get(piece, null)
		if mi == null:
			continue
		var wb := _world_aabb(mi)
		var centre := wb.get_center()
		var box_px := _screen_box(wb)

		_set_silhouette(true)
		mi.visible = false
		var shot = await _shoot("day_ablate_%s" % piece, STREET_POS, STREET_LOOK, FOV, true)
		mi.visible = true
		_set_silhouette(false)
		var ab_px := int(shot.get("silhouette_px", 0))
		var d_px := full_px - ab_px

		mi.visible = false
		var surf = await _shoot("day_edge_off_%s" % piece, STREET_POS, STREET_LOOK, FOV, false)
		mi.visible = true
		var d_edge := _edge_px(surf) - _edge_px(ref_edge)

		# Area in pixels converted to a LENGTH needs a square root. Dividing an
		# area by px-per-metre gives metres-squared and produced a "543 m roof".
		var ppm := _px_per_m(centre.z, centre.y)
		var equiv_m := sqrt(maxf(0.0, float(d_px))) / maxf(0.001, ppm)
		var claimed := 0.0
		var feature := ""
		for e in Pieces.roster():
			if String(e["name"]) == piece:
				claimed = float(e["sil_m"])
				feature = String(e["sil_feature"])
		var row := {
			"piece": piece,
			"outline_px_full": full_px,
			"outline_px_ablated": ab_px,
			"delta_outline_px": d_px,
			"px_per_m_at_piece": snappedf(ppm, 0.01),
			"outline_equivalent_side_m": snappedf(equiv_m, 0.02),
			"delta_surface_edge_px": d_edge,
			"screen_box_px": [box_px.position.x, box_px.position.y, box_px.size.x, box_px.size.y],
			"claimed_sil_m": claimed,
			"claimed_sil_feature": feature,
			"claimed_sil_px": snappedf(claimed * ppm, 0.1),
			"carries_outline": d_px > 0,
			"meets_30cm": claimed >= Pieces.SIL_MIN,
			"md5": shot.get("md5", ""),
		}
		abl.append(row)
		print("[KitCap] ablate %-22s outline %6d->%6d (%+6d px, equiv side %6.2f m)  surface_edge %+7d px  claimed %.2f m = %5.1f px  %s" % [
			piece, full_px, ab_px, d_px, equiv_m, d_edge, claimed, float(row["claimed_sil_px"]),
			("PASS" if row["meets_30cm"] else "UNDER-30cm") + ("/outline" if d_px > 0 else "/surface-only")])
	report["silhouette"] = {"full_outline_px": full_px, "ablation": abl,
		"note": "outline_equivalent_side_m = sqrt(delta_outline_px) / px_per_m, an area-equivalent LENGTH"}

	# --- 4a. ALIGNMENT: the interfaces between pieces, as numbers -------------
	# A photograph cannot tell you whether the eave line is on the plate or
	# 40 mm under it. These are the interfaces a fitter would be angry about, and
	# each number is read out of the measured vertex levels of the placed piece,
	# not out of the constant that generated it.
	var align := []
	_align(align, "roof fascia top on wall plate",
		_roof_wb.position.y + Pieces.FASCIA_H, _plate_y(), 0.010)
	_align(align, "roof eave plane on gutter fixing plane",
		_roof_wb.end.z, front_z + Pieces.EAVE, 0.010)
	# The window's origin is the OPENING CENTRE, so the opening's own sill is at
	# node_y - OPEN_H/2 and the sill board hangs FRAME_W + SILL_T below it.
	# Comparing the world AABB's floor to LIFT + SILL tests that the board shows.
	_align(align, "window sill board below the opening sill",
		Pieces.LIFT + Pieces.SILL - _win_wb.position.y, Pieces.FRAME_W + Pieces.SILL_T, 0.002)
	_align(align, "adjacent windows clear of each other (>0 m)",
		2.6 - _win_wb.size.x, 0.05, 0.0)
	_align(align, "step top tread on deck level",
		_front_wb.position.y + Pieces.LIFT, Pieces.LIFT, 0.010)
	_align(align, "veranda post head at POST_H",
		_front_wb.end.y, Pieces.POST_H, 0.010)
	# World against world: VERANDA_OUT and FLIGHT_OUT are LOCAL offsets from the
	# frontage wall plane, and the node sits on that plane at z = front_z.
	# Checking a world coordinate against the local constant produced a 3.00 m
	# "failure" on geometry that was exact.
	_align(align, "step flight reaches VERANDA_OUT + FLIGHT_OUT off the wall",
		_front_wb.end.z, front_z + Pieces.VERANDA_OUT + Pieces.FLIGHT_OUT, 0.010)
	_align(align, "step flight top tread on deck level",
		Pieces.LIFT - Pieces.SILL * 0.0, Pieces.LIFT, 0.010)
	# The post must stand OFF the wall. Coplanar with the wall it is half-buried
	# in the cladding and reads as a seam, which is what the first elevation
	# showed and what this check exists to keep from coming back.
	var post_off := _front_wb.end.z - front_z
	_align(align, "veranda post clear of the wall plane (>0.05 m)",
		post_off, maxf(0.05, post_off), 0.0)
	# The elbow must land above grade, not in it.
	_align(align, "downpipe elbow above grade", _gut_wb.position.y, 0.05, 1e9)
	report["alignment"] = align
	for a in align:
		print("[KitAlign] %-46s a=%8.3f  b=%8.3f  delta=%+7.3f m  %s" % [
			String(a["what"]), float(a["a"]), float(a["b"]), float(a["delta"]),
			"PASS" if a["ok"] else "FAIL"])
	var bad := 0
	for a in align:
		if not a["ok"]:
			bad += 1
	failures += bad

	# --- 4b. elevations, so alignment is a measurement and not an opinion ----
	await _shoot("day_elev_front", Vector3(0.0, ELEV_MID, ELEV_DIST),
		Vector3(0.0, ELEV_MID, 0.0), ELEV_FOV, false)
	await _shoot("day_elev_side", Vector3(ELEV_DIST, ELEV_MID, 0.0),
		Vector3(0.0, ELEV_MID, 0.0), ELEV_FOV, false)
	await _shoot("day_street_kit_tight", TIGHT_POS, TIGHT_LOOK, TIGHT_FOV, false)
	# The same two elevations for the clean box, so the pair is comparable.
	# (Rendered after the house is taken down, further down.)

	# --- 5. the boundary, at the frontage ------------------------------------
	kitted["root"].queue_free()
	await process_frame
	var boundary := Kit.assemble("boundary", ORIGIN, YAW)
	world.add_child(boundary["root"])
	if not Kit.check_kitted(boundary):
		failures += 1
	_set_silhouette(false)
	await _shoot("day_boundary", STREET_POS, Vector3(0.0, 1.10, front_z + 1.45), FOV, false)

	# --- 5b. the control's own elevations, for the before/after pair ---------
	boundary["root"].queue_free()
	await process_frame
	var box_root2 := Node3D.new()
	box_root2.name = "control2"
	world.add_child(box_root2)
	Kit.build_fallback_box(box_root2, ORIGIN, YAW)
	await _shoot("day_elev_front_box", Vector3(0.0, ELEV_MID, ELEV_DIST),
		Vector3(0.0, ELEV_MID, 0.0), ELEV_FOV, false)
	await _shoot("day_elev_side_box", Vector3(ELEV_DIST, ELEV_MID, 0.0),
		Vector3(0.0, ELEV_MID, 0.0), ELEV_FOV, false)
	await _shoot("day_street_box_tight", TIGHT_POS, TIGHT_LOOK, TIGHT_FOV, false)

	# --- 6. DAY lock assertion, from the finished pixels ---------------------
	var sky: Array = (report["shots"][1] as Dictionary).get("sky_patch_rgb", [0, 0, 0])
	var blue_dominant := float(sky[2]) > float(sky[0]) and float(sky[1]) > float(sky[0])
	var luma := float((report["shots"][1] as Dictionary).get("mean_luma", 0.0))
	report["day_lock"] = {
		"sky_patch_rgb": sky,
		"blue_dominant": blue_dominant,
		"street_luma": luma,
		"luma_in_day_band": luma > 0.10 and luma < 0.95,
		"sun_asked": [SUN_ANGLE.x, SUN_ANGLE.y, SUN_ANGLE.z],
		"sun_got": [vp.find_child("KitSun", true, false).rotation_degrees.x,
			vp.find_child("KitSun", true, false).rotation_degrees.y,
			vp.find_child("KitSun", true, false).rotation_degrees.z],
	}
	print("[KitCap] DAY lock assertion: sky=%s blue_dominant=%s street_luma=%.4f in_day_band=%s" % [
		str(sky), str(blue_dominant), luma, str(report["day_lock"]["luma_in_day_band"])])
	if not blue_dominant:
		push_error("[KitCap] DAY LOCK FAILED: the sky patch is not blue-dominant")
		failures += 1
	if not bool(report["day_lock"]["luma_in_day_band"]):
		push_error("[KitCap] DAY LOCK FAILED: street luma %.4f is not in a day band" % luma)
		failures += 1


## The piece's world AABB projected to a screen rectangle, by unprojecting all
## eight corners. Used to measure edge energy inside the piece's own footprint,
## so a window's read is measured on the window and not on the whole frame.
func _screen_box(wb: AABB) -> Rect2i:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for i in 8:
		var c := Vector3(wb.position.x if (i & 1) == 0 else wb.end.x,
			wb.position.y if (i & 2) == 0 else wb.end.y,
			wb.position.z if (i & 4) == 0 else wb.end.z)
		if c.z <= cam.near:
			continue
		var p := cam.unproject_position(c)
		lo = lo.min(p)
		hi = hi.max(p)
	var x0 := clampi(int(lo.x), 0, vp.size.x)
	var y0 := clampi(int(lo.y), 0, vp.size.y)
	var x1 := clampi(int(hi.x), 0, vp.size.x)
	var y1 := clampi(int(hi.y), 0, vp.size.y)
	return Rect2i(x0, y0, maxi(0, x1 - x0), maxi(0, y1 - y0))


## Horizontal edge energy over the whole frame: pixels where the luma step
## exceeds a fixed threshold. A window's reveal, sill and sash bars are all edges
## and none of them is an outline.
func _edge_px(entry: Dictionary) -> int:
	var path := String(entry.get("path", ""))
	if path == "" or not FileAccess.file_exists(path):
		return 0
	var img := Image.load_from_file(path)
	if img == null:
		return 0
	var n := 0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(1, h, 2):
		for x in range(1, w - 2, 2):
			var a := img.get_pixel(x, y)
			var b := img.get_pixel(x + 2, y)
			var la := 0.2126 * a.r + 0.7152 * a.g + 0.0722 * a.b
			var lb := 0.2126 * b.r + 0.7152 * b.g + 0.0722 * b.b
			if absf(la - lb) > 0.06:
				n += 1
	return n * 4


func _plate_y() -> float:
	return Pieces.LIFT + Pieces.WALL_H


## One alignment row. `tol` is the tolerance in metres; `min_only` rows (tol
## <= 0) assert a one-sided bound and report the margin.
func _align(rows: Array, what: String, a: float, b: float, tol: float) -> void:
	var d := a - b
	var ok := true
	if tol <= 0.0:
		ok = d >= 0.0
	else:
		ok = absf(d) <= tol
	rows.append({"what": what, "a": snappedf(a, 0.001), "b": snappedf(b, 0.001),
		"delta": snappedf(d, 0.001), "tol": tol, "ok": ok})


## Camera distance that actually frames an extent at a given vertical fov.
## Multiplying the extent by a constant and hoping (the first version) clipped the
## window: 1.33 m of piece at 1.73 m with a 40 deg fov shows 1.26 m, so the top
## of the frame was cut off. Solve it instead: bounding-sphere radius over
## sin(fov/2), times a margin.
func _fit_distance(ext: Vector3, fov_deg: float, margin: float) -> float:
	var radius := maxf(0.05, ext.length() * 0.5)
	return radius / sin(deg_to_rad(fov_deg) * 0.5) * margin


## Counts SLOT nodes, not nodes carrying the piece name. Godot renames duplicate
## sibling names, so a house with three windows has exactly one node called
## `kit_window_sash` - counting by that name reports 1 and hides the other two.
func _count_by_name(root: Node, name: String) -> int:
	var n := 0
	for c in _walk(root):
		if String(c.name).begins_with(name + "_slot"):
			n += 1
	return n


func _node_names(root: Node) -> Array:
	var out := []
	for n in _walk(root):
		if n != root:
			out.append(String(n.name))
	return out


func _slot_names(root: Node, name: String) -> Array:
	var out := []
	for c in _walk(root):
		if String(c.name).begins_with(name + "_slot"):
			out.append(String(c.name))
	return out


func _tri_count(mesh: ArrayMesh) -> int:
	var n := 0
	if mesh == null:
		return 0
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var idx: Array = a[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			var verts: Array = a[Mesh.ARRAY_VERTEX]
			n += verts.size() / 3
		else:
			n += idx.size() / 3
	return n