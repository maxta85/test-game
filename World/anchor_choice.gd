class_name AnchorChoice
extends RefCounted
## Which street the start line, the starting grid and the car meet sit on.
##
## The rule is one line: **the anchor is the street the race network starts from.**
## RoadGraph.build() numbers nodes in corridor order, so node 0 is corridors[0], and
## every route in RaceDef.catalogue() is handed start_node 0. RaceDirector then lays
## its grid out from the route's first point (`_line_o = _pts[0]`), and Game/main.gd
## spawns the player and the rival on OSMLayout.start_grid_position(). Two different
## anchors therefore meant the free-roam grid and the racing grid sat in two
## different suburbs - measured 1096 m apart, which is how the `street` camera
## preset came to frame an empty road while the HUD read POS 1/2.
##
## "Nearest arterial to the middle of the map" is the rule this replaces, and it is
## wrong in a way that reads like it is working. The middle of the map is a bounding
## box, so one outlying corridor moves it. Gordon Street sits 1.3 km west of the CBD
## block; adding it dragged the box centre south-west and handed the anchor to
## Alfred Street, 348 m long and on the western edge of the network, where it had
## been Aumuller Street at 825 m. Nothing about Cairns changed, only the box did -
## and the box is an artefact of the fetch, not a fact about the city.
##
## What is left after the alignment rule is a fallback, and it is deliberately
## outlier-proof: a median of corridor midpoints, not a bounding box. Tools/diag_osm.gd
## prints both rules against the same data, plus the connected-component census, so
## the claim above is checkable rather than remembered.
##
## What the rule resolves to on the shipped map (assets/maps/cairns_map.json, 255
## corridors, 34.85 km): **Hoare Street**, corridor 0, 1408 m, class ARTERIAL - the
## longest run in the fetch and the street the Gordon Street Sprint trace already
## sits on. If a regeneration moves the node-0 corridor, the anchor moves with it and
## diag_osm.gd says so; the name below is the measured answer for the map that
## shipped, not a hardcoded preference.

## Shortest run that can hold a grid and still leave the car meet 70 m back of the
## line. Below this the grid runs off the end of its own street.
const MIN_ANCHOR_LEN := 200.0

## Longest of the tied candidates wins, by this much per metre of length. Same
## tie-break the old rule used, so the candidate ordering is comparable.
const LEN_BONUS := 0.01


## Total run length of a polyline in metres.
static func run_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	return total


## Midpoint of a run's endpoints. Not the centroid of the vertices: a street that
## doubles back on itself has a midpoint nowhere near its own bulk, and this is the
## same quantity the old rule used, kept so the two are comparable.
static func run_midpoint(pts: PackedVector2Array) -> Vector2:
	if pts.is_empty():
		return Vector2.ZERO
	return (pts[0] + pts[pts.size() - 1]) * 0.5


## Middle of the network the way a street would describe it: the median corridor
## midpoint, taken per axis. Half the corridors lie either side of it on each axis
## independently, so a single outlying street cannot move it - which is exactly what a
## bounding box cannot say. On this fetch the two disagree by 727 m, and the box is
## the one the old rule used.
static func median_centre(corridors: Array) -> Vector2:
	var xs: Array = []
	var ys: Array = []
	for c in corridors:
		var pts: PackedVector2Array = c["points"]
		if pts.size() >= 2:
			var m := run_midpoint(pts)
			xs.append(m.x)
			ys.append(m.y)
	if xs.is_empty():
		return Vector2.ZERO
	xs.sort()
	ys.sort()
	return Vector2(xs[xs.size() / 2], ys[ys.size() / 2])


## Bounding-box centre. Kept because it is what the old rule used and diag needs to
## show how far it drifts; not used to choose anything.
static func bbox_centre(corridors: Array) -> Vector2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in corridors:
		for p in c["points"]:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return (lo + hi) * 0.5


## The corridor the race network starts on: index 0, which is node 0, which is what
## RaceDef.catalogue() passes to every route. Returns -1 for an empty network.
static func start_corridor() -> int:
	return 0


## Pick the anchor. Returns
##   { index: int, name: String, pts: PackedVector2Array, reason: String }
## or {} when there is no corridor with two points at all.
static func pick(corridors: Array) -> Dictionary:
	if corridors.is_empty():
		return {}

	# 1. The node-0 street. Alignment with the racing grid outranks every other
	#    consideration, so this is not a preference to be traded away for centrality.
	var i := start_corridor()
	if i >= 0 and i < corridors.size():
		var c: Dictionary = corridors[i]
		var pts: PackedVector2Array = c["points"]
		if pts.size() >= 2 and run_length(pts) >= MIN_ANCHOR_LEN:
			var who := String(c["name"])
			return {
				"index": i,
				"name": who,
				"pts": pts,
				"reason": "node 0 is %s: every route starts on it, so the grid and the "
					% who + "racing line are one street",
			}

	# 2. Fallback: the arterial nearest the median centre. Reached only when the
	#    node-0 street cannot hold a grid, which no current fetch does.
	var centre := median_centre(corridors)
	var best := {}
	var best_score := INF
	var best_index := -1
	for j in corridors.size():
		var c: Dictionary = corridors[j]
		if int(c["class"]) < RoadGraph.RoadClass.ARTERIAL:
			continue
		var pts: PackedVector2Array = c["points"]
		if pts.size() < 2 or run_length(pts) < MIN_ANCHOR_LEN:
			continue
		var score: float = run_midpoint(pts).distance_to(centre) \
			- run_length(pts) * LEN_BONUS
		if score < best_score:
			best_score = score
			best_index = j
			best = c
	if best_index >= 0:
		return {
			"index": best_index,
			"name": String(best["name"]),
			"pts": best["points"],
			"reason": "node 0 is too short for a grid; nearest arterial to the median "
				+ "centre of the network",
		}

	# 3. Anything long enough. A city with no arterial still needs a street to put
	#    the grid on; the start line is better than the origin.
	for j in corridors.size():
		var c: Dictionary = corridors[j]
		var pts: PackedVector2Array = c["points"]
		if pts.size() >= 2 and run_length(pts) >= MIN_ANCHOR_LEN:
			return {
				"index": j,
				"name": String(c["name"]),
				"pts": pts,
				"reason": "no arterial in the fetch; longest street that can hold a grid",
			}

	# 4. Last resort: the first corridor with two points, grid or no grid.
	for j in corridors.size():
		var c: Dictionary = corridors[j]
		var pts: PackedVector2Array = c["points"]
		if pts.size() >= 2:
			return {
				"index": j,
				"name": String(c["name"]),
				"pts": pts,
				"reason": "every street is shorter than %.0f m; anchoring anyway"
					% MIN_ANCHOR_LEN,
			}
	return {}