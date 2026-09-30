class_name OSMWater
extends RefCounted
## The real water in the extraction, in the shape Systems/water consumes it.
##
## assets/maps/cairns_water.json holds two different things and the split is the
## whole point of this file:
##
##   - `water`    - 5 closed rings. Real polygons with a real area, and the only
##                   water this project can put a surface on.
##   - `rivers`   - 26 open centrelines. Lines where water was, NOT water bodies.
##
## The extractor is explicit about the second group ("an open centreline is not a
## water body, it is a line where water was; closing it by hand invents a shape
## nobody mapped, and a wrong polygon is worse than a missing one"), and it is
## right: `width_m` is null on 26 of 26 centrelines, so a surface built from one
## would have to invent its own width. `centrelines()` reports them and
## `surfaced_centrelines()` returns the ones that could be built without that
## guess, which is none of them. Measured, not assumed - see Tests/test_water.gd.
##
## One line to wire in, from WorldBuilder.build():
##     add_child(OSMWater.surface(graph, self._terrain_height))
##
## `ground` is a Callable(x, z) -> height, supplied by the caller rather than
## read from WorldBuilder: that file is being edited next door, and water that
## reaches into its internals goes down with the next rename. Systems/water
## WaterSurface does the geometry, the seating on the terrain and the material.
##
## Regenerate with:  python3 Tools/osm_cairns.py
## Data (c) OpenStreetMap contributors, ODbL 1.0.

const DATA_PATH := "res://assets/maps/cairns_water.json"

static var _data: Variant = null
static var _bodies: Array = []
static var _centrelines: Array = []


## The parsed file, or {} if it is missing or malformed.
static func data() -> Dictionary:
	if _data == null:
		_data = _read()
	return _data if _data is Dictionary else {}


static func available() -> bool:
	return not bodies().is_empty()


## Every closed water polygon, closing point dropped and wound counter-clockwise
## in (x, z) so the signed area is positive. Same convention as OSMBuildings, so
## the two agree on what a ring is.
##
## NOT keyed by osm_id: relation 18504432 is the Barron and arrives as two rings.
static func bodies() -> Array:
	if not _bodies.is_empty():
		return _bodies
	var out: Array = []
	for w in data().get("water", []):
		var ring := _ring(w.get("polygon", []))
		if ring.size() < 3:
			continue
		out.append({
			"id": int(w.get("osm_id", 0)),
			"kind": _text(w.get("kind", null)),
			"ring": ring,
			"area": absf(_area(ring)),
		})
	_bodies = out
	return out


## The open centrelines, in OSMLayout corridor point order. `width_m` is kept as
## it arrived, null included: it is the measurement that says these cannot be
## surfaced yet.
static func centrelines() -> Array:
	if not _centrelines.is_empty():
		return _centrelines
	var out: Array = []
	for r in data().get("rivers", []):
		var pts := PackedVector2Array()
		for p in r.get("centreline", []):
			pts.append(Vector2(float(p[0]), float(p[1])))
		if pts.size() < 2:
			continue
		var w: Variant = r.get("width_m")
		out.append({
			"id": int(r.get("osm_id", 0)),
			# 21 of the 26 arrive with no name at all, and `String(null)` is an
			# error rather than an empty string.
			"name": _text(r.get("name", null)),
			"kind": _text(r.get("kind", null)),
			"width_m": null if w == null else float(w),
			"points": pts,
			"length": _run_length(pts),
		})
	_centrelines = out
	return out


## The centrelines that carry a width, so a surface could be built from one
## without inventing it. Empty in this fetch: 0 of 26 have a `width` tag.
static func surfaced_centrelines() -> Array:
	var out: Array = []
	for c in centrelines():
		if c["width_m"] != null:
			out.append(c)
	return out


## The open water features: everything a river or a pool is called in this file.
static func feature_count() -> int:
	return data().get("stats", {}).get("water", 0)


static func stats() -> Dictionary:
	return data().get("stats", {})


static func bbox() -> Dictionary:
	return data().get("bbox", {})


## The self-contained node, ready for the world builder to add. `ground` is a
## Callable(x: float, z: float) -> float; it is the same height function the
## terrain mesh was built from, so the water sits on the ground rather than on a
## guessed y.
static func surface(graph: RoadGraph, ground: Callable) -> Node3D:
	return WaterSurface.new().setup(graph, ground)


# ------------------------------------------------------------------- parsing

## A JSON string field that is allowed to be null.
static func _text(v: Variant) -> String:
	return "" if v == null else String(v)

## A closed OSM ring as a PackedVector2Array: the repeated closing point dropped
## and the winding normalised, because the triangulator downstream cares which
## way round the vertices are and OSM hands back both.
static func _ring(poly: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in poly:
		pts.append(Vector2(float(p[0]), float(p[1])))
	if pts.size() >= 2 and pts[0].is_equal_approx(pts[pts.size() - 1]):
		pts.remove_at(pts.size() - 1)
	if pts.size() >= 3 and _area(pts) < 0.0:
		pts.reverse()
	return pts


## Twice the signed area, in the (x, z) plane.
static func _area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var u := ring[i]
		var v := ring[(i + 1) % ring.size()]
		a += u.x * v.y - v.x * u.y
	return a * 0.5


static func _run_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	return total


## Load via ResourceLoader so this works in an exported PCK (where a .json is an
## imported JSON resource, not a loose file), falling back to a raw read for
## source runs. Returns {} rather than failing the boot.
static func _read() -> Dictionary:
	if ResourceLoader.exists(DATA_PATH):
		var res := ResourceLoader.load(DATA_PATH)
		if res is JSON:
			return (res as JSON).data
	if FileAccess.file_exists(DATA_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if parsed is Dictionary:
			return parsed
	push_warning("OSMWater: no water data at %s - run Tools/osm_cairns.py" % DATA_PATH)
	return {}
