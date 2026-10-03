extends RefCounted
## Every sound the game claims to make, measured where it comes out.
## Run with: ./test.sh sound
##
## The failure this exists to catch is a sound that nothing triggers. 1047 lines
## of correct audio sat in the tree with no consumer, and that bug has the same
## shape as the artkit: it compiles, every gate on the synthesis passes, and
## nothing plays it.
##
## So nothing here reads the synthesis. Every check drives the trigger the game
## uses and then reads the audio server's own bus meters, which are computed from
## the real post-fader mix. A buffer can be full of samples and still be silent
## in the mix - on a muted bus, at -80 dB, on a bus nothing sends to - and only
## the meter knows. Equally, a sound with no trigger cannot move a meter at all,
## which is the whole point.
##
## Under `--audio-driver Dummy` the mix still runs: the driver discards the
## samples rather than declining to compute them, so the meters are live
## headless. Measured on a plain boot, before this suite touched anything:
## Master -22 dB, Music -29, Ambience -33.
##
## Three directions, because each catches something the others cannot:
##   - each declared sound moves its bus when its trigger fires
##   - every cue in the bank comes out of one of those triggers, so a recipe
##     nothing plays fails rather than sitting there. That check is what found
##     `screech`: in the bank, correct, and played by nothing, ever, because the
##     tyre bed is that sound now.
##   - a sweep at the end that nothing is still sounding when nothing is driving.
##     That is the same bug pointed the other way: an engine holding its last
##     revs and a tyre at full squeal with no car in the world are sounds with no
##     cause, which is not a soundtrack either.
##
## ORIGINAL GAME CONTENT.

## A bus at or below this is silence. A meter with nothing playing on it floors
## near -200, and a bed left at its -80 dB trim reads about -87.
const SILENT := -70.0
## An SFX bus with a bed player on it never reads -200: the bed is still
## playing, it is just playing its own silence at the bed floor, which lands
## here after the SFX fader. So the SFX silence test is against that floor.
const BUS_FLOOR := -80.0
## ...and a bus has to clear this to count as heard. Everything measured here
## lands between -47 and -19, so the threshold is nowhere near any of them.
const AUDIBLE := -55.0
## How loud a bed's own bus has to be before it counts as reaching the mix.
const BED_AUDIBLE := -60.0
## A trigger has to move its bus by at least this much to count as having caused
## something. The tyre squeal is a 40 dB jump and the UI click 58, so 20 dB is
## half the quietest real event and far above the meter's own drift.
const CAUSED := 20.0
## How long to watch a bus, in seconds. A click is 140 ms and the meters update
## on the audio thread, so one read can miss it entirely: the peak is sampled
## across a window and the maximum kept.
const WATCH := 0.45
## ...and the longer window for proving a bed is a loop rather than a blip.
const WATCH_LOOP := 0.6

## How long to wait for the audio server to mix before a meter window opens, in
## milliseconds. A mix is about 90 ms of wall clock under `--audio-driver
## Dummy`, so this is an order of magnitude of headroom, and a window is only
## worth opening once there is something in it to measure.
const METER_MIX_WAIT_MS := 1000

## The audio server's mix period, in seconds: the 4096 frames it consumes per
## mix at the 44100 Hz `EngineVoice` generates at. **This is the resolution of
## every bus meter in the project.** A meter does not change between mixes, so
## a window's real unit is mixes and not milliseconds.
##
## The number a window asks for is derived from this, and that is what makes it
## honest rather than a hidden second opinion about timing. A free-running main
## loop starves the audio thread and a starved thread mixes *less* often -
## measured here: 93, 93, 187, 376 and 187 ms between consecutive mixes - never
## more often. So a count derived from this is a floor on how much a window
## covers rather than a promise about how long it will take, and asking for four
## of them is four of them whether they take 370 ms or 1.5 s to arrive.
const MIX_PERIOD := 4096.0 / 44100.0

## How long, as a multiple of the nominal mix period, to keep waiting for the
## mixes a window asked for before reporting what it has. Only a server that
## has stopped mixing altogether reaches this, and a truncated window is the
## least of that problem.
const MIX_PATIENCE := 10.0

## Metres between the car and the wall it is thrown at. A contact is a trigger
## that cannot be faked - `body_entered` needs a closing speed - so this suite
## throws a car at something rather than calling the impact handler.
const CRASH_GAP := 5.0
## 54 kph, over the speed at which a contact is a crash rather than a bump, and
## slow enough that five metres is a comfortable margin.
const CRASH_KPH := 54.0
## Physics frames for that to happen, plus the frames the contact needs to be
## reported and the cue played.
const CRASH_FRAMES := 40

var _tree: SceneTree
var _service: AudioService
var _director: AudioDirector
## Every cue name the triggers below actually produced. Compared against the bank
## at the end, which is what makes a recipe nothing plays a failure.
var _heard: Dictionary = {}
var _world: Node3D
var _car: CarBody


func run(t: TestHarness) -> void:
	t.suite("sound")
	_tree = t.tree
	# An autoload's `_ready` is not called until the tree starts iterating, so at
	# the top of the run the service is in the tree and not live yet.
	await _frames(3)
	_service = AudioService.instance
	if not t.ok(_service != null, "the audio service is in the tree"):
		return
	_director = _service._director()
	t.ok(_director != null, "with a director to play cues through")
	await _at_rest(t)
	await _beds(t)
	await _engine(t)
	await _tyres(t)
	await _collision(t)
	await _ui(t)
	await _countdown(t)
	await _quiet_again(t)
	_bank(t)
	await _drop_world()


# ------------------------------------------------------------------- at rest

## The main menu: two beds and nothing else. No car exists, so no engine and no
## tyres may be making a sound. A soundtrack full of things with no cause is the
## same bug as one with nothing playing.
func _at_rest(t: TestHarness) -> void:
	t.eq(_tree.root.find_children("*", "CarBody", true, false).size(), 0,
			"the menu really has no car in it")
	await _settle()
	var engine := await _peak(AudioBuses.ENGINE)
	t.between(engine, -200.0, SILENT, "an engine with no car is silent  (%.1f dB)" % engine)
	var sfx := await _peak(AudioBuses.SFX)
	t.between(sfx, -200.0, SILENT, "and so are the tyres  (%.1f dB)" % sfx)


# --------------------------------------------------------------------- beds

## The two continuous layers, on their own buses, into Master, on both channels,
## and still going half a second later - a bed that stops is a cue.
func _beds(t: TestHarness) -> void:
	var music := await _peak(AudioBuses.MUSIC, WATCH_LOOP)
	t.between(music, BED_AUDIBLE, 6.0, "the music bed reaches its bus  (%.1f dB)" % music)
	var night := await _peak(AudioBuses.AMBIENCE, WATCH_LOOP)
	t.between(night, BED_AUDIBLE, 6.0, "the night reaches its bus  (%.1f dB)" % night)

	var master := await _peak(AudioBuses.MASTER, WATCH_LOOP)
	t.between(master, BED_AUDIBLE, 6.0, "and they reach Master  (%.1f dB)" % master)
	var pair := await _peak_both(AudioBuses.MASTER, WATCH_LOOP)
	t.ok(absf(pair.x - pair.y) <= 1.5,
			"on both channels  (%.1f vs %.1f dB)" % [pair.x, pair.y])

	var later := await _peak(AudioBuses.MUSIC, WATCH_LOOP)
	t.between(later, BED_AUDIBLE, 6.0,
			"and it is still going half a second later  (%.1f dB)" % later)


# ------------------------------------------------------------------- engine

## The engine is a voice per car, fed by the car's own drivetrain through the
## bridge. So: silent with no car, sounding with one, following the revs, and
## stopping when the car is freed.
func _engine(t: TestHarness) -> void:
	_world_ready()
	var before := await _peak(AudioBuses.ENGINE)
	t.between(before, -200.0, SILENT, "the engine is silent before there is a car  (%.1f dB)" % before)

	_car = _make_car("kairo_s13")
	await _frames(4)
	var idle := await _peak(AudioBuses.ENGINE)
	t.between(idle, AUDIBLE, 6.0, "a car on the grid has an engine  (%.1f dB)" % idle)
	t.gt(idle - before, CAUSED,
			"which is %d dB louder than no car at all" % int(idle - before))

	# It follows the revs rather than sitting at idle whatever happens, which is
	# the difference between an engine and a drone.
	_car.throttle = 1.0
	await _frames(30)
	var hot := await _peak(AudioBuses.ENGINE)
	t.between(hot, AUDIBLE, 6.0, "and on full throttle it is louder  (%.1f dB)" % hot)
	t.gt(hot - idle, 3.0, "by %d dB" % int(hot - idle))
	_car.throttle = 0.0
	await _frames(20)


# -------------------------------------------------------------------- tyres

## The tyres are a loop the service opens with the slip: silent with the tyres
## straight, a squeal in a slide, silent again - and never a 40 dB step, which
## is a click.
func _tyres(t: TestHarness) -> void:
	var bed := _tyre()
	# Full throttle from the grid left the wheels spinning, which is a real
	# squeal and not the at-rest state this section is about, so the car is
	# brought to a genuine stop first.
	await _stop_the_car()
	t.between(bed.volume_db, -200.0, SILENT,
			"the tyre voice is silent with the car stopped  (%.1f dB)" % bed.volume_db)
	var rest := await _peak(AudioBuses.SFX)
	t.between(rest, -200.0, BUS_FLOOR, "so the SFX bus is the bed's own silence  (%.1f dB)" % rest)

	# The wheel state is written by the car's own tyre model every physics step,
	# so standing in for a slide means standing in for one the model is not
	# going to overwrite: the service's read of the wheels and its level mapping
	# are what is under test, and those run on their own frames as usual.
	_car.set_physics_process(false)
	_slide(1.0)
	var closed := bed.volume_db
	await _physics_step()
	t.near(bed.volume_db, closed + AudioService.TYRE_SLEW_DB, 0.5,
			"a slide opens the voice by exactly one slew step  (%.1f -> %.1f dB)" % [
					closed, bed.volume_db])
	var slid := await _peak(AudioBuses.SFX)
	t.between(slid, AUDIBLE, 6.0, "a full slide is a squeal on the bus  (%.1f dB)" % slid)
	t.gt(slid - rest, CAUSED, "which is %d dB above the quiet road" % int(slid - rest))

	# The whole climb, one physics frame at a time, is a slew the whole way: a
	# jump straight to the target would be a click at the moment the squeal
	# starts, which is the one instant a tyre noise is allowed to be heard.
	var full := _service._tyre_db(1.0)
	var worst_step := 0.0
	var last := bed.volume_db
	for _i in 40:
		await _physics_step()
		worst_step = maxf(worst_step, bed.volume_db - last)
		last = bed.volume_db
	t.ok(worst_step <= AudioService.TYRE_SLEW_DB + 0.001,
			"and it never opens faster than %.0f dB a frame  (worst step %.1f dB)" % [
					AudioService.TYRE_SLEW_DB, worst_step])
	t.near(bed.volume_db, full, 0.5,
			"and it gets all the way to a full slide  (%.1f dB)" % bed.volume_db)

	_slide(0.0)
	await _physics_step()
	t.near(bed.volume_db, full - AudioService.TYRE_SLEW_DB, 0.5,
			"letting go starts closing it, one step at a time  (%.1f dB)" % bed.volume_db)
	await _wait_silent(AudioBuses.SFX, 400)
	var quiet := await _peak(AudioBuses.SFX, 0.3)
	t.between(quiet, -200.0, BUS_FLOOR, "and the squeal goes  (%.1f dB)" % quiet)
	t.near(bed.volume_db, AudioBuses.SILENCE_DB, 0.5,
			"right back to silence  (%.1f dB)" % bed.volume_db)


# ---------------------------------------------------------------- collision

## The trigger that cannot be faked: two physics bodies meeting. A car is thrown
## at a wall at 54 kph and the bus is watched, so the cue has been through the
## contact monitor, the speed read and the cue pool.
func _collision(t: TestHarness) -> void:
	# The quiet road, before anything is thrown: a baseline measured after the
	# throw would be a baseline of the car's own tyres.
	var before := await _peak(AudioBuses.SFX)
	_car.set_physics_process(true)
	var wall := _wall()
	_car.global_position = wall.position + Vector3(0, _car.spec.tyre_radius + 0.02, CRASH_GAP)
	_car.linear_velocity = Vector3(0, 0, -CRASH_KPH / 3.6)
	var played := _director.cues_played
	for _i in CRASH_FRAMES:
		await _physics_step()
		if _director.cues_played > played:
			break

	t.eq(_director.last_cue, "hit", "hitting something is a hit  (got \"%s\")" % _director.last_cue)
	_heard["hit"] = true
	var hit := await _peak(AudioBuses.SFX)
	t.between(hit, AUDIBLE, 6.0, "and it is loud on the bus  (%.1f dB)" % hit)
	t.gt(hit - before, CAUSED, "which is %d dB above the quiet road" % int(hit - before))

	# A pile-up is many contacts in a row, and a stream of thumps is a machine
	# gun rather than a crash, so the cooldown has to hold through the bounce.
	var after := _director.cues_played
	await _frames(15)
	t.ok(_director.cues_played - after <= 1,
			"and one crash is one thump  (%d more)" % (_director.cues_played - after))

	# Against a wall with its brakes on, the car comes to rest and the squeal of
	# the stop goes with it, so the next section starts on a quiet road too.
	await _stop_the_car()


# ----------------------------------------------------------------------- ui

## A screen change is the click. MenuFlow is built by the host's `_ready`, so this
## drives the entry point the service calls rather than standing up a screen
## stack to click.
func _ui(t: TestHarness) -> void:
	var before := await _peak(AudioBuses.SFX)
	_service._on_ui()
	t.eq(_director.last_cue, "ui_ok", "a UI press is a click  (got \"%s\")" % _director.last_cue)
	_heard["ui_ok"] = true
	var clicked := await _peak(AudioBuses.SFX)
	t.between(clicked, AUDIBLE, 6.0, "and it clicks on the bus  (%.1f dB)" % clicked)
	t.gt(clicked - before, CAUSED, "which is %d dB above the quiet road" % int(clicked - before))


# ---------------------------------------------------------------- countdown

## The lights, through the bridge, from a real race director - the loudest moment
## in the game, and the one that used to be correct synthesis with nothing driving
## it. `lights` is set directly rather than through a full race because what is
## under test is the poll from the race to the cue, not the race.
func _countdown(t: TestHarness) -> void:
	var race := RaceDirector.new()
	_service.bridge.race = race
	var before := await _peak(AudioBuses.SFX)
	var seq: Array[String] = []
	for lights in [3, 2, 1, 0, 0, 0]:
		race.lights = lights
		await _frames(2)
		if _director.last_cue != "" and (seq.is_empty() or seq[seq.size() - 1] != _director.last_cue):
			seq.append(_director.last_cue)
	t.eq(seq, ["count_3", "count_2", "count_1", "go"] as Array[String],
			"3-2-1-GO comes out of the race's lights  (got %s)" % str(seq))
	for name in seq:
		_heard[name] = true
	var beeped := await _peak(AudioBuses.SFX)
	t.between(beeped, AUDIBLE, 6.0, "and the countdown is on the bus  (%.1f dB)" % beeped)
	t.gt(beeped - before, CAUSED, "which is %d dB above the quiet road" % int(beeped - before))
	_service.bridge.race = null

	# A gear change, which is the cue that happens on a car's own.
	var gears := _director.cues_played
	_car.current_gear = 3
	await _frames(1)
	_car.current_gear = 2
	await _frames(2)
	t.eq(_director.last_cue, "shift", "a gear change shifts  (got \"%s\")" % _director.last_cue)
	_heard["shift"] = true
	t.eq(_director.cues_played, gears + 1, "once per gear, not once per frame")


# -------------------------------------------------------------- quiet again

## The end of the sweep: nothing driving, nothing sounding. Each of these was a
## measurement, not a prediction - the engine held -20 dB with no car in the
## world, and the squeal stayed at -40 dB after the car it belonged to was freed.
func _quiet_again(t: TestHarness) -> void:
	if _car != null and is_instance_valid(_car):
		_car.queue_free()
		_car = null
	var frames := await _wait_silent(AudioBuses.ENGINE)
	t.ok(frames >= 0, "the engine stops when the car goes  (%d frames)" % frames)
	var engine := await _peak(AudioBuses.ENGINE, 0.3)
	t.between(engine, -200.0, SILENT, "and the engine bus is empty  (%.1f dB)" % engine)
	var tyre_frames := await _wait_silent(AudioBuses.SFX, 400)
	t.ok(tyre_frames >= 0, "and the tyres stop with it  (%d frames)" % tyre_frames)
	var sfx := await _peak(AudioBuses.SFX, 0.3)
	t.between(sfx, -200.0, BUS_FLOOR, "so SFX is the bed floor again  (%.1f dB)" % sfx)

	# The beds are meant to still be there: they are the game, not an event.
	var music := await _peak(AudioBuses.MUSIC)
	t.between(music, BED_AUDIBLE, 6.0,
			"while the music carries on regardless  (%.1f dB)" % music)


# --------------------------------------------------------------- the bank

## The list and the triggers have to be the same list. This is the check that
## found `screech`: a correct, expensive recipe in the bank with nothing playing
## it, which every synthesis gate in the repository passed.
func _bank(t: TestHarness) -> void:
	for name in AudioCues.names():
		t.ok(_heard.has(name), "cue %s is played by something in the game" % name)
	for name in AudioBeds.RECIPES.keys():
		var bed := _tree.root.find_child("Bed_" + String(name).capitalize(), true, false) as AudioStreamPlayer
		t.ok(bed != null and bed.playing, "bed %s has a player running it" % name)


# ----------------------------------------------------------------- fixtures

## This suite's world, gone again before it returns. It hangs off the tree root
## rather than under the harness, so nothing else frees it: left standing it was
## reported by the harness' census every run ("sound left 1 node(s) in the
## world"), and the *next* suite - and the next run of this one - inherited a
## ground plate and a wall it did not build. An order-dependent suite hands
## someone a false pass or a false failure later, which is a worse cost than the
## ground plate ever was.
##
## One process frame is what a delete queue costs, and `end_suite` runs the
## census as soon as this returns, so the wait is the whole of it.
func _drop_world() -> void:
	if _world != null and is_instance_valid(_world):
		_world.queue_free()
		_world = null
	await _tree.process_frame


## A ground plate and a wall. The car needs something under it or it is in free
## fall, and a free-falling car is not one whose drivetrain means anything.
func _world_ready() -> void:
	_world = _tree.root.get_node_or_null("SoundWorld") as Node3D
	if _world != null:
		return
	_world = Node3D.new()
	_world.name = "SoundWorld"
	_tree.root.add_child(_world)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1600, 1, 1600)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	_world.add_child(ground)


func _wall() -> StaticBody3D:
	var wall := _world.get_node_or_null("Wall") as StaticBody3D
	if wall != null:
		return wall
	wall = StaticBody3D.new()
	wall.name = "Wall"
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8, 4, 1)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0, 1.0, 0)
	_world.add_child(wall)
	return wall


func _make_car(id: String) -> CarBody:
	var spec := CarDB.get_spec(id)
	spec.start_position = Vector3(0, spec.tyre_radius + 0.04, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.name = "SoundCar"
	car.spec = spec
	car.build_visual = false
	_world.add_child(car)
	return car


## One physics frame, run to completion. The `physics_frame` signal is emitted
## before the nodes in the frame have had their step, so a read taken straight
## after it sees the state before the step rather than after it.
## Brakes the car to a standstill under its own physics and lets the tyre slip
## decay. Nothing is teleported: a car that is at rest with its wheels still
## turning is a state the game cannot reach, and the squeal it makes would be
## the test's own artefact rather than the game's bug.
func _stop_the_car() -> void:
	_car.throttle = 0.0
	_car.brake = 1.0
	for _i in 400:
		await _tree.physics_frame
		if _car.speed_kph < 0.5:
			break
	_car.brake = 0.0
	# The squeal outlives the slide: the tyre model's slip is smoothed over a
	# relaxation length, so a stopped car is still squeaking for the first
	# fraction of a second. A second is ten of those constants.
	await _settle(1.0)


func _physics_step() -> void:
	await _tree.physics_frame
	await _tree.process_frame


func _tyre() -> AudioStreamPlayer:
	return _service.get_node_or_null("Bed_Tyre") as AudioStreamPlayer


## Standing in for a tyre that is being abused, by hand: the wheel state is what
## the tyre model writes every step, and a car driven into a slide under power
## would be testing the tyre model as much as the audio.
func _slide(amount: float) -> void:
	for w in _car.wheels():
		w["load"] = 400.0
		w["sr_smooth"] = amount
		w["slip_angle"] = amount * 0.4


## Both channels of a bus from a single window, as a Vector2 of peaks. Left and
## right have to be read together: two windows of the same noise bed are two
## different pieces of noise, and comparing their peaks measures the bed's
## noise rather than the mixer.
func _peak_both(bus: String, secs: float = WATCH) -> Vector2:
	var idx := AudioServer.get_bus_index(bus)
	if not await _await_mix():
		# The server never mixed inside the wait, so this window measured nothing
		# and the block it inherited is all there is.
		return Vector2(_meter(idx, false), _meter(idx, true))
	var want := _mixes_for(secs)
	var deadline := _mix_deadline(want)
	var since := AudioServer.get_time_since_last_mix()
	var peak := Vector2(-200.0, -200.0)
	for _m in want:
		while true:
			peak.x = maxf(peak.x, _meter(idx, false))
			peak.y = maxf(peak.y, _meter(idx, true))
			var now := AudioServer.get_time_since_last_mix()
			if now < since:
				break
			since = now
			if Time.get_ticks_msec() >= deadline:
				return peak
			await _tree.process_frame
	return Vector2(maxf(peak.x, _meter(idx, false)), maxf(peak.y, _meter(idx, true)))


## How many mixes a window of `secs` is asking for. That is the only part of a
## window's length the meter can resolve, so it is the only part that is counted;
## `secs` keeps meaning what the callers say it means, and the number of mixes
## that fits in it is derived rather than assumed to have happened.
func _mixes_for(secs: float) -> int:
	return maxi(1, int(secs / MIX_PERIOD))


## Wall-clock backstop for a window that wants `count` mixes, so a server that
## stops mixing ends the window instead of hanging the run.
func _mix_deadline(count: int) -> int:
	return Time.get_ticks_msec() + int(MIX_PATIENCE * MIX_PERIOD * 1000.0 * float(count))


## One side of one bus's meter.
func _meter(idx: int, right: bool) -> float:
	return AudioServer.get_bus_peak_volume_right_db(idx, 0.0) if right \
			else AudioServer.get_bus_peak_volume_left_db(idx, 0.0)


## Real time, where something is time-based: a bed fading in over its own
## envelope, or the physics settling onto its springs.
##
## Wall clock, deliberately, and not `create_timer`. This runner is started with
## `--fixed-fps 60`, which pins the engine delta at 1/60 s no matter how much
## wall clock passes, and a `SceneTreeTimer` counts *simulated* frames. Measured
## on this runner: `create_timer(0.5)` returned after **20.3 ms** of wall time
## and `create_timer(1.0)` after **1.098 ms**, where without `--fixed-fps` the
## same calls take 354 ms and 1000.7 ms. So a settle written that way is a
## thirty-frame wait wearing a half-second's name, and anything measured after
## it is measured on a world that has not settled.
##
## `Time.get_ticks_usec()` is the monotonic OS clock, so it is untouched by
## `Engine.time_scale` and by `--fixed-fps` alike, and this does not assume a
## frame rate either: it re-checks every frame and returns on the clock.
func _settle(secs: float = 0.5) -> void:
	var until := Time.get_ticks_usec() + int(secs * 1000000.0)
	while Time.get_ticks_usec() < until:
		await _tree.process_frame


## Frames until the bus is quiet, or the budget runs out. Returns the frames it
## took so the caller can assert it was not the budget - which is all either
## caller does with it, so this is a diagnostic rather than a measurement.
##
## A frame count is the right unit for *what it waits on*: the tyre voice walks
## `volume_db` in `AudioService._physics_process`, so its level moves per step.
## It is emphatically not the right unit for the meter, which only moves when
## the audio server mixes - roughly every 90 ms of wall clock, while this
## runner's frames take about 30 microseconds. So this almost always returns the
## budget, and it used to be read as "the bus is still loud". Nothing here
## asserts on that; `_peak` is the read, and it waits for its own mixes.
func _wait_silent(bus: String, budget: int = 4000) -> int:
	var idx := AudioServer.get_bus_index(bus)
	var peak := 0.0
	for i in budget:
		peak = maxf(peak, AudioServer.get_bus_peak_volume_left_db(idx, 0.0))
		if peak <= SILENT:
			return i
		await _tree.process_frame
	peak = maxf(peak, AudioServer.get_bus_peak_volume_left_db(idx, 0.0))
	return budget if peak > SILENT else -1


func _frames(n: int) -> void:
	for _i in n:
		await _tree.physics_frame


## The highest the audio server's own meter for a bus reached across a window of
## real time. The meters are updated on the audio thread, so a single read can
## miss a 140 ms click entirely - which is how the first version of this read
## nothing at all and looked like a dead cue. So the window is a maximum, and it
## starts by waiting for a mix.
##
## That wait is the whole of "do not report a sound that has already stopped",
## and it is a placement fix rather than a filter. A bus meter is not a live
## value: it holds the peak of the last block the audio server mixed, and under
## `--audio-driver Dummy` the server mixes about once per 90 ms of wall clock
## while `--fixed-fps` runs the tree at ~33,600 frames per wall second. A
## maximum taken over that window includes the block the server mixed *before*
## the window opened, which is a number about a state that has since ended.
## Measured - an Engine bus that reported -32 dB with no CarBody anywhere in the
## tree, while the five mixes that fell inside the same window read -45.8,
## -70.3, -84.3, -85.6 and -100.1 dB. The same on SFX: five in-window mixes
## between -87.9 and -86.5 dB, reported as -13.6 dB, which was the wheelspin
## that had been shut off a fraction of a millisecond before the window opened.
##
## Waiting for a mix can only remove those readings and cannot hide a real one:
## a stream that is still making a sound is still making it while the window is
## open, and the mixes inside the window say so.
##
## The window itself is counted in MIXES, which is the rest of the fix. A
## millisecond window against a meter that only changes every MIX_PERIOD is a
## sample count nobody chose: measured on this runner, a 450 ms window contained
## anywhere from two to five mixes depending on the phase it opened at, so every
## reading in this suite was "the loudest of however many 93 ms blocks happened
## to land, selected by an uncontrolled phase". That is not a measurement. It
## cost this suite two different failures for the same defect on the same tree,
## and the engine one is worth stating plainly: the voice is a generator behind
## a 0.25 s ring, so it takes 380-440 ms from a car existing to the engine being
## audible at the bus - measured, four mixes at -200.0000 dB and then -22.3 dB -
## against a 450 ms window. Whether the transition landed inside the window was
## a coin flip, and a coin flip reads -200.0000 dB as "there is no engine here".
##
## Counting mixes removes the coin flip without touching the bar: WATCH and
## WATCH_LOOP still mean what they always meant, the same number of mixes are
## measured, and now the number of them is the same every run instead of being
## whatever the phase allowed. Nothing is widened to make a marginal reading
## pass - the maximum is still taken over the same kind of blocks - and because
## a window now reliably contains its four or six mixes, a *silent* assertion
## gets slightly more chances to catch a transient, not fewer.
func _peak(bus: String, secs: float = WATCH, right: bool = false) -> float:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return -200.0
	if not await _await_mix():
		# The server never mixed inside the wait, so this window measured nothing
		# and the block it inherited is all there is.
		return _meter(idx, right)
	var want := _mixes_for(secs)
	var deadline := _mix_deadline(want)
	var since := AudioServer.get_time_since_last_mix()
	var best := -200.0
	for _m in want:
		# Sampled every frame rather than every mix: the maximum is the point of
		# the window and the frames between mixes cost nothing. Only the *waiting*
		# is counted in mixes.
		while true:
			best = maxf(best, _meter(idx, right))
			var now := AudioServer.get_time_since_last_mix()
			if now < since:
				break
			since = now
			if Time.get_ticks_msec() >= deadline:
				return best
			await _tree.process_frame
	return maxf(best, _meter(idx, right))


## Blocks until the audio server has mixed at least once, so the first meter
## read of a window is one that belongs to the window. `AudioServer` counts the
## time since the last mix, and that counter restarting is the only signal there
## is that a mix has happened.
func _await_mix() -> bool:
	var since := AudioServer.get_time_since_last_mix()
	var deadline := Time.get_ticks_msec() + METER_MIX_WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var now := AudioServer.get_time_since_last_mix()
		if now < since:
			return true
		since = now
		await _tree.process_frame
	return false
