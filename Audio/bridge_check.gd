extends SceneTree
## Acceptance gate for the audio bridge. Run:
##   godot --headless --audio-driver Dummy --path . --script res://Audio/bridge_check.gd
##
## Drives a real `RaceDirector` over a real street graph with a real `CarBody`
## behind it, and checks the only two things the bridge exists to do: the
## countdown reaches the cue bank as 3-2-1-GO exactly once each, and the car's
## rpm reaches the engine voice.
##
## It drives the bridge the game runs - `AudioService`'s - rather than making one
## of its own. An autoload has been in the tree since the first frame, so a
## bridge built here would be the second one and would stand down on its first
## frame, testing nothing. Driving the incumbent means what is checked is the
## path the game actually takes.
##
## The negative cases are the point. A bridge that read nothing would leave the
## synth at idle, and a bridge that fired on every poll would produce sixty beeps
## a second, so both of those are asserted against directly rather than left to
## be inferred from a count that also passes when the bridge is absent.
##
## ORIGINAL GAME CONTENT.

## Frames a physics run needs before a car's engine has come off idle. The
## drivetrain lerps toward free revs at 16/s, so a third of a second is short of
## enough - the assertion is a ratio, not a value, so it only has to be the
## right side of one.
const REVS := 30
## Half of the audio thread's 80 ms rpm smoother, to five time constants: long
## enough that the synth is sounding the rpm it was given rather than still on
## its way to it.
const SETTLE := 0.4

var _passed: int = 0
var _failed: int = 0
var _failures: Array[String] = []

## The only thing here that is not the real thing. `Cfg` is an autoload, and
## autoload identifiers are not registered under `--script`, so the director is
## handed a wallet rather than left to find one it cannot reach.
class Wallet extends RefCounted:
	var money: int = 100000
	func add_money(a: int) -> void:
		money += a
	func spend_money(a: int) -> bool:
		if money < a:
			return false
		money -= a
		return true
	func record_race(_id: String, _t: float, _l: float = 0.0) -> void:
		pass


## The contract a *race entrant* needs, which is not the same contract a
## `CarBody` satisfies: the director writes `facing` onto every car it starts,
## and `CarBody` has no such property, so the scored cars here are stubs of the
## kind `test_race.gd` uses. The bridge's own car is a real one, below - the two
## are separate jobs, and the bridge only ever reads rpm and throttle off its
## own. Worth knowing before someone hands `main.gd` a `CarBody` and watches
## `RaceDirector.start()` fail on it.
class GridCar extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var facing: Vector3 = Vector3.FORWARD


func _initialize() -> void:
	await _run()
	_report()


# ------------------------------------------------------------------ the wiring

func _run() -> void:
	# One frame before anything is read: the autoload is in the tree from the
	# start but its `_ready` is not called until the tree starts iterating, so
	# `AudioService.instance` is null until then.
	await process_frame
	var graph := RoadGraph.new()
	graph.build(ManundaLayout.corridors())
	var def := RaceDef.circuit(graph, 0, 700.0, "bridge_test", "Bridge Test", 1)
	_ok(def.valid(), "the check has a real circuit to score a race on")

	var world := _world()
	await _check_wiring(world)
	await _check_countdown(world, graph, def)
	await _check_engine(world)
	await _check_freed(world, graph, def)
	_teardown(world)


## A flat plate under the whole playable block. Without it the car free-falls
## for the length of the check, and a car in free-fall is not a car whose engine
## note means anything.
func _world() -> Node3D:
	var world := Node3D.new()
	world.name = "BridgeWorld"
	root.add_child(world)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1600, 1, 1600)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	world.add_child(ground)
	return world


func _car(world: Node3D) -> CarBody:
	var spec := CarDB.get_spec("kairo_s13")
	spec.start_position = Vector3(0, spec.tyre_radius + 0.04, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	car.build_visual = false
	world.add_child(car)
	return car


func _check_wiring(world: Node3D) -> void:
	var service := AudioService.instance
	_ok(service != null, "the game has a bridge to drive, from its autoload")
	if service == null:
		return
	var bridge := service.bridge
	_ok(bridge != null, "the service is holding one")
	_ok(bridge.director != null, "and it has a director")
	_ok(bridge.director == AudioDirector.instance,
			"which is the one the rest of the game reaches through the static")

	# The knob, driven the way a settings menu drives it.
	bridge.master_volume = 0.5
	_ok(absf(AudioBuses.master_volume() - 0.5) < 0.01,
			"the master volume knob reaches the Master bus  (%.3f, want 0.500)" % AudioBuses.master_volume())
	bridge.master_volume = 1.0
	bridge.master_volume = NAN
	_ok(absf(AudioBuses.master_volume() - 1.0) < 0.01,
			"a NaN off the volume knob leaves the mix alone rather than silencing the game")

	# A bridge with nothing to read is idle, not broken, and saying so is worth
	# a check: the alternative is it throwing on frame one of every session.
	_fails(bridge.lost, "a bridge with no race and no car has not lost anything")
	bridge.race = RaceDirector.new()
	await physics_frame
	await physics_frame
	_fails(bridge.lost, "and a director on its own is not a loss either")
	bridge.race = null

	# The duplicate, which is what a host that also wires audio from its own
	# `_ready` produces: a second bridge, a second engine voice and a second poll
	# of the same car. The second one stops rather than doubling the game.
	var second := AudioBridge.new()
	second.name = "BridgeDuplicate"
	world.add_child(second)
	await physics_frame
	await physics_frame
	_ok(second.standing_down, "a second bridge stands down instead of doubling the engine")
	_ok(second.director == null or second.director == bridge.director,
			"and never makes a second engine voice")
	_drop(second)
	await process_frame
	_fails(is_instance_valid(second), "and the bridge itself is gone, so this case is not checking a live one")
	_fails(bridge.standing_down, "and the game's own bridge is still polling")


## The countdown, end to end, off a real `RaceDirector`. The bridge is attached
## *before* the race starts, because a director sits at 0 on the grid and a GO
## fired there would be the loudest possible way to be wrong.
func _check_countdown(world: Node3D, graph: RoadGraph, def: RaceDef) -> void:
	var car := _car(world)
	var race := RaceDirector.new()
	race.wallet = Wallet.new()
	var bridge := AudioService.instance.bridge
	bridge.race = race
	bridge.car = car
	await physics_frame
	await physics_frame

	_ok(race.try_enter(def), "the test race is paid for")
	var cues: Array[String] = []
	_eq(race.lights, 0, "an unstarted race is sitting at no lights")
	var before := bridge.director.cues_played
	await physics_frame
	await physics_frame
	_eq(bridge.director.cues_played, before, "so an idle director makes no sound - no GO at race load")

	_ok(race.start(def, graph, [GridCar.new(), GridCar.new()]), "the race starts")
	await physics_frame
	_collect(bridge.director, cues)
	_eq(race.lights, 3, "three lights are on")
	for _i in 3:
		race.tick(1.0)
		await physics_frame
		_collect(bridge.director, cues)

	_eq(cues, ["count_3", "count_2", "count_1", "go"] as Array[String],
			"3-2-1-GO comes out of the director in order, once each  (got %s)" % str(cues))
	_eq(bridge.director.cues_played, 4, "and the whole countdown is four cues, not one per poll")
	_eq(race.state_name(), "racing", "the countdown is over")

	# Polled at 60 Hz through a second of racing, the lights do not change. If
	# the bridge fired on the poll rather than on the change, this is sixty cues.
	before = bridge.director.cues_played
	for _i in 60:
		race.tick(1.0 / 60.0)
		await physics_frame
	_eq(bridge.director.cues_played, before, "sixty polls of an unchanged light make no sound")

	# A second race on the same director: the lights go back up, and the beeps
	# have to come with them.
	cues.clear()
	_ok(race.start(def, graph, [GridCar.new()]), "a second race starts on the same director")
	await physics_frame
	_collect(bridge.director, cues)
	_eq(cues, ["count_3"] as Array[String], "and the lights come back on with a fresh beep")

	# Detached rather than freed: this bridge is the game's, and the service polls
	# it every frame.
	bridge.race = null
	bridge.car = null
	car.queue_free()
	await process_frame
	await process_frame


## The engine, fed by the car's own drivetrain. rpm is not written by the check:
## a real CarBody is put on full throttle and its physics step is what moves the
## revs, so a bridge reading the wrong field, or scaling it, fails here.
func _check_engine(world: Node3D) -> void:
	var car := _car(world)
	var race := RaceDirector.new()
	var bridge := AudioService.instance.bridge
	bridge.race = race
	bridge.car = car
	await physics_frame
	await physics_frame

	var synth := bridge.director.engine_synth()
	_ok(synth != null, "the engine voice is reachable through the bridge's director")

	car.throttle = 0.0
	for _i in REVS:
		await physics_frame
	var idle_rpm: float = car.engine_rpm
	var hz_idle := _settled(synth)

	car.throttle = 1.0
	for _i in REVS:
		await physics_frame
	# One more frame, so the last rpm the car reached is the one the bridge last
	# pushed rather than the one before it.
	await physics_frame
	var hot_rpm: float = car.engine_rpm
	var hz_hot := _settled(synth)

	_ok(hot_rpm > idle_rpm * 2.0,
			"full throttle on a real car takes the revs off idle  (%.0f -> %.0f rpm)" % [idle_rpm, hot_rpm])
	_ok(hz_hot > hz_idle * 1.5,
			"and the engine voice follows them  (%.1f -> %.1f Hz)" % [hz_idle, hz_hot])
	# Against the cylinders the voice is actually sounding, not the synth's
	# six-cylinder default: the service retunes it to the car, and an
	# expectation pinned to the default would be asserting that it does not.
	_ok(synth.cylinders == int(AudioService.CYLINDERS["kairo_s13"]),
			"and it is sounding the cylinders this car has, not the default  (%d)" % synth.cylinders)
	var want := EngineSynth.firing_frequency(hot_rpm, synth.cylinders)
	_ok(absf(hz_hot - want) < want * 0.15,
			"landing on the pitch those revs should be sounding  (%.1f Hz, want ~%.1f)" % [hz_hot, want])

	# The comparison itself: an engine nothing ever fed. Without this the two
	# assertions above also pass against a bridge that reads no rpm at all.
	var untouched := EngineSynth.new()
	_settle(untouched)
	_ok(untouched.frequency() < hz_idle * 1.5,
			"an engine nothing fed stays at idle  (%.1f Hz), so the two above are not vacuous" % untouched.frequency())

	# Load is the other half of what goes in, and it is a different number from
	# rpm: same revs, more load, a harder sound.
	car.throttle = 0.0
	for _i in REVS:
		await physics_frame
	var off := _settled(synth)
	car.throttle = 1.0
	for _i in REVS:
		await physics_frame
	var on := _settled(synth)
	_ok(on > off * 1.5, "throttle opens the engine as well as moving it  (%.4f -> %.4f)" % [off, on])

	bridge.race = null
	bridge.car = null
	car.queue_free()
	await process_frame
	await process_frame


## A bridge is freed between cases, and the AudioDirector it made goes with it
## carrying six AudioStreamPlayers. The audio server releases a playback on its
## own mix step rather than on the frame the node is freed, so the players are
## stopped first - the same teardown `audio_check.gd` needs for the same reason,
## and the difference between a clean exit and an ObjectDB leak warning.
func _drop(bridge: AudioBridge) -> void:
	if bridge == null or not is_instance_valid(bridge):
		return
	if bridge.director != null:
		for child in bridge.director.get_children():
			if child is AudioStreamPlayer:
				child.stop()
				child.stream = null
	bridge.queue_free()


## A car is freed between races, and a node freed mid-frame stops being a node
## without stopping being a reference. The bridge has to notice, say so once,
## and keep the frame.
func _check_freed(world: Node3D, graph: RoadGraph, def: RaceDef) -> void:
	var car := _car(world)
	var race := RaceDirector.new()
	race.wallet = Wallet.new()
	var bridge := AudioService.instance.bridge
	bridge.race = race
	bridge.car = car
	await physics_frame
	_ok(race.try_enter(def), "the freed-node race is paid for")
	_ok(race.start(def, graph, [GridCar.new()]), "and started")
	await physics_frame
	_fails(bridge.lost, "a bridge with a live car has lost nothing")

	car.queue_free()
	await process_frame
	await physics_frame
	_fails(is_instance_valid(car), "the car really is gone, or none of this is testing anything")

	# Lights up with no car to read. A bridge still reading the old one either
	# throws here or fires a cue it has no business firing.
	race.lights = 1
	var before := bridge.director.cues_played
	await physics_frame
	await physics_frame
	_ok(bridge.lost, "a freed car is noticed rather than read")
	_eq(bridge.director.cues_played, before, "and the audio is quiet until there is a car to drive")

	var second := _car(world)
	bridge.car = second
	await physics_frame
	_fails(bridge.lost, "handing it a new car clears the loss")
	# The lights are still up from the start of the race, so the director
	# settling back onto them can legitimately make a sound. Count from after
	# that has happened rather than pretending it has not.
	var mark := bridge.director.cues_played
	race.lights = 2
	await physics_frame
	_eq(bridge.director.cues_played, mark + 1, "and the lights work again on the new one")

	bridge.race = null
	bridge.car = null
	second.queue_free()
	await process_frame
	await process_frame


# ------------------------------------------------------------------- measuring

## What the synth is actually sounding, read off its own smoothed rpm rather
## than off a spectrum: the DSP underneath is `audio_check.gd`'s subject, and
## what is being checked here is the number that reached it.
func _settled(s: EngineSynth) -> float:
	_settle(s)
	return s.frequency()


## Pushes the synth's own smoothers past five time constants.
func _settle(s: EngineSynth) -> void:
	var buf := PackedFloat32Array()
	buf.resize(int(SETTLE * s.mix_rate))
	s.render(buf)


## The cue that just fired, if it is new. A cue between two polls would still
## land here, and one polled twice does not land twice.
func _collect(d: AudioDirector, into: Array[String]) -> void:
	if d.last_cue != "" and (into.is_empty() or into[into.size() - 1] != d.last_cue):
		into.append(d.last_cue)


## Every player in the tree is stopped and the synthesised streams are dropped
## from their static cache. The audio server releases a playback on its own mix
## step, which a headless dummy driver gets on the audio thread rather than on
## the frame we are standing in, so the wait is real time and not frames. The
## cache is cleared because a test process is about to exit: there is nothing to
## keep the streams for, and a static cache still holding them at ObjectDB
## teardown is the one leak warning this project should not have.
func _teardown(world: Node3D) -> void:
	_stop_players(world)
	world.queue_free()
	# Real time, not frames, and blocking rather than `create_timer`: the audio
	# server drops a finished playback on its own mix step, and a headless dummy
	# driver runs those on the audio thread, which `OS.delay_msec` waits out
	# perfectly well and a `SceneTreeTimer` does not - awaiting one leaves the
	# timer itself alive at exit, which is the same ObjectDB leak warning the
	# wait was meant to avoid.
	OS.delay_msec(500)
	AudioCues._cache.clear()
	var service := AudioService.instance
	_ok(service != null and service.bridge != null and service.bridge.race == null
			and service.bridge.car == null,
			"the game's bridge is left holding nothing but its own director")


## Stopped *and* unstreamed. A stopped player still holds its `AudioStreamWAV`,
## and a freed player leaves the server holding a playback that points at one,
## so this check has to let go of both.
func _stop_players(node: Node) -> void:
	for child in node.get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
		_stop_players(child)


# --------------------------------------------------------------------- harness

func _ok(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("    [PASS] %s" % label)
	else:
		_failed += 1
		_failures.append(label)
		print("    [FAIL] %s" % label)
	return cond


func _eq(actual: Variant, expected: Variant, label: String) -> bool:
	return _ok(actual == expected, "%s  (got %s, want %s)" % [label, str(actual), str(expected)])


func _fails(cond: bool, label: String) -> bool:
	return _ok(not cond, "NOT %s" % label)


func _report() -> void:
	print("\n%s\n  %d passed, %d failed\n%s" % ["=".repeat(58), _passed, _failed, "=".repeat(58)])
	for f in _failures:
		print("  FAILED: %s" % f)
	print("=".repeat(58))
	quit(1 if _failed > 0 else 0)
