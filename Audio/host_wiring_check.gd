extends SceneTree
## Checks the three things the host wiring has to be true of. Run:
##   godot --headless --audio-driver Dummy --path . --script res://Audio/host_wiring_check.gd
##
## `bridge_check.gd` proves the bridge, once it exists, drives a race and a car.
## This proves the other two halves, which are the ones that were never true: that
## there IS a bridge at boot, that a throttle change arrives at the engine voice
## rather than at a synthesiser nothing is holding, and that the music bus is a
## thing that can be played, ducked and faded rather than a bed that only ever
## plays at one level.
##
## The music is measured through `MusicChannel`'s silent placeholder, not through
## the bed's samples. What is being checked is the channel - routing, duck depth,
## fade, loop shape - and a check that also asserted what the music sounds like
## would be asserting the owner's taste, and would fail the day they change it.
## The placeholder is the same length, at the same rate, with the same loop
## points as the bed, so every measurement of shape is still a measurement of the
## real bed's shape.
##
## ORIGINAL GAME CONTENT.

## Frames a physics run needs before a car's engine has come off idle. The
## drivetrain lerps toward free revs at 16/s, so a third of a second is short of
## enough - the assertions here are ratios, not values, so they only have to be on
## the right side of one.
const REVS := 30
## Half of the audio thread's 80 ms rpm smoother, to five time constants: long
## enough that the voice is sounding the rpm it was given rather than still on its
## way to it.
const SETTLE := 0.4
## Below this a fade is finished, as far as this file is concerned.
const DONE_DB := 0.05
## A placeholder that is not silent is not a placeholder.
const SILENT := 0.0001

var _passed: int = 0
var _failed: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	await _run()
	_report()


# ------------------------------------------------------------------ the wiring

func _run() -> void:
	# One frame before anything is read: the autoload is in the tree from the
	# start but its `_ready` is not called until the tree starts iterating, so
	# `AudioService.instance` is null until then.
	await process_frame
	var service := AudioService.instance
	_check_bridge_at_boot(service)
	_check_music(service)
	await _check_engine(service)
	_check_host_source()
	_teardown()


## The bridge has to be there before anything is driving it, because nothing ever
## constructs a second one: it is made in the autoload's `_ready`, and a host that
## built its own would get a bridge that stands itself down. So "at boot, with no
## car and no race, there is still one" is the whole of this case.
func _check_bridge_at_boot(service: AudioService) -> void:
	_ok(service != null, "the audio service autoload is in the tree")
	if service == null:
		return
	_ok(service.has_bridge(), "and it reports a bridge with a director")
	var bridge := service.bridge
	_ok(bridge != null, "the bridge is there at boot, with no car and no race")
	if bridge == null:
		return
	_ok(bridge.director != null, "the bridge made a director rather than waiting for one")
	_ok(bridge.director == AudioDirector.instance,
			"and it is the director the rest of the game reaches through the static")
	_fails(bridge.standing_down, "the game's own bridge is the one polling, not a duplicate")
	_fails(bridge.lost, "a bridge with nothing to drive has not lost anything")
	var voice := _voice(bridge)
	_ok(voice != null, "the bridge's director is holding an engine voice")
	if voice != null:
		# Nothing has fed it yet, and a voice sounding on the first frame is an
		# engine idling in a menu with no car anywhere - the exact failure the
		# voice's own header says it was written to prevent.
		_fails(voice.sounding(), "the engine voice is silent until a car asks for it")


## The music bus, as a thing that can be moved rather than a bed at one level.
func _check_music(service: AudioService) -> void:
	_ok(AudioBuses.has_bus(AudioBuses.MUSIC), "the Music bus is in the layout")
	if AudioBuses.index_of(AudioBuses.MUSIC) >= 0:
		_ok(AudioServer.get_bus_send(AudioBuses.index_of(AudioBuses.MUSIC)) == AudioBuses.MASTER,
				"and it sends to Master")
	_ok(absf(AudioBuses.volume(AudioBuses.MUSIC) - float(AudioService.MIX[AudioBuses.MUSIC])) < 0.01,
			"the Music bus sits where the mix puts it  (%.2f)" % AudioBuses.volume(AudioBuses.MUSIC))

	_ok(service.music != null, "the service owns a music channel")
	if service.music == null:
		return
	var music := service.music
	var st := music.state()
	var recipe: Dictionary = AudioBeds.RECIPES[MusicChannel.BED]

	_eq(st["bed"], MusicChannel.BED, "the channel drives the music bed")
	_eq(st["bus"], AudioBuses.MUSIC, "on the Music bus")
	_ok(bool(st["playing"]), "and it is playing at boot  (%s)" % str(st["playing"]))
	_eq(st["placeholder"], false, "with the real bed, not the placeholder")

	# The metadata is copied out of the bed's own recipe rather than restated, so
	# the two cannot drift apart. These are the numbers a check - and the owner's
	# own tool - needs to know the shape of the slot they are filling.
	_eq(st["loop_seconds"], float(recipe["dur"]), "the metadata carries the bed's length")
	_eq(st["gain"], float(recipe["gain"]), "and the bed's gain")
	_eq(st["mix_hz"], AudioBeds.MIX_HZ, "and the rate the bed is built at")
	_eq(st["samples"], int(float(recipe["dur"]) * float(AudioBeds.MIX_HZ)),
			"and a sample count consistent with that length and rate")
	_eq(st["trim_db"], AudioService.MUSIC_DB, "and the trim the service set on it")
	_ok(absf(float(st["level_db"]) - AudioService.MUSIC_DB) < DONE_DB,
			"the bed is sitting at its resting level, not ducked  (%.2f dB)" % float(st["level_db"]))

	# The placeholder: the same shape, no sound. A check on the channel must not
	# also be a check on the music, and this is what makes that possible.
	music.use_placeholder(true)
	await process_frame
	var ph := music.state()
	_ok(bool(ph["placeholder"]), "a check can swap in the silent placeholder")
	_eq(ph["samples"], st["samples"], "which is the same length as the bed it stands in for")
	_eq(ph["loop_seconds"], st["loop_seconds"], "and declares the same length")
	var silent := _peak(music.bed.stream)
	_ok(silent < SILENT, "and is silent by construction  (peak %.6f)" % silent)

	# Duck: down by the documented depth, and back. Both edges, because a duck
	# that only opens is a fade somebody forgot.
	music.duck(true)
	await _fade_closed(music)
	var down := float(music.state()["level_db"])
	_eq(down, AudioService.MUSIC_DB + MusicChannel.DUCK_DB,
			"a duck lands the bed exactly DUCK_DB down  (%.2f dB)" % down)
	_ok(bool(music.state()["ducked"]), "and the channel says it is ducked")
	music.duck(false)
	await _fade_closed(music)
	_ok(absf(float(music.state()["level_db"]) - AudioService.MUSIC_DB) < DONE_DB,
			"undoing the duck puts the bed back  (%.2f dB)" % float(music.state()["level_db"]))

	# A fade over a stated time, and the NaN refusal: a fade aimed at a value
	# that is not a number never arrives, and never says why.
	music.fade_to(AudioService.MUSIC_DB - 12.0, 0.05)
	await process_frame
	_ok(bool(music.state()["fading"]), "a fade to -15 dB is in flight rather than applied at once")
	await _fade_closed(music)
	_ok(absf(float(music.state()["level_db"]) - (AudioService.MUSIC_DB - 12.0)) < DONE_DB,
			"and it lands where it was asked to  (%.2f dB)" % float(music.state()["level_db"]))
	var before := float(music.state()["level_db"])
	music.fade_to(NAN)
	await process_frame
	_eq(float(music.state()["level_db"]), before,
			"a NaN off a fade leaves the bed where it was rather than stranding it")

	# Back to the real bed, and prove the swap put the original stream back rather
	# than leaving the game running on silence.
	music.use_placeholder(false)
	await process_frame
	var real := music.state()
	_ok(not bool(real["placeholder"]), "the real bed can be handed back")
	_ok(_peak(music.bed.stream) > SILENT,
			"and it is audible again, not left on the placeholder  (peak %.4f)" % _peak(music.bed.stream))


## A throttle change, read at the engine voice. Not at the synthesiser: the
## question is whether the bridge's feed arrived at the thing that makes the
## sound, and a synthesiser nobody holds would render happily either way.
func _check_engine(service: AudioService) -> void:
	var bridge := service.bridge
	if bridge == null:
		return
	var world := _world()
	var car := _car(world)
	bridge.car = car
	await physics_frame
	await physics_frame

	var voice := _voice(bridge)
	if not _ok(voice != null, "the engine voice is reachable through the bridge"):
		world.queue_free()
		return
	_ok(voice.sounding(), "and the bridge told it to sound, because there is a car")

	car.throttle = 0.0
	for _i in REVS:
		await physics_frame
	var off_load := _settled_load(voice)
	var off_rpm := voice.sounding_rpm()
	var idle := EngineSynth.new()
	_settle(idle)
	_ok(off_load < idle.load() + 0.01,
			"a car off the throttle leaves the voice's load at nothing  (%.4f)" % off_load)

	car.throttle = 1.0
	for _i in REVS:
		await physics_frame
	await physics_frame
	var on_load := _settled_load(voice)
	var on_rpm := voice.sounding_rpm()

	_ok(on_rpm > off_rpm * 1.5,
			"full throttle moves the revs the voice is sounding  (%.0f -> %.0f rpm)" % [off_rpm, on_rpm])
	_ok(on_load > off_load * 2.0 + 0.01,
			"and the throttle itself reaches the voice  (%.4f -> %.4f)" % [off_load, on_load])

	# The comparison: a voice the feed never arrived at. Without it the two
	# assertions above also pass against a bridge that feeds nothing at all.
	var orphan := EngineVoice.new()
	orphan.synth.set_engine(800.0, 0.0)
	_settle(orphan.synth)
	_ok(orphan.sounding_load() < off_load * 2.0 + 0.01,
			"a voice nothing fed stays off the throttle, so the above are not vacuous  (%.4f)"
					% orphan.sounding_load())
	orphan.free()

	bridge.car = null
	car.queue_free()
	await process_frame
	await process_frame
	world.queue_free()
	await process_frame


## The host hands its director and car over. Read from the source rather than
## from a running `main.gd`, because booting the whole game to prove a method is
## called on it is not a check - and because this is the one case that cannot be
## observed at all from inside a headless run: nothing instantiates the scene, so
## nothing here would notice if the host stopped handing things over and went
## back to letting the audio system find them by reflection.
func _check_host_source() -> void:
	var f := FileAccess.open("res://Game/main.gd", FileAccess.READ)
	if not _ok(f != null, "the host source is readable"):
		return
	var src := f.get_as_text()
	_ok(src.contains("_wire_audio"), "the host has one place that wires audio")
	# Qualified on the service, not bare: `camera.set_car(player_car)` is in the
	# same file three lines away from the line that matters, and a check that
	# passes on the camera's call is a check that proves nothing.
	_ok(src.contains("audio.set_race("), "and it hands the service its race director")
	_ok(src.contains("AudioService.instance.set_car("), "and its car")
	# The one thing it must NOT do: build a second bridge. A host that does gets
	# a bridge that stands itself down, so the game's engine would be silent and
	# the host would have no idea why.
	_fails(src.contains("AudioBridge.new("),
			"the host never builds a bridge of its own - the autoload's is the game's")
	_fails(src.contains("AudioDirector.new("), "nor a director of its own")


# ------------------------------------------------------------------- measuring

## A flat plate under the car. Without it the car free-falls for the length of
## the check, and a car in free fall is not a car whose engine note means
## anything.
func _world() -> Node3D:
	var world := Node3D.new()
	world.name = "HostWiringWorld"
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


func _voice(bridge: AudioBridge) -> EngineVoice:
	if bridge == null or bridge.director == null:
		return null
	return bridge.director.get_node_or_null("EngineVoice") as EngineVoice


## The smoothed load the voice is sounding, after pushing the smoother past five
## time constants.
##
## Rendered by hand rather than waited for, and deliberately: under
## `--audio-driver Dummy` the mixer never drains the generator's ring, so the
## voice's own `_process` finds no room and renders nothing (that is the whole of
## `EngineVoice`'s header). A check that waited for the ring would be testing the
## driver. What is under test is that the number arrived, so it is rendered into
## a plain array and read back through the voice.
func _settled_load(voice: EngineVoice) -> float:
	_settle(voice.synth)
	return voice.sounding_load()


func _settle(s: EngineSynth) -> void:
	var buf := PackedFloat32Array()
	buf.resize(int(SETTLE * s.mix_rate))
	s.render(buf)


## Frames until the channel's fade has landed. Bounded, because "wait until it
## finishes" with no bound is how a check hangs instead of failing.
func _fade_closed(music: MusicChannel) -> void:
	for _i in 600:
		await process_frame
		if not bool(music.state()["fading"]):
			return


## Largest absolute sample in a stream's buffer. Silent is zero, not -inf: a
## sixteen-bit buffer of zeros decodes to zeros.
func _peak(stream: AudioStream) -> float:
	var wav := stream as AudioStreamWAV
	if wav == null or wav.data.size() < 2:
		return 0.0
	var data := wav.data
	var top := 0
	for i in range(0, data.size() - 1, 2):
		var v := data[i] | (data[i + 1] << 8)
		if v > top:
			top = v
	return float(top) / 32767.0


## Stopped *and* unstreamed, for the same reason `bridge_check.gd` does it: a
## stopped player still holds its `AudioStreamWAV`, and a freed player leaves the
## server holding a playback pointing at one. The music channel is handed the
## placeholder first so the bed being released is the real one.
func _teardown() -> void:
	var service := AudioService.instance
	if service != null and service.music != null:
		service.music.use_placeholder(false)
	AudioCues._cache.clear()
	AudioBeds._cache.clear()
	OS.delay_msec(300)


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
