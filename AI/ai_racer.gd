class_name AIRacer
extends Node
## A racing driver: follows a smoothed racing line, brakes for corners before
## they arrive, overtakes, defends, makes mistakes and recovers from them.
##
## Drives the same throttle / brake / steer / handbrake surface the player does.
## It never touches velocity, position or grip directly, so it cannot do
## anything the player could not.
##
## `skill` is pace AND nerve; `aggression` is a separate axis, because a fast
## cautious driver and a slow aggressive one are both worth racing against.
##
## ORIGINAL GAME CONTENT.

enum Mode { RACE, RECOVER }

## How far ahead the driver looks, as a fraction of speed plus a floor. Short at
## parking speed so it does not saw at the wheel, long at speed so it does not
## oscillate.
const LOOKAHEAD_BASE := 6.0
const LOOKAHEAD_PER_MPS := 0.6
const LOOKAHEAD_MIN := 6.0
const LOOKAHEAD_MAX := 26.0

## Seconds a car has to stay spun, or stay lost, before the driver believes it.
## Without this, a hairpin sets it off: where the circuit doubles back on itself
## the nearest point on the line is briefly ambiguous, the direction flips, and
## a car going perfectly well at 60 km/h declares itself spun twice a lap.
const CONFIRM_LOST := 0.4

## How far ahead a car counts as traffic the driver has to get round.
const PASS_RANGE := 26.0

## Samples either side of us to search when placing another car on the line.
const TRAFFIC_WINDOW := 10

## How far off the line a car has to be before the driver gives up and goes to
## find the road again. Wider than any road in the network on purpose: a driver
## that panics while merely running a wide apex is worse than one that lets the
## car gather itself up.
const LOST_LATERAL := 24.0
## Facing this far back down the road counts as spun. Running wide is a driving
## problem, not a recovery problem, and treating it as one used to throw the car
## into a U-turn and then have it circle the circuit backwards for ever.
const SPUN_FACING := -0.5
## Seconds to leave the car alone after a recovery gives up, so it cannot bounce
## straight back into one and spend the lap in circles.
const RECOVER_SETTLE := 2.0
const RECOVER_GIVE_UP := 10.0

## Braking a fraction early, as a margin on top of the calculated distance. An
## AI that brakes at the exact physical limit is an AI that is one frame late.
const BRAKE_MARGIN := 1.25

## Below this skill the driver is considered fallible at all. A 0.95 driver makes
## no scripted mistakes, which is what "near-clean" is supposed to mean.
const FLAWLESS_SKILL := 0.9

var car: CarBody
var graph: RoadGraph
## 0 = novice, 1 = flawless. How close to the limit it dares, and how often it
## gets it wrong.
@export var skill := 0.7
## Separate from skill: how much it wants a gap, and how late it will defend.
@export var aggression := 0.7
## Optional. When set, the driver follows the exact route the race is scored on
## rather than generating its own circuit from the graph.
var director: RaceDirector = null
## Cars to race against. Left empty, the driver finds its siblings for itself.
var rivals: Array = []

## Scripted mistakes made since the last reset. Tests read this; so could a HUD.
var errors: int = 0
var mode: int = Mode.RACE

var _line: RacingLine = null
var _idx: int = 0
var _rng := RandomNumberGenerator.new()
## Fixed by default so a race replays the same way twice, which is the only way
## to test "a low-skill driver makes mistakes" rather than "sometimes it does".
var rng_seed: int = 20250929

var _lookahead := 14.0
var _target_lateral := 0.0
var _speed_cap := 0.0        ## extra limit from traffic, 0 = none
var _pass_side := 0.0        ## committed overtake side, 0 = not passing
var _pass_target: Object = null
var _error_time := 0.0
var _error_kind := 0
var _recover_time := 0.0
var _settle := 0.0
var _lost_time := 0.0
var _since_error := 0.0
var _scan_time := 0.0
var _found_rivals := false


func _ready() -> void:
	_rng.seed = rng_seed
	# Run the driver before the car, not after it. Every caller adds the CarBody
	# first and the driver second (Game/main.gd, Tests/test_ai.gd,
	# Tests/test_integration.gd), and with both on the default physics priority
	# Godot processes them in tree order - so the car spends each step building
	# its tyres from the steering the driver asked for last step. That is a whole
	# step of lag on the loop whose only job is lateral tracking, and the pure
	# pursuit gain is aggressive enough that the lag is the whole difference
	# between holding a straight line and weaving off it.
	set_physics_process_priority(-1)


func _physics_process(delta: float) -> void:
	if car == null or not is_instance_valid(car) or graph == null:
		return
	if _line == null or _line.size() < 4:
		_build_line()
		if _line == null or _line.size() < 4:
			_coast()
			return

	var here := _project_car()
	_idx = int(here["i"])
	_lookahead = clampf(LOOKAHEAD_BASE + car.speed_mps * LOOKAHEAD_PER_MPS, LOOKAHEAD_MIN, LOOKAHEAD_MAX)

	_check_recovery(delta, here)
	if mode == Mode.RECOVER:
		_drive_recovery(delta, here)
	else:
		_read_traffic(delta)
		_pick_error(delta)
		_drive_race(delta, here)
	car.auto_shift()


# ------------------------------------------------------------------ route

## The route being raced. A director that is already running a race is the
## authority on which line is being timed, so its route wins; otherwise the
## driver generates a circuit of its own from the same street network.
func _build_line() -> void:
	var route: Array = []
	var is_closed := true
	if director != null and director.route_points().size() >= 4:
		route = director.route_points()
		is_closed = director.def == null or director.def.closed
	elif graph != null:
		# find_loop hands back junction ids, so they have to become points.
		for n in graph.find_loop(0, 700.0):
			route.append(graph.node_pos(int(n)))
	if route.size() < 4:
		return
	_line = RacingLine.from_route(route, graph, is_closed)
	if _line.size() >= 4:
		_idx = director.nearest_route_index(car.global_position) if director != null else 0
		if is_closed and director == null:
			_idx = 0


## Where the car is on the line, seeded from scratch if it has clearly left the
## line somewhere (a shunt, a reset) so the local search cannot get lost.
func _project_car() -> Dictionary:
	var v := Vector2(car.global_position.x, car.global_position.z)
	if absf(float(_line.project(v, _idx)["lateral"])) > 40.0:
		_idx = 0
	return _line.project(v, _idx)


# ---------------------------------------------------------------- recovery

## Spun, backwards, or off in a car park. The driver has to come back, and coming
## back is the part that is easy to leave as a hope rather than a behaviour.
func _check_recovery(delta: float, here: Dictionary) -> void:
	if _settle > 0.0:
		_settle -= delta
		return
	if mode == Mode.RACE:
		var lost: bool = _facing_dot(here) < SPUN_FACING or absf(float(here["lateral"])) > LOST_LATERAL
		_lost_time = _lost_time + delta if lost else 0.0
		if _lost_time > CONFIRM_LOST:
			mode = Mode.RECOVER
			_recover_time = 0.0
			_lost_time = 0.0
			_pass_side = 0.0
			_pass_target = null
	if mode == Mode.RECOVER:
		_recover_time += delta
		# Bounded. A driver that has been recovering for ten seconds is not
		# recovering, it is circling: hand it back to the racing line and let it
		# sort itself out rather than re-entering recovery on the very next frame.
		if _recover_time > RECOVER_GIVE_UP:
			mode = Mode.RACE
			_settle = RECOVER_SETTLE
			_recover_time = 0.0
		elif _facing_dot(here) > 0.3 and absf(float(here["lateral"])) < 10.0:
			mode = Mode.RACE
			_recover_time = 0.0


## How well the car's nose points the right way, 1 = dead on, -1 = backwards.
func _facing_dot(here: Dictionary) -> float:
	var f := Vector2(car.forward().x, car.forward().z)
	if f.length_squared() < 0.0001:
		return 0.0
	return f.normalized().dot(_line.direction_at(int(here["i"])))


## Slow down, turn back toward the line and drive a wide arc onto it. A car
## facing the wrong way rotates quickest at low speed, so the recovery target is
## deliberately unambitious, and it aims a little way *along* the line rather
## than at the nearest point on it: aiming sideways at a point just off the nose
## is what turns "running wide" into "driving backwards down the circuit".
func _drive_recovery(delta: float, here: Dictionary) -> void:
	var i: int = int(here["i"])
	# Far off the line, aim at the nearest point on it - that is the shortest way
	# back. Aiming a couple of samples *ahead* of where it is sends the car round
	# a wide arc, and on a street grid that arc crosses a city block.
	var aim_index: int = i if absf(float(here["lateral"])) > 8.0 else i + 2
	_steer_at(_line.point_at(aim_index, 0.0))
	var over: float = car.speed_mps - 6.0
	car.throttle = 0.35 if over < 0.0 else 0.0
	car.brake = clampf(over / 5.0, 0.0, 1.0)
	car.handbrake = 0.0
	_target_lateral = 0.0
	_speed_cap = 0.0


# ----------------------------------------------------------------- traffic

## Looks for cars in the way and decides whether to go round one, hold station
## behind it, or defend the line.
func _read_traffic(delta: float) -> void:
	_scan_time -= delta
	if _scan_time <= 0.0:
		_scan_time = 0.4
		_collect_rivals()
	_speed_cap = 0.0
	_target_lateral = 0.0

	# Everything in front on our road, not just the nearest of it: two cars
	# abreast is the case where there is no gap, and you cannot see that from
	# the closest car alone.
	var queue: Array = []
	var ahead: Object = null
	var ahead_gap := 999.0
	var ahead_speed := 0.0
	var behind_gap := 999.0
	for r in _others():
		if not is_instance_valid(r):
			continue
		var d: float = _gap_to(r)
		# Ahead of us or level with us: a car abeam has no longitudinal gap at
		# all, and excluding it let the driver read the tarmac the car was
		# sitting on as a clear pass lane. Two cars abreast is the case where
		# there is no gap, and neither of them has a positive gap.
		if d >= 0.0 and d < PASS_RANGE:
			# Only cars genuinely in front, and only ones actually on the road we
			# are on: a fixed few metres is a car in the next lane on a wide street
			# and a car squarely in the way on a back street.
			if absf(_lateral_of(r)) < _line.width_at(_idx) * 0.5:
				queue.append(r)
				if d < ahead_gap:
					ahead_gap = d
					ahead = r
					ahead_speed = r.speed_mps
		elif d < 0.0 and -d < behind_gap:
			behind_gap = -d

	if ahead == null:
		_pass_side = 0.0
		_pass_target = null
		_defend(behind_gap)
		return

	# Committed to a pass: keep going until it is done. Backing out halfway is
	# the single worst-looking thing a racing AI does.
	if _pass_target != null and is_instance_valid(_pass_target) and _gap_to(_pass_target) > 0.0:
		_target_lateral = _pass_side * maxf(_free_room(_pass_side, queue) - _car_half_width() - 0.15, 0.0)
		_speed_cap = maxf(ahead_speed + 6.0, 8.0)
		return

	var closing: float = car.speed_mps - ahead_speed
	if _pass_target != null:
		# The car we were passing is gone from in front of us: either it is
		# behind now or it pulled out. Either way the move is over.
		_pass_target = null
		_pass_side = 0.0

	# Free tarmac either side, once every car in the queue has taken its share of
	# the road. If neither side has room for a car, there is no pass: sit behind
	# rather than drive through it.
	var free_r: float = _free_room(1.0, queue)
	var free_l: float = _free_room(-1.0, queue)
	var needed: float = _car_half_width() + 0.35
	if maxf(free_r, free_l) < needed or closing < 0.6:
		_speed_cap = maxf(ahead_speed + maxf(1.5, closing * 0.25), 0.0)
		_target_lateral = 0.0
		_pass_side = 0.0
		return

	# Pick the roomier side and commit to it.
	_pass_side = 1.0 if free_r >= free_l else -1.0
	_pass_target = ahead
	_target_lateral = _pass_side * maxf(_free_room(_pass_side, queue) - _car_half_width() - 0.15, 0.0)
	_speed_cap = maxf(ahead_speed + 5.0, 8.0)


## Nudge toward the inside of the next corner when someone is close behind.
func _defend(behind_gap: float) -> void:
	if behind_gap > 18.0:
		return
	var here := _line.direction_at(_idx)
	var ahead := _line.direction_at(_idx + maxi(int(_lookahead / _line.spacing), 2))
	var turn: float = here.cross(ahead)
	if absf(turn) < 0.15:
		return
	# Inside of the corner is the side it turns toward, and only as far as the
	# road allows.
	var bias: float = signf(turn) * _line.room_at(_idx) * (0.35 + 0.45 * aggression)
	_target_lateral = bias


func _collect_rivals() -> void:
	if not rivals.is_empty() or _found_rivals:
		return
	_found_rivals = true
	# No list was handed in: race the other cars we share a parent with, which is
	# what the game hands us.
	var parent := get_parent()
	if parent == null:
		return
	for child in parent.get_children():
		if child is CarBody and child != car:
			rivals.append(child)


func _others() -> Array:
	var out: Array = []
	for r in rivals:
		if is_instance_valid(r):
			out.append(r)
	return out


## Distance along the line from us to another car: positive if it is ahead.
## Looked up with a wide window - the other car is up to PASS_RANGE away, which
## is several samples, and a local search that quietly returns the nearest
## sample instead gives a gap that is simply wrong.
func _gap_to(other: Object) -> float:
	var i: int = _line.project(Vector2(other.global_position.x, other.global_position.z), _idx, TRAFFIC_WINDOW)["i"]
	var n := _line.size()
	var fwd := (i - _idx + n) % n if _line.closed else i - _idx
	return float(fwd) * _line.spacing


func _lateral_of(other: Object) -> float:
	return float(_line.project(Vector2(other.global_position.x, other.global_position.z), _idx, TRAFFIC_WINDOW)["lateral"])


func _car_half_width() -> float:
	return 0.85 if car.spec == null else car.spec.body_width * 0.5


## Tarmac free on one side of the racing line, once every car in the queue has
## taken its share of the road on that side. This is the number a pass is
## decided on: if it cannot hold a car, there is no pass.
func _free_room(side: float, queue: Array) -> float:
	var half: float = _line.width_at(_idx) * 0.5
	for r in queue:
		if not is_instance_valid(r):
			continue
		var lat: float = _lateral_of(r)
		if side * lat > 0.0:
			half -= absf(lat) + _car_half_width() + 0.3
	return maxf(half, 0.0)


# ------------------------------------------------------------------- errors

## Mistakes, scaled by skill. A driver who never gets anything wrong is a car on
## rails, and a driver who gets it wrong constantly is noise - so the rate is
## zero at the top and climbs steeply at the bottom.
func _pick_error(delta: float) -> void:
	if _error_time > 0.0:
		_error_time -= delta
		return
	_since_error += delta
	if _since_error < 1.5:
		return
	_since_error = 0.0
	var fallible: float = clampf((FLAWLESS_SKILL - skill) / FLAWLESS_SKILL, 0.0, 1.0)
	if fallible <= 0.0 or _rng.randf() > fallible * 0.5:
		return
	errors += 1
	_error_kind = 1 + _rng.randi_range(0, 2)
	_error_time = 0.4 + _rng.randf() * 0.7


# -------------------------------------------------------------------- driving

func _drive_race(delta: float, here: Dictionary) -> void:
	var i: int = int(here["i"])
	var aim_index: int = i + maxi(int(round(_lookahead / _line.spacing)), 2)
	_steer_at(_line.point_at(aim_index, _target_lateral))

	# How fast the line allows here, and what this driver is willing to use.
	var decel: float = _line.brake_decel * (0.5 + 0.5 * skill)
	if _error_kind == 1 and _error_time > 0.0:
		decel *= 0.45           # brakes too late
	var want: float = _line.allowed_speed(i, _lookahead + BRAKE_MARGIN * car.speed_mps, decel)
	want *= 0.58 + 0.38 * skill
	if _error_kind == 3 and _error_time > 0.0:
		want *= 1.25            # carries too much speed into the corner
	if _speed_cap > 0.0:
		want = minf(want, _speed_cap)
	want = minf(want, _line.limit_at(i) * 1.05)

	car.throttle = 0.0
	car.brake = 0.0
	var over: float = car.speed_mps - want
	if over > 0.4:
		car.brake = clampf(over / 3.0, 0.25, 1.0)
	else:
		var push: float = clampf((-over) / 3.0, 0.0, 1.0)
		car.throttle = 1.0 if push > 0.6 else push
		if _error_kind == 2 and _error_time > 0.0:
			car.throttle *= 0.25  # lifts mid-corner
	car.handbrake = 0.0


## Pure pursuit: aim at a point on the line and steer at it. Positive `steer`
## is a left turn on CarBody, hence the negation.
func _steer_at(aim: Vector2) -> void:
	var to: Vector3 = Vector3(aim.x - car.global_position.x, 0.0, aim.y - car.global_position.z)
	if to.length_squared() < 0.04:
		car.steer = 0.0
		return
	var local: Vector3 = car.global_transform.basis.inverse() * to
	car.steer = clampf(-atan2(local.x, -local.z) * 2.6, -1.0, 1.0)


func _coast() -> void:
	if car == null or not is_instance_valid(car):
		return
	car.throttle = 0.0
	car.brake = 0.0
	car.steer = 0.0
	car.handbrake = 0.0


## Whether the driver is currently committed to a pass, and which way. 0 means
## no: it is either racing its own line or sitting behind what is in the way.
func attempting_pass() -> float:
	return _pass_side


## The line being driven, and where on it the car is. Public so a test or a
## replay tool can watch the driver without reaching into privates.
func line() -> RacingLine:
	return _line


func line_index() -> int:
	return _idx


## Drops the route so the next physics frame rebuilds it. For a race restart.
func reset() -> void:
	_line = null
	_idx = 0
	errors = 0
	mode = Mode.RACE
	_error_time = 0.0
	_recover_time = 0.0
	_lost_time = 0.0
	_pass_side = 0.0
	_pass_target = null
	_speed_cap = 0.0
	_target_lateral = 0.0
	_rng.seed = rng_seed
