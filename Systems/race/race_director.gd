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

## The rounds this director has run, oldest first, capped at
## `RoundResult.HISTORY_LIMIT`. Deliberately *not* cleared by `reset()`: a reset is
## the next entry on the grid, not a new career. `results` below is the race
## currently on the road and is thrown away; this is what the player has done.
var _history: Array = []
var _round_no: int = 0
## The round being written, so `last_round()` is answerable during the frame
## `_conclude` runs in without every caller reaching into `results`.
var _round: RoundResult = null
## The wallet as it stood when this race's lights went out, i.e. after the entry
## fee. Read at `start()` rather than at `try_enter()` because `reset()` keeps an
## entry paid for: a retry goes straight through `start()` with no second charge,
## and a balance snapshotted at entry would then credit the retry's payout to the
## first race's fee.
var _money_before: int = 0

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
			# Every completed lap, in the order they were banked. `best_lap` alone
			# cannot tell a driver what they did on the other laps, and a lap timer
			# that only ever shows the minimum is not a lap timer.
			"splits": [],
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
	_money_before = _balance()
	return true


## Back to the grid for the next race. Keeps the entry paid for - and keeps the
## rounds already run. A reset is the next heat, not a new career: clearing the
## history here is exactly how a player ends a session with a lap time and no
## record of ever having driven it. `clear_history()` is the deliberate way out.
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


## Every lap entrant `i` has banked this race, in order, in seconds. Empty before
## the first line crossing, and one short of the lap count for anyone still out.
func splits(i: int) -> Array:
	return _st[i]["splits"].duplicate() if i >= 0 and i < _st.size() else []


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
				s["splits"].append(lt)
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
	var best := {"s": 0.0, "dir": _line_d, "i": 0}
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
			best = {"s": float(_cum[i]) + t * sqrt(len2), "dir": ab / sqrt(len2), "i": i}
	return best


# ------------------------------------------------------------------- route query
# The route the race is actually scored on, so the AI can drive the same line.
# Read-only: nothing here changes race state.

## Array[Vector2] through the junctions, start/finish line first.
func route_points() -> Array:
	return _pts.duplicate()


func route_length() -> float:
	return _route_length


## Which segment of the route a car is on. Seed an AI's own tracking from this
## and then walk forward from it, rather than re-searching every frame.
func nearest_route_index(pos: Vector3) -> int:
	if _pts.size() < 2:
		return 0
	return int(_project(Vector2(pos.x, pos.z))["i"])


func line_position() -> Vector3:
	return Vector3(_line_o.x, 0.0, _line_o.y)


func line_direction() -> Vector2:
	return _line_d


# --------------------------------------------------------------------- results

func _all_finished() -> bool:
	for s in _st:
		if not bool(s["finished"]):
			return false
	return true


## Classifies the field, pays the player out, and writes the round down.
##
## The classification itself is unchanged - finishers by time, anyone still out
## behind them on how far they got. What is new is that the outcome *survives*:
## `results` is cleared by the next `reset()`, so on its own it is a lap counter.
## A `RoundResult` is written here and kept, because a race that pays out and
## leaves no trace is a demo rather than a loop.
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
	# The payout is the player's, and only the player's: the sliding scale exists
	# to rank a field, and paying a stub rival would be paying a car that does not
	# exist. The winner's share is stored on every row regardless, because the board
	# shows the whole scale and a row that reads $0 for a podium finish is a lie.
	var player_pos: int = int(_st[0]["pos"])
	var won: bool = bool(_st[0]["finished"])
	var credit: int = payout_for_position(player_pos) if won else 0
	if w != null and won:
		w.add_money(credit)
		w.record_race(def.id, float(_st[0]["finish_time"]), float(_st[0]["best_lap"]))

	# Read the balance *after* the credit, not before it and not adjusted for it:
	# the round ends on what the bank actually holds, which is the one figure a
	# player can check against their own.
	_write_round(credit, _balance())
	state = State.FINISHED


## Files the round just decided. Every figure is read from the classification that
## was just built, so the record cannot disagree with `results` about who came in
## where - the two are written from one pass, not derived from each other after the
## fact.
func _write_round(credit: int, money_after: int) -> void:
	var r := RoundResult.new()
	r.round_index = _round_no + 1
	r.race_id = def.id if def != null else ""
	r.race_name = def.display_name if def != null else ""
	r.laps_required = def.laps if def != null else 1
	r.field_size = entrants.size()
	r.positions = _round_positions()
	r.splits = _st[0]["splits"].duplicate()
	r.best_lap = float(_st[0]["best_lap"])
	r.finished = bool(_st[0]["finished"])
	r.fee = def.entry_fee if def != null else 0
	r.paid = credit
	r.money_before = _money_before
	r.money_after = money_after
	_round_no = r.round_index
	_round = r
	_history.append(r)
	# Oldest out first, so the HUD reads recent form without having to reverse.
	while _history.size() > RoundResult.HISTORY_LIMIT:
		_history.pop_front()


## The classification as the round records it: one row per car, position 1 first,
## carrying what that position was worth so the board and the wallet cannot drift.
func _round_positions() -> Array:
	var out: Array = []
	for r in results:
		var row: Dictionary = r
		var pos: int = int(row["pos"])
		var index: int = entrants.find(row["car"])
		var s: Dictionary = _st[index] if index >= 0 else {}
		out.append({
			"pos": pos,
			"index": index,
			"car": row["car"],
			"time": float(row["time"]),
			"best_lap": float(row["best_lap"]),
			"laps": int(row["laps"]),
			"finished": bool(row["finished"]),
			"progress": float(s.get("progress", 0.0)),
			"paid": def.payout_for_position(pos, entrants.size()) if def != null else 0,
		})
	return out


## The rounds run so far, oldest first. A copy: history that a caller can sort in
## place is history that can be silently reordered.
func round_history() -> Array:
	return _history.duplicate()


## The round just finished, or null if none has.
func last_round() -> RoundResult:
	return _round


## How many rounds this director has concluded. Counts from the first race of the
## session, so a player on their first night is told ROUND 1 and not ROUND 0.
func round_count() -> int:
	return _round_no


## The best lap any round on this route has produced by the player, or 0.0. Read
## out of the history rather than off `Cfg`, so it is answerable on a director that
## was handed a stub wallet - and so "personal best" means something within a
## session even when nothing is being written to disk.
func career_best_lap(race_id: String = "") -> float:
	var best := 0.0
	for r in _history:
		var round: RoundResult = r
		if race_id != "" and round.race_id != race_id:
			continue
		if round.best_lap > 0.0 and (best <= 0.0 or round.best_lap < best):
			best = round.best_lap
	return best


## The balance a race was entered on, after the fee. What the HUD calls the
## round's starting bank, and what `RoundResult.money_before` was read from.
func money_before() -> int:
	return _money_before


## The player's finish in the round just concluded, or 0. Reading it off the round
## rather than off `_st` means a caller cannot get a live position and mistake it
## for a classified one.
func last_paid() -> int:
	return _round.paid if _round != null else 0


## Drops the kept rounds. Only a host that means to end the career - a new save, a
## quit - has any business calling it; `reset()` deliberately does not, because the
## next race on the grid is the same night.
func clear_history() -> void:
	_history.clear()
	_round = null
	_round_no = 0


## The wallet defaults to the Cfg autoload, looked up through the scene tree
## rather than the bare global name. The bare name works here too - measured
## under the suite's `--script` runner, `Cfg` and `root.get_node_or_null("Cfg")`
## are the same object, which `Tests/test_1economy.gd` asserts - so the lookup is
## for the null, not for the name: a director built before the tree is up must
## be able to come up with no wallet and refuse an entry, not crash on it. Same
## reason and same shape as `Garage._autoload()`.
func _money() -> Object:
	if wallet != null:
		return wallet
	var loop := Engine.get_main_loop()
	return loop.root.get_node_or_null("Cfg") if loop is SceneTree else null


## The wallet's balance, or 0 when there is no wallet at all. `money` rather than
## `get`: a stub that answers `add_money` and `spend_money` but not `money` is a
## wallet this director still has to be able to run a race for, so it reads 0
## rather than throwing in the middle of `_conclude`.
func _balance() -> int:
	var w := _money()
	if w == null or not ("money" in w):
		return 0
	return int(w.money)
