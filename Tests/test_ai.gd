extends RefCounted
## The racing AI, on real physics. Run with: ./test.sh ai
##
## Every case here drops a real CarBody onto real ground with a real RoadGraph
## and lets the AI drive it, because the questions being asked - does it brake
## before the corner, does it come back when it is spun - are questions about
## what the car does, not about what the AI intends.
##
## Physics in a headless SceneTree advances in real time, so a run's wall clock
## is its simulated seconds. TIME_SCALE is how this suite buys back the time the
## brief asks for; it is put back after every case so no other suite inherits it.

## Presents a CarBody to RaceDirector the way the game does: something with a
## `position` and a `facing` that the race can move and read.
class Racer extends RefCounted:
	var body: CarBody
	var position: Vector3:
		get: return body.global_position
		set(v):
			# The director holds cars on their grid slots by re-setting position
			# every frame of the countdown. Setting a position on a rigid body is a
			# teleport, and without clearing the velocity the car quietly
			# accelerates while parked and launches off the line at 40 km/h.
			if v.distance_squared_to(body.global_position) > 0.0001:
				body.linear_velocity = Vector3.ZERO
				body.angular_velocity = Vector3.ZERO
			body.global_position = v
	var facing: Vector3:
		get: return body.forward()
		set(v):
			var flat := Vector3(v.x, 0.0, v.z)
			if flat.length_squared() < 0.0001:
				return
			body.global_position.y = v.y
			body.basis = Basis.looking_at(flat.normalized(), Vector3.UP)


const CAR_ID := "shinobi_rs"
const DT := 1.0 / 60.0
## The circuit the game races.
const MAIN_TARGET := 700.0
## A short loop through the same streets, for the cases that do not need a
## whole lap of the long one.
const SHORT_TARGET := 400.0
const TIME_SCALE := 3.0

var g: RoadGraph


func run(t: TestHarness) -> void:
	# The first suite in a run is called before the SceneTree has settled, and a
	# node added to the root in that window never enters the tree - so its
	# physics never runs. One frame first, and everything below can rely on the
	# world actually existing.
	await t.ticks(1)
	g = RoadGraph.new()
	g.build(ManundaLayout.corridors())
	Cfg.money = 99999

	await _drives_a_lap(t)
	await _brakes_before_the_corner(t)
	await _overtakes(t)
	await _no_gap_no_pass(t)
	await _recovers_from_a_spin(t)
	await _skill_changes_pace(t)
	await _makes_mistakes(t)
	Engine.time_scale = 1.0


# ----------------------------------------------------------------- the world

## Flat ground and nothing else. There are no walls: how far off the road the AI
## strays is measured, not enforced, which is the property worth testing.
func _spawn(t: TestHarness, name: String) -> Node3D:
	var world := t.new_root(name)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3000, 1, 3000)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)
	return world


func _car(world: Node3D, at: Vector3, yaw: float = 0.0) -> CarBody:
	var c := CarBody.new()
	c.spec = CarDB.get_spec(CAR_ID)
	world.add_child(c)
	c.reset_to(at, Vector3(0, yaw, 0))
	return c


## A race, with the car on the grid and the AI driving the exact route the race
## is scored on - the same line, not a lookalike.
func _setup_race(t: TestHarness, world: Node3D, laps: int = 2, target: float = SHORT_TARGET) -> Dictionary:
	var def := RaceDef.circuit(g, 0, target, "ai_test", "AI Test", laps)
	var dr := RaceDirector.new()
	dr.try_enter(def)
	var body := _car(world, Vector3.ZERO)
	var racer := Racer.new()
	racer.body = body
	var ok := dr.start(def, g, [racer])
	assert(ok, "the AI test race should start")
	var ai := AIRacer.new()
	ai.car = body
	ai.graph = g
	ai.skill = 0.8
	ai.director = dr
	world.add_child(ai)
	# The driver builds its line on the first physics frame; the tests below all
	# ask it where the car is, so let it get there before any of them look.
	await t.ticks(3)
	return {"def": def, "director": dr, "car": body, "ai": ai, "world": world}


## Runs the simulation, driving the race forward alongside the physics.
## Everything the assertions need is measured on the way past.
func _run(t: TestHarness, setup: Dictionary, seconds: float) -> Dictionary:
	var dr: RaceDirector = setup["director"]
	var car: CarBody = setup["car"]
	var steps: int = int(seconds / DT)
	var off_road := 0
	var samples := 0
	var off_road_recover := 0
	var worst_ratio := 0.0
	var max_over := 0.0
	var brake_ahead := 0.0
	var max_kph := 0.0
	var went_off := false
	var last_speed := 0.0
	var worst_at := ""
	for i in steps:
		await t.ticks(1)
		dr.tick(DT)
		if car.global_position.y < -5.0:
			went_off = true
			break
		if dr.state_name() == "finished":
			break
		if i % 3 != 0:
			continue
		# Braking is judged by what the car is doing, not by which pedal it is
		# on: a driver that lifts early is braking, and lifting early is better.
		if car.speed_mps < last_speed - 0.05:
			brake_ahead = maxf(brake_ahead, _distance_to_slow(setup, car))
		last_speed = car.speed_mps
		var near: Dictionary = g.nearest_road(car.global_position)
		var lat: float = float(near["lateral"])
		var cls: int = int(g.edges[int(near["edge"])]["class"])
		samples += 1
		# On the road means inside the tarmac at the point it is at, not inside
		# the widest road in the network.
		var half: float = g.width_for(cls) * 0.5
		if lat > half + 1.5:
			off_road += 1
			if int(setup["ai"].mode) == AIRacer.Mode.RECOVER:
				off_road_recover += 1
		if lat / maxf(half, 0.1) > worst_ratio:
			worst_ratio = lat / maxf(half, 0.1)
			worst_at = "t=%.0fs %s off=%s mode=%d kph=%.0f" % [
				dr.race_time, "lat=%.1f half=%.1f" % [lat, half],
				str(car.global_position.round()), setup["ai"].mode, car.speed_kph]
		var road_limit: float = g.speed_for(cls)
		max_over = maxf(max_over, car.speed_mps - road_limit)
		max_kph = maxf(max_kph, car.speed_kph)
	return {
		"off_road": off_road,
		"samples": samples,
		"off_road_recover": off_road_recover,
		"worst_ratio": worst_ratio,
		"max_over": max_over,
		"brake_ahead": brake_ahead,
		"max_kph": max_kph,
		"laps": dr.laps(0),
		"time": dr.race_time,
		"errors": setup["ai"].errors,
		"off_world": went_off,
		"worst_at": worst_at,
	}


## Metres along the line to the nearest point the line is much slower than here.
## Positive means there was a corner still ahead of the car when it braked, which
## is the whole difference between braking before a corner and braking in it.
func _distance_to_slow(setup: Dictionary, car: CarBody) -> float:
	var line: RacingLine = setup["ai"].line()
	if line == null or line.size() < 4:
		return 0.0
	var i: int = _index_of(setup, car)
	var here: float = car.speed_mps
	for k in range(1, line.size()):
		if float(line.speed_at((i + k) % line.size())) < here - 3.0:
			return float(k) * line.spacing
	return 0.0


# ---------------------------------------------------------------------- cases

## The headline. One lap of the real Manunda Street Circuit, timed by the race
## system itself rather than by the test - and the same lap is where the
## road-holding and speed-limit promises get checked, because they are the same
## lap.
func _drives_a_lap(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var setup := await _setup_race(t, _spawn(t, "LapWorld"), 1, MAIN_TARGET)
	var length: float = setup["def"].length_m(g)
	var r := await _run(t, setup, 95.0)
	t.fails(bool(r["off_world"]), "the car stayed on the world for the whole lap")
	t.gt(float(r["laps"]), 0.0, "the AI completed a lap of the real circuit (%.0f m) in %.1f s" % [length, r["time"]])
	# "Stays on the road surface" measured the way the brief words it: the worst
	# offset bounded against the width of the road it is on. A driver that runs
	# a couple of metres wide at a hairpin and gathers it up is racing; one that
	# spends the lap in a side street is not.
	t.between(float(r["worst_ratio"]), 0.0, 2.2,
		"and held the road all lap - worst %.2f of the way across at %s" % [r["worst_ratio"], r["worst_at"]])
	t.gt(99.9, float(r["off_road"]) / maxf(float(r["samples"]), 1.0) * 100.0,
		"and was on the road surface for %.1f%% of the lap (%d of %d samples over the kerb, %d while recovering)" % [
			100.0 - float(r["off_road"]) / maxf(float(r["samples"]), 1.0) * 100.0,
			r["off_road"], r["samples"], r["off_road_recover"]])
	t.between(float(r["max_over"]), -99.0, 6.0,
		"and never ran more than %.1f m/s over the posted limit (top speed %.0f km/h)" % [r["max_over"], r["max_kph"]])
	Engine.time_scale = 1.0
	await t.drop(setup["world"])


func _brakes_before_the_corner(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var setup := await _setup_race(t, _spawn(t, "BrakeWorld"), 1, MAIN_TARGET)
	var r := await _run(t, setup, 35.0)
	t.gt(float(r["brake_ahead"]), 10.0,
		"it was still braking %.0f m before a corner, not in the corner" % r["brake_ahead"])
	Engine.time_scale = 1.0
	await t.drop(setup["world"])


## A slow car in the way on a street wide enough to get round: the AI should go
## past it and come out in front, not drive through it.
func _overtakes(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var setup := await _setup_race(t, _spawn(t, "PassWorld"), 1)
	var dr: RaceDirector = setup["director"]
	var car: CarBody = setup["car"]
	var ai: AIRacer = setup["ai"]
	var world: Node3D = setup["world"]

	var blocker := _car(world, _point_on_route(setup, 35.0), _yaw_at(setup, 35.0))
	ai.rivals = [blocker]
	var got_past := false
	var min_gap := 99.0
	for i in int(35.0 / DT):
		await t.ticks(1)
		dr.tick(DT)
		# Held still on the road ahead. A blocker that drives itself off into a
		# block within a few corners stops being a test of overtaking.
		blocker.throttle = 0.0
		blocker.brake = 1.0
		blocker.steer = 0.0
		var ci: int = _index_of(setup, car)
		var bi: int = _index_of(setup, blocker)
		min_gap = minf(min_gap, _gap_between(car, blocker))
		if _is_ahead(setup, bi, ci):
			got_past = true
	t.ok(got_past, "the AI got past the slow car in front of it")
	t.between(min_gap, 0.0, 12.0, "having actually had to pass it (closest %.1f m)" % min_gap)
	t.gt(min_gap, 1.3, "and giving it room rather than driving through it")
	Engine.time_scale = 1.0
	await t.drop(world)


## Two slow cars filling the road: there is no gap, so the AI has to sit behind
## rather than start a pass that cannot fit.
func _no_gap_no_pass(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var setup := await _setup_race(t, _spawn(t, "WallWorld"), 1)
	var dr: RaceDirector = setup["director"]
	var car: CarBody = setup["car"]
	var ai: AIRacer = setup["ai"]
	var world: Node3D = setup["world"]

	var line: RacingLine = ai.line()
	var here_i: int = int(round(45.0 / line.spacing))
	var centre: Vector2 = line.point_at(here_i, 0.0)
	var along: Vector2 = line.direction_at(here_i)
	var side := Vector3(along.y, 0.0, -along.x)
	var yaw: float = atan2(-along.x, -along.y)
	# Across the racing line, not the road centre: that is the line the driver
	# measures its room from, and the two can be a couple of metres apart.
	var offset: float = line.width_at(here_i) * 0.5 * 0.8
	var left := _car(world, Vector3(centre.x, 0.0, centre.y) - side * offset, yaw)
	var right := _car(world, Vector3(centre.x, 0.0, centre.y) + side * offset, yaw)
	ai.rivals = [left, right]

	var attempted := false
	var min_gap := 99.0
	var reached := false
	for i in int(25.0 / DT):
		await t.ticks(1)
		dr.tick(DT)
		for c in [left, right]:
			c.throttle = 0.0
			c.brake = 1.0
			c.steer = 0.0
		if not reached and _gap_between(car, left) < 30.0:
			reached = true
		if reached:
			min_gap = minf(min_gap, minf(_gap_between(car, left), _gap_between(car, right)))
		if ai.attempting_pass() != 0.0:
			attempted = true
	t.ok(reached, "the AI caught up to the two cars blocking the road")
	if reached:
		# The driver's own decision, not index arithmetic: two cars in contact
		# can shuffle a car forward along the line without it being a pass.
		t.fails(attempted, "with no gap it never committed to a pass")
		t.gt(min_gap, 1.2, "and did not drive through it either (closest %.1f m)" % min_gap)
	Engine.time_scale = 1.0
	await t.drop(world)


## Spun and facing the wrong way. This is the one that is easy to write and not
## to test, so it is tested: a car pointed backwards at a known point on the
## route has to be driving the right way again, in bounded time.
func _recovers_from_a_spin(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var setup := await _setup_race(t, _spawn(t, "SpinWorld"), 2)
	var dr: RaceDirector = setup["director"]
	var car: CarBody = setup["car"]
	var ai: AIRacer = setup["ai"]

	# Backwards on the racing line, pointing up the oncoming lane.
	car.reset_to(_point_on_route(setup, 80.0), Vector3(0, _yaw_at(setup, 80.0) + PI, 0))
	await t.ticks(2)

	var recovered := -1.0
	var elapsed := 0.0
	var give_up := 25.0
	for i in int(give_up / DT):
		await t.ticks(1)
		dr.tick(DT)
		elapsed += DT
		var line: RacingLine = ai.line()
		var here: Dictionary = line.project(Vector2(car.global_position.x, car.global_position.z), ai.line_index())
		var lat: float = absf(float(here["lateral"]))
		# Against the line where the car is now, not against a fixed point it has
		# already driven away from.
		var want: Vector2 = line.direction_at(int(here["i"]))
		var heading: float = Vector2(car.forward().x, car.forward().z).normalized().dot(want)
		if heading > 0.5 and lat < 6.0 and car.speed_mps > 3.0:
			recovered = elapsed
			break
	t.gt(recovered, 0.0, "a car spun 180 degrees was driving the right way again")
	if recovered > 0.0:
		t.between(recovered, 0.1, 14.0, "and it rejoined the route in %.1f s" % recovered)
	Engine.time_scale = 1.0
	await t.drop(setup["world"])


## Two drivers, same circuit, same car: the better one has to cover more road in
## the same time. Measured over distance rather than a full lap, because two
## full laps of physics is most of this suite's wall clock.
func _skill_changes_pace(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var fast := await _pace_over(t, 0.95)
	var slow := await _pace_over(t, 0.25)
	if fast <= 0.0 or slow <= 0.0:
		t.ok(false, "both skill levels drove (fast %.0f m, slow %.0f m)" % [fast, slow])
		return
	t.gt(fast, slow * 1.05, "a high-skill driver covers more road in the same time (%.0f m vs %.0f m)" % [fast, slow])


## Metres along the racing line covered in a fixed window.
func _pace_over(t: TestHarness, at_skill: float) -> float:
	var setup := await _setup_race(t, _spawn(t, "Skill%d" % int(at_skill * 100)), 3)
	var ai: AIRacer = setup["ai"]
	ai.skill = at_skill
	ai.aggression = at_skill
	ai.rng_seed = 4242
	var dr: RaceDirector = setup["director"]
	var car: CarBody = setup["car"]
	var start_i: int = _index_of(setup, car)
	var furthest := start_i
	for i in int(35.0 / DT):
		await t.ticks(1)
		dr.tick(DT)
		if car.global_position.y < -5.0:
			break
		furthest = maxi(furthest, _index_of(setup, car))
	var line: RacingLine = ai.line()
	var covered: float = float(furthest - start_i) * line.spacing
	await t.drop(setup["world"])
	return covered


## A fallible driver makes mistakes; a near-flawless one does not.
func _makes_mistakes(t: TestHarness) -> void:
	Engine.time_scale = TIME_SCALE
	var sloppy := await _setup_race(t, _spawn(t, "SloppyWorld"), 3)
	sloppy["ai"].skill = 0.3
	sloppy["ai"].aggression = 0.4
	var sloppy_run := await _run(t, sloppy, 45.0)
	t.gt(int(sloppy_run["errors"]), 0, "a low-skill driver made %d mistakes" % sloppy_run["errors"])
	await t.drop(sloppy["world"])

	var clean := await _setup_race(t, _spawn(t, "CleanWorld"), 3)
	clean["ai"].skill = 0.96
	clean["ai"].aggression = 0.5
	var clean_run := await _run(t, clean, 45.0)
	t.eq(int(clean_run["errors"]), 0, "a near-flawless driver made none (%d)" % clean_run["errors"])
	Engine.time_scale = 1.0
	await t.drop(clean["world"])


# ------------------------------------------------------------------- geometry

## A point `m` metres along the route from the start line.
func _point_on_route(setup: Dictionary, m: float) -> Vector3:
	var pts: Array = setup["director"].route_points()
	var s: float = fposmod(m, setup["director"].route_length())
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg: float = a.distance_to(b)
		if s <= seg or i == pts.size() - 2:
			var p: Vector2 = a.lerp(b, clampf(s / maxf(seg, 0.01), 0.0, 1.0))
			return Vector3(p.x, 0.0, p.y)
		s -= seg
	return Vector3.ZERO


## Half the width of the road at a point on the route.
func _road_half_width(setup: Dictionary, m: float) -> float:
	var near: Dictionary = g.nearest_road(_point_on_route(setup, m))
	if int(near["edge"]) < 0:
		return 4.5
	return g.width_for(int(g.edges[int(near["edge"])]["class"])) * 0.5


func _direction_at(setup: Dictionary, m: float) -> Vector3:
	var d: Vector3 = _point_on_route(setup, m + 3.0) - _point_on_route(setup, m)
	d.y = 0.0
	return d.normalized() if d.length() > 0.01 else Vector3.FORWARD


## Heading that makes a car face along the route at `m`.
func _yaw_at(setup: Dictionary, m: float) -> float:
	var d: Vector3 = _direction_at(setup, m)
	return atan2(-d.x, -d.z)


## Where a car sits on the racing line, as an index into it.
func _index_of(setup: Dictionary, car: CarBody) -> int:
	var ai: AIRacer = setup["ai"]
	return int(ai.line().project(Vector2(car.global_position.x, car.global_position.z), ai.line_index())["i"])


## Metres from `from_i` forward round the lap to `to_i`. On a closed circuit
## "ahead" is a distance, not a comparison, which is how the traffic tests decide
## whether the AI has actually got past something.
func _forward_gap(setup: Dictionary, from_i: int, to_i: int) -> float:
	var line: RacingLine = setup["ai"].line()
	var n: int = line.size()
	if not line.closed:
		return float(to_i - from_i) * line.spacing
	return float((to_i - from_i + n) % n) * line.spacing


## True when `to_i` is in front of `from_i` rather than a whole lap behind it.
func _is_ahead(setup: Dictionary, from_i: int, to_i: int) -> bool:
	var gap: float = _forward_gap(setup, from_i, to_i)
	return gap > 0.5 and gap < _forward_gap(setup, 0, setup["ai"].line().size() / 2)


## Centre-to-centre distance between two cars, on the ground plane.
func _gap_between(a: CarBody, b: CarBody) -> float:
	return Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()
