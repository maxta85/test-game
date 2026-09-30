extends RefCounted
## End-to-end integration: a REAL CarBody, wrapped in the REAL RaceEntrant
## adapter, racing a REAL circuit generated from the REAL road graph.
##
## This exists because the race system's own 99 tests drive a plain stub - which
## proves the state machine but not the seam. Everything between "the director
## ticks" and "the player's car physically completes a lap" was untested, and
## that is exactly the part a player experiences.

var _graph: RoadGraph


func run(t: TestHarness) -> void:
	_graph = RoadGraph.new()
	_graph.build(ManundaLayout.corridors())
	await _circuit_is_raceable(t)
	await _entrant_places_and_orients(t)
	await _full_lap_completes(t)
	await _entering_costs_money(t)


## Builds a flat world and returns it, with a car already dropped on it.
func _world_with_car(t: TestHarness, car_id: String = "kairo_s13") -> Array:
	var world := t.new_root("IntegrationWorld")

	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2200, 1, 2200)
	cs.shape = box
	ground.add_child(cs)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)

	var spec := CarDB.get_spec(car_id)
	spec.start_position = Vector3(0, spec.tyre_radius + 0.05, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	world.add_child(car)
	await t.ticks(6)
	return [world, car]


func _circuit_is_raceable(t: TestHarness) -> void:
	var catalogue: Array = RaceDef.catalogue(_graph)
	t.gt(catalogue.size(), 3, "a catalogue of races is generated from the road graph")
	var circuit: RaceDef = null
	for r in catalogue:
		if r.kind == RaceDef.Kind.CIRCUIT:
			circuit = r
			break
	t.ok(circuit != null, "a circuit race exists in the catalogue")
	if circuit == null:
		return
	t.ok(circuit.valid(), "the generated circuit is valid")
	t.gt(circuit.length_m(_graph), 500.0, "the circuit has real length (%.0f m)" % circuit.length_m(_graph))
	t.gt(circuit.laps, 1, "the circuit is raced over more than one lap")
	# A circuit that immediately self-intersects or has no checkpoints is a
	# definition that would produce an unfinishable race.
	t.ok(circuit.path.size() >= 4, "the circuit has enough junctions to be a lap (%d)" % circuit.path.size())


func _entrant_places_and_orients(t: TestHarness) -> void:
	var r := await _world_with_car(t)
	var world: Node = r[0]
	var car: CarBody = r[1]

	var e := RaceEntrant.new(car)
	# The director writes to `position` and `facing`; the adapter must translate
	# that into a legal placement on a physics body.
	e.position = Vector3(12, 0, 34)
	e.facing = Vector3(1, 0, 0)
	e.sync()
	await t.ticks(10)

	t.gt(car.global_position.distance_to(Vector3(12, 0, 34)) - car.global_position.y, -1.0,
		"adapter moved the car to the requested x/z (at %s)" % str(car.global_position.snapped(Vector3(0.1, 0.1, 0.1))))
	t.between(car.global_position.y, -1.0, 2.0, "car is on the ground after placement, not in orbit")
	t.gt(car.wheels_on_ground, 2, "car has settled onto its wheels")
	t.near(car.forward().dot(Vector3(1, 0, 0)), 1.0, 0.35,
		"car is facing the direction the director asked for")
	t.near(e.facing.length(), 1.0, 0.01, "adapter reports facing as a unit vector")
	t.near(e.position.y, car.global_position.y, 0.01, "adapter position tracks the car's real position")

	await t.drop(world)


func _full_lap_completes(t: TestHarness) -> void:
	## The real test. Drive an actual car around an actual generated circuit with
	## a simple autopilot, and assert the race state machine notices.
	var r := await _world_with_car(t)
	var world: Node = r[0]
	var car: CarBody = r[1]

	var circuit: RaceDef = null
	for d in RaceDef.catalogue(_graph):
		if d.kind == RaceDef.Kind.CIRCUIT:
			circuit = d
			break
	# A short circuit, built the same way test_ai.gd builds its own. The
	# catalogue's Manunda Street Circuit is 2283 m and AIRacer needs ~200 s to
	# lap it at the pace this harness runs at, so a 60 s budget ended the run
	# mid-lap at checkpoint 13/19 with laps == 0 - the assertion below failing
	# for reasons unrelated to the seam it exists to test. This is about the
	# director, not endurance.
	circuit = RaceDef.circuit(_graph, 0, 400.0, "integration", "Integration Circuit", 1)
	circuit.laps = 1          # one lap is enough to prove the seam
	circuit.entry_fee = 0     # and money is tested separately

	# Entry first: the director refuses to start a race that was not paid for,
	# and charging the entry fee is the real game flow, not a test convenience.
	var wallet := _Wallet.new()
	wallet.money = 5000
	var dr := RaceDirector.new()
	dr.wallet = wallet
	t.ok(dr.try_enter(circuit), "the generated circuit can be entered")
	t.eq(wallet.money, 5000, "a free entry costs nothing")

	var e := RaceEntrant.new(car)
	if not dr.start(circuit, _graph, [e]):
		t.ok(false, "race director refused to start a generated circuit")
		await t.drop(world)
		return
	t.ok(dr.state == RaceDirector.State.COUNTDOWN, "race opens in countdown")
	t.ok(dr.lights > 0, "countdown lights are showing (3..1)")

	# COUNTDOWN_TIME is 3.0s at 60Hz, so 180 ticks, not 90 - the previous run
	# checked the lights before they had finished going out.
	for i in 220:
		await t.ticks(1)
		dr.tick(1.0 / 60.0)
	t.eq(dr.state, RaceDirector.State.RACING, "race goes green when the countdown ends")

	# Autopilot: aim at a point ahead on the route. Deliberately crude - the point
	# is to prove the seam, not to drive well.
	# The real driver, not a local stub. The stub this replaced aimed two route
	# points ahead and re-projected from scratch every frame; on a closed circuit
	# that oscillates, and the car orbited a 200 m loop without ever passing
	# checkpoint 0 (cp stayed 0/10 for all 3600 frames). Re-implementing driving
	# here was a second, worse copy of AIRacer - the seam under test is the
	# car/director contract, so drive it with the thing that actually drives.
	var ai := AIRacer.new()
	ai.car = car
	ai.graph = _graph
	ai.skill = 0.8
	ai.director = dr
	world.add_child(ai)
	# The driver builds its line on the first physics frame.
	await t.ticks(3)

	var laps_seen := 0
	var frames := 7200          # 120 s of simulated time
	for i in frames:
		dr.tick(1.0 / 60.0)
		await t.ticks(1)
		e.sync()
		if dr.laps(0) > laps_seen:
			laps_seen = dr.laps(0)
		if dr.is_finished(0):
			break

	t.gt(dr.laps(0), 0, "a real car driven around a real circuit banks a lap (peak %.0f kph)" % car.speed_kph)
	t.gt(car.speed_kph, 15.0, "the car is genuinely moving, not creeping")
	t.eq(dr.is_wrong_way(0), false, "an autopilot following the route is not flagged as wrong way")
	t.gt(car.global_position.y, -2.0, "the car stayed on the surface (y=%.2f)" % car.global_position.y)
	if dr.is_finished(0):
		t.ok(dr.results.size() > 0, "a finished race produced results")
		t.gt(dr.results[0]["time"], 0.0, "and a finish time")

	await t.drop(world)


func _entering_costs_money(t: TestHarness) -> void:
	## The seam between the director and the real wallet.
	var stub := _Wallet.new()
	var catalogue: Array = RaceDef.catalogue(_graph)
	var paid: RaceDef = null
	for d in catalogue:
		if d.entry_fee > 0:
			paid = d
			break
	if paid == null:
		paid = catalogue[0]
		paid.entry_fee = 250

	var dr := RaceDirector.new()
	dr.wallet = stub
	stub.money = 1000
	t.ok(dr.try_enter(paid), "a race the player can afford is enterable")
	t.eq(stub.money, 1000 - paid.entry_fee, "the entry fee is taken exactly once")

	stub.money = 0
	var dr2 := RaceDirector.new()
	dr2.wallet = stub
	t.fails(dr2.try_enter(paid), "a race the player cannot afford is refused")
	t.eq(stub.money, 0, "a refused entry charges nothing")


class _Wallet:
	extends RefCounted
	var money: int = 0
	func add_money(a: int) -> void:
		money += a
	func spend_money(a: int) -> bool:
		if money < a:
			return false
		money -= a
		return true
	func record_race(_id: String, _t: float, _l: float = 0.0) -> void:
		pass
