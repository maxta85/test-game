class_name ArtKitScatter
extends Node3D
## The consumer. One node, added to the world, that turns a placement list into
## the handful of draw calls the kit's cost model assumes.
##
## ## The line the world builder needs
##
##     ArtKitScatter.attach(self, placements)
##
## That is the whole integration. Everything the kit knows that a caller would
## otherwise get wrong lives here: which strategy (instancing or baking) a given
## object needs, which mesh variant it wears, and the rule that variant choice
## must be positional rather than random so two runs over the same placements
## produce the same city.
##
## ## What it takes
##
## `placements` is an array whose elements are either:
##
## - a **`PackedVector2Array`** - an OSM footprint in metres, baked. The common
##   case for the road agent's data, so it needs no wrapping.
## - a **`Dictionary`** for anything else:
##   - `{"footprint": PackedVector2Array, "storeys": 2, "lit": 0.4, "seed": 7}`
##   - `{"prop": "palm_coco", "pos": Vector3, "yaw": 0.4, "scale": 1.0, "seed": 7}`
##   - `{"building": "qld_house", "pos": Vector3, "yaw": 0.0, "seed": 7}`
##
## `seed` is optional everywhere; the element's index is the fallback. Variant
## choice is `posmod(seed, VARIANTS)`, so it is derived from the data rather
## than drawn from an RNG - a consumer that used an RNG would be untestable, and
## the kit's own check is only meaningful because placements are deterministic.
##
## Anything malformed is skipped and reported in the returned stats rather than
## crashing the world build. A scatter that throws halfway through leaves a
## half-built suburb, and a caller cannot tell a bad entry from a bug in the kit.
##
## ## Why it is here and not in the world builder
##
## Because the footgun this kit is built around is calling a generator in a
## placement loop instead of `variant()`, which silently produces one unique mesh
## per object and turns 1600 palms into 1600 draw calls. Nothing errors. The
## frame rate is the only symptom. A caller that has to know that rule is a
## caller that will eventually not know it, so the rule is enforced here once.

## Filled by `populate()`, and returned by it. Keys:
## `nodes` (draw calls), `instances`, `triangles`, `props`, `buildings`,
## `skipped` (array of strings).
var stats: Dictionary = {}


## The one-line entry point. Creates the node, parents it under `parent`,
## populates it, and returns it - so a caller can keep the node and read
## `stats` off it, or ignore the return value entirely.
static func attach(parent: Node, placements: Array) -> ArtKitScatter:
	var node := ArtKitScatter.new()
	node.name = "ArtKitScatter"
	if parent != null and is_instance_valid(parent):
		parent.add_child(node)
	node.populate(placements)
	return node


## Feeds every placement into the right batch and builds both. Props go into the
## instanced batch, buildings and footprints into the baked one: a building is
## unique geometry, so a MultiMesh per building buys nothing and baking collapses
## the whole city to one node per material.
func populate(placements: Array) -> Dictionary:
	var instanced := ArtKitBatch.new("props")
	var baked := ArtKitBatch.new("buildings")
	var skipped: Array[String] = []
	var n_props := 0
	var n_buildings := 0

	for i in placements.size():
		var entry: Variant = placements[i]
		# A bare polygon is the OSM case, and taking it as-is is the difference
		# between a one-line integration and a dictionary per building. A polygon
		# is already in world coordinates, so it needs no transform.
		if entry is PackedVector2Array:
			if _add_footprint(baked, entry, Transform3D.IDENTITY, i, skipped):
				n_buildings += 1
			continue
		if not (entry is Dictionary):
			skipped.append("#%d: expected a footprint or a dictionary" % i)
			continue
		var d: Dictionary = entry
		if d.has("prop"):
			if _add_prop(instanced, d, i, skipped):
				n_props += 1
		elif d.has("footprint"):
			# A footprint polygon is already in world coordinates, so `pos` is
			# optional here - the OSM data arrives that way.
			if d.has("pos") and not _valid_transform(d, i, skipped):
				continue
			var xf := _xform(d, i) if d.has("pos") else Transform3D.IDENTITY
			if _add_footprint(baked, d, xf, i, skipped):
				n_buildings += 1
		elif d.has("building"):
			if _add_building(baked, d, i, skipped):
				n_buildings += 1
		else:
			skipped.append("#%d: no prop, building or footprint key" % i)

	# A batch that collected nothing emits nothing rather than an empty draw call.
	var prop_nodes := 0
	if instanced.instances() > 0:
		prop_nodes = instanced.build(self).get_child_count()
	var building_nodes := 0
	if baked.instances() > 0:
		building_nodes = baked.build_merged(self).get_child_count()

	stats = {
		"nodes": prop_nodes + building_nodes,
		"prop_nodes": prop_nodes,
		"building_nodes": building_nodes,
		"instances": instanced.instances() + baked.instances(),
		"triangles": instanced.triangles() + baked.triangles(),
		"props": n_props,
		"buildings": n_buildings,
		"skipped": skipped,
	}
	return stats


## The shared, memoised path. `ArtKitProps.variant()` is the whole point: calling
## `palm_coco()` here instead would build a fresh ArrayMesh per placement and the
## signatures would all differ, which is the silent 1600-draw-call failure the
## kit documents at length.
##
## Note the wrap. `variant()` is only memoised per index *within* the variant
## set - pass it the raw placement index and each one generates its own mesh, so
## every placement becomes its own draw call. Measured while writing this: 600
## placements, unwrapped, 1202 draw calls; wrapped, 22.
func _add_prop(batch: ArtKitBatch, d: Dictionary, i: int, skipped: Array[String]) -> bool:
	var name := String(d.get("prop", ""))
	if not ArtKitProps.has(name):
		skipped.append("#%d: '%s' is not a registered prop" % [i, name])
		return false
	if not _valid_transform(d, i, skipped):
		return false
	var v := posmod(_seed(d, i), ArtKitProps.VARIANTS)
	batch.add_array(ArtKitProps.variant(name, v), _xform(d, i))
	return true


## `ArtKitBuildings.variant()` for the same reason, over the wider house set.
func _add_building(batch: ArtKitBatch, d: Dictionary, i: int, skipped: Array[String]) -> bool:
	var name := String(d.get("building", ""))
	if not ArtKitBuildings.has(name):
		skipped.append("#%d: '%s' is not a registered building" % [i, name])
		return false
	if not _valid_transform(d, i, skipped):
		return false
	var v := posmod(_seed(d, i), ArtKitBuildings.HOUSE_VARIANTS)
	batch.add_array(ArtKitBuildings.variant(name, v), _xform(d, i))
	return true


## The one place a raw generator is called on purpose. Every footprint is a
## different mesh, so there is no shared resource to hand out and no signature to
## match - `variant()` would be meaningless here. This is why the batching falls
## to `build_merged()` on the other side.
func _add_footprint(batch: ArtKitBatch, entry: Variant, xform: Transform3D,
		i: int, skipped: Array[String]) -> bool:
	# `as` does not narrow a Variant holding a built-in type, so the two accepted
	# shapes are peeled apart explicitly. `footprint` is type-checked rather than
	# cast: a caller that hands over the wrong thing under that key gets a
	# skipped entry, not a hard cast error halfway through a world build.
	var poly := PackedVector2Array()
	var opts := {}
	if entry is PackedVector2Array:
		poly = entry
	elif entry is Dictionary:
		opts = entry
		var raw: Variant = opts.get("footprint", null)
		if not (raw is PackedVector2Array):
			skipped.append("#%d: 'footprint' is not a PackedVector2Array" % i)
			return false
		poly = raw
	else:
		skipped.append("#%d: expected a footprint or a dictionary" % i)
		return false
	# A degenerate polygon is the map's problem, not a crash: `wrap_footprint`
	# returns an empty array and the entry is simply not placed.
	if poly.size() < 3:
		skipped.append("#%d: footprint has %d points" % [i, poly.size()])
		return false
	var storeys := maxi(1, int(opts.get("storeys", 1)))
	var lit := clampf(float(opts.get("lit", 0.4)), 0.0, 1.0)
	var parts := ArtKitBuildings.wrap_footprint(poly, storeys, lit, _seed(opts, i))
	if parts.is_empty():
		skipped.append("#%d: wrap_footprint produced nothing" % i)
		return false
	batch.add_array(parts, xform)
	return true


## Uniform instance scale only: `ArtKitBatch` does not normalise transforms, and a
## non-uniform scale shears the normals of a baked mesh. So scale is a scalar.
##
## Validation is a separate pass on purpose. Returning `IDENTITY` to mean "this
## was bad" is indistinguishable from a legitimate placement at the origin, and
## that ambiguity placed rejected props at the world origin instead of skipping
## them - measured, not reasoned: two malformed entries got through before this
## was split.
func _valid_transform(d: Dictionary, i: int, skipped: Array[String]) -> bool:
	if not d.has("pos"):
		# A prop or a building with no position is a caller bug, not a default:
		# the node is built immediately, so nobody can move it afterwards, and a
		# silent fallback to the origin stacks 600 props in one place.
		skipped.append("#%d: no pos" % i)
		return false
	if not (d["pos"] is Vector3):
		skipped.append("#%d: pos is not a Vector3" % i)
		return false
	if float(d.get("scale", 1.0)) <= 0.0:
		skipped.append("#%d: scale %f is not positive" % [i, float(d.get("scale", 1.0))])
		return false
	return true


func _xform(d: Dictionary, i: int) -> Transform3D:
	return ArtKitBatch.place(d["pos"] as Vector3,
			float(d.get("yaw", ArtKitBatch.scatter_yaw(i))), float(d.get("scale", 1.0)))


## Index-derived, so the same placement list always yields the same city. An RNG
## here would make the kit's own acceptance run meaningless.
func _seed(d: Dictionary, i: int) -> int:
	return int(d.get("seed", i))
