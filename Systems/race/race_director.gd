class_name RaceDirector
extends RefCounted
## Runs one race from the grid to the finish line.
##
## Pure logic. Entrants are anything with a `position: Vector3` and a
## `facing: Vector3` (world space, flattened to the ground plane), so the
## player's CarBody and a three-line stub in a test drive the same code. It
## touches no physics, no scene tree and no rendering - the caller calls
## `tick(delta)` once a frame and reads the results.
##
## ORIGINAL GAME CONTENT.

enum State { IDLE, COUNTDOWN, RACING, FINISHED }

const COUNTDOWN_TIME := 3.0
## How near a junction a car must be for it to count as that checkpoint.
const CHECKPOINT_RADIUS := 14.0
## The start/finish line is a place, not a projection: coming inside this
## radius while travelling with the racing direction is a crossing. Crossing the
## wider arm radius is what re-arms it, so it fires exactly once per pass even
## for a car moving slower than the gap between the two radii - with one
## threshold it could never fire at all.
const LINE_RADIUS := 30.0
const LINE_ARM := 60.0
## Facing dot track direction below this is going the wrong way.
const WRONG_WAY_DOT := -0.35

const GRID_FIRST_ROW := 8.0      # metres behind the line
const GRID_ROW_GAP := 5.0
const GRID_COLUMN := 2.5

var state: int = State.IDLE
var def: RaceDef = null
## Car objects. Index 0 is the player: their finish ends the race.
var entrants: Array = []
## [{ car, pos, time, best_lap, laps, finished }], pos 1 is the winner.
var results: Array = []
## 3, 2, 1 while the lights are on; 0 from GO. Drives the revving audio.
var lights: int = 0
var countdown_left: float = 0.0
var race_time: float = 0.0
## Anything with money / add_money / spend_money / record_race. Null means the
## Cfg autoload, so the game does not have to wire it up. Tests inject a stub.
var wallet: Object = null

# --- route, rebuilt on every start() -----------------------------------------
var _pts: Array = []          # Vector2, the route through the junctions
var _cp: Array = []           # Vector2, the junctions that must be taken in order
var _cum: Array = []          # cumulative metres at the start of each segment
var _route_length: float = 0.0
var _line_o: Vector2 = Vector2.ZERO   # start/finish line
var _line_d: Vector2 = Vector2.ONE    # and the direction that counts as forward
var _st: Array = []           # per-entrant state, parallel to `entrants`
var _entry: RaceDef = null    # paid-for race, cleared by reset()


# ------------------------------------------------------------------- lifecycle

func state_name() -> String:
	return ["idle", "countdown", "racing", "finished"][clampi(state, 0, 3)]


## Paid-for entry. Refuses when the fee cannot be covered, and charges nothing
## when it cannot.
func try_enter(d: RaceDef) -> bool:
	if d == null or state != State.IDLE:
		return false
	var w := _money()
	if w == null:
		return false
	if d.entry_fee > 0 and not w.spend_money(d.entry_fee):
		return false
	_entry = d
	return true


## Builds the route, drops the cars on the grid and starts the countdown.
## Refuses a definition that was never paid for, or one with no route in it.
func start(d: RaceDef, graph: RoadGraph, cars: Array) -> bool:
	if d == null or d != _entry or not d.valid() or cars.is_empty():
		return false
	if not _build_route(d, graph):
		return false
	entrants = cars.duplicate()
	_st.clear()
	for i in entrants.size():
		var car = entrants[i]
		var slot := _grid_slot(i)
		car.position = slot
		car.facing = Vector3(_line_d.x, 0.0, _line_d.y)
		_st.append({
			"next_cp": 0,
			"lap": 0,
			"lap_start": 0.0,
			"best_lap": 0.0,
			"finished": false,
			"finish_time": -1.0,
			"pos": 0,
			"progress": 0.0,
			"wrong": false,
			"grid": slot,
			# The grid sits inside the line, so the run out of it is not a
			# crossing: the first pass of the line restarts, it does not count.
			"last_pos": Vector2(slot.x, slot.z),
			"armed": false,
		})
	results.clear()
	race_time = 0.0
	countdown_left = COUNTDOWN_TIME
	lights = 3
	state = State.COUNTDOWN
	return true


## Back to the grid for the next race. Keeps the entry paid for.
func reset() -> void:
	state = State.IDLE
	entrants.clear()
	_st.clear()
	results.clear()
	lights = 0
	countdown_left = 0.0
	race_time = 0.0


## The gate the driving code asks before it applies throttle or steering.
func can_drive(_car: Object = null) -> bool:
	return state == State.RACING


func tick(delta: float) -> void:
	match state:
		State.COUNTDOWN:
			# Cars are held on their grid slots until the lights go out.
			for i in entrants.size():
				entrants[i].position = _st[i]["grid"]
			countdown_left -= delta
			lights = clampi(int(ceil(maxf(countdown_left, 0.0))), 0, 3)
			if countdown_left <= 0.0:
				state = State.RACING
		State.RACING:
			race_time += delta
			for i in entrants.size():
				if not bool(_st[i]["finished"]):
					_update_car(i)
			# The race is the player's run: the moment they cross the line the
			# rest are classified on how far they got.
			if bool(_st[0]["finished"]) or _all_finished():
				_conclude()
		_:
			pass


# ------------------------------------------------------------------ per entrant

func next_checkpoint(i: int) -> int:
	return int(_st[i]["next_cp"])


func checkpoint_count() -> int:
	return _cp.size()


func laps(i: int) -> int:
	return int(_st[i]["lap"])


func best_lap(i: int) -> float:
	return float(_st[i]["best_lap"])


func is_wrong_way(i: int) -> bool:
	return bool(_st[i]["wrong"])


func is_finished(i: int) -> bool:
	return bool(_st[i]["finished"])


func position_of(car: Object) -> int:
	for i in entrants.size():
		if entrants[i] == car:
			return int(_st[i]["pos"])
	return 0


func payout_for_position(pos: int) -> int:
	return def.payout_for_position(pos, entrants.size()) if def != null else 0


# ---------------------------------------------------------------------- update

func _update_car(i: int) -> void:
	var s: Dictionary = _st[i]
	var car = entrants[i]
	var p: Vector3 = car.position
	var flat := Vector2(p.x, p.z)
	var pr := _project(flat)
	var along: float = pr["s"]

	# Checkpoints, strictly in order. Only ever the next one is tested, so a car
	# that skips a junction gains nothing and has to come back for it - and a
	# lap cannot complete on a short set.
	var n: int = s["next_cp"]
	while n < _cp.size() and flat.distance_to(_cp[n]) <= CHECKPOINT_RADIUS:
		n += 1
	s["next_cp"] = n

	# The start/finish line. Coming inside it while moving with the racing
	# direction is a crossing, and the arm radius outside it means that fires
	# once per pass: a car parked on the line cannot re-trigger it, and one
	# running parallel to the line up the next street is already inside it, so
	# it never comes in at all. Keyed off the line as a place rather than off
	# distance along the route, because a street circuit passes close to itself
	# and "furthest along" is ambiguous where it doubles back.
	var prev: Vector2 = s["last_pos"]
	var near: float = flat.distance_to(_line_o)
	if near > LINE_ARM:
		s["armed"] = true
	elif near <= LINE_RADIUS and bool(s["armed"]):
		s["armed"] = false
		if def.closed and (flat - prev).dot(_line_d) > 0.0:
			if n == _cp.size() and int(s["lap"]) < def.laps:
				var lt: float = race_time - float(s["lap_start"])
				s["lap"] = int(s["lap"]) + 1
				s["lap_start"] = race_time
				if lt > 0.0 and (float(s["best_lap"]) <= 0.0 or lt < float(s["best_lap"])):
					s["best_lap"] = lt
			# A fresh set of checkpoints either way: a crossed line that was not
			# earned restarts the lap rather than banking it.
			s["next_cp"] = 0
	s["last_pos"] = flat

	if not bool(s["finished"]) and ((not def.closed and n == _cp.size()) or (def.closed and int(s["lap"]) >= def.laps)):
		s["finished"] = true
		s["finish_time"] = race_time

	s["progress"] = float(s["lap"]) * _route_length + along
	s["wrong"] = Vector2(car.facing.x, car.facing.z).normalized().dot(pr["dir"]) < WRONG_WAY_DOT


# ------------------------------------------------------------------ route build

## Turns the definition's junction list into flat geometry the update can work
## on: the point list, the ordered checkpoints, the line and its direction.
func _build_route(d: RaceDef, graph: RoadGraph) -> bool:
	_pts.clear()
	_cp.clear()
	_cum.clear()
	for n in d.path:
		_pts.append(graph.node_pos(int(n)))
	# path[0] is the line itself, and a closed route repeats it at the end, so
	# the junctions between are the checkpoints to take.
	var last: int = _pts.size() - (1 if d.closed else 0)
	for i in range(1, last):
		_cp.append(_pts[i])
	if _pts.size() < 2 or _cp.is_empty():
		return false
	_cum.append(0.0)
	_route_length = 0.0
	for i in _pts.size() - 1:
		_cum.append(_route_length)
		_route_length += _pts[i].distance_to(_pts[i + 1])
	_line_o = _pts[0]
	_line_d = (_pts[1] - _pts[0]).normalized()
	if _line_d == Vector2.ZERO:
		return false
	def = d
	return true


## Grid slot i: staggered back from the line in two columns, pole at the front.
func _grid_slot(i: int) -> Vector3:
	var row := i / 2
	var side := 1.0 if i % 2 == 0 else -1.0
	var p: Vector2 = _line_o - _line_d * (GRID_FIRST_ROW + float(row) * GRID_ROW_GAP) \
			+ _line_d.orthogonal() * (side * GRID_COLUMN)
	return Vector3(p.x, 0.0, p.y)



## Nearest point on the route: how far along it (for the line crossing and for
## ranking) and which way it runs there (for wrong-way).
func _project(v: Vector2) -> Dictionary:
	var best := {"s": 0.0, "dir": _line_d}
	var best_d := INF
	for i in _pts.size() - 1:
		var a: Vector2 = _pts[i]
		var ab: Vector2 = _pts[i + 1] - a
		var len2: float = ab.length_squared()
		if len2 < 0.01:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		var d: float = a.distance_squared_to(v - ab * t)
		if d < best_d:
			best_d = d
			best = {"s": float(_cum[i]) + t * sqrt(len2), "dir": ab / sqrt(len2)}
	return best


# --------------------------------------------------------------------- results

func _all_finished() -> bool:
	for s in _st:
		if not bool(s["finished"]):
			return false
	return true


## Classifies the field and pays the player out.
func _conclude() -> void:
	var order: Array = range(entrants.size())
	# Finishers by time; anyone still out is behind them on how far they got.
	order.sort_custom(func(a: int, b: int) -> bool:
		var fa: bool = bool(_st[a]["finished"])
		var fb: bool = bool(_st[b]["finished"])
		if fa != fb:
			return fa
		if fa:
			return float(_st[a]["finish_time"]) < float(_st[b]["finish_time"])
		return float(_st[a]["progress"]) > float(_st[b]["progress"]))

	results.clear()
	for pos in order.size():
		var i: int = int(order[pos])
		var s: Dictionary = _st[i]
		s["pos"] = pos + 1
		results.append({
			"car": entrants[i],
			"pos": pos + 1,
			"time": float(s["finish_time"]),
			"best_lap": float(s["best_lap"]),
			"laps": int(s["lap"]),
			"finished": bool(s["finished"]),
		})

	var w := _money()
	if w != null and bool(_st[0]["finished"]):
		w.add_money(payout_for_position(int(_st[0]["pos"])))
		w.record_race(def.id, float(_st[0]["finish_time"]), float(_st[0]["best_lap"]))
	state = State.FINISHED


## The wallet defaults to the Cfg autoload, looked up through the scene tree
## rather than by the bare global name: autoload identifiers are not registered
## in a `--script` context, and the director has to load in one.
func _money() -> Object:
	if wallet != null:
		return wallet
	var loop := Engine.get_main_loop()
	return loop.root.get_node_or_null("Cfg") if loop is SceneTree else null
