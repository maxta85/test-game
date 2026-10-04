class_name OSMLayout
extends RefCounted
## Real Cairns streets, in the shape World/road_graph.gd already consumes.
##
## The corridor format is ManundaLayout's, unchanged. That is the whole point:
## `RoadGraph.build()` computes intersections itself, so every downstream system
## (world geometry, traffic, race routes, the racing line, kerbs, lane markings,
## streetlights) reads real Cairns without knowing anything changed. A .glb from
## a marketplace would have to be reverse-engineered back into corridors; this
## goes to the source data instead.
##
## Regenerate with:  python3 Tools/osm_cairns.py
## Data (c) OpenStreetMap contributors, ODbL 1.0.

const MAP_PATH := "res://assets/maps/cairns_map.json"

static var _data: Variant = null
static var _corridors: Variant = null


## The parsed map file, or an empty dictionary if it is missing or malformed.
static func data() -> Dictionary:
	if _data == null:
		_data = _read()
	return _data if _data is Dictionary else {}


static func available() -> bool:
	return not corridors().is_empty()


## Corridors in RoadGraph.build() format:
##   { name: String, class: RoadClass, points: Array[Vector2] }
static func corridors() -> Array:
	if _corridors != null:
		return _corridors
	var out: Array = []
	for c in data().get("corridors", []):
		var raw: Array = c.get("points", [])
		if raw.size() < 2:
			continue
		var pts := PackedVector2Array()
		for p in raw:
			pts.append(Vector2(float(p[0]), float(p[1])))
		out.append({
			"name": String(c.get("name", "")),
			"class": int(c.get("class", RoadGraph.RoadClass.STREET)),
			"points": pts,
		})
	_corridors = out
	return out


static func stats() -> Dictionary:
	return data().get("stats", {})


## The anchor street's centreline run. The rule lives in World/anchor_choice.gd
## because it is a decision about the city, not a projection detail: the anchor is
## the street the race network starts on, so the free-roam grid and the grid
## RaceDirector builds from the route are the same piece of road. It used to be
## "the arterial nearest the middle of the bounding box", which any outlying
## corridor could move - Gordon Street in Earlville moved it 300 m and handed the
## anchor to Alfred Street. Tools/diag_osm.gd prints both rules side by side.
##
## Returns { name, pts } as before, so every caller is unaffected.
static func anchor() -> Dictionary:
	var pick: Dictionary = AnchorChoice.pick(corridors())
	if pick.is_empty():
		return {}
	return {"name": String(pick["name"]), "pts": pick["pts"]}


## Midpoint of the anchor street and the direction of travel there, as
## { pos: Vector3, dir: Vector2 }. Public because the camera presets aim at it.
static func start_line() -> Dictionary:
	var a: Dictionary = anchor()
	var pts: PackedVector2Array = a.get("pts", PackedVector2Array())
	if pts.size() < 2:
		return {"pos": Vector3.ZERO, "dir": Vector2(1, 0)}
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	var want := total * 0.5
	for i in pts.size() - 1:
		var seg: float = pts[i].distance_to(pts[i + 1])
		if want <= seg or i == pts.size() - 2:
			var u: float = 0.0 if seg == 0.0 else want / seg
			var lo := pts[i].lerp(pts[i + 1], u)
			return {"pos": Vector3(lo.x, 0.0, lo.y), "dir": (pts[i + 1] - pts[i]).normalized()}
		want -= seg
	return {"pos": Vector3.ZERO, "dir": Vector2(1, 0)}


## Steps `metres` back along the anchor street from the start line. Distances,
## not fractions of the polyline: a fraction of a 250 m street and a fraction of
## a 1400 m one are not the same place, and the car meet ended up 3 m from the
## grid until this was a distance.
static func _back(metres: float) -> Vector3:
	var s := start_line()
	var p: Vector3 = s["pos"]
	var d: Vector2 = s["dir"]
	return p - Vector3(d.x, 0.0, d.y) * metres


## Start grid, staggered back from the start line along the anchor street.
static func start_grid_position(slot: int) -> Vector3:
	var s := start_line()
	var d: Vector2 = s["dir"]
	var side := Vector2(-d.y, d.x)
	var p := _back(18.0 + float(slot / 2) * 9.0)
	return p + Vector3(side.x, 0.0, side.y) * (float(slot % 2) * 4.0 - 2.0)


## Car meet: on the anchor street, 70 m short of the start line. It has to be on
## the carriageway. The old Manunda position was a mid-block coordinate that may
## have been inside a house, and offsetting sideways off a real street just walks
## into whatever building is there.
static func car_meet_position() -> Vector3:
	return _back(70.0)


## Load via ResourceLoader so this works in an exported PCK (where a .json is an
## imported JSON resource, not a loose file), falling back to a raw read for
## source runs. Returns {} rather than failing the boot.
static func _read() -> Dictionary:
	if ResourceLoader.exists(MAP_PATH):
		var res := ResourceLoader.load(MAP_PATH)
		if res is JSON:
			return (res as JSON).data
	if FileAccess.file_exists(MAP_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_PATH))
		if parsed is Dictionary:
			return parsed
	push_warning("OSMLayout: no map at %s - run Tools/osm_cairns.py" % MAP_PATH)
	return {}
