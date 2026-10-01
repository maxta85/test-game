class_name Minimap
extends Control
## The map, drawn from the real road network.
##
## There was no map in this game at all. The player was dropped into 31.7 km of
## real Cairns street with no way to see the shape of anything - not where they
## were, not which way they were pointing, and not where the route went. The
## route was a list of junction indices in `RaceDef`; the streets were built from
## the same `RoadGraph`, and nothing ever drew the second on top of the first.
##
## So this is not a placeholder rectangle with a dot on it. It is the
## `RoadGraph` the world is actually built from: every edge, at its real
## position, so the shape on the minimap is the shape of the streets under the
## car. `TrackMarker.route_points()` supplies the route rather than the minimap
## re-deriving it, so the line on the map is the same line the barriers sit on.
##
## Two orientations, because they answer different questions. `ROTATE` turns the
## map under the player so their heading points up the screen, which is what you
## want while driving: the next corner is always at the top, so it stays
## readable mid-drift without the player having to reorient. `NORTH_UP` keeps the
## world still, which is what you want when you have stopped and are working out
## where you are. Switched with `set_rotate()`.
##
## Axes, straight from the map data: `+X east, +Z south`. Screen Y grows
## downward, so south is already down and north is already up with no flip
## anywhere. Getting this backwards is the classic minimap bug, so
## `_screen_dir()` is the one place the rotation is worked out and the test
## checks north lands at the top of the widget.
##
## Reads `RoadGraph` and `RaceDef`; owns no game state.
##
## OWNED BY: the race system (it is route information, not chrome).
##
## ORIGINAL GAME CONTENT.

enum Orientation { ROTATE, NORTH_UP }

## Metres of world per pixel. Not a constant: it is derived from the graph's own
## extent and the widget's size, so the whole network fits with a margin. A
## minimap showing a fragment of the street you are on is a decoration, and the
## one thing this has to be is a legible overview of where the route sits.
const FIT_MARGIN := 12.0
const ROAD_COLOUR := Color(0.30, 0.34, 0.42, 0.85)
const ROUTE_COLOUR := Color(1.0, 0.63, 0.24, 0.95)
const ROUTE_GLOW := Color(1.0, 0.63, 0.24, 0.26)
const START_COLOUR := Color(0.20, 0.95, 0.95, 1.0)
const PLAYER_COLOUR := Color(0.95, 0.95, 0.92, 1.0)
const RIVAL_COLOUR := Color(1.0, 0.24, 0.48, 1.0)
const NORTH_COLOUR := Color(0.55, 0.60, 0.70, 0.9)

var orientation: int = Orientation.ROTATE

var _graph: RoadGraph
var _route: Array = []            ## Vector2, map space, in order
var _route_closed := false
## World XZ -> widget pixels, about the widget's centre.
var _scale := 1.0
var _origin := Vector2.ZERO        ## world position drawn at the widget centre
## Every edge, pre-converted. Blitting these is the whole per-frame cost; a
## 401-edge search per frame would be a map that stutters exactly when the car
## is fastest.
var _road_segments: Array = []     ## Array[PackedVector2Array], centre-relative px
var _baked := false
var _player := Vector2.ZERO
var _player_heading := 0.0
var _rivals: Array = []            ## [{ pos: Vector2, heading: float }]
var _spin := 0.0                  ## radians the map frame is turned by


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Hands in the graph the world was built from. Cheap to call with the same
## graph: the pixel geometry is rebuilt only when the graph or the size changes.
func set_graph(g: RoadGraph) -> void:
	if g == _graph and _baked:
		return
	_graph = g
	_bake()


## The route to draw, in world-space Vector2. Pass `TrackMarker.route_points()`
## so the map and the road marks cannot disagree.
func set_route(points: Array, closed: bool) -> void:
	_route = points.duplicate()
	_route_closed = closed
	queue_redraw()


func set_route_from_def(def: RaceDef, g: RoadGraph) -> void:
	if def == null or g == null:
		set_route([], false)
		return
	var pts: Array = []
	for n in def.path:
		pts.append(g.node_pos(int(n)))
	set_route(pts, def.closed)


## Where the player is and which way they point. `heading` is any vector in the
## ground plane; only its direction matters, and a zero vector leaves the last
## heading alone rather than snapping the arrow north.
func set_player(pos: Vector3, heading: Vector3) -> void:
	_player = Vector2(pos.x, pos.z)
	var h := Vector2(heading.x, heading.z)
	if h.length_squared() > 0.0001:
		_player_heading = h.angle()


## The field. `cars` is anything with a `position: Vector3` and a `facing:
## Vector3` - the same contract the director uses, so a `CarBody` and a
## `RaceEntrant` both work and neither knows the map exists.
func set_rivals(cars: Array) -> void:
	_rivals.clear()
	for c in cars:
		if c == null:
			continue
		var p: Vector3 = c.position
		var f: Vector3 = c.facing
		var h := Vector2(f.x, f.z)
		_rivals.append({
			"pos": Vector2(p.x, p.z),
			"heading": h.angle() if h.length_squared() > 0.0001 else 0.0,
		})
	queue_redraw()


func set_rotate(on: bool) -> void:
	orientation = Orientation.ROTATE if on else Orientation.NORTH_UP
	queue_redraw()


func clear() -> void:
	_route.clear()
	_rivals.clear()
	_route_closed = false
	queue_redraw()


# ---------------------------------------------------------------------- baking

## World metres to widget pixels, relative to the widget's centre.
##
## One scale for both axes. A stretched map is worse than no map, because it
## lies about which way a corner goes - the one thing a driver reads off it.
func _bake() -> void:
	_baked = false
	_road_segments.clear()
	if _graph == null or _graph.nodes.is_empty():
		queue_redraw()
		return

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in _graph.nodes:
		var p: Vector2 = n["pos"]
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	if lo.x > hi.x or lo.y > hi.y:
		lo = Vector2.ZERO
		hi = Vector2(1, 1)
	_origin = (lo + hi) * 0.5
	var span := hi - lo
	var box := size if size.x >= 8.0 and size.y >= 8.0 else Vector2(260, 260)
	_scale = maxf(minf((box.x - FIT_MARGIN * 2.0) / maxf(span.x, 1.0),
		(box.y - FIT_MARGIN * 2.0) / maxf(span.y, 1.0)), 0.0001)

	for e in _graph.edges:
		var a: Vector2 = _graph.node_pos(int(e["a"])) - _origin
		var b: Vector2 = _graph.node_pos(int(e["b"])) - _origin
		if a.distance_squared_to(b) < 0.000001:
			continue
		_road_segments.append(PackedVector2Array([a * _scale, b * _scale]))
	_baked = true
	queue_redraw()


func _notification(what: int) -> void:
	# A resize invalidates the fit. `_baked` gates the walk, so this costs
	# nothing until the size really changed.
	if what == NOTIFICATION_RESIZED:
		_baked = false
		queue_redraw()


func _process(_delta: float) -> void:
	if not _baked:
		_bake()
	# Player and rivals move every frame; the route and the graph do not. So the
	# redraw is queued here and the expensive part is still behind `_baked`.
	if _graph != null:
		_spin = _spin_for()
		queue_redraw()


## How far the map frame is turned, in radians.
##
## In ROTATE mode the player's heading has to end up pointing up the screen.
## Drawing with `draw_set_transform(pos, spin, ...)` adds `spin` to the on-screen
## angle of everything it draws, and the player's heading sits at angle
## `_player_heading`, so solving `heading + spin = -PI/2` gives this. North
## (`-Z`) is `_player_heading == -PI/2` and comes out as `spin == 0`, which is
## the check the test asserts: an unrotated map when you are driving north.
func _spin_for() -> float:
	if orientation != Orientation.ROTATE:
		return 0.0
	return -_player_heading - PI * 0.5


## A world direction as it appears on screen: turned by whatever the map frame is
## turned by. One function, because the route, the start tick, the player arrow
## and every rival all have to agree about it.
func _screen_dir(world_dir: Vector2) -> Vector2:
	return world_dir.rotated(_spin)


## A world position as a widget pixel. In ROTATE mode the player sits at the
## centre, because the map is what turns; in NORTH_UP mode the player sits where
## they actually are.
func _screen_point(world_pos: Vector2) -> Vector2:
	var off: Vector2 = (world_pos - _origin) * _scale
	return off.rotated(_spin) if orientation == Orientation.ROTATE else off


# --------------------------------------------------------------------- drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.72))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.13, 0.19, 0.29, 0.9), false, 1.0)
	if not _baked:
		return
	var centre := size * 0.5

	# Everything map-shaped is drawn in the turned frame about the centre, so the
	# player can stay pinned at the middle.
	draw_set_transform(centre, _spin, Vector2.ONE)
	if _route.size() >= 2:
		var r := _px_route()
		# A fat translucent pass under a thin bright one: that is what makes the
		# route visible over a dense street grid without a glow shader.
		draw_polyline(r, ROUTE_GLOW, 7.0, true)
		draw_polyline(r, ROUTE_COLOUR, 2.0, true)
		_start_tick()
	for seg in _road_segments:
		draw_line(seg[0], seg[1], ROAD_COLOUR, 1.0, true)
	draw_set_transform(centre, 0.0, Vector2.ONE)

	_north_needle(centre)
	_rival_arrows(centre)
	_player_arrow(centre)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _px_route() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _route:
		out.append((Vector2(p) - _origin) * _scale)
	# `RaceDef` repeats the first junction at the end of a closed route, but a
	# caller may hand over a ring without the repeat. Closing it here means the
	# line closes either way, and the start tick sits on the real line.
	if _route_closed and out.size() >= 3:
		if out[0].distance_to(out[out.size() - 1]) > 0.5:
			out.append(out[0])
	return out


## The start/finish tick, in the turned frame so it goes with the rest of the map.
func _start_tick() -> void:
	if _route.is_empty():
		return
	var p: Vector2 = (Vector2(_route[0]) - _origin) * _scale
	draw_line(p - Vector2(5, 0), p + Vector2(5, 0), START_COLOUR, 2.5, true)


func _north_needle(centre: Vector2) -> void:
	# Drawn outside the turned frame: north is north whichever way the map is
	# turned, which is the whole reason for the compass. Only worth drawing when
	# the map is actually spinning.
	if orientation != Orientation.ROTATE:
		return
	var tip := centre + Vector2(0, -size.y * 0.5 + 14.0)
	draw_line(centre, tip, NORTH_COLOUR, 1.0, true)
	draw_circle(tip, 2.5, NORTH_COLOUR)
	var f := ThemeDB.fallback_font
	if f != null:
		draw_string(f, centre + Vector2(-3.0, -size.y * 0.5 + 28.0), "N",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, NORTH_COLOUR)


func _player_arrow(centre: Vector2) -> void:
	var p: Vector2 = centre if orientation == Orientation.ROTATE else _screen_point(_player)
	var nose := p + _screen_dir(Vector2.from_angle(_player_heading)) * 9.0
	var l := p + _screen_dir(Vector2.from_angle(_player_heading + 2.5)) * 7.0
	var r := p + _screen_dir(Vector2.from_angle(_player_heading - 2.5)) * 7.0
	# A filled arrowhead, not a dot: the heading is half the information here.
	draw_colored_polygon(PackedVector2Array([nose, l, p + (l - p) * 0.25,
		r, p + (r - p) * 0.25]), PLAYER_COLOUR)


func _rival_arrows(centre: Vector2) -> void:
	for r in _rivals:
		var at := _screen_point(r["pos"])
		# Turned by the map's own spin, exactly like the player arrow. Without
		# this every rival appears to drive one fixed way while the map rotates
		# under them, which is worse than no heading at all.
		var d := Vector2.from_angle(float(r["heading"])).rotated(_spin)
		draw_circle(at, 3.5, RIVAL_COLOUR)
		draw_line(at, at + d * 7.0, RIVAL_COLOUR, 1.5, true)