extends RefCounted
## Race system. Run with: ./test.sh race
##
## Drives the director with a stub car rather than CarBody, so this suite is
## pure logic: it moves `position` around a real RoadGraph and checks the state
## machine, the checkpoint order, the lap counting and the money.

## The whole contract the director needs from an entrant.
class FakeCar extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var facing: Vector3 = Vector3.FORWARD


var g: RoadGraph
var def: RaceDef
var cars: Array = []


func run(t: TestHarness) -> void:
	Cfg.money = 500
	g = RoadGraph.new()
	g.build(ManundaLayout.corridors())
	def = RaceDef.circuit(g, 0, 700.0, "test_circuit", "Test Circuit", 2)

	_definitions(t)
	_countdown(t)
	_checkpoints_in_order(t)
	_lap_counting(t)
	_backwards_crossing(t)
	_finish(t)
	_results_order(t)
	_payout(t)
	_entry_fee(t)
	_wrong_way(t)


# ---------------------------------------------------------------------- cases

## Every race type the design brief asks for has to be a route in the real
## network, not a placeholder.
func _definitions(t: TestHarness) -> void:
	t.ok(def.valid(), "the street network yields a runnable circuit")
	t.gt(def.length_m(g), 400.0, "the circuit is a real distance (%.0f m)" % def.length_m(g))
	t.ok(def.closed, "a circuit is a closed route")
	t.eq(def.laps, 2, "a circuit is run for the laps it was given")

	var cat: Array = RaceDef.catalogue(g)
	t.eq(cat.size(), 5, "there is one race of every kind")
	var kinds := {}
	for d in cat:
		kinds[int(d.kind)] = true
		t.ok(d.valid(), "%s found a route through the streets" % d.kind_name())
		t.gt(d.length_m(g), 200.0, "%s is a real distance (%.0f m)" % [d.kind_name(), d.length_m(g)])
	t.eq(kinds.size(), 5, "all five race types are defined")

	var sprint: RaceDef = cat[0]
	t.eq(sprint.kind, RaceDef.Kind.SPRINT, "the first entry is a sprint")
	t.fails(sprint.closed, "a sprint is point to point, never lapped")
	t.gt(sprint.path[0] != sprint.path[sprint.path.size() - 1], 0, "a sprint does not end where it started")

	var tt: RaceDef = cat[2]
	t.eq(tt.kind, RaceDef.Kind.TIME_ATTACK, "the third entry is a time attack")
	t.eq(tt.opponents, 0, "a time attack is solo")

	var pursuit: RaceDef = cat[3]
	t.eq(pursuit.kind, RaceDef.Kind.PURSUIT, "the fourth entry is a pursuit")
	t.gt(float(pursuit.escalation[0]), 0.0, "pursuit pressure levels are data, not systems")

	var touge: RaceDef = cat[4]
	t.eq(touge.kind, RaceDef.Kind.TOUGE, "the fifth entry is a touge run")
	var widest := RoadGraph.RoadClass.LANE
	for i in touge.path.size() - 1:
		widest = maxi(widest, _class_between(int(touge.path[i]), int(touge.path[i + 1])))
	t.between(float(widest), 0.0, float(RoadGraph.RoadClass.STREET),
		"a touge run stays on the lanes and back streets")


func _countdown(t: TestHarness) -> void:
	var dr := _on_the_grid(_field(3))

	t.eq(dr.state_name(), "countdown", "a race opens on the countdown")
	t.eq(dr.lights, 3, "three lights are on")
	t.fails(dr.can_drive(), "input is blocked before lights out")
	t.fails(dr.can_drive(cars[0]), "and the car is told so, not just the race")

	var slot: Vector3 = cars[0].position
	t.gt(slot.distance_to(Vector3(_waypoints()[0].x, 0.0, _waypoints()[0].z)), 1.0, "the grid is behind the line")
	t.gt(cars[0].position.distance_to(cars[1].position), 1.0, "cars start in separate slots")

	cars[0].position = slot + Vector3(0, 0, -40.0)
	dr.tick(0.1)
	t.near(cars[0].position.distance_to(slot), 0.0, 0.01, "a car that tries to leave before GO is held on its slot")

	dr.tick(1.0)
	t.eq(dr.lights, 2, "two lights")
	dr.tick(1.0)
	t.eq(dr.lights, 1, "one light")
	dr.tick(1.0)
	t.eq(dr.state_name(), "racing", "GO: the countdown ends in racing")
	t.eq(dr.lights, 0, "the lights go out")
	t.ok(dr.can_drive(), "input is released at lights out")
	t.near(dr.race_time, 0.0, 0.001, "the clock starts at lights out")


## The property the whole race rests on: a junction only counts if it is the
## next one due, so no amount of cutting the course banks a lap.
func _checkpoints_in_order(t: TestHarness) -> void:
	var dr := _on_the_grid(_field(1))
	_green_light(dr)
	var wps := _waypoints()

	t.eq(dr.checkpoint_count(), def.path.size() - 2, "the checkpoints are the junctions between start and line")
	t.eq(dr.next_checkpoint(0), 0, "the race opens on the first checkpoint")

	# Straight past the first two to the third.
	cars[0].position = wps[3]
	dr.tick(0.05)
	t.eq(dr.next_checkpoint(0), 0, "jumping past checkpoints does not count them")

	# And the line cannot be cashed on a short set either.
	cars[0].position = _past_line(4.0)
	dr.tick(0.05)
	t.eq(dr.laps(0), 0, "crossing the line without every checkpoint does not count a lap")
	t.eq(dr.next_checkpoint(0), 0, "the crossing restarts the checkpoint set")

	for k in range(1, def.path.size() - 1):
		cars[0].position = wps[k]
		dr.tick(0.05)
	t.eq(dr.next_checkpoint(0), dr.checkpoint_count(), "checkpoints taken in order all count")


## A whole lap driven round the real street circuit, not teleported.
func _lap_counting(t: TestHarness) -> void:
	var dr := _on_the_grid(_field(1))
	_green_light(dr)
	_drive(dr, [4.0], _route(def).size())

	t.eq(dr.laps(0), 1, "a full lap over every checkpoint counts")
	t.gt(dr.best_lap(0), 0.0, "the lap is timed")
	t.fails(dr.is_finished(0), "one lap of a two lap race is not a finish")
	t.fails(dr.laps(0) > 1, "a lap cannot be banked twice on one crossing")

	_drive(dr, [4.0], _route(def).size())
	t.eq(dr.laps(0), 2, "the second lap counts too")


## Crossing the line the wrong way, and crossing it again with no checkpoints
## banked, both have to leave the lap count alone.
func _backwards_crossing(t: TestHarness) -> void:
	var dr := _on_the_grid(_field(1))
	_green_light(dr)
	var wps := _waypoints()
	for k in range(1, def.path.size() - 1):
		cars[0].position = wps[k]
		dr.tick(0.05)
	t.eq(dr.next_checkpoint(0), dr.checkpoint_count(), "the full set is taken")

	cars[0].position = _past_line(4.0)
	dr.tick(0.05)
	t.eq(dr.laps(0), 1, "the earned crossing counts")

	cars[0].position = _past_line(-4.0)
	dr.tick(0.05)
	t.eq(dr.laps(0), 1, "rolling back over the line does not count a lap")

	cars[0].position = _past_line(4.0)
	dr.tick(0.05)
	t.eq(dr.laps(0), 1, "coming forward again with no checkpoints banked does not either")

	_drive(dr, [4.0], _route(def).size())
	t.eq(dr.laps(0), 2, "and a proper lap still counts afterwards")


func _finish(t: TestHarness) -> void:
	var dr := _on_the_grid(_field(1))
	_green_light(dr)
	t.eq(def.laps, 2, "the race under test is two laps")
	t.fails(dr.is_finished(0), "a race is not finished on the grid")

	_drive(dr, [4.0], _route(def).size())
	t.fails(dr.is_finished(0), "one lap short of the required laps is not a finish")
	t.eq(dr.state_name(), "racing", "and the race is still running")

	_drive(dr, [4.0], _route(def).size())
	t.ok(dr.is_finished(0), "the required laps finish the race")
	t.eq(dr.state_name(), "finished", "the race ends when the player crosses the line")
	t.gt(dr.results[0]["time"], 0.0, "the finishing time is recorded")
	t.eq(dr.results[0]["pos"], 1, "and the finisher is classified")

	# The loop back round: finished races reset to idle so the next one can go on
	# the grid, keeping the entry the player already paid for.
	dr.reset()
	t.eq(dr.state_name(), "idle", "a finished race resets to idle")
	t.eq(dr.results.size(), 0, "and clears its results")
	t.eq(dr.entrants.size(), 0, "and clears the grid")
	t.ok(dr.start(def, g, _field(2)), "the paid-up race can be run again")


## Position 1 is the fastest finisher; anyone still out is behind them on how
## far they got.
func _results_order(t: TestHarness) -> void:
	var wps := _route(def)

	# The player is the slowest here, so the two faster cars are already home
	# when the race is called - which is the case results ordering has to get
	# right.
	var dr := _on_the_grid(_field(3))
	_green_light(dr)
	_race(dr, [2.0, 4.0, 6.0], [wps.size() * 2, wps.size() * 2, wps.size() * 2])

	t.eq(dr.results.size(), 3, "every entrant is classified")
	t.eq(dr.results[0]["car"], cars[2], "the fastest car wins")
	t.eq(dr.results[1]["car"], cars[1], "the next fastest is second")
	t.eq(dr.results[2]["car"], cars[0], "the player is last")
	for i in dr.results.size():
		t.eq(int(dr.results[i]["pos"]), i + 1, "result %d is in position %d" % [i, i + 1])
	var ordered := true
	for i in dr.results.size() - 1:
		ordered = ordered and float(dr.results[i]["time"]) <= float(dr.results[i + 1]["time"])
	t.ok(ordered, "results are ordered by finish time")

	# Player wins the race outright, the other two are still out on the road.
	var dr2 := _on_the_grid(_field(3))
	_green_light(dr2)
	_race(dr2, [8.0, 2.0, 2.0], [wps.size() * 2, wps.size(), int(wps.size() / 2)])
	t.eq(dr2.results[0]["pos"], 1, "the player who crosses the line first is classified first")
	t.fails(dr2.results[1]["finished"], "a car still on the road is not a finisher")
	t.fails(dr2.results[2]["finished"], "neither is one that never got near the line")
	t.eq(dr2.results[1]["pos"], 2, "the car that got further is classified ahead of the one that did not")
	t.eq(dr2.results[2]["pos"], 3, "and the one that barely left is last")


## Winner takes the lot, the field is paid on a sliding scale, and it all comes
## off the player's bank less the entry fee.
func _payout(t: TestHarness) -> void:
	var d := RaceDef.circuit(g, 0, 700.0, "payout_test", "Payout Test", 1)
	d.payout = 1000
	d.entry_fee = 100

	var dr := _on_the_grid_with(d, _field(4))
	t.eq(dr.payout_for_position(1), 1000, "the winner takes the whole payout")
	t.eq(dr.payout_for_position(2), 750, "second place is paid three quarters")
	t.eq(dr.payout_for_position(3), 500, "third place is paid half")
	t.eq(dr.payout_for_position(4), 250, "last place is paid a quarter")
	t.eq(dr.payout_for_position(0), 0, "an unclassified position is paid nothing")
	t.eq(dr.payout_for_position(5), 0, "there is no fifth place in a four car race")

	var dr2 := _on_the_grid_with(d, _field(4), 1000)
	t.eq(Cfg.money, 900, "the entry fee comes off first")
	_green_light(dr2)
	_race(dr2, [8.0, 2.0, 2.0, 2.0], [_route(def).size() * 2, 1, 1, 1])
	t.eq(dr2.position_of(cars[0]), 1, "the player won")
	t.eq(Cfg.money, 1900, "the winner's payout lands on top of the fee they paid")
	t.ok(Cfg.get_race_record(d.id).has("best_time"), "the result is recorded on the player's profile")


func _entry_fee(t: TestHarness) -> void:
	var d := RaceDef.circuit(g, 0, 700.0, "gated", "Gated", 1)
	d.entry_fee = 500

	Cfg.money = 100
	var dr := RaceDirector.new()
	t.fails(dr.try_enter(d), "a race the player cannot afford refuses entry")
	t.eq(Cfg.money, 100, "a refused entry charges nothing")
	t.fails(dr.start(d, g, _field(2)), "a race that was never paid for does not start")

	Cfg.money = 500
	t.ok(dr.try_enter(d), "the same race goes through once the money is there")
	t.eq(Cfg.money, 0, "the entry fee is taken on entry")
	t.ok(dr.start(d, g, _field(2)), "and the paid-up race starts")

	var free := RaceDef.circuit(g, 0, 700.0, "free", "Free", 1)
	free.entry_fee = 0
	t.ok(RaceDirector.new().try_enter(free), "a free race is always enterable")


func _wrong_way(t: TestHarness) -> void:
	var dr := _on_the_grid(_field(1))
	_green_light(dr)
	var wps := _waypoints()
	var forward: Vector3 = (wps[6] - wps[5]).normalized()

	cars[0].position = wps[5]
	cars[0].facing = forward
	dr.tick(0.05)
	t.fails(dr.is_wrong_way(0), "a car pointing down the track is going the right way")

	cars[0].facing = -forward
	dr.tick(0.05)
	t.ok(dr.is_wrong_way(0), "a car facing back up the track is going the wrong way")

	cars[0].facing = forward
	dr.tick(0.05)
	t.fails(dr.is_wrong_way(0), "and it clears the moment the car is turned around")


# ------------------------------------------------------------------- plumbing

func _field(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(FakeCar.new())
	return out


## A fresh director on the standard two lap circuit, with `cars` on the grid.
func _on_the_grid(field: Array) -> RaceDirector:
	return _on_the_grid_with(def, field)


## A fresh director, entered and started, with `cars` on the grid. The bank is
## topped up first so one case's entry fee cannot starve the next.
func _on_the_grid_with(d: RaceDef, field: Array, money: int = 500) -> RaceDirector:
	Cfg.money = money
	var dr := RaceDirector.new()
	dr.try_enter(d)
	var ok := dr.start(d, g, field)
	assert(ok, "the test race should start: %s" % d.id)
	cars = field
	return dr


func _green_light(dr: RaceDirector) -> void:
	for i in 4:
		dr.tick(1.0)
	assert(dr.state_name() == "racing", "the countdown should be over")


## Every junction on a route as a world position, line first.
func _waypoints(d: RaceDef = def) -> Array:
	var out: Array = []
	for n in d.path:
		var p: Vector2 = g.node_pos(int(n))
		out.append(Vector3(p.x, 0.0, p.y))
	return out


## The route to drive, ending 30 m past the line. A car that stops on the start
## junction has not crossed it, so the walk carries on through it.
func _route(d: RaceDef) -> Array:
	var wps := _waypoints(d)
	wps.append(wps[0] + (wps[1] - wps[0]).normalized() * 30.0)
	return wps


## A point `m` metres past the start/finish line, along the racing direction.
func _past_line(m: float) -> Vector3:
	var wps := _waypoints()
	return wps[0] + (wps[1] - wps[0]).normalized() * m


## Walks car 0 round `count` junctions at `step` metres a tick. This is the real
## thing: the car is moved through every checkpoint and over the line the way a
## player would drive it.
func _drive(dr: RaceDirector, speeds: Array, count: int) -> void:
	var wps := _route(dr.def)
	var idx := 0
	var guard := 0
	while idx < count and guard < 40000:
		var car = cars[0]
		var target: Vector3 = wps[idx % wps.size()]
		var step: float = float(speeds[0])
		if car.position.distance_to(target) > step * 0.5:
			car.facing = (target - car.position).normalized()
			car.position = car.position.move_toward(target, step)
		else:
			idx += 1
		dr.tick(0.05)
		guard += 1


## Runs the whole field until the race is over. `speeds[i]` is metres per tick
## and `limit[i]` how many junctions car i is allowed, so a car can be left
## behind on purpose.
func _race(dr: RaceDirector, speeds: Array, limit: Array) -> void:
	var wps := _route(dr.def)
	var idx: Array = []
	for i in dr.entrants.size():
		idx.append(0)
	var guard := 0
	while dr.state_name() == "racing" and guard < 40000:
		for i in dr.entrants.size():
			if int(idx[i]) >= int(limit[i]):
				continue
			var car = dr.entrants[i]
			var target: Vector3 = wps[int(idx[i]) % wps.size()]
			var step: float = float(speeds[i])
			if car.position.distance_to(target) > step * 0.5:
				car.facing = (target - car.position).normalized()
				car.position = car.position.move_toward(target, step)
			else:
				idx[i] = int(idx[i]) + 1
		dr.tick(0.05)
		guard += 1


## The class of the road between two adjacent junctions, for checking a touge
## route never climbs out of the back streets.
func _class_between(n1: int, n2: int) -> int:
	for eid in g.nodes[n1]["edges"]:
		if g.other_node(eid, n1) == n2:
			return int(g.edges[eid]["class"])
	return RoadGraph.RoadClass.HIGHWAY
