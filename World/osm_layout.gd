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


static func _run_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	return total


## Middle of the network, in metres.
static func _centre() -> Vector2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in corridors():
		for p in c["points"]:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return (lo + hi) * 0.5


## The anchor street's centreline run: the arterial whose midpoint is nearest the
## middle of the network, among arterials long enough to race on.
##
## "Longest arterial" is the obvious pick and it is wrong here. In this fetch the
## longest is Hoare Street, 1408 m, but its midpoint sits 1019 m from the centre
## of the city - a start line anchored to it opens the race in an empty corner.
## Measured across the candidates, Aumuller Street wins on both counts: 825 m of
## real arterial 553 m from the middle. See Tools/diag_osm.gd, which prints the
## candidate table this rule is derived from.
const MIN_ANCHOR_LEN := 200.0

## { name: String, pts: PackedVector2Array } for the chosen street, or {}.
static func anchor() -> Dictionary:
	var mid := _centre()
	var best := {}
	var best_score := INF
	for c in corridors():
		if int(c["class"]) < RoadGraph.RoadClass.ARTERIAL:
			continue
		var pts: PackedVector2Array = c["points"]
		if pts.size() < 2 or _run_length(pts) < MIN_ANCHOR_LEN:
			continue
		var centre_of_run: Vector2 = (pts[0] + pts[pts.size() - 1]) * 0.5
		# Nearest first; length breaks ties, so two equally central arterials
		# resolve to the longer one.
		var score: float = centre_of_run.distance_to(mid) - _run_length(pts) * 0.01
		if score < best_score:
			best_score = score
			best = {"name": String(c["name"]), "pts": pts}
	return best


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
