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
	await _check_api()
	_report()


# ----------------------------------------------------------------------- buses

func _check_buses() -> void:
	AudioBuses.ensure()
	_ok(AudioBuses.index_of(AudioBuses.MASTER) == 0, "the layout has a Master bus")
	for bus in [AudioBuses.MUSIC, AudioBuses.SFX, AudioBuses.ENGINE]:
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
