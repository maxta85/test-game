class_name ArtKitPart
extends RefCounted
## One drawable piece of a generated object: a mesh, the material key it wears,
## and its triangle count.
##
## A building is not one mesh, because a building is a wall and a roof and a
## window and a lit window and those are five different materials. So a generator
## returns *parts*, and `ArtKitBatch` collapses parts back down by grouping
## identical (mesh, material) pairs into MultiMeshes. Generators that happen to
## be one material return a single-element array.
##
## The triangle count is carried rather than computed so a generator can report
## a budget without re-walking its own arrays, and so `standards.md` can be
## checked against reality without every check re-deriving every mesh.

var mesh: ArrayMesh
var mat: String
var tri: int


func _init(p_mesh: ArrayMesh = null, p_mat: String = "", p_tri: int = -1) -> void:
	mesh = p_mesh
	mat = p_mat
	tri = p_tri if p_tri >= 0 else ArtKitMesh.triangles(p_mesh)


## Identity for batching: the same mesh resource and the same material key. Two
## parts with the same signature go in the same MultiMesh, which is the entire
## trick.
func signature() -> String:
	return "%d|%s" % [mesh.get_rid().get_id() if mesh != null else 0, mat]


## Convenience for a generator: build the part and count its triangles.
static func of(p_mesh: ArrayMesh, p_mat: String) -> ArtKitPart:
	return ArtKitPart.new(p_mesh, p_mat)


func is_empty() -> bool:
	return mesh == null or mesh.get_surface_count() == 0


## Collapses parts that share a material into one part each.
##
## This is not a micro-optimisation, it is the difference between a draw call and
## a geometry merge: two parts of the same object wearing the same material are
## two MultiMeshes, and a fan palm assembled as five separate bark pieces is five
## draw calls for one tree. Every generator ends with `weld()` on its part list,
## and `artkit_check.gd` fails if any generator returns two parts wearing the
## same material.
##
## The returned array keeps first-appearance order, so the result is stable.
static func weld(parts: Array) -> Array:
	var order: Array = []
	var merged: Dictionary = {}
	var meshes: Dictionary = {}
	for p in parts:
		var part := p as ArtKitPart
		if part == null or part.is_empty():
			continue
		if not merged.has(part.mat):
			order.append(part.mat)
			merged[part.mat] = []
		(merged[part.mat] as Array).append(part.mesh)
	var out: Array = []
	for mat in order:
		var list: Array = merged[mat]
		var mesh: ArrayMesh = list[0] if list.size() == 1 else ArtKitMesh.merge(list, [])
		out.append(ArtKitPart.new(mesh, String(mat)))
	return out
