extends RefCounted
## Boot wiring, the music bus, and the rpm getter. Run: `./test.sh audio_boot`
##
## The suite-level half of the t62 work; `Audio/host_wiring_check.gd` is the
## gate-level half and asserts the same three things standalone. This file exists
## because a gate nobody runs from `test.sh` rots, and because these are exactly
## the three claims that are easy to believe and hard to keep true.
##
## ## On the brief this work came from
##
## The report said the game had been silent since before 0.1.0 because
## `Game/main.gd` never instantiates the bridge, and it offered that as VERIFIED.
## It is not what is wrong, and the correction is the first thing this suite
## pins: `AudioService` is an autoload and builds the bridge in its own `_ready`
## (`Audio/audio_service.gd:123-128`), before any scene is in the tree, because
## the beds want to be playing from the first frame and the main menu is a night
## street too. `Audio/bridge_check.gd` asserted exactly that and passed 40/0 on
## the unmodified tree. A host that built its own bridge would have doubled the
## engine and then stood itself down
## (`Audio/audio_bridge.gd:69-76`).
##
## So the host's missing half was the other direction - not making the bridge,
## but saying what it drives - and that is what `_boot_wiring` below asserts: the
## one bridge in the game is the autoload's, and the host hands its director and
## car to *that* node rather than letting discovery go looking for them.
##
## ## Why so much of this is reached dynamically
##
## `get("music")`, `has_method("rpm")`, `call("placeholder", ...)`. Typed access
## to an API that does not exist yet is a *parse* error, and a parse error takes
## the whole suite down: `Tests/run_tests.gd:76` reports it as one failed
## assertion, "suite failed to load", which is a weaker claim than the one being
## made here. Reached dynamically these assertions compile against both trees and
## fail as assertions - a number, a label, a diff - on the tree without the work
## and pass on the tree with it. That is the whole reason for the style, and it
## costs a `has_method` guard that a typed call would not have needed.
##
## ORIGINAL GAME CONTENT.

## How many physics steps a car needs before its engine has come off idle. The
## drivetrain lerps toward free revs at 16/s, so a third of a second is short of
## enough; the assertions are ratios, not values, so they only have to be on the
## right side of one. As used and measured in `Audio/bridge_check.gd:23-27`.
const REVS := 30
## Enough of the audio thread's rpm smoother to get past five time constants:
## `EngineSynth.RPM_TAU` is 0.08 s (Audio/engine_synth.gd:36), and 5 x 0.08 is
## 0.4. Half that, because this renders the head rather than the whole.
const SETTLE := 0.4
## A load this far below the first audible threshold is the synth's own zero.
## `Audio/engine_synth.gd:90-93` starts `_target_load` at 0.0 and a car off the
## throttle never raises it, so the settled value is the number it started on.
const NO_LOAD := 0.01
## A fade the channel has finished is within `MusicChannel.DONE_DB`
## (Audio/music_channel.gd), which is four hundredths of a percent of full scale.
## Read from the script rather than restated here, so this file cannot disagree
## with the constant it is checking.

var _car: CarBody = null
var _world: Node = null


func run(t: TestHarness) -> void:
	# The autoload is in the tree from the first frame but its `_ready` is not
	# called until the tree starts iterating, so `AudioService.instance` is null
	# until then - the same wait `Audio/bridge_check.gd:72-76` documents.
	await t.ticks(2)
	await _boot_wiring(t)
	await _music_bus(t)
	_rpm_getter(t)
	await _restore(t)


## The bridge at boot, the autoload's own, and the host handing its work to it.
func _boot_wiring(t: TestHarness) -> void:
	var service := AudioService.instance
	t.ok(service != null, "the audio autoload is in the tree")
	if service == null:
		return

	# `:123-128` of the service is the design: one bridge, made by the autoload,
	# named, parented to the autoload and given the autoload's own director.
	var bridge := service.bridge
	t.ok(bridge != null, "the autoload built the bridge at boot (audio_service.gd:123-128)")
	if bridge == null:
		return
	t.eq(bridge.name, "AudioBridge", "and named it, as that block does")
	t.eq(bridge.get_parent(), service, "and parented it to itself rather than to a scene")
	t.ok(bridge.director != null, "with a director, so a car has somewhere to go")
	t.ok(bridge.director == AudioDirector.instance,
			"and it is the one the rest of the game reaches through the static")
	t.fails(bridge.standing_down, "the game's own bridge is the one polling, not a duplicate")
	# Exactly one. A host that made its own would have a second, and the second
	# is the one that stands down, so this count is the difference between the
	# engine sounding and the engine not.
	var found := t.tree.root.find_children("*", "AudioBridge", true, false)
	t.eq(found.size(), 1, "and it is the only bridge in the tree, so only one engine")

	# The handover the host now does explicitly, exercised through the same pair
	# `Game/main.gd` calls. This pins the contract the host depends on, so the
	# next change to either side of it is caught here rather than in play.
	_world = t.new_root("AudioBootWorld")
	_car = _make_car()
	await t.ticks(2)
	service.set_car(_car)
	t.ok(bridge.car == _car,
			"the host's set_car reaches the autoload's bridge  (%s)" % str(bridge.car == _car))
	t.ok(_car.get_node_or_null("..") != null, "and the car it handed over is in the world")
	service.set_race(RaceDirector.new())
	t.ok(bridge.race != null, "the host's set_race reaches it as well")

	# The part that cannot be observed from inside a headless run: nothing here
	# instantiates the game scene, so no runtime assertion can tell whether
	# `main.gd` still hands its work over or has gone back to letting the audio
	# system find it by reflection. So it is read from the source.
	#
	# Qualified on the service, not bare: `camera.set_car(player_car)` sits in the
	# same file three lines from the one that matters, and a check that passes on
	# the camera's call proves nothing about the audio.
	var src := _host_source()
	t.ok(src.contains("_wire_audio"), "the host has one place that wires audio")
	t.ok(src.contains("AudioService.instance.set_car("), "and it hands over its car")
	t.ok(src.contains("audio.set_race("), "and its race director")
	# What it must never do: make a bridge or a director of its own.
	t.fails(src.contains("AudioBridge.new("),
			"the host never builds a bridge - the autoload's is the game's")
	t.fails(src.contains("AudioDirector.new("), "nor a director")


## The music bus, as something that can be moved rather than a bed at one level.
func _music_bus(t: TestHarness) -> void:
	var service := AudioService.instance
	t.ok(AudioBuses.has_bus(AudioBuses.MUSIC), "the Music bus is in the layout (audio_buses.gd:13)")
	if AudioBuses.index_of(AudioBuses.MUSIC) >= 0:
		t.eq(AudioServer.get_bus_send(AudioBuses.index_of(AudioBuses.MUSIC)), AudioBuses.MASTER,
				"and it sends to Master (audio_buses.gd:20)")
	# `AudioService.MIX` is the level the service claims for each bus
	# (audio_service.gd:28-33); the music bed sits at `MUSIC_DB` on top of it
	# (audio_service.gd:38, :109).
	t.near(AudioBuses.volume(AudioBuses.MUSIC), float(AudioService.MIX[AudioBuses.MUSIC]), 0.01,
			"the Music bus sits where the mix puts it")

	# Dynamic on purpose: this member does not exist without the work, and a typed
	# read of a missing member would stop the suite loading rather than fail it.
	var music: Object = service.get("music")
	t.ok(music != null, "the service owns a music channel")
	if music == null:
		return
	var st: Dictionary = music.call("state")
	# "music" quoted rather than read off `MusicChannel`, which does not exist
	# without this work: a static reference to a missing class is a parse error.
	var recipe: Dictionary = AudioBeds.RECIPES["music"]

	t.eq(st["bed"], "music", "the channel drives the music bed (audio_beds.gd:40)")
	t.eq(st["bus"], AudioBuses.MUSIC, "on the Music bus")
	t.ok(bool(st["playing"]), "and it is playing at boot")
	t.eq(st["placeholder"], false, "with the real bed rather than the placeholder")

	# The metadata is copied out of the bed's recipe rather than restated, so the
	# two cannot drift: the numbers a check - or the owner's own tool - needs to
	# know the shape of the slot they are filling.
	t.eq(st["loop_seconds"], float(recipe["dur"]), "and the metadata carries the bed's length")
	t.eq(st["gain"], float(recipe["gain"]), "and its gain")
	t.eq(st["mix_hz"], AudioBeds.MIX_HZ, "and the rate it is built at (audio_beds.gd:24)")
	t.eq(st["samples"], int(float(recipe["dur"]) * float(AudioBeds.MIX_HZ)),
			"and a sample count consistent with that length and rate")
	t.eq(st["trim_db"], AudioService.MUSIC_DB, "and the trim the service set (audio_service.gd:38)")
	t.near(float(st["level_db"]), AudioService.MUSIC_DB, 0.01,
			"the bed is sitting at its resting level, not ducked")

	# Duck, both edges, at the depth the channel documents rather than a number
	# this file invented. `DUCK_DB` is read off the script's own constants so a
	# change to it cannot turn into a failure here or be silently asserted.
	var duck_db: float = _constant(music, "DUCK_DB")
	t.ok(duck_db < 0.0, "the channel has a duck depth to go to  (%.1f dB)" % duck_db)
	music.call("duck", true)
	await _fade_closed(t, music)
	t.eq(float(music.call("state")["level_db"]), AudioService.MUSIC_DB + duck_db,
			"a duck lands the bed exactly that far down")
	t.ok(bool(music.call("state")["ducked"]), "and the channel reports being ducked")
	music.call("duck", false)
	await _fade_closed(t, music)
	t.near(float(music.call("state")["level_db"]), AudioService.MUSIC_DB,
			_constant(music, "DONE_DB"),
			"undoing it puts the bed back  (within the channel's own DONE_DB)")

	# The placeholder. `AudioBeds.placeholder` is absent without the work, and
	# this is what a check uses to measure the channel rather than the music.
	#
	# Reached through the Script resource rather than the class name:
	# `AudioBeds` declares only statics, and GDScript refuses a non-static call
	# on a class name outright ("Cannot call non-static function has_method() on
	# the class directly") - which is a parse error, and a parse error takes the
	# runner down with it rather than costing this suite its assertions.
	var beds: Script = load("res://Audio/audio_beds.gd")
	t.ok(beds.has_method("placeholder"),
			"the bed bank can hand out a silent stand-in (audio_beds.gd)")
	if beds.has_method("placeholder"):
		var wav: AudioStreamWAV = beds.call("placeholder", "music")
		t.ok(wav != null, "and it produces one for the music bed")
		if wav != null:
			t.eq(wav.data.size() / 2, st["samples"],
					"of the same length as the bed it stands in for")
			t.eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD, "looping, so it is a bed shape")
			t.ok(_peak(wav) < 0.0001,
					"and silent by construction  (peak %.6f)" % _peak(wav))


## `EngineSynth.rpm()`, which is what t67 needs to map a sample back to an engine
## speed: without it, a sample can be dated and measured but not attributed.
func _rpm_getter(t: TestHarness) -> void:
	var s := EngineSynth.new()
	# The pair with `load()`, which already existed (engine_synth.gd:117-119) and
	# rpm did not - the asymmetry that put every caller inside a private field.
	t.ok(s.has_method("rpm"), "the synth has an rpm getter beside its load()")
	if not s.has_method("rpm"):
		return

	# What it says before anything is fed it: `IDLE_RPM`, the floor a zero rpm
	# would otherwise become a zero frequency (engine_synth.gd:30-32).
	var idle := EngineSynth.IDLE_RPM
	t.near(float(s.call("rpm")), idle, 1.0,
			"an unfed synth reports idle  (%.1f, want %.1f)" % [float(s.call("rpm")), idle])

	# And that it tracks: set_engine is given the car's rpm and the getter has to
	# report where the smoother has got to, which is the number a sample would be
	# attributed to.
	s.mix_rate = EngineSynth.MIX_RATE
	s.set_engine(4000.0, 0.5)
	var buf := PackedFloat32Array()
	buf.resize(int(SETTLE * s.mix_rate))
	s.render(buf)
	var got: float = s.call("rpm")
	t.gt(got, idle * 1.5,
			"and it follows the rpm it is fed  (%.0f -> %.0f rpm)" % [idle, got])
	t.near(got, 4000.0, 400.0, "landing on the rpm that was handed in  (%.0f rpm)" % got)

	# The mapping the getter exists for: rpm and the pitch it produces have to
	# agree, or a sample measured at a frequency cannot be attributed to a rev
	# count. `frequency()` and `firing_frequency()` both predate this.
	t.eq(s.cylinders, EngineSynth.DEFAULT_CYLINDERS,
			"and it is still sounding the cylinders it defaults to")
	t.near(s.frequency(), EngineSynth.firing_frequency(got, s.cylinders), 0.001,
			"the frequency it sounds is the one its rpm implies  (%.2f Hz at %.0f rpm)"
					% [s.frequency(), got])

	# The comparison itself, or the two above also pass against a getter that
	# answers with a constant.
	var other := EngineSynth.new()
	t.gt(absf(float(other.call("rpm")) - got), 1.0,
			"a synth fed something else reports something else, so the above are not vacuous")


## Everything this suite moved, put back: the next suite's mix has to be the mix
## it was handed. `Tests/test_sound.gd:128` reads the Music bus meter and wants
## it above the bed floor, so a suite that left the music ducked would fail one
## file alphabetically after this one.
func _restore(t: TestHarness) -> void:
	var service := AudioService.instance
	if service != null:
		var music: Object = service.get("music")
		if music != null:
			music.call("duck", false)
			music.call("use_placeholder", false)
			await _fade_closed(t, music)
		if service.bridge != null:
			service.bridge.car = null
			service.bridge.race = null
	t.ok(AudioBeds.stream("music").data.size() > 0, "the real bed is still loaded afterwards")
	if _world != null:
		# Awaited, because `drop` awaits a process frame to let the delete queue
		# flush. Un-awaited it returns at its own first await, the world is still
		# standing, and the runner - correctly - reports this suite as having left
		# its physics in the next suite's world.
		await t.drop(_world)
		_world = null
	_car = null


# ------------------------------------------------------------------- fixtures

## A flat plate under the car, so it is not in free fall for the length of the
## suite: a car falling is a car whose engine note means nothing.
func _make_car() -> CarBody:
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

	var spec := CarDB.get_spec("kairo_s13")
	spec.start_position = Vector3(0, spec.tyre_radius + 0.04, 0)
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.name = "AudioBootCar"
	car.spec = spec
	car.build_visual = false
	_world.add_child(car)
	return car


func _host_source() -> String:
	var f := FileAccess.open("res://Game/main.gd", FileAccess.READ)
	return "" if f == null else f.get_as_text()


## A constant off the channel's own script, so this file quotes no number it has
## not read from the thing it is checking.
func _constant(obj: Object, name: String) -> float:
	var scr: Script = obj.get_script()
	if scr == null:
		return 0.0
	var map: Dictionary = scr.get_script_constant_map()
	return float(map.get(name, 0.0))


## Frames until the channel's fade has landed. Bounded, because a wait with no
## bound is how a check hangs instead of failing.
func _fade_closed(t: TestHarness, music: Object) -> void:
	for _i in 600:
		await t.ticks(1)
		if not bool((music.call("state") as Dictionary)["fading"]):
			return


## Largest absolute sample in a 16-bit buffer. Silent is zero, not -inf: a buffer
## of zeros decodes to zeros.
func _peak(wav: AudioStreamWAV) -> float:
	if wav == null or wav.data.size() < 2:
		return 0.0
	var data := wav.data
	var top := 0
	for i in range(0, data.size() - 1, 2):
		var v := data[i] | (data[i + 1] << 8)
		if v > top:
			top = v
	return float(top) / 32767.0