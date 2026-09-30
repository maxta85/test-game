class_name ArtKitBatch
extends RefCounted
## Turns thousands of generated props and buildings into a handful of draw calls.
##
## ## Why this file is the most important one in the kit
##
## The world has 2198 buildings, ~1600 palms and ~1300 streetlights. One node
## each is 5000 draw calls before anything is even visible, which on a forward+
## renderer is a 3 fps scene. One MultiMesh per (mesh, material) pair is a few
## dozen, and the GPU cost becomes vertex-bound instead of draw-call-bound. The
## engine has no Nanite and no BVH (see `ENGINE_DECISION.md`), so this class is
## the substitute, and it belongs in the artkit rather than in each consumer -
## written four times, four consumers get it subtly wrong.
##
## ## How to use it
##
##     var batch := ArtKitBatch.new("Suburb")
##     for b in footprints:
##         batch.add_array(ArtKitBuildings.qld_house(seed), xform)
##     batch.build(world)                      # -> ArtKitBatchStats
##
## `add_array` takes the parts a generator returned and one transform for the
## whole object. `build()` groups every accumulated part by signature and emits
## one MultiMeshInstance3D per group under a single parent node.
##
## ## The rules that make this work, and that a caller can break
##
## 1. **Meshes must be shared, not copied per instance.** If a caller passes
##    `mesh.duplicate()` into a part, the signatures stop matching and the
##    batching silently collapses back to one draw call per instance. Nothing
##    will tell you; the frame rate is the only symptom. `ArtKitProps.variant()`
##    exists to hand out shared meshes.
## 2. **Materials must come from `ArtKitMaterials.get_()`.** Two equal-by-value
##    StandardMaterial3D instances are two draw calls.
## 3. **Uniform instance scale only.** `ArtKitBatch` does not normalise
##    transforms; a non-uniform scale shears the normals of a baked mesh.
## 4. **Per-instance colour is not supported**, deliberately. A MultiMesh can
##    take per-instance custom data, but then every material needs a shader
##    variant and a uniform-array upload, and the win is not worth the cost at
##    this count. Variation is achieved by *mesh* variant and *material* variant
##    instead, which is what `standards.md` budgets for.
##
## ## The two strategies, and which one you want
##
## **`build()` — instancing.** Right for anything repeated: 1600 palms from 3
## shared meshes, 1300 streetlights, wire spans. The meshes must be *shared
## resources*; get that from `ArtKitProps.variant()` / `ArtKitBuildings.variant()`,
## never from calling a generator again in a loop, because a regenerated mesh is a
## new resource and the signatures stop matching.
##
## **`build_merged()` — baking.** Right for anything unique: the 2198 real OSM
## footprints, and any building generated from its own seed. These meshes are
## different every time, so a MultiMesh per building is 2198 draw calls and
## instancing buys nothing. Baking the transforms into one mesh per material gives
## one draw call per material instead, at the cost of not being able to move an
## instance afterwards. Static city geometry does not need to move.
##
## Instancing first is the wrong instinct here. A merged 2198-building suburb is
## ~5 draw calls and ~1.5 M triangles; the same suburb as MultiMeshes is 2198 draw
## calls and the same triangles. Draw calls are the scarcer resource.
##
## ## What it does not do
##
## No LOD, no occlusion culling, no light culling, no spatial partitioning. Both
## strategies are one draw call for the batch, so a culling scheme would have to
## split batches to pay off, and splitting a batch per district is a bigger win
## than per-object LOD at this count. `custom_aabb` is set from the collected
## transforms so the whole batch is not frustum-culled by accident - see
## `set_bounds()`.

var _groups: Dictionary = {}     ## signature -> {mesh, mat, xforms: Array[Transform3D]}
var _label: String = "ArtKitBatch"
var _bounds: AABB = AABB()
var _have_bounds: bool = false


func _init(label: String = "ArtKitBatch") -> void:
	_label = label


## One part, one placement.
func add(part: ArtKitPart, xform: Transform3D) -> void:
	if part == null or part.is_empty():
		return
	var sig := part.signature()
	if not _groups.has(sig):
		_groups[sig] = {"mesh": part.mesh, "mat": part.mat, "xforms": []}
	var g: Dictionary = _groups[sig]
	var list: Array = g["xforms"]
	list.append(xform)
	_grow_bounds(part.mesh, xform)


## A whole generated object: every part at the same transform.
func add_array(parts: Array, xform: Transform3D) -> void:
	for p in parts:
		add(p as ArtKitPart, xform)


## The same object, placed once per transform. The common case for a scatter -
## one palm, 1600 places, one array of transforms.
func add_array_at(parts: Array, xforms: Array) -> void:
	for x in xforms:
		add_array(parts, x as Transform3D)


## Instance count of the whole batch, across every group.
func instances() -> int:
	var n := 0
	for sig in _groups:
		var g: Dictionary = _groups[sig]
		var list: Array = g["xforms"]
		n += list.size()
	return n


## How many MultiMeshes `build()` will emit. This is the draw-call number, and
## it is the thing `standards.md` budgets.
func group_count() -> int:
	return _groups.size()


## Triangles in the scene this batch represents. This is the number that decides
## whether a MultiMesh is affordable.
func triangles() -> int:
	var n := 0
	for sig in _groups:
		var g: Dictionary = _groups[sig]
		var list: Array = g["xforms"]
		n += ArtKitMesh.triangles(g["mesh"]) * list.size()
	return n


## Emits the MultiMeshes under `parent` and returns a stats dictionary. The
## parent gets one child node; that child gets one MultiMeshInstance3D per group.
## A group of zero is skipped, so a batch that collected nothing emits nothing
## rather than an empty MultiMesh that still costs a draw call.
func build(parent: Node, cull_bounds: AABB = AABB()) -> Node3D:
	var holder := Node3D.new()
	holder.name = _label
	var ordered := _groups.keys()
	ordered.sort()
	for sig in ordered:
		var g: Dictionary = _groups[sig]
		var list: Array = g["xforms"]
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = g["mesh"]
		mm.instance_count = list.size()
		# Without an explicit AABB a MultiMesh is culled against a box derived
		# from the *first* instance, which is how a whole suburb silently
		# disappears when you turn away from one particular house.
		mm.custom_aabb = cull_bounds if cull_bounds.size.length() > 0.0 else _bounds
		for i in list.size():
			mm.set_instance_transform(i, list[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var mat: StandardMaterial3D = ArtKitMaterials.get_(String(g["mat"]))
		if mat != null:
			# material_override, not a surface override: the shared mesh has no
			# surface material, and this is one assignment per draw call.
			mmi.material_override = mat
		holder.add_child(mmi)
	if parent != null and is_instance_valid(parent):
		parent.add_child(holder)
	return holder


## Bakes every accumulated part into world space and emits one mesh per material.
##
## This is the strategy for geometry that is unique per instance, where a MultiMesh
## buys nothing because there is nothing to share. One `MeshInstance3D` per
## material, whatever the instance count.
func build_merged(parent: Node) -> Node3D:
	var holder := Node3D.new()
	holder.name = _label + "_merged"
	# Keyed by material, not by signature: several groups can share a material
	# (four roof-iron variants, six wall colours) and the whole point is that they
	# end up in one node.
	var tools: Dictionary = {}
	for sig in _groups:
		var g: Dictionary = _groups[sig]
		var list: Array = g["xforms"]
		var key := String(g["mat"])
		if not tools.has(key):
			tools[key] = ArtKitMesh.begin()
		var st: SurfaceTool = tools[key]
		var mesh: ArrayMesh = g["mesh"]
		for x in list:
			ArtKitMesh.blit(st, mesh, x as Transform3D)
	var names := tools.keys()
	names.sort()
	for key in names:
		var mi := MeshInstance3D.new()
		mi.name = key
		mi.mesh = ArtKitMesh.commit(tools[key])
		var mat: StandardMaterial3D = ArtKitMaterials.get_(String(key))
		if mat != null:
			mi.material_override = mat
		holder.add_child(mi)
	if parent != null and is_instance_valid(parent):
		parent.add_child(holder)
	return holder


## Overrides the culling box for the whole batch. Use it when the batch covers
## something whose extents the collected transforms do not describe - a skyline
## 2 km away, or a wire span that stretches off the map edge.
func set_bounds(aabb: AABB) -> void:
	_bounds = aabb
	_have_bounds = true


func bounds() -> AABB:
	return _bounds


func _grow_bounds(mesh: ArrayMesh, xform: Transform3D) -> void:
	if _have_bounds:
		return
	var aabb := mesh.get_aabb()
	if aabb.size.length() <= 0.0:
		return
	var t := xform * aabb
	if t.size.length() <= 0.0:
		return
	_bounds = t if _bounds.size.length() <= 0.0 else _bounds.merge(t)


# ------------------------------------------------------------------ transforms

## The transform that puts a prop in the world. Every generator in the kit is
## built with the origin at the footprint centre on the ground, so placement is
## a position and a yaw, with no correction offset. `yaw` in radians, 0 means
## +Z is the front.
static func place(position: Vector3, yaw: float = 0.0, scale: float = 1.0) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)).scaled(Vector3.ONE * scale),
			position)


## Yaw that makes a prop's +Z face `towards` from `at`. Almost every prop in the
## world wants to face something - a sign faces the road, a bin faces a kerb, a
## bench faces the street.
static func facing(at: Vector3, towards: Vector3) -> float:
	var d := towards - at
	if d.length_squared() < 0.0001:
		return 0.0
	return atan2(d.x, d.z)


## A deterministic yaw from a seed, for scatter that should not look combed.
static func scatter_yaw(seed_value: int) -> float:
	return float((seed_value * 2654435761) % 6283) / 1000.0
