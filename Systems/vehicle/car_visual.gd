class_name CarVisual
extends Node3D
## The car you actually see. CarBody is physics with no opinion about looks, so
## this builds the exterior procedurally from a CarSpec: a box body, a glass
## greenhouse, a roof, wheels that steer and spin off the real suspension data,
## and working lights.
##
## Boxes on purpose as the fallback: a stack of well-proportioned boxes with a
## good paint material reads as a car at night far better than an untextured
## sphere ever would, and every dimension comes from the spec, so a new car in
## CarDB looks right without touching this file. Where a scanned model exists
## it is used instead - see _build_model.
##
## The wheels are the only part that has to be built, because the physics already
## computes the right answer for them: each wheel carries its own `steer_angle`
## and `spin_vis`, so the visual follows the tyre model rather than guessing.

## Paint names used by CarDB, as colours. Metallic and low roughness because a
## car in the rain at night is a mirror - the reflection probe on the player
## gives it something to reflect.
const PAINTS := {
	"primer_grey": Color(0.20, 0.20, 0.21),
	"faded_white": Color(0.62, 0.61, 0.57),
	"storm_white": Color(0.78, 0.79, 0.80),
	"pearl_white": Color(0.86, 0.87, 0.88),
	"midnight_blue": Color(0.035, 0.055, 0.115),
	"gunmetal": Color(0.13, 0.14, 0.16),
	"racing_green": Color(0.045, 0.19, 0.10),
	"taxi_yellow": Color(0.72, 0.50, 0.04),
	"burnt_orange": Color(0.42, 0.13, 0.03),
}

## Which imported model stands in for which car. The glb files are named after
## the real car they are and the CarDB ids are not, so this is the one place the
## two meet - same kind of lookup as PAINTS above.
##
## A car with no entry here keeps its procedural body on purpose. kairo_mx90 and
## kaze_type_r are a Miata and an AE86 Trueno, neither of which is in the
## downloaded set, and a correctly sized box beats the wrong car.
const MODELS := {
	"kairo_s13": "silvia_s13",      ## S13. The player car.
	"tatsuya_gt": "supra_mk4",      ## A80.
	"shinobi_rs": "wrx_gc8",        ## GC8 blobeye. The rival.
	"hayate_turbo": "evo_v",        ## CP9A.
	"akuma_gt": "silvia_s15",       ## S15.
}

const TAIL_IDLE := 1.1      ## emission energy with the brakes off
const TAIL_BRAKING := 4.0   ## ... and with them on. This is a brake light; it
                            ## has to be unmissable in a mirror at 200 km/h,
                            ## but past the glow threshold the lens turns into
                            ## a white blob and the shape of the car is lost.
const REVERSE_IDLE := 0.0
const REVERSE_ON := 4.0

var spec: CarSpec

var _wheels: Array = []          ## [{ "name": String, "steer": Node3D, "spin": Node3D }]
var _tail_mat: StandardMaterial3D
var _reverse_mat: StandardMaterial3D
var _tail_lens: Array[MeshInstance3D] = []
var _reverse_lens: Array[MeshInstance3D] = []
var _lights: Node3D              ## children of this that are Light3D
var _holder: Node3D              ## the "Model" node from _build_model
var _model: Node                 ## the instantiated gltf scene


func _init() -> void:
	spec = null


## Builds the exterior. `body_spec` is the same CarSpec the physics uses, so the
## visual and the collision box can never disagree about how big the car is.
func build(body_spec: CarSpec) -> void:
	spec = body_spec
	if spec == null:
		return
	_lights = Node3D.new()
	_lights.name = "CarLights"
	add_child(_lights)

	# An imported model replaces the shell, and its wheels are lifted out of the
	# scan so they can steer and spin - see _rig_scanned_wheels. A model whose
	# tyres turn out to be welded into its body panels gets procedural wheels
	# instead, so the car still rolls on the real tyre model.
	if _build_model():
		if not _rig_scanned_wheels():
			_build_wheels()
		_build_lights()
		return

	_build_shell()
	_build_wheels()
	_build_lights()


## Instances the imported glTF for this car, if there is a usable one.
## Returns true when it did, so the caller can skip the procedural build.
##
## Nothing here knows about any particular model. Which cars have a model, how
## big it is and which way up it was exported all live in CarFit, which is
## generated from the files themselves - see Tools/fit_cars.gd. A car with no
## entry, or one marked unusable, falls back to the procedural exterior.
func _build_model() -> bool:
	if spec == null or not MODELS.has(spec.id):
		return false
	var model_id: String = MODELS[spec.id]
	if not CarFit.ALL.has(model_id):
		return false
	var fit: Dictionary = CarFit.ALL[model_id]
	if not bool(fit.get("usable", false)):
		return false
	var path := "res://assets/cars/%s.glb" % model_id
	if not ResourceLoader.exists(path):
		return false
	var packed: PackedScene = load(path)
	if packed == null:
		return false
	var scene := packed.instantiate()
	if scene == null:
		return false

	var deg: Vector3 = fit["rot_deg"]
	var s: float = float(fit["scale"])
	var basis := Basis.from_euler(Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y), deg_to_rad(deg.z)))
	basis = basis.scaled(Vector3.ONE * s)

	var holder := Node3D.new()
	holder.name = "Model"
	# The car's origin sits at hub height rather than on the ground, so a model
	# fitted to stand on y=0 has to be lifted by a tyre radius or it sinks.
	holder.transform = Transform3D(
		basis,
		Vector3(fit["offset"]) + Vector3(0.0, spec.tyre_radius, 0.0)
	)
	add_child(holder)
	holder.add_child(scene)
	_holder = holder
	_model = scene
	return true

## ---- wheels lifted back out of a scanned model ------------------------------
##
## A scan's wheel geometry is only useful if it can be turned, so this walks the
## imported model looking for it, hangs each corner under the same steer/spin
## pair the procedural wheels use, and hides the geometry it moved. Everything
## here works in car space - the holder's fit transform is baked into the new
## vertices - so the rig needs no knowledge of how a particular model was
## exported or which way round it faces.
##
## The test is geometric rather than by node name, because the names are useless:
## three of the five models call their wheels Object_NN and MeshNNN, a fourth
## bakes both front wheels into one mesh across the centreline, and none of them
## agree with each other. What all five do agree on is that a wheel is a solid
## of revolution sitting on its axle, so for each corner:
##
##   1. only vertices on that corner's side of the car's centreline count, which
##      handles the centreline-baked model and the per-corner ones the same way;
##   2. candidates are the meshes with enough of that side's vertices inside a
##      tube around the axle, which separates wheels from bodywork;
##   3. the hub height is the vertex-weighted median of those candidates, so one
##      panel with a bad bounding box cannot drag the axis off the wheel;
##   4. a candidate is kept when the vertices near the hub are wrapped all the
##      way round the axle - a strut above the hub and a bumper through it both
##      fail that, a tyre and a brake disc both pass it;
##   5. kept geometry is clipped to a cylinder around the axle, so a wheel that
##      arrived welded to a body panel leaves that panel behind. Everything the
##      corners did not claim is rebuilt alongside the wheels, so the car keeps
##      every panel it came with.

const SCAN_CORNERS := ["FL", "FR", "RL", "RR"]
const SCAN_MIN_VERTS := 12        ## below this a mesh is trim, not a wheel
const SCAN_TUBE := 1.30           ## axle tube radius, in tyre radii
const SCAN_MIN_TUBE_FRAC := 0.45  ## share of a side's vertices that must be in it
const SCAN_MIN_RING := 0.50       ## share of vertices sitting in a ring round the axle
const SCAN_MIN_BELOW := 0.20      ## ... and how many must be under the hub
const SCAN_CLIP := 1.70           ## wheel cylinder radius, in tyre radii
const SCAN_MAX_OFFSET := 0.45     ## how far a wheel's centroid may sit off its axle
const SCAN_MIN_CORNER := 30       ## vertices a corner needs before we trust it
const SCAN_MIN_HEIGHT := 1.25     ## how tall a corner's geometry must be, in tyre radii
const SCAN_ROUND_LO := 0.65       ## how close to square a wheel's tall/deep face has to be...
const SCAN_ROUND_HI := 1.55       ## ...measured as that ratio, before we call it a disc

const SCAN_REST := 4             ## destination for geometry that stays put
const SCAN_AXLE := {"FL": "F", "FR": "F", "RL": "R", "RR": "R"}

## The split rewrites every vertex of every scanned wheel, which is far too slow
## to do per car, so it happens once per model and every car built from that
## model shares the result.
static var _scan_cache: Dictionary = {}


## Builds the steer/spin rig for a scanned model. Returns false when the scan has
## no usable per-corner wheel geometry, so the caller can fall back to the
## procedural wheels rather than leave the car on baked-in tyres.
func _rig_scanned_wheels() -> bool:
	if _holder == null or _model == null:
		return false
	var key := "%s/%.4f" % [String(MODELS[spec.id]), spec.tyre_radius]
	var rig: Dictionary
	if _scan_cache.has(key):
		rig = _scan_cache[key]
	else:
		rig = _scan_wheels()
		_scan_cache[key] = rig
	if not bool(rig.get("rigged", false)):
		return false

	for corner in SCAN_CORNERS:
		var steer := Node3D.new()
		steer.name = "Steer_" + corner
		steer.position = _axle(corner, float(rig["hub"][corner]))
		add_child(steer)
		var spin := Node3D.new()
		spin.name = "Spin"
		steer.add_child(spin)
		for part in rig["wheels"][corner]:
			var mi := MeshInstance3D.new()
			mi.name = String(part["name"])
			mi.mesh = part["mesh"]
			spin.add_child(mi)
		_wheels.append({"name": corner, "steer": steer, "spin": spin})

	# Whatever the corners did not claim is rebuilt in place, so only the wheel
	# geometry itself needs hiding - and it is hidden per car, not once per
	# model, because each car owns its own copy of the imported scene.
	var to_holder := _holder.transform.affine_inverse()
	for path in rig["hidden"]:
		var old: Node = _model.get_node_or_null(path)
		if old is MeshInstance3D:
			(old as MeshInstance3D).visible = false
	for part in rig["kept"]:
		var mi := MeshInstance3D.new()
		mi.name = String(part["name"])
		mi.mesh = part["mesh"]
		_holder.add_child(mi)
		mi.transform = to_holder
	return true


## Why this car's model could not be rigged from its own geometry and fell back
## to procedural wheels, or an empty string when the scan found four wheels.
## A model whose tyres are welded into its body panels says so here.
func scan_fallback_reason() -> String:
	if _holder == null or _model == null:
		return ""
	var key := "%s/%.4f" % [String(MODELS[spec.id]), spec.tyre_radius]
	if not _scan_cache.has(key):
		return ""
	var rig: Dictionary = _scan_cache[key]
	if bool(rig.get("rigged", false)):
		return ""
	return String(rig.get("reason", ""))


## Runs the scan once for one model. Returns { rigged, hub, wheels, kept, hidden }
## when every corner found a wheel, or { rigged: false, reason } when it did not.
func _scan_wheels() -> Dictionary:
	var half_base: float = spec.wheelbase * 0.5
	var half_track: float = spec.track_width * 0.5
	var axles := {
		"FL": Vector3(-half_track, 0.0, -half_base),
		"FR": Vector3(half_track, 0.0, -half_base),
		"RL": Vector3(-half_track, 0.0, half_base),
		"RR": Vector3(half_track, 0.0, half_base),
	}
	var r: float = spec.tyre_radius

	var meshes: Array = []
	_scan_meshes(_model, Transform3D.IDENTITY, _holder.transform, r, axles, meshes)

	# A mesh that reaches both axles is a body panel that happens to pass through
	# the wheels, not a wheel. Nothing else in the model can rescue it, so it is
	# out before any corner looks at it.
	var panels: Array = []
	for m in meshes:
		var seen: Array = []
		for corner in SCAN_CORNERS:
			if _side_is_candidate(m, corner):
				seen.append(SCAN_AXLE[corner])
		if seen.has("F") and seen.has("R"):
			panels.append(String(m["path"]))

	var hub := {}
	var owners := {}
	var problems: Array[String] = []
	for corner in SCAN_CORNERS:
		var cands: Array = []
		for m in meshes:
			if panels.has(String(m["path"])):
				continue
			if _side_is_candidate(m, corner):
				cands.append(m)
		if cands.is_empty():
			problems.append("%s found no wheel candidates" % corner)
			continue
		var axis_y: float = _hub_height(cands, corner)
		hub[corner] = axis_y
		var mine: Array = []
		for m in cands:
			if absf(_mid_y(m, corner) - axis_y) > r * 0.95:
				continue
			var slice := _wheel_slice(m, corner, axles[corner], axis_y, r)
			if slice.is_empty():
				continue
			mine.append({"node": String(m["name"]), "indices": slice["indices"], "pos": m["pos"]})
			if not m.has("taken"):
				m["taken"] = {}
			m["taken"][corner] = slice["indices"]
		var total: int = 0
		for entry in mine:
			total += (entry["indices"] as PackedInt32Array).size()
		if total < SCAN_MIN_CORNER:
			problems.append("%s found only %d wheel vertices" % [corner, total])
			continue
		# Ring coverage and centroid only say the geometry sits in the right place.
		# A corner whose survivors are still shallow, or not round across the axle,
		# is bodywork that got this far - which is how a model with its tyres
		# welded into its panels gets caught rather than half rigged.
		var span: Vector3 = _corner_span(mine)
		if span.y < r * SCAN_MIN_HEIGHT:
			problems.append("%s kept %d vertices spanning only %.3f m" % [corner, total, span.y])
			continue
		var ratio: float = span.y / maxf(0.001, span.z)
		if ratio < SCAN_ROUND_LO or ratio > SCAN_ROUND_HI:
			problems.append("%s kept geometry is %.3f tall by %.3f deep, not a disc" % [corner, span.y, span.z])
			continue
		owners[corner] = mine

	if not problems.is_empty():
		return {"rigged": false, "reason": " / ".join(problems)}

	var wheels := {}
	var kept: Array = []
	var hidden: Array = []
	for m in meshes:
		if not m.has("taken"):
			continue
		hidden.append(m["path"])
		var parts := _split_mesh(m, m["taken"])
		for n in SCAN_CORNERS.size():
			var corner: String = SCAN_CORNERS[n]
			if not m["taken"].has(corner):
				continue
			var list: Array = wheels.get(corner, [])
			for i in parts[n].size():
				list.append({
					"name": "%s_%d" % [String(m["name"]), i],
					"mesh": parts[n][i],
				})
			wheels[corner] = list
		for i in parts[SCAN_REST].size():
			kept.append({
				"name": "%s_body%d" % [String(m["name"]), i],
				"mesh": parts[SCAN_REST][i],
			})
	return {"rigged": true, "hub": hub, "wheels": wheels, "kept": kept, "hidden": hidden}


## Fills one dictionary per MeshInstance3D in the model: how many of that side's
## vertices each corner's axle tube catches, plus every vertex in car space so
## the ring test and the rebuild can both work off the same numbers.
func _scan_meshes(node: Node, xf: Transform3D, holder: Transform3D, r: float, axles: Dictionary, out: Array) -> void:
	var mine: Transform3D = xf * (node as Node3D).transform if node is Node3D else xf
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			out.append(_measure(mi, mine, holder, r, axles))
	for child in node.get_children():
		_scan_meshes(child, mine, holder, r, axles, out)


func _measure(mi: MeshInstance3D, xf: Transform3D, holder: Transform3D, r: float, axles: Dictionary) -> Dictionary:
	var car_xf: Transform3D = holder * xf
	var pos := PackedVector3Array()
	var surfaces: Array = []
	var count: int = 0
	for surf in mi.mesh.get_surface_count():
		var arrays: Array = mi.mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		surfaces.append({
			"arrays": arrays,
			"start": count,
			"count": verts.size(),
			"material": mi.mesh.surface_get_material(surf),
		})
		for i in verts.size():
			pos.append(car_xf * verts[i])
		count += verts.size()

	var left: int = 0
	var right: int = 0
	var tube := {"FL": 0, "FR": 0, "RL": 0, "RR": 0}
	var lo := {"FL": INF, "FR": INF, "RL": INF, "RR": INF}
	var hi := {"FL": -INF, "FR": -INF, "RL": -INF, "RR": -INF}
	for i in pos.size():
		var p: Vector3 = pos[i]
		var is_left: bool = p.x < 0.0
		if is_left:
			left += 1
		else:
			right += 1
		for corner in SCAN_CORNERS:
			if (corner == "FL" or corner == "RL") != is_left:
				continue
			var axle: Vector3 = axles[corner]
			if Vector2(p.x - axle.x, p.z - axle.z).length() <= r * SCAN_TUBE:
				tube[corner] = int(tube[corner]) + 1
				lo[corner] = minf(float(lo[corner]), p.y)
				hi[corner] = maxf(float(hi[corner]), p.y)

	return {
		"path": mi.get_path(),
		"name": String(mi.name),
		"pos": pos,
		"surfaces": surfaces,
		"normal_basis": car_xf.basis.inverse().transposed(),
		"left": left,
		"right": right,
		"side": {"FL": left, "FR": right, "RL": left, "RR": right},
		"tube": tube,
		"lo": lo,
		"hi": hi,
	}


## A mesh is a candidate for a corner when enough of that side's vertices sit in
## the axle tube. Counting per side is what lets one mesh serve both corners when
## a scan has welded the left and right wheels together across the centreline.
func _side_is_candidate(m: Dictionary, corner: String) -> bool:
	var n: int = int(m["side"][corner])
	if n < SCAN_MIN_VERTS:
		return false
	return float(m["tube"][corner]) / float(n) >= SCAN_MIN_TUBE_FRAC


func _mid_y(m: Dictionary, corner: String) -> float:
	return (float(m["lo"][corner]) + float(m["hi"][corner])) * 0.5


## The hub is wherever most of the wheel's vertices are, so it is the weighted
## median of the candidates' vertical midpoints rather than the mean or the
## tallest: one long body panel cannot drag the axis off the axle, and a wheel
## built from several meshes does not have to agree with itself.
func _hub_height(cands: Array, corner: String) -> float:
	var pairs: Array = []
	var total: int = 0
	for m in cands:
		var w: int = int(m["tube"][corner])
		if w <= 0:
			continue
		pairs.append([_mid_y(m, corner), w])
		total += w
	if pairs.is_empty():
		return 0.0
	pairs.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var run: int = 0
	for p in pairs:
		run += int(p[1])
		if run * 2 >= total:
			return float(p[0])
	return float(pairs[pairs.size() - 1][0])


## Picks the vertices of one mesh that belong to one wheel: on this corner's side
## of the centreline, inside a cylinder around the axle, and wrapped all the way
## round it. Returns { indices }, or an empty dictionary when the mesh is not a
## wheel for this corner.
func _wheel_slice(m: Dictionary, corner: String, axle: Vector3, axis_y: float, r: float) -> Dictionary:
	var pos: PackedVector3Array = m["pos"]
	var want_left: bool = corner == "FL" or corner == "RL"
	var indices := PackedInt32Array()
	var ring: int = 0
	var below: int = 0
	var sum_x: float = 0.0
	var clip: float = r * SCAN_CLIP
	for i in pos.size():
		var p: Vector3 = pos[i]
		if want_left != (p.x < 0.0):
			continue
		var rho: float = Vector2(p.y - axis_y, p.z - axle.z).length()
		if rho > clip:
			continue
		indices.append(i)
		sum_x += p.x
		if rho >= r * 0.25 and rho <= r * 1.10:
			ring += 1
		if p.y < axis_y - r * 0.12:
			below += 1
	var n: int = indices.size()
	if n < SCAN_MIN_VERTS:
		return {}
	if float(ring) / float(n) < SCAN_MIN_RING:
		return {}
	if float(below) / float(n) < SCAN_MIN_BELOW:
		return {}
	# A wheel is centred on its axle. A strut or a bumper welded across the same
	# spot still passes the ring test, but its centroid sits well inboard, and
	# that is the one measurement that tells the two apart.
	if absf(sum_x / float(n) - axle.x) > r * 2.0 * SCAN_MAX_OFFSET:
		return {}
	return {"indices": indices}


## The union extent of one corner's kept vertices, in car space. A wheel is a disc
## turned about its axle, so it is about as deep as it is tall and both reach
## past the hub by most of a radius. A strut bar, a bumper blade or a body panel
## that survived the ring test is wide and shallow, or far too small, and this is
## what says so.
func _corner_span(mine: Array) -> Vector3:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for entry in mine:
		var pos: PackedVector3Array = entry["pos"]
		for i in entry["indices"]:
			var p: Vector3 = pos[i]
			lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
			hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
	return hi - lo


## Rewrites one source mesh into a set of meshes, one per destination, keeping
## only the triangles whose three vertices all belong to the same destination.
## Every destination ends up with exactly the geometry it should, so the original
## can be hidden without the car losing a panel.
func _split_mesh(m: Dictionary, claimed: Dictionary) -> Dictionary:
	var pos: PackedVector3Array = m["pos"]
	var total: int = pos.size()
	var dest := PackedInt32Array()
	dest.resize(total)
	for i in total:
		dest[i] = -1
	var corners: Array = []
	for n in SCAN_CORNERS.size():
		var corner: String = SCAN_CORNERS[n]
		if not claimed.has(corner):
			continue
		corners.append(n)
		for i in claimed[corner]:
			dest[i as int] = n
	for i in total:
		if dest[i] < 0:
			dest[i] = SCAN_REST

	var parts := {}
	for n in corners + [SCAN_REST]:
		var sets: Array = []
		for surf in m["surfaces"]:
			var built := _emit_surface(surf, dest, n, m["pos"], m["normal_basis"])
			if built != null:
				sets.append(built)
		parts[n] = sets
	return parts


## Builds one surface of one destination. Returns an ArrayMesh, or an empty
## dictionary when that destination has no geometry in this surface.
func _emit_surface(surf: Dictionary, dest: PackedInt32Array, which: int, pos: PackedVector3Array, nrm: Basis) -> ArrayMesh:
	var arrays: Array = surf["arrays"]
	var start: int = int(surf["start"])
	var count: int = int(surf["count"])
	var remap := PackedInt32Array()
	remap.resize(count)
	remap.fill(-1)
	var kept: int = 0
	for j in count:
		if dest[start + j] == which:
			remap[j] = kept
			kept += 1
	if kept == 0:
		return null

	var src_idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if src_idx.is_empty():
		src_idx = PackedInt32Array()
		src_idx.resize(count)
		for j in count:
			src_idx[j] = j
	var out_idx := PackedInt32Array()
	var i: int = 0
	while i + 2 < src_idx.size():
		var a: int = remap[src_idx[i]]
		var b: int = remap[src_idx[i + 1]]
		var c: int = remap[src_idx[i + 2]]
		if a >= 0 and b >= 0 and c >= 0:
			out_idx.append(a)
			out_idx.append(b)
			out_idx.append(c)
		i += 3
	if out_idx.is_empty():
		return null

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	# Godot stores tangents flat, four floats a vertex, with the fourth holding
	# the xyz handedness - so they are read and written in that shape rather than
	# being squeezed into a Vector3 and losing the handedness.
	var tans := PackedFloat32Array()
	# Untyped on purpose: the gltf importer hands back plain Arrays for normals
	# on some of these meshes and PackedVector3Arrays on others.
	var src_norm = arrays[Mesh.ARRAY_NORMAL]
	var src_tan = arrays[Mesh.ARRAY_TANGENT]
	for j in count:
		var at: int = remap[j]
		if at < 0:
			continue
		verts.append(pos[start + j])
		if src_norm != null:
			norms.append(nrm * src_norm[j])
		if src_tan != null and j * 4 + 3 < src_tan.size():
			var w: float = src_tan[j * 4 + 3]
			var rt: Vector3 = nrm * Vector3(src_tan[j * 4], src_tan[j * 4 + 1], src_tan[j * 4 + 2])
			tans.append(rt.x * w)
			tans.append(rt.y * w)
			tans.append(rt.z * w)
			tans.append(w)

	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = norms
	out[Mesh.ARRAY_TANGENT] = tans
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		out[Mesh.ARRAY_TEX_UV] = _pick(arrays[Mesh.ARRAY_TEX_UV], remap)
	if arrays[Mesh.ARRAY_TEX_UV2] != null:
		out[Mesh.ARRAY_TEX_UV2] = _pick(arrays[Mesh.ARRAY_TEX_UV2], remap)
	if arrays[Mesh.ARRAY_COLOR] != null:
		out[Mesh.ARRAY_COLOR] = _pick(arrays[Mesh.ARRAY_COLOR], remap)
	out[Mesh.ARRAY_INDEX] = out_idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	if surf["material"] != null:
		mesh.surface_set_material(0, surf["material"])
	return mesh


## Copies the vertices a destination kept out of any per-vertex array.
func _pick(src, remap: PackedInt32Array):
	var out = src.duplicate()
	out.resize(remap.size())
	var keep: int = 0
	for j in remap.size():
		if remap[j] < 0:
			continue
		out[keep] = src[j]
		keep += 1
	out.resize(keep)
	return out


func _axle(corner: String, axis_y: float) -> Vector3:
	var half_base: float = spec.wheelbase * 0.5
	var half_track: float = spec.track_width * 0.5
	if corner == "FL":
		return Vector3(-half_track, axis_y, -half_base)
	if corner == "FR":
		return Vector3(half_track, axis_y, -half_base)
	if corner == "RL":
		return Vector3(-half_track, axis_y, half_base)
	return Vector3(half_track, axis_y, half_base)


func _build_shell() -> void:
	var w: float = spec.body_width
	var h: float = spec.body_height
	var l: float = spec.body_length
	# A coupe's cabin is short and set well back; a hatch or sedan carries more
	# glass and pushes the roof forward. Two numbers of difference is all it takes
	# for the two silhouettes to read differently at a glance.
	var coupe: bool = spec.body_style == "coupe"
	var cabin_l: float = 0.42 * l if coupe else 0.52 * l
	var cabin_z: float = 0.10 * l if coupe else 0.02 * l

	# The lower body has to be narrower than the track, or it swallows the
	# wheels whole: this car is 1.66 m wide across the body but the tyres only
	# reach 1.635 m, so at full width there is no wheel visible from any angle.
	# ponytail: no wheel arches - the body is one slab, so the tyres just stand
	# proud of it. Real arches mean splitting the body into side panels.
	var body_w: float = minf(w, spec.track_width + 0.04)
	var clearance: float = 0.10 * h
	_add_box("LowerBody", Vector3(body_w, 0.56 * h, l), Vector3(0, 0.28 * h + clearance, 0), _paint_mat())
	# Greenhouse in glass, roof panel in paint. Two boxes, and the car stops
	# looking like a shipping crate.
	_add_box("Cabin", Vector3(0.88 * w, 0.40 * h, cabin_l), Vector3(0, 0.76 * h, cabin_z), _glass_mat())
	_add_box("Roof", Vector3(0.90 * w, 0.08 * h, cabin_l * 0.92), Vector3(0, 0.99 * h, cabin_z), _paint_mat())

	if coupe:
		# A ducktail. Reads as a spoiler in silhouette, costs one box.
		_add_box("Spoiler", Vector3(0.80 * w, 0.05 * h, 0.16 * l), Vector3(0, 0.66 * h, 0.46 * l), _paint_mat())
	else:
		# A boot lid / tailgate step, so a sedan and a hatch are not the same box.
		_add_box("Boot", Vector3(0.92 * w, 0.18 * h, 0.26 * l), Vector3(0, 0.60 * h, 0.40 * l), _paint_mat())


func _build_wheels() -> void:
	var r: float = spec.tyre_radius
	var half_base: float = spec.wheelbase * 0.5
	var half_track: float = spec.track_width * 0.5
	var layout := [
		{"name": "FL", "pos": Vector3(-half_track, 0.0, -half_base)},
		{"name": "FR", "pos": Vector3(half_track, 0.0, -half_base)},
		{"name": "RL", "pos": Vector3(-half_track, 0.0, half_base)},
		{"name": "RR", "pos": Vector3(half_track, 0.0, half_base)},
	]
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.022, 0.022, 0.024)
	rubber.roughness = 0.92
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.55, 0.57, 0.62)
	rim_mat.metallic = 0.7
	rim_mat.roughness = 0.30

	for item in layout:
		# steer -> spin -> meshes, so steering and rolling compose instead of
		# fighting over the same transform.
		var steer := Node3D.new()
		steer.name = "Steer_" + String(item["name"])
		steer.position = item["pos"]
		add_child(steer)
		var spin := Node3D.new()
		spin.name = "Spin"
		steer.add_child(spin)
		_add_cylinder(spin, r, 0.215, rubber, "Tyre")
		# Protrudes 10 mm proud of the tyre on each side, so from the chase camera
		# the wheel reads as a wheel and not a black disc.
		_add_cylinder(spin, r * 0.56, 0.235, rim_mat, "Rim")
		_wheels.append({"name": String(item["name"]), "steer": steer, "spin": spin})


func _build_lights() -> void:
	var w: float = spec.body_width
	var h: float = spec.body_height
	var l: float = spec.body_length

	var lens := MatLib.emissive(Color(1.0, 0.96, 0.86), 5.0)
	_add_box("HeadL", Vector3(0.26, 0.13, 0.05), Vector3(-0.30 * w, 0.44 * h, -0.49 * l), lens)
	_add_box("HeadR", Vector3(0.26, 0.13, 0.05), Vector3(0.30 * w, 0.44 * h, -0.49 * l), lens)

	_tail_mat = MatLib.emissive(Color(1.0, 0.09, 0.05), TAIL_IDLE)
	_reverse_mat = MatLib.emissive(Color(1.0, 0.95, 0.9), REVERSE_IDLE)
	for side in [-1.0, 1.0]:
		var tail := _add_box("Tail%s" % ("L" if side < 0.0 else "R"),
			Vector3(0.30, 0.14, 0.05), Vector3(side * 0.30 * w, 0.50 * h, 0.49 * l), _tail_mat)
		_tail_lens.append(tail)
		var rev := _add_box("Reverse%s" % ("L" if side < 0.0 else "R"),
			Vector3(0.13, 0.09, 0.05), Vector3(side * 0.11 * w, 0.50 * h, 0.49 * l), _reverse_mat)
		_reverse_lens.append(rev)

	# One beam per car, not two. The two glowing lens boxes sell the "twin
	# headlight" look; a second spot light doubles the per-car lighting cost for
	# detail nobody can see from behind the car.
	var beam := SpotLight3D.new()
	beam.name = "Headlights"
	beam.position = Vector3(0, 0.52 * h, -0.48 * l)
	beam.rotation_degrees = Vector3(-7.0, 0.0, 0.0)   # -Z is forward; tilt down
	beam.spot_range = 52.0
	beam.spot_angle = 34.0
	beam.spot_angle_attenuation = 0.7
	beam.spot_attenuation = 1.1
	beam.light_color = Color(1.0, 0.95, 0.86)
	beam.light_energy = 6.5
	beam.shadow_enabled = false          # a shadowed spot per car is not worth it here
	_lights.add_child(beam)

	# A soft fill behind and above the car, so the car reads as a shape.
	#
	# Between streetlights a real car at night is a black shape, and that is
	# correct and unplayable: the player spends the entire game looking at the
	# back of their own car. This is the standard "hero light" every racing game
	# ships - dim, cool, no shadows, short range. It sits behind and above rather
	# than straight overhead, because overhead it blows the roof out to a white
	# slab and leaves the sides, which is what the player actually sees, black.
	var fill := OmniLight3D.new()
	fill.name = "HeroFill"
	# High and only slightly behind, raking down the roof and boot. It used to
	# sit at z=+3.4, which put it between the car and the chase camera, so every
	# rear-facing shot got a blown white blob across the tail instead of a car.
	fill.position = Vector3(0, 2.5, 5.4)
	fill.omni_range = 11.0
	fill.omni_attenuation = 1.6
	fill.light_color = Color(0.72, 0.80, 1.0)
	fill.light_energy = 1.5
	fill.shadow_enabled = false
	_lights.add_child(fill)


func _paint_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var col: Color = PAINTS.get(spec.default_paint, Color(0.18, 0.18, 0.19))
	m.albedo_color = col
	# Car paint is a dielectric with a clearcoat, not a metal. Metallic 0.55 was
	# the mistake: a metal car at night reflects a black sky and is therefore
	# invisible, which is precisely the failure this file exists to fix. Low
	# metallic, moderate roughness, so a streetlight actually lands on it.
	m.metallic = 0.18
	m.metallic_specular = 0.6
	m.roughness = 0.42
	return m


func _glass_mat() -> StandardMaterial3D:
	var m := MatLib.window_glass()
	m.metallic = 0.0
	m.roughness = 0.16
	return m


func _add_box(node_name: String, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = at
	mi.material_override = mat
	add_child(mi)
	return mi


func _add_cylinder(parent: Node3D, r: float, height: float, mat: Material, node_name: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var cyl := CylinderMesh.new()
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = height
	cyl.radial_segments = 12
	cyl.rings = 1
	mi.mesh = cyl
	mi.material_override = mat
	# A cylinder's axis is +Y; lay it on its side so the axis is the axle.
	mi.rotation_degrees = Vector3(0, 0, 90)
	parent.add_child(mi)


func _process(_delta: float) -> void:
	var car := get_parent() as CarBody
	if car != null and is_instance_valid(car):
		sync(car)


## Copies the physics state onto the exterior: wheels follow their own struts,
## brake lights follow the brake pedal, reverse lights follow the gear.
func sync(car: CarBody) -> void:
	for w in _wheels:
		var src: Dictionary = car.get_wheel(String(w["name"]))
		if src.is_empty():
			continue
		(w["steer"] as Node3D).rotation.y = float(src["steer_angle"])
		(w["spin"] as Node3D).rotation.x = float(src["spin_vis"])

	if _tail_mat == null:
		return
	var braking: bool = car.brake > 0.05 or car.handbrake > 0.05
	_tail_mat.emission_energy_multiplier = TAIL_BRAKING if braking else TAIL_IDLE
	_reverse_mat.emission_energy_multiplier = REVERSE_ON if car.current_gear < 0 else REVERSE_IDLE


## Lights only, for a car the player is not looking at. Same state, no mesh work.
func set_lights_on(on: bool) -> void:
	if _lights != null:
		_lights.visible = on


func wheel_nodes() -> Array:
	return _wheels
