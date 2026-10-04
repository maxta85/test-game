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
## Metres from the line to the lane actually driven, positive to the right of
## travel.
##
## DEFAULT 0.0, and that default is a decision with a reason rather than a shrug:
## the racing circuit's `RacingLine` already carries an inside bias
## (`APEX_BUDGET`), so its centre IS the racing line, and offsetting it would move
## the car off the fast line and onto the inside verge at every corner.
##
## It is not zero for a STREET, and that is where the measurement belongs. On a
## named street the line is the street's centreline, and on these streets the
## centreline is the OCCUPIED side: `Tools/street_blockers.gd` measured the clear
## band at +2.5 .. +6.0 m right of travel on both Aumuller and Hoare, because every
## prop batch stands on the other kerb. A driver tracking the centreline there finds
## a prop within 84 m. `AI/street_ai_probe.gd` sets this from that measurement;
## nothing in the game sets it for you, because only the physics server knows where
## the palms are.
@export var lane_offset := 0.0
## Optional. When set, the driver follows the exact route the race is scored on
## rather than generating its own circuit from the graph.
var director: RaceDirector = null
## Cars to race against. Left empty, the driver finds its siblings for itself.
var rivals: Array = []

## Scripted mistakes made since the last reset. Tests read this; so could a HUD.
var errors: int = 0
var mode: int = Mode.RACE

var _line: RacingLine = null
## The follower that actually produces the steering, over the same points as
## `_line`. `Systems/race/lane_follower.gd`, consumed rather than reimplemented:
## the driver used to carry its own pure pursuit, which is the same idea missing
## every part that makes it hold a straight - no yaw damping, no bound on the aim
## angle, and no speed floor. See `lane_offset` for the measured cost of that.
var _lane: LaneFollower = null
## Compare the line's windowed projection with the follower's global one, every
## frame. Costs a second full scan of the line, so it is off unless asked for.
@export var audit_projections := false
## Worst disagreement seen while auditing, in metres along the line.
var proj_max_gap := 0.0
## Frames audited, and of those how many disagreed by more than two samples.
var proj_frames := 0
var proj_disagree_frames := 0
var proj_disagree_s: Array = []
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
	_sync_lane()


## Hand `_line`'s points to a `LaneFollower`.
##
## Built here rather than in `_ready` because the line is rebuilt whenever the
## route changes, and a follower holding a stale line would drive a car that no
## longer exists. The two use the SAME lateral convention with no sign flip:
## `RacingLine._closest_on` measures lateral as `off.dot(dir.orthogonal())` and
## `point_at` offsets by `dir.normalized().orthogonal() * lateral`, and
## `LaneFollower` uses `Vector2(tan.y, -tan.x)` — which is `orthogonal()`. So
## `_target_lateral` and `LaneFollower.lane_offset` are the same number and a
## conversion would be a bug waiting to happen.
func _sync_lane() -> void:
	if _lane == null:
		_lane = LaneFollower.new()
	var packed := PackedVector2Array()
	for p in _line.points:
		packed.append(p)
	_lane.set_lane(packed, _line.closed)


## Follow a named street instead of a circuit. Public so a harness can put the AI
## on a real road and measure whether it holds the lane there, which is the case
## the old controller provably could not handle.
##
## `route` is an open polyline of the street's centreline points. It goes through
## the same `RacingLine` as a circuit - smoothed, apex-biased and pulled back onto
## the streets - so this does not hand the driver a privileged line; it only says
## WHICH line.
func follow_street(route: Array, offset: float = 0.0) -> bool:
	if route.size() < 2 or graph == null:
		return false
	_line = RacingLine.from_route(route, graph, false)
	if _line.size() < 4:
		_line = null
		return false
	lane_offset = offset
	_idx = 0
	_sync_lane()
	return true


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
	_steer_along_lane(here)

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


## Pure pursuit, by way of `Systems/race/lane_follower.gd`: aim at the lane a
## little way ahead and steer at it, damped by yaw rate. Used for BOTH open lines
## and closed circuits.
##
## It was NOT safe on a circuit until t124 gave `LaneFollower.project()` a windowed,
## seeded search. Before that it was a global nearest-point scan, and handing it a
## closed lap sent `./test.sh ai` from worst road ratio 0.56 to **2.85** (bound 2.2,
## red), lap 136.7 s to 140.4 s, and 0 of 932 samples over the kerb to 17 of 957 -
## every one of them in RECOVER - because on a street circuit that passes close to
## itself it returned a point on a DIFFERENT LEG of the lap. `AI/street_ai_probe.gd
## --selftest` measures the fix and its control on a dogleg: the windowed round trip
## is 0.00 m out over 31 probes walked in 16 m steps, and a fresh global scan of the
## same line is 32.00 m out.
##
## Recovery keeps `_steer_at`, because it aims at a PLACE - the nearest point on the
## line, or two samples ahead of it - and a speed-scaled look-ahead cannot express
## "the nearest point, please".
##
## `_target_lateral` carries traffic and defending through unchanged, and it is the
## same number as `LaneFollower.lane_offset` - see `_sync_lane` on why there is no
## sign flip between them.
func _steer_along_lane(here: Dictionary) -> void:
	if _lane == null:
		var fallback := _idx + maxi(int(round(_lookahead / _line.spacing)), 2)
		_steer_at(_line.point_at(fallback, _target_lateral))
		return
	_audit_projection(here)
	_lane.lane_offset = _target_lateral + lane_offset
	car.steer = _lane.steer_for(car.global_position, car.forward(),
		car.angular_velocity.y, car.speed_mps)


## Whether this driver is actually steering with the follower. True for streets and
## circuits alike since t124 gave the follower's projection a window.
func steering_with_follower() -> bool:
	return _lane != null


## How far apart the two projections of the same car are, and how often they
## disagree. OFF BY DEFAULT because it costs a second scan of the line.
##
## Both are windowed now, but they are separate implementations with separate
## scales - `RacingLine` derives `s` from a `spacing` that includes the closing
## segment, so its `s` grows about 1.38x faster per sample than the follower's sum
## of consecutive distances. Compare their `s` values and you will measure THAT,
## not the search. What is worth watching is a disagreement that GROWS, which is
## what a lost window looks like; a constant offset is a scale, not a fault.
func _audit_projection(here: Dictionary) -> void:
	if not audit_projections or _lane == null:
		return
	var theirs: float = float(_lane.project(car.global_position)["s"])
	var mine: float = float(here["s"])
	var gap: float = absf(theirs - mine)
	proj_frames += 1
	proj_max_gap = maxf(proj_max_gap, gap)
	# `spacing` is the line's own resolution, so a disagreement worth acting on is
	# one larger than a couple of samples.
	if gap > _line.spacing * 2.0:
		proj_disagree_frames += 1
		proj_disagree_s.append({"s": mine, "theirs": theirs, "gap": gap})


## Aim at a point on the ground, in world XZ. Recovery only - see
## `_steer_along_lane`. Positive `steer` is a left turn on CarBody, hence the
## negation.
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


## The follower doing the steering. Public so a harness can ask it to verify its
## own geometry while the AI is driving it - the invariants in
## `LaneFollower.verify()` were written for a street probe and have never been
## checked against a car being driven by this driver rather than by input.
func lane() -> LaneFollower:
	return _lane


func line_index() -> int:
	return _idx


## Drops the route so the next physics frame rebuilds it. For a race restart.
func reset() -> void:
	_line = null
	_lane = null
	proj_max_gap = 0.0
	proj_frames = 0
	proj_disagree_frames = 0
	proj_disagree_s.clear()
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
