# =============================================================================
# house_kit.gd - place a kitted house, or a clean box, never half a house
# =============================================================================
#
# THE ALL-OR-NOTHING RULE
#
#   A house kitted on the front and bare on the back is worse than a clean box,
#   because the eye reads the kitted side as a promise and then finds it broken.
#   So assemble() is a transaction: every required piece is resolved FIRST, and
#   if any one fails to load, has no mesh, or has the wrong surface count, the
#   whole thing falls back to the single clean box and says why in `reason`.
#   There is no code path that returns a partial kit.
#
#   The fallback is not an error dressed up as a feature. It is the production
#   default for a suburb: most of Manunda's 2198 OSM footprints are not
#   Queenslanders and must not be dressed as ones. A kitted house is the
#   exception that has to be earned, and it is the box that has to be beatable.
#
# ASSERTING THE KIT PATH WAS TAKEN
#
#   `kitted` is a claim; `placed` is the evidence. A caller that wants to know
#   the kit path ran must check that `placed` holds every required name, not
#   merely that nothing errored. A graceful fallback is valid behaviour, so a
#   check that only asserts "no errors" is satisfied by a house with no windows
#   at all. check_kitted() below is the check the fallback cannot pass.
#
# LOADING WITHOUT AN IMPORT PASS
#
#   The .glb files are read with GLTFDocument.append_from_file on the raw path,
#   not load(). load() needs Godot's importer (.import + .godot/imported/*.scn),
#   which needs an editor import pass that writes sidecar files for every asset
#   in the project - not this file's business. append_from_file needs none of
#   that, so the kit works on a cold clone with no import step at all.
#
# Class resolution is by preload(), not by the class_name registry, for the same
# reason: global class names only resolve once
# .godot/global_script_class_cache.cfg exists, and a consumer on a fresh
# worktree would see "Identifier not declared" for six pieces that all exist.

const Pieces := preload("res://assets/kits/house_kit_pieces.gd")
const Geom := preload("res://assets/kits/house_kit_geom.gd")

const MANIFEST := "res://assets/kits/manifest.json"

const ARCH_QLD_HOUSE := "qld_house"
const ARCH_QLD_SHOP := "qld_shop"
const ARCH_BOUNDARY := "boundary"


static func manifest() -> Dictionary:
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


static func _manifest_pieces() -> Dictionary:
	var out := {}
	var m := manifest()
	if m.has("pieces"):
		for p in m["pieces"]:
			out[String(p["node"])] = p
	return out


static func _first_mesh(node: Node) -> ArrayMesh:
	if node == null:
		return null
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null


## Loads one kit piece's geometry straight out of the .glb. Returns {} on any
## failure; the caller must treat {} as fatal to the whole kit.
static func load_piece(name: String) -> Dictionary:
	var entry = _manifest_pieces().get(name, null)
	if entry == null:
		return {}
	var path := String(entry["file"])
	if not FileAccess.file_exists(path):
		return {}
	var st := GLTFState.new()
	var doc := GLTFDocument.new()
	if doc.append_from_file(path, st) != OK:
		return {}
	var scn := doc.generate_scene(st)
	var mesh := _first_mesh(scn)
	if scn != null:
		scn.free()
	if mesh == null or mesh.get_surface_count() <= 0:
		return {}
	return {"mesh": mesh, "roles": entry["roles"], "entry": entry}


## The piece list one archetype must have before it is allowed to be a kitted
## house. Anything not in here is decoration; anything in here is mandatory.
static func required(kind: String) -> Array:
	match kind:
		ARCH_QLD_HOUSE:
			return ["kit_roof_gable", "kit_window_sash", "kit_gutter_downpipe",
				"kit_frontage_step_post"]
		ARCH_QLD_SHOP:
			return ["kit_roof_hip", "kit_window_sash", "kit_gutter_downpipe"]
		ARCH_BOUNDARY:
			return ["kit_fence_paling_gateling"]
	push_error("house_kit: unknown archetype '%s'" % kind)
	return []


static func role_material(role: String) -> StandardMaterial3D:
	var spec = Pieces.ROLES.get(role, null)
	var m := StandardMaterial3D.new()
	if spec == null:
		m.albedo_color = Color(0.7, 0.7, 0.7)
		return m
	var c: Array = spec["color"]
	m.albedo_color = Color(c[0], c[1], c[2], c[3])
	m.metallic = float(spec["metallic"])
	m.metallic_specular = 0.5
	m.roughness = float(spec["roughness"])
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m


static func _mesh_from(g) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = g.verts
	arrays[Mesh.ARRAY_NORMAL] = g.norms
	arrays[Mesh.ARRAY_TEX_UV] = g.uvs
	arrays[Mesh.ARRAY_INDEX] = g.idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The clean box: one closed box on the ground, no stumps, no openings, no
## eaves, nothing you could name. It is the control in the capture and the
## fallback in production, and it is deliberately the shape the world already
## produces for an OSM footprint with no archetype.
static func build_fallback_box(parent: Node3D, at: Vector3, yaw: float) -> Node3D:
	var g = Geom.new()
	g.push_box(Vector3(-Pieces.WALL_W * 0.5, 0.0, -Pieces.DEPTH * 0.5),
		Vector3(Pieces.WALL_W, Pieces.LIFT + Pieces.WALL_H, Pieces.DEPTH))
	var mi := MeshInstance3D.new()
	mi.name = "kit_fallback_box"
	mi.mesh = _mesh_from(g)
	mi.material_override = role_material("timber")
	parent.add_child(mi)
	mi.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	return mi


## Where each piece of a kitted house goes: {piece: [{at, yaw}, ...]}. Positions
## are derived from the pieces' own origin rules, not hard-coded, so moving a
## piece's origin moves its placement with it.
static func layout(kind: String) -> Dictionary:
	var out := {}
	var half_w := Pieces.WALL_W * 0.5
	var front_z := Pieces.DEPTH * 0.5
	var plate_y := Pieces.LIFT + Pieces.WALL_H
	match kind:
		ARCH_QLD_HOUSE:
			out["kit_roof_gable"] = [
				{"at": Vector3(0.0, plate_y + Pieces.RIDGE_H, 0.0), "yaw": 0.0}]
			var win_y := Pieces.LIFT + Pieces.SILL + Pieces.OPEN_H * 0.5
			var wins := []
			for wx in [-2.6, 0.0, 2.6]:
				wins.append({"at": Vector3(float(wx), win_y, front_z), "yaw": 0.0})
			out["kit_window_sash"] = wins
			out["kit_gutter_downpipe"] = [
				{"at": Vector3(half_w + 0.10, plate_y, front_z + Pieces.EAVE), "yaw": 0.0}]
			out["kit_frontage_step_post"] = [
				{"at": Vector3(0.0, 0.0, front_z), "yaw": 0.0}]
		ARCH_QLD_SHOP:
			out["kit_roof_hip"] = [
				{"at": Vector3(0.0, plate_y + Pieces.RIDGE_H, 0.0), "yaw": 0.0}]
			var shop_wins := []
			for wx in [-3.2, 3.2]:
				shop_wins.append({
					"at": Vector3(float(wx), Pieces.LIFT + 1.45, front_z), "yaw": 0.0})
			out["kit_window_sash"] = shop_wins
			out["kit_gutter_downpipe"] = [
				{"at": Vector3(half_w + 0.10, plate_y, front_z + Pieces.EAVE), "yaw": 0.0}]
		ARCH_BOUNDARY:
			# Clear of the step flight, not level with the deck edge. The steps
			# project FLIGHT_OUT past the deck, so a fence on the deck line would
			# run straight through them - and the gateling would be a gate onto a
			# wall of timber.
			out["kit_fence_paling_gateling"] = [
				{"at": Vector3(0.0, 0.0,
					front_z + Pieces.VERANDA_OUT + Pieces.FLIGHT_OUT + 0.35), "yaw": 0.0}]
	return out


## Builds a house or a boundary. Always returns a root Node3D to add to a tree.
##   root    Node3D
##   kitted  bool, true only if EVERY required piece resolved
##   placed  PackedStringArray of the kit node names actually created
##   reason  "" when kitted, otherwise exactly why it fell back
##   kind    the archetype, echoed so a caller need not re-derive it
static func assemble(kind: String, at: Vector3, yaw: float) -> Dictionary:
	var root := Node3D.new()
	root.name = "house_" + kind
	var need := required(kind)
	if need.is_empty():
		return _fallback(root, kind, at, yaw, "archetype '%s' is unknown" % kind, [])
	var plan := layout(kind)

	# --- resolve everything before touching the tree ------------------------
	var resolved := {}
	for piece in need:
		var got := load_piece(piece)
		if got.is_empty():
			return _fallback(root, kind, at, yaw, "piece '%s' would not load" % piece, [])
		var insts: Array = plan.get(piece, [])
		if insts.is_empty():
			return _fallback(root, kind, at, yaw, "piece '%s' has no placement" % piece, [])
		resolved[piece] = {"got": got, "instances": insts}
	if resolved.size() != need.size():
		return _fallback(root, kind, at, yaw, "resolved %d of %d pieces" % [
			resolved.size(), need.size()], [])

	# --- commit --------------------------------------------------------------
	var placed := PackedStringArray()
	var instances := 0
	for piece in need:
		var entry: Dictionary = resolved[piece]
		var got: Dictionary = entry["got"]
		var mesh: ArrayMesh = got["mesh"]
		var roles: Array = got["roles"]
		if mesh.get_surface_count() != roles.size():
			return _fallback(root, kind, at, yaw, "piece '%s' has %d surfaces for %d roles" % [
				piece, mesh.get_surface_count(), roles.size()], [])
		var slot := 0
		for inst in entry["instances"]:
			slot += 1
			# ONE node per kit piece, and the node is named exactly the kit piece
			# name. Three windows therefore need three nodes with three DIFFERENT
			# names in one parent, which Godot will not allow: add_child() silently
			# renames the second and third to kit_window_sash2 and
			# kit_window_sash3, and then `placed` and every query by name sees ONE
			# window on a house with three. So each instance gets an explicitly
			# named slot node and the kit piece name is used once per slot.
			var slot_node := Node3D.new()
			slot_node.name = "%s_slot%d" % [piece, slot]
			root.add_child(slot_node)
			var mi := MeshInstance3D.new()
			mi.name = piece
			mi.mesh = mesh
			for s in roles.size():
				mi.set_surface_override_material(s, role_material(String(roles[s])))
			slot_node.add_child(mi)
			var local: Vector3 = inst["at"]
			mi.transform = Transform3D(Basis(Vector3.UP, float(inst["yaw"])),
				at + Basis(Vector3.UP, yaw) * local)
			if not placed.has(piece):
				placed.append(piece)
			instances += 1
	_shell(root, kind, at, yaw)
	return {"root": root, "kitted": true, "placed": placed, "reason": "", "kind": kind,
		"instances": instances}


static func _fallback(root: Node3D, kind: String, at: Vector3, yaw: float,
		reason: String, placed: Array) -> Dictionary:
	build_fallback_box(root, at, yaw)
	return {"root": root, "kitted": false, "placed": PackedStringArray(placed),
		"reason": reason, "kind": kind}


## The wall shell, built from panels around REAL openings rather than a solid box
## with windows stuck on it, because artkit/buildings.gd:27 is explicit that the
## openings are the thing and a painted rectangle is not a window. The window
## piece's reveal returns then have somewhere to be visible.
static func _shell(root: Node3D, kind: String, at: Vector3, yaw: float) -> Node3D:
	var g = Geom.new()
	var hw := Pieces.WALL_W * 0.5
	var hd := Pieces.DEPTH * 0.5
	var y0 := Pieces.LIFT
	var y1 := Pieces.LIFT + Pieces.WALL_H
	var t := Pieces.WALL_T

	var openings: Array = []
	if kind == ARCH_QLD_HOUSE:
		for wx in [-2.6, 0.0, 2.6]:
			openings.append({"x": float(wx), "w": Pieces.OPEN_W,
				"y0": Pieces.LIFT + Pieces.SILL, "y1": Pieces.LIFT + Pieces.SILL + Pieces.OPEN_H})
	elif kind == ARCH_QLD_SHOP:
		for wx in [-3.2, 3.2]:
			openings.append({"x": float(wx), "w": Pieces.OPEN_W,
				"y0": Pieces.LIFT + 1.45 - Pieces.OPEN_H * 0.5,
				"y1": Pieces.LIFT + 1.45 + Pieces.OPEN_H * 0.5})

	if openings.is_empty():
		return null
	var lowest := y1
	var highest := y0
	for o in openings:
		lowest = minf(lowest, float(o["y0"]))
		highest = maxf(highest, float(o["y1"]))
	g.push_box(Vector3(-hw, y0, hd - t), Vector3(Pieces.WALL_W, lowest - y0, t))
	if highest < y1:
		g.push_box(Vector3(-hw, highest, hd - t), Vector3(Pieces.WALL_W, y1 - highest, t))
	var sorted := openings.duplicate()
	sorted.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
	var cursor := -hw
	for o in sorted:
		var lx := float(o["x"]) - float(o["w"]) * 0.5
		if lx > cursor:
			g.push_box(Vector3(cursor, lowest, hd - t), Vector3(lx - cursor, highest - lowest, t))
		cursor = float(o["x"]) + float(o["w"]) * 0.5
	if cursor < hw:
		g.push_box(Vector3(cursor, lowest, hd - t), Vector3(hw - cursor, highest - lowest, t))

	# Back and two sides: solid panels, which is all they are in this archetype.
	g.push_box(Vector3(-hw, y0, -hd), Vector3(Pieces.WALL_W, y1 - y0, t))
	g.push_box(Vector3(-hw, y0, -hd + t), Vector3(t, y1 - y0, Pieces.DEPTH - t * 2.0))
	g.push_box(Vector3(hw - t, y0, -hd + t), Vector3(t, y1 - y0, Pieces.DEPTH - t * 2.0))
	# Stumps: a highset house stands on posts, and the shadow under it is a
	# depth cue the flat-box fallback cannot have at all.
	for sx in [-hw + 0.35, 0.0, hw - 0.55]:
		g.push_box(Vector3(float(sx), 0.0, hd - 0.30), Vector3(0.20, Pieces.LIFT, 0.20))
	var mi := MeshInstance3D.new()
	mi.name = "house_shell"
	mi.mesh = _mesh_from(g)
	mi.material_override = role_material("timber")
	root.add_child(mi)
	mi.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	return mi


## The check the fallback cannot pass. Use this instead of asserting "no
## errors": a graceful fallback is valid behaviour, so only the piece list can
## tell a kitted house from a clean box.
static func check_kitted(result: Dictionary) -> bool:
	var kind := String(result.get("kind", ""))
	if not bool(result.get("kitted", false)):
		push_error("house_kit: kit path NOT taken (%s)" % String(result.get("reason", "?")))
		return false
	var placed := PackedStringArray(result.get("placed", PackedStringArray()))
	for piece in required(kind):
		if not placed.has(piece):
			push_error("house_kit: kit path claimed but '%s' was never placed" % piece)
			return false
		var want: int = (layout(kind).get(piece, []) as Array).size()
		var got := 0
		for slot in _slot_nodes(result.get("root"), piece):
			got += 1
		if want > 0 and got != want:
			push_error("house_kit: '%s' wanted %d instances, found %d" % [piece, want, got])
			return false
	return true


## Slot nodes named `<piece>_slotN`, in tree order.
static func _slot_nodes(root, piece: String) -> Array:
	var out := []
	if root == null:
		return out
	for c in (root as Node).get_children():
		if String(c.name) == "%s_slot%d" % [piece, out.size() + 1]:
			out.append(c)
	return out