extends SceneTree
## Acceptance gate for the audio system. Run:
##   godot --headless --audio-driver Dummy --path . --script res://Audio/audio_check.gd
##
## Checks the signal, not the plumbing. Under the dummy driver no audio frames
## are ever pulled back out of a player, so "the player is playing" proves
## nothing about whether the engine is audible. What is measurable is the
## synthesised audio itself: rendered into an array, the engine's pitch, level
## and continuity can be measured, and that is what this does.
##
## Every check is paired with a case that must NOT pass - silence against the
## audibility test, a hard discontinuity against the click bound, an identical
## pair against the "did it change" test. A gate that cannot fail is worse than
## no gate, and those pairs are what stop this one from quietly rotting into
## one.
##
## ORIGINAL GAME CONTENT.

## The largest sample-to-sample step that is not a click, as a fraction of full
## scale. Anything under this between adjacent samples at 44.1 kHz is below
## about -12 dBFS of broadband transient per sample: a tick, not a pop.
const MAX_STEP := 0.35
## Below this the engine is inaudible, so a check of "it makes a sound" is
## really a check of "it is above the noise floor of the mix".
const AUDIBLE := 0.002
const AUDIBLE_LOADED := 0.02

var _passed: int = 0
var _failed: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	_check_buses()
	_check_engine_signal()
	_check_engine_guards()
	_check_cues()
	await _check_wired()
	await _check_api()
	_report()


# ----------------------------------------------------------------------- buses

func _check_buses() -> void:
	AudioBuses.ensure()
	_ok(AudioBuses.index_of(AudioBuses.MASTER) == 0, "the layout has a Master bus")
	for bus in [AudioBuses.MUSIC, AudioBuses.SFX, AudioBuses.ENGINE, AudioBuses.AMBIENCE]:
		_ok(AudioBuses.has_bus(bus), "%s bus exists" % bus)
		_ok(AudioServer.get_bus_send(AudioBuses.index_of(bus)) == AudioBuses.MASTER,
				"%s routes to Master" % bus)

	var before := AudioServer.get_bus_count()
	AudioBuses.ensure()
	AudioBuses.ensure()
	_eq(AudioServer.get_bus_count(), before, "ensure() is idempotent - two more calls change nothing")

	_fails(AudioBuses.has_bus("Nope"), "a bus that is not in the layout does not exist")
	_eq(AudioBuses.index_of("Nope"), -1, "an unknown bus index is -1, not 0")

	AudioBuses.set_volume(AudioBuses.SFX, 0.5)
	_ok(absf(AudioBuses.volume(AudioBuses.SFX) - 0.5) < 0.01,
			"SFX volume round-trips  (got %.3f, want 0.500)" % AudioBuses.volume(AudioBuses.SFX))
	AudioBuses.set_volume(AudioBuses.SFX, 4.0)
	_ok(AudioBuses.volume(AudioBuses.SFX) <= 1.0, "a volume over 1 clamps rather than overdriving the bus")
	AudioBuses.set_volume(AudioBuses.SFX, NAN)
	_ok(AudioBuses.volume(AudioBuses.SFX) == 1.0, "a NaN volume leaves the mix alone instead of silencing it")
	AudioBuses.set_volume(AudioBuses.SFX, 0.0)
	_ok(AudioBuses.volume(AudioBuses.SFX) == 0.0 and is_finite(AudioBuses.volume_db(AudioBuses.SFX)),
			"a volume of 0 is a dB floor, not -inf")
	AudioBuses.set_volume(AudioBuses.SFX, 1.0)

	var master := AudioBuses.master_volume()
	AudioBuses.set_volume("Nope", 0.1)
	_eq(AudioBuses.master_volume(), master, "writing a bus that does not exist touches nothing")
	AudioBuses.set_muted(AudioBuses.SFX, true)
	_ok(AudioBuses.is_muted(AudioBuses.SFX), "a bus can be muted")
	AudioBuses.set_muted(AudioBuses.SFX, false)
	_fails(AudioBuses.is_muted(AudioBuses.SFX), "and unmuted again")


# ---------------------------------------------------------------- engine signal

func _check_engine_signal() -> void:
	var idle := EngineSynth.new()
	var hot := EngineSynth.new()
	idle.set_engine(EngineSynth.IDLE_RPM, 0.0)
	hot.set_engine(EngineSynth.REDLINE, 1.0)
	var a := _settled(idle, 0.35, 0.25)
	var b := _settled(hot, 0.35, 0.25)

	var rms_idle := _rms(a)
	var rms_hot := _rms(b)
	_ok(_audible(a), "the engine is audible at idle  (rms %.4f, want > %.4f)" % [rms_idle, AUDIBLE])
	_ok(rms_hot > AUDIBLE_LOADED, "and loud on load  (rms %.4f, want > %.4f)" % [rms_hot, AUDIBLE_LOADED])
	_ok(rms_hot > rms_idle * 1.5, "load opens the level  (%.4f vs %.4f idle)" % [rms_hot, rms_idle])

	var hz_idle := _dominant_hz(a, idle.mix_rate)
	var hz_hot := _dominant_hz(b, hot.mix_rate)
	var want_idle := EngineSynth.firing_frequency(EngineSynth.IDLE_RPM)
	var want_hot := EngineSynth.firing_frequency(EngineSynth.REDLINE)
	_ok(absf(hz_idle - want_idle) < want_idle * 0.2,
			"idle fires at the engine's fundamental  (got %.1f Hz, want ~%.1f)" % [hz_idle, want_idle])
	_ok(absf(hz_hot - want_hot) < want_hot * 0.15,
			"redline fires an octave up and more  (got %.1f Hz, want ~%.1f)" % [hz_hot, want_hot])
	_ok(hz_hot > hz_idle * 3.0, "so rpm moves the pitch  (%.1f Hz vs %.1f Hz)" % [hz_hot, hz_idle])

	_ok(_max_step(a) < MAX_STEP, "idle has no discontinuity  (max step %.3f, want < %.3f)" % [_max_step(a), MAX_STEP])
	_ok(_max_step(b) < MAX_STEP, "nor on load  (max step %.3f, want < %.3f)" % [_max_step(b), MAX_STEP])

	# The comparison itself, both ways round.
	_fails(_differs(a, a), "two identical renders do not count as a change")
	_ok(_differs(a, b), "idle and full load do count as a change")
	_fails(_audible(_silence(2048)), "the audibility test rejects silence")
	_fails(_max_step(_ramp(2048)) < MAX_STEP, "the click bound rejects a hard discontinuity")

	# Same inputs, same samples: the noise is a fixture, so a check can compare
	# two renders exactly instead of fuzzily.
	var twin_a := _settled(EngineSynth.new(), 0.05, 0.05)
	var twin_b := _settled(EngineSynth.new(), 0.05, 0.05)
	_eq(twin_a, twin_b, "the synth is deterministic")


func _check_engine_guards() -> void:
	var s := EngineSynth.new()
	# What a car actually hands over on the first frame of a race, and what a
	# divide-by-zero in the driving code hands over a moment later.
	s.set_engine(0.0, 0.0)
	s.set_engine(NAN, NAN)
	s.set_engine(-500.0, -2.0)
	s.set_engine(INF, 5.0)
	s.set_engine(1e30, 1e30)
	var buf := _settled(s, 0.05, 0.05)
	_ok(_all_finite(buf), "rpm and load of NaN, INF, negative or absurd still render a finite signal")
	_ok(_peak(buf) <= 1.0, "and the signal stays inside full scale  (peak %.3f)" % _peak(buf))
	_ok(s.frequency() > 0.0, "a zero rpm is still an engine turning over  (%.1f Hz)" % s.frequency())
	_ok(s.load() >= 0.0 and s.load() <= 1.0, "load stays a fraction  (%.3f)" % s.load())

	_eq(EngineSynth.firing_frequency(-1.0), EngineSynth.firing_frequency(0.0), "a negative rpm fires like no rpm")
	_eq(EngineSynth.firing_frequency(NAN), EngineSynth.firing_frequency(0.0), "a NaN rpm fires like no rpm")
	_ok(is_finite(EngineSynth.firing_frequency(INF)), "an infinite rpm is finite")
	_ok(EngineSynth.firing_frequency(9000.0, 0) > 0.0, "zero cylinders does not divide by zero")

	# The no-pop guarantee, stated as a test: an engine that jumps from idle to
	# redline in one frame is a car changing gear at 9000, not a click.
	var ramp := EngineSynth.new()
	ramp.set_engine(EngineSynth.IDLE_RPM, 0.1)
	_settled(ramp, 0.3, 0.0)
	ramp.set_engine(EngineSynth.REDLINE, 1.0)
	var stepped := _settled(ramp, 0.05, 0.05)
	_ok(_max_step(stepped) < MAX_STEP,
			"idle straight to redline in one frame does not click  (max step %.3f, want < %.3f)" % [_max_step(stepped), MAX_STEP])


# -------------------------------------------------------------------- the bank

func _check_cues() -> void:
	for name in AudioCues.names():
		_ok(AudioCues.has(name), "cue %s is in the bank" % name)
	_fails(AudioCues.has("no_such_cue"), "a name that is not in the bank is not a cue")
	_eq(AudioCues.stream("no_such_cue"), null, "a name that is not in the bank has no stream")
	_fails(AudioCues.stream("") != null, "an empty name has no stream either")

	var go := AudioCues.stream("go")
	_ok(go != null, "go synthesises")
	_ok(go is AudioStreamWAV, "as a WAV, so a player can just play it")
	_eq(go.mix_rate, AudioCues.MIX_HZ, "at the rate the bank declares")
	_ok(go.get_length() > 0.3, "long enough to be heard  (%.3f s)" % go.get_length())
	_ok(absf(go.get_length() - AudioCues.seconds("go")) < 1.0 / float(AudioCues.MIX_HZ),
			"and as long as the recipe says, to within one sample")

	for name in AudioCues.names():
		var v := _decode(AudioCues.stream(name))
		_ok(v.size() == int(AudioCues.seconds(name) * float(AudioCues.MIX_HZ)),
				"cue %s is the right length  (%d frames)" % [name, v.size()])
		_ok(_peak(v) > 0.01, "cue %s is not silence  (peak %.3f)" % [name, _peak(v)])
		_ok(_peak(v) <= 1.0, "cue %s does not clip  (peak %.3f)" % [name, _peak(v)])
		_ok(absf(v[0]) < 0.01, "cue %s starts at silence  (%.4f)" % [name, v[0]])
		_ok(absf(v[v.size() - 1]) < 0.01, "cue %s ends at silence  (%.4f)" % [name, v[v.size() - 1]])
		_ok(_max_step(v) < MAX_STEP, "cue %s has no step in it  (%.3f)" % [name, _max_step(v)])

	# The countdown is one sound repeated and then a different one, so a
	# 3-2-1-GO sequence is three beats of the same pitch and a rise. Compared
	# without _eq: printing a kilobyte of PCM to explain a pass helps nobody.
	_ok(AudioCues.stream("count_3").data == AudioCues.stream("count_2").data, "the lights share one pitch")
	_ok(AudioCues.stream("count_2").data == AudioCues.stream("count_1").data, "all three of them")
	_ok(AudioCues.stream("go").data != AudioCues.stream("count_1").data, "GO is a different sound from the lights")

	_ok(AudioCues.stream("go") == go, "a stream is cached rather than rebuilt on every cue")


# --------------------------------------------------------------------- wired

## The service as the game runs it: one autoload, started before the first frame,
## with nothing handed to it. Everything above is synthesis in a vacuum; this is
## the part that decides whether anyone hears it.
##
## Runs after a frame, because an autoload\'s `_ready` is not called until the
## tree starts iterating: inside `_initialize` the node is in the tree and not
## ready yet, which is the same trap as any callback that fires too early.
func _check_wired() -> void:
	# One frame, to let the tree start: see the note above.
	await process_frame
	var service := AudioService.instance
	_ok(service != null, "the service is registered, so nothing has to find it")
	if service == null:
		return
	_ok(root.get_node_or_null("Audio") == service,
			"as an autoload called Audio, so it exists before the main scene does")
	_ok(service.bridge != null, "with a bridge to hand the race and the car over")

	var director := service._director()
	_ok(director != null, "and a director of its own to play cues through")
	if director == null:
		return

	# The mix it asks for, with the buses up.
	for bus in AudioService.MIX:
		var name := String(bus)
		_ok(AudioBuses.has_bus(name), "the mix bus %s is in the layout" % name)
		_ok(not AudioBuses.is_muted(name), "%s is not muted" % name)
		_ok(absf(AudioBuses.volume(name) - float(AudioService.MIX[bus])) < 0.01,
				"%s sits where the mix puts it  (%.2f, want %.2f)" % [
					name, AudioBuses.volume(name), float(AudioService.MIX[bus])])

	# Two beds playing from the first frame, and a tyre voice that is playing and
	# silent: a loop that starts when the player wants to hear it is a loop that
	# clicks on the way in.
	var expected := {"Bed_Music": AudioBuses.MUSIC, "Bed_Night": AudioBuses.AMBIENCE,
			"Bed_Tyre": AudioBuses.SFX}
	for node_name in expected:
		var bed := service.get_node_or_null(node_name) as AudioStreamPlayer
		_ok(bed != null, "%s exists" % node_name)
		if bed == null:
			continue
		_ok(bed.playing, "%s is playing  (%s)" % [node_name, str(bed.playing)])
		_ok(bed.bus == String(expected[node_name]), "%s is on its own bus  (%s)" % [node_name, bed.bus])
		var wav := bed.stream as AudioStreamWAV
		_ok(wav != null, "%s carries a WAV" % node_name)
		if wav == null:
			continue
		_ok(wav.loop_mode != AudioStreamWAV.LOOP_DISABLED, "%s loops" % node_name)
		_ok(wav.loop_begin == 0 and wav.loop_end == wav.data.size() / 2,
				"%s loops over the whole buffer  (%d..%d of %d)" % [
					node_name, wav.loop_begin, wav.loop_end, wav.data.size() / 2])
		# The loop point is the one splice in a looped stream between two samples
		# that never met, so it is the one that clicks.
		var v := _decode(wav)
		_ok(v.size() > 2, "%s has samples to splice" % node_name)
		_ok(_peak(v) > AUDIBLE, "%s is not silence  (peak %.3f)" % [node_name, _peak(v)])
		_ok(absf(v[v.size() - 1] - v[0]) < MAX_STEP,
				"%s joins its tail to its head without a click  (%.4f, want < %.2f)" % [
					node_name, absf(v[v.size() - 1] - v[0]), MAX_STEP])
			# Player level plus bus level, in dB. The point is the sum: a bed playing
		# at -3 dB on a muted bus is silence. The tyre bed is deliberately not in
		# here - it is meant to be silent until the tyres are abused.
		if node_name != "Bed_Tyre":
			var chain := bed.volume_db + AudioBuses.volume_db(bed.bus)
			_ok(chain > -40.0, "%s arrives above the noise floor  (%.1f dB)" % [node_name, chain])
	_fails(AudioBeds.stream("music").data == AudioBeds.stream("night").data,
			"the music and the night are not the same loop")

	var tyre := service.get_node_or_null("Bed_Tyre") as AudioStreamPlayer
	_ok(tyre != null and tyre.volume_db <= AudioBuses.SILENCE_DB + 0.001,
			"and the tyre voice stays silent until a tyre is abused  (%.1f dB)" % [
				0.0 if tyre == null else tyre.volume_db])

	# The engine voice follows the car, and the cylinders are what the sound is
	# made of: a six and a four idle 13 Hz apart and you hear which one it is.
	for id in CarDB.ALL_IDS:
		_ok(AudioService.CYLINDERS.has(id), "%s has a cylinder count" % id)
	var four: CarBody = await _car("kairo_s13")
	var six: CarBody = await _car("shinobi_rs")
	_ok(four != null and six != null, "two cars to change between")
	var synth := director.engine_synth() as EngineSynth
	_ok(synth != null, "the engine voice lives on the director, which the car drives")
	var voice := director.find_child("EngineVoice", true, false) as EngineVoice
	_ok(voice != null and voice.bus == AudioBuses.ENGINE, "and it plays onto the Engine bus")
	_ok(service.bridge.director == director, "the bridge is driving this same one")
	if four != null:
		service.set_car(four)
		_ok(synth != null and synth.cylinders == int(AudioService.CYLINDERS["kairo_s13"]),
				"a four is four cylinders  (%d)" % [0 if synth == null else synth.cylinders])
		_ok(four.contact_monitor, "and a contact monitor, without which no impact is reported")
		_ok(four.max_contacts_reported > 0, "reporting contacts  (%d)" % four.max_contacts_reported)
		_ok(four.body_entered.is_connected(service._on_impact), "and an impact listener")
	if six != null:
		service.set_car(six)
		_ok(synth != null and synth.cylinders == int(AudioService.CYLINDERS["shinobi_rs"]),
				"so swapping to a six is six cylinders  (%d)" % [0 if synth == null else synth.cylinders])

	# Slip is read from the contact patches and not from the body\'s attitude: a
	# big slide with the rears barely moving is a drift, and a drift is not a squeal.
	var car: CarBody = six if six != null else four
	if car != null:
		var resting := service._slip(car)
		_slide(car, 1.0)
		var sliding := service._slip(car)
		_reset(car)
		_ok(resting <= 0.01, "a car on its wheels is quiet  (slip %.3f)" % resting)
		_ok(sliding > 0.9, "and a fully sliding one squeals  (slip %.3f)" % sliding)
		_fails(sliding == resting, "so slip is not a constant")
		_ok(service._tyre_db(sliding) > service._tyre_db(resting) + 10.0,
				"and the squeal is the louder of the two  (%.1f dB vs %.1f dB)" % [
					service._tyre_db(sliding), service._tyre_db(resting)])
		# Measured, not assumed: a floor under the tyre voice meant a parked car
		# squealed continuously at -40 dB, which is a noise nobody asked for and
		# nobody can turn off. The gap between "silent" and "a squeal" is a slew
		# rate rather than a level, and that is what keeps the onset from being a
		# click on the one frame a tyre noise is allowed to be heard.
		_ok(service._tyre_db(resting) == AudioBuses.SILENCE_DB,
				"and silent at rest  (%.1f dB)" % service._tyre_db(resting))
		_ok(service._tyre_db(0.0) == AudioBuses.SILENCE_DB,
				"including at no slip at all  (%.1f dB)" % service._tyre_db(0.0))
		_ok(service._tyre_db(0.5) > AudioBuses.SILENCE_DB + 20.0,
				"while half a slide is still a squeal  (%.1f dB)" % service._tyre_db(0.5))
		_ok(AudioService.TYRE_SLEW_DB > 0.0 and AudioService.TYRE_SLEW_DB <= 12.0,
				"and the slew rate is the one a tyre noise can open with  (%.1f dB a frame)" % [
						AudioService.TYRE_SLEW_DB])

		# An impact is a crash at speed and a bump at walking pace, and a scrape is
		# one thump rather than a stream of them.
		var played := director.cues_played
		car.speed_kph = 4.0
		service._on_impact(null)
		_eq(director.cues_played, played, "a nudge is not an impact")
		car.speed_kph = 60.0
		service._on_impact(null)
		_eq(director.last_cue, "hit", "a contact at 60 kph is a hit")
		_eq(director.cues_played, played + 1, "and it is heard once")
		service._on_impact(null)
		_eq(director.cues_played, played + 1, "a scrape is one hit, not a stream of them")
		_ok(service._impact_db() < 0.0, "louder the faster it was  (%.1f dB)" % service._impact_db())
		service._impact_lock = 0.0
		car.speed_kph = 90.0
		_ok(service._impact_db() > -0.01, "up to a flat wall  (%.1f dB)" % service._impact_db())

		# A gear change is the one cue that happens on a car\'s own, so it is
		# stepped through the same per-frame call the game uses. The first call is
		# the one that picks the car up and notes the gear it is already in.
		car.current_gear = 1
		service._physics_process(1.0 / 60.0)
		var before_shift := director.cues_played
		car.current_gear = 2
		car.engine_rpm = 3000.0
		service._physics_process(1.0 / 60.0)
		_eq(director.last_cue, "shift", "a gear change shifts")
		service._physics_process(1.0 / 60.0)
		_eq(director.cues_played, before_shift + 1, "and once for a gear held")

	# A UI click needs nothing but the service.
	var ui_played := director.cues_played
	service._on_ui()
	_eq(director.last_cue, "ui_ok", "a UI press clicks")
	_eq(director.cues_played, ui_played + 1, "and it is one cue")

	# The click wiring attaches by name, and the menus are built by the host's
	# `_ready` long after this one, so a signal that gets renamed leaves three
	# silent no-ops rather than an error. Asked of the script rather than of an
	# instance: standing up a real MenuFlow to check its signal list is a whole
	# screen stack for a reflection.
	var flow_script := load("res://UI/menu_flow.gd") as GDScript
	var has_signal := {}
	for sig in flow_script.get_script_signal_list():
		has_signal[sig["name"]] = true
	for host_signal in AudioService.HOST_CLICKS:
		_ok(has_signal.has(host_signal), "%s is a signal MenuFlow has" % host_signal)
	var has_method := {}
	for method in flow_script.get_script_method_list():
		has_method[method["name"]] = true
	_ok(has_method.has("screen_name"),
			"and screen_name is how the service notices the screen changed")

	# Every car builds a director for its own engine and each registers itself as
	# the static. Drive the car through that static and the engine is played by
	# whichever car was built last, which is inaudible until there are two.
	var rogue := AudioDirector.new()
	rogue.name = "AudioRogue"
	root.add_child(rogue)
	await process_frame
	await process_frame
	_ok(AudioDirector.instance == rogue, "so a second director does register itself")
	_ok(director != rogue, "and the service does not hand its car to it")
	for child in rogue.get_children():
		if child is AudioStreamPlayer:
			child.stop()
	rogue.queue_free()
	await create_timer(0.25).timeout

	for node in [four, six]:
		if node != null and is_instance_valid(node):
			node.queue_free()
	await create_timer(0.25).timeout


## A car with nothing under it: the voice and the wheels are what is under test,
## and a body with no world to hit still reports its wheels.
func _car(id: String) -> CarBody:
	var car := CarBody.new()
	car.name = "AudioCheck_" + id
	car.spec = CarDB.get_spec(id)
	car.build_visual = false
	root.add_child(car)
	await process_frame
	return car


## Puts every wheel into a slide without moving the car, so the mapping can be
## measured on a body that is parked on a world with no tarmac.
func _slide(car: CarBody, amount: float) -> void:
	for w in car.wheels():
		w["load"] = 400.0
		w["sr_smooth"] = amount


func _reset(car: CarBody) -> void:
	for w in car.wheels():
		w["load"] = 0.0
		w["sr_smooth"] = 0.0
		w["slip_angle"] = 0.0


# ------------------------------------------------------------------- the API

func _check_api() -> void:
	# Never in the tree: everything on the surface has to be safe anyway, since
	# the car pushes rpm from the first frame and the race director polls
	# lights before the audio exists.
	var orphan := AudioDirector.new()
	_fails(orphan.play_cue("hit"), "a cue on a director that is not in the tree fails instead of crashing")
	orphan.set_engine(1200.0, 0.5)
	orphan.set_lights(3)
	orphan.set_master_volume(0.5)
	orphan.stop_engine()
	_eq(orphan.engine_synth(), null, "an unready director has no engine yet")
	orphan.free()

	var d := AudioDirector.new()
	d.name = "AudioCheck"
	root.add_child(d)
	await process_frame
	await process_frame

	_ok(AudioDirector.instance == d, "the director registers itself so no caller needs a node path")
	_fails(d.play_cue("no_such_cue"), "play_cue refuses a cue that is not in the bank")
	_fails(d.play_cue(""), "play_cue refuses an empty name")
	_ok(d.play_cue("hit"), "play_cue accepts one that is")
	_eq(d.last_cue, "hit", "and says which one it played")
	_ok(d.cues_played == 1, "having played exactly one  (%d)" % d.cues_played)
	for name in AudioCues.names():
		_ok(d.play_cue(name), "play_cue plays %s" % name)

	# More cues than the pool holds, because a pile-up is more cues than the
	# pool holds and the oldest must be recycled rather than dropped.
	var played := d.cues_played
	for i in AudioDirector.VOICE_POOL * 2:
		d.play_cue("shift")
	_eq(d.cues_played, played + AudioDirector.VOICE_POOL * 2, "cues keep coming when the pool is full")

	d.set_engine(0.0, 0.0)
	d.set_engine(EngineSynth.REDLINE, 1.0)
	d.set_engine(NAN, NAN)
	d.set_engine(-100.0, -1.0)
	d.set_engine(INF, INF)
	d.set_master_volume(0.5)
	d.set_master_volume(NAN)
	d.set_bus_volume(AudioBuses.MUSIC, 0.25)
	d.set_bus_volume("no_such_bus", 0.25)
	d.set_bus_muted(AudioBuses.MUSIC, true)
	d.set_bus_muted(AudioBuses.MUSIC, false)
	d.stop_engine()
	await process_frame
	await process_frame

	var synth := d.engine_synth()
	_ok(synth != null, "the engine synth is reachable")
	_ok(synth.frequency() > 0.0, "rpm of NaN, INF or negative still leaves the engine turning  (%.1f Hz)" % synth.frequency())
	_ok(synth.level() > 0.0, "the engine is generating signal inside the tree, with no audio device  (level %.4f)" % synth.level())
	var voice := d.find_child("EngineVoice", true, false) as EngineVoice
	_ok(voice != null and voice.queued_frames() > 0, "and the voice is feeding the generator")
	_ok(voice != null and voice.bus == AudioBuses.ENGINE, "on the Engine bus")
	_ok(AudioBuses.is_muted(AudioBuses.MUSIC) == false, "and the bus layout is still intact after all of that")
	_ok(AudioBuses.index_of(AudioBuses.ENGINE) >= 0, "including the Engine bus")

	# The countdown hook, on a director that has not seen a light yet: a race
	# director sits at 0 on the grid, and that must not be a GO.
	var lights := AudioDirector.new()
	lights.name = "AudioCheckLights"
	root.add_child(lights)
	await process_frame
	lights.set_lights(0)
	_ok(lights.last_cue == "", "a director sitting at 0 does not fire a GO at race load")
	var seq: Array[String] = []
	for n in [3, 3, 2, 1, 0, 0, 7, -2, 0]:
		lights.set_lights(n)
		if lights.last_cue != "" and (seq.is_empty() or seq[seq.size() - 1] != lights.last_cue):
			seq.append(lights.last_cue)
	_eq(seq, ["count_3", "count_2", "count_1", "go"] as Array[String], "3-2-1-GO comes out in order, once each")
	_eq(lights.cues_played, 4, "and a value that is not a light makes no sound at all")

	# Stopped before they are freed, and given frames to be released in. A
	# player the audio server still holds a playback for outlives the node by
	# one teardown, and an ObjectDB leak at exit is the one warning this
	# project should not have.
	for child in d.get_children() + lights.get_children():
		if child is AudioStreamPlayer:
			child.stop()
	d.queue_free()
	lights.queue_free()
	# Real time, not frames: the audio server releases a playback on its own mix
	# step, and a headless dummy driver gets one of those on the audio thread
	# rather than on the frame we are standing in.
	await create_timer(0.25).timeout
	# The synthesised streams outlive the players by design, which is what makes
	# them a cache - and a static cache is still holding them when the engine
	# tears the object database down. A test process is about to exit, so there
	# is nothing to keep them for.
	AudioCues._cache.clear()
	_ok(AudioDirector.instance == null, "the director lets go of the static reference when it leaves")


# ------------------------------------------------------------------- measuring

## Lets the smoothers settle, then returns the next `secs` of signal. A synth
## that has just been told 9000 rpm is still at idle for the first few frames,
## which is the point of the smoothing and also why a check has to wait for it.
func _settled(s: EngineSynth, settle: float, secs: float) -> PackedFloat32Array:
	var warm := PackedFloat32Array()
	warm.resize(int(settle * s.mix_rate))
	s.render(warm)
	var out := PackedFloat32Array()
	out.resize(int(secs * s.mix_rate))
	s.render(out)
	return out


func _rms(buf: PackedFloat32Array) -> float:
	if buf.is_empty():
		return 0.0
	var sum := 0.0
	for v in buf:
		sum += v * v
	return sqrt(sum / float(buf.size()))


func _peak(buf: PackedFloat32Array) -> float:
	var p := 0.0
	for v in buf:
		p = maxf(p, absf(v))
	return p


func _all_finite(buf: PackedFloat32Array) -> bool:
	for v in buf:
		if not is_finite(v):
			return false
	return true


## Biggest jump between neighbouring samples. A discontinuity, i.e. a click.
func _max_step(buf: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(1, buf.size()):
		worst = maxf(worst, absf(buf[i] - buf[i - 1]))
	return worst


func _audible(buf: PackedFloat32Array) -> bool:
	return _rms(buf) > AUDIBLE


## Whether two renders are different enough to be two sounds. Compared as
## samples rather than as statistics so a synth that got quieter without
## changing pitch still counts as changed.
func _differs(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return true
	for i in a.size():
		if absf(a[i] - b[i]) > 0.05:
			return true
	return false


## The loudest frequency in the signal, by Goertzel over a Hann-windowed prefix.
## Counting waveform peaks would be wrong here: an engine is a pulse train with
## strong harmonics, and once the filter opens the peak count stops being the
## pitch.
func _dominant_hz(buf: PackedFloat32Array, rate: float, max_hz: float = 700.0) -> float:
	var n := mini(buf.size(), 4096)
	if n < 128:
		return 0.0
	var top := clampi(int(max_hz * float(n) / rate), 1, n / 2 - 1)
	var best := -1.0
	var best_hz := 0.0
	for k in range(1, top + 1):
		var re := 0.0
		var im := 0.0
		for i in n:
			var x := buf[i] * (0.5 - 0.5 * cos(TAU * float(i) / float(n)))
			var a := TAU * float(k) * float(i) / float(n)
			re += x * cos(a)
			im += x * sin(a)
		var mag := re * re + im * im
		if mag > best:
			best = mag
			best_hz = float(k) * rate / float(n)
	return best_hz


func _silence(n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	return out


## A buffer that steps straight from -1 to +1: the click this project is not
## allowed to make.
func _ramp(n: int) -> PackedFloat32Array:
	var out := _silence(n)
	for i in n:
		out[i] = -1.0 if i < n / 2 else 1.0
	return out


## Little-endian 16-bit, read by hand rather than with decode_s16: the packing
## is part of what is being checked, and a helper would only hide it.
func _decode(w: AudioStreamWAV) -> PackedFloat32Array:
	var d := w.data
	var out := PackedFloat32Array()
	out.resize(d.size() / 2)
	for i in out.size():
		var v: int = d[i * 2] | (d[i * 2 + 1] << 8)
		if v >= 32768:
			v -= 65536
		out[i] = float(v) / 32768.0
	return out


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
