class_name EngineVoice
extends AudioStreamPlayer
## The engine you hear: four recorded loops mapped to the revs, with the
## synthesiser underneath as the fallback for a build with no samples in it.
##
## The generator is right-sized rather than generous: a long buffer survives a
## hitch, and a short one is what lets the engine track rpm the way an engine
## does instead of catching up a tenth of a second late.
##
## Everything the player touches lives in `synth`. That is deliberate - the
## player is a delivery mechanism for a signal that has to be measurable, and
## a check that can only see a player cannot tell a running engine from a
## silent one under the dummy driver.
##
## `set_sounding` is the whole contract, and it is a stop rather than a fader
## because a generator is a ring the audio server drains at a rate of its own
## choosing and nothing else empties. Three measured consequences, all of them
## an engine sounding with no engine:
##
##  - A voice that `play()`s itself in `_ready` is an idling engine from frame
##    one. Measured with zero CarBody nodes in the tree - the main menu - the
##    Engine bus sat at -32 dB.
##  - Fading the synthesiser down is not stopping it. The audio server keeps
##    mixing a ring nobody is emptying, so it plays back whatever was last
##    committed to it: 4000 frames after the car was freed, the Engine bus was
##    still at -20 dB.
##  - The fade does not even close, because `render` only runs on the frames
##    that find room in a ring the mixer has stopped draining. After those 4000
##    frames the fade was still at 0.21.
##
## So `set_sounding(false)` ramps the synthesiser into the ring - which is the
## anti-click half, and is bounded rather than open-ended - and then puts the
## player down. A stopped player is not in the mix at all, so the bus is empty
## from the next audio step. `set_sounding(true)` ramps back up from nothing
## rather than resuming a level somebody left behind.
##
## The samples are on that same contract rather than a second one. With the loops
## present the generator is a shadow: it is still rendered into a scratch buffer
## every frame, because that is where the one-poles that smooth rpm and load
## live, and `sounding_rpm`/`sounding_load` read those smoothed values - but its
## output is thrown away, so there is exactly one engine sounding. With the loops
## absent the players are never built, `sample_mode()` is false and this class is
## exactly the voice it was before any of the samples existed.

const MIX_RATE := 44100.0
## Frames handed to the audio thread in one go. Bigger is not better: a block
## that arrives late is a block of the wrong pitch.
const MAX_BLOCK := 1024
## How many blocks the fade-out gets before the player is put down regardless.
## `EngineSynth.FADE_TAU` is 0.06 s, which is two and a half of these at 44.1
## kHz; the rest is headroom for a ring that had no room on the first attempt.
## The budget exists because the alternative - waiting for a fade that a stalled
## mixer will never let finish - is the failure above. A tail that is
## occasionally cut is a compromise; a tail with no end is the bug.
const TAIL_BLOCKS := 6

## Below this throttle the car is off the gas. It is not this class's number:
## Systems/vehicle/car_body.gd stops spooling at `throttle > 0.05` and bleeds
## boost off at anything below it, so a lift - the thing a wastegate is for - is
## exactly this edge.
const FLUTTER_LOAD := 0.05

## Boost that has not finished bleeding off. Systems/vehicle/car_body.gd bleeds
## boost at `move_toward(boost, 0.0, delta * 6.0)`, so 0.10 takes 17 ms to reach
## zero and a full 1.0 takes 167 ms - which is the `turbo_blowoff_time` band of
## 0.14..0.20 s in Vehicles/car_db.gd. Anything still above this when the pedal
## comes up is a turbo that had something to give.
const FLUTTER_BOOST := 0.10

## Slack on the end of the timed release, so the sample is not cut a frame early.
const BLOWOFF_TAIL_S := 0.06

## Used only when the stream will not report a length: 0.285 s, measured off
## assets/audio/turbo/blowoff.ogg.
const FALLBACK_BLOWOFF_S := 0.345

var synth := EngineSynth.new()

var _playback: AudioStreamGeneratorPlayback = null
var _sounding: bool = false
var _tail: int = 0
## One player per recorded layer, or empty when there are no samples.
var _layers: Array[AudioStreamPlayer] = []
var _flutter: AudioStreamPlayer = null
## Seconds of release left to play. See `_blowoff_secs`.
var _flutter_left: float = 0.0
## Where the shadow render goes. Never listened to.
var _scratch := PackedFloat32Array()
var _redline: float = EngineSamples.DEFAULT_REDLINE
var _boost_seen: float = 0.0


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.25
	stream = gen
	bus = AudioBuses.ENGINE
	synth.mix_rate = MIX_RATE
	# Deliberately not `play()`. A voice is not a sound until the game has given
	# it an engine to be, and `synth.running` opening at false is only half of
	# that: a player the audio server is mixing is a voice it has been asked to
	# mix, whatever the samples in it turn out to be.
	set_process(false)
	_scratch.resize(MAX_BLOCK)
	_build_layers()


func _exit_tree() -> void:
	# `AudioService._exit_tree` stops this node and drops its generator stream on
	# its way out. These players are children and nothing else touches them, and
	# a player the audio server still holds a playback for outlives its node.
	for p in _layers:
		p.stop()
		p.stream = null
	if _flutter != null:
		_flutter.stop()
		_flutter.stream = null
	_playback = null


## One player per layer, all on the Engine bus, all silent until told to sound.
## Absent samples are not an error and not a warning: the synthesiser is what
## this class was for six tasks before this one, and a build with no loops in it
## has to sound like the game it always did.
func _build_layers() -> void:
	var streams := EngineSamples.streams()
	if streams.size() != EngineSamples.LAYERS.size():
		return
	for i in streams.size():
		_loop_forever(streams[i])
		var p := AudioStreamPlayer.new()
		p.name = "Layer%d" % i
		p.stream = streams[i]
		p.bus = AudioBuses.ENGINE
		p.volume_db = AudioBuses.SILENCE_DB
		add_child(p)
		_layers.append(p)
	var blow := EngineSamples.blowoff_stream()
	if blow != null:
		_flutter = AudioStreamPlayer.new()
		_flutter.name = "Wastegate"
		_flutter.stream = blow
		_flutter.bus = AudioBuses.ENGINE
		_flutter.volume_db = AudioBuses.SILENCE_DB
		add_child(_flutter)


## A recorded engine that stops at the end of its file is a hiccup once a
## second. The wav importer does not loop by default and the `.import` sidecars
## are deliberately not committed (`.gitignore`), so the loop has to be set on
## the stream here or it is set nowhere.
static func _loop_forever(s: AudioStream) -> void:
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		var frames := int(round(w.get_length() * float(w.mix_rate)))
		w.loop_end = frames if frames > 0 else 0


## True when the recorded engine is the one sounding, false when this class is
## the synthesiser it started as.
func sample_mode() -> bool:
	return _layers.size() == EngineSamples.LAYERS.size()


## True while the engine is sounding. Both edges are idempotent, because the
## bridge asks for an engine on every physics frame and a voice that restarted
## itself sixty times a second would re-render its opening ramp sixty times a
## second and never get past it.
func set_sounding(on: bool) -> void:
	if on == _sounding:
		return
	_sounding = on
	if on:
		_tail = 0
		# Before `play`, and while `running` is still false, so the ramp opens
		# from zero instead of from wherever the last fade-out was left.
		synth.reset()
		if sample_mode():
			for p in _layers:
				p.volume_db = AudioBuses.SILENCE_DB
				p.play()
			# The synth's own `running` flag is the fade on this path too. It is
			# set here rather than in `else` below because the samples are what is
			# audible and the synth is only the shadow - but `synth.fade()` is the
			# ramp the layers ride, so it has to be opening.
			synth.set_running(true)
			set_process(true)
		else:
			play()
			# Only valid once playing, and only for a generator stream; asking
			# before either is an error the engine logs, not one it returns.
			_playback = get_stream_playback()
			synth.set_running(true)
			set_process(_playback != null)
	else:
		_stop_layers()
		synth.set_running(false)
		_tail = TAIL_BLOCKS


## True between `set_sounding(true)` and the end of the fade-out. For a check
## that has to tell a voice which has been told to stop from one that has
## finished stopping.
func sounding() -> bool:
	return _sounding


## The revs the voice is sounding, after the synth's own smoothing. Read-only
## and additive: the fade, the tail budget and `_sounding` above are t37's and
## nothing here touches them.
##
## It exists because the voice is what the rest of the game holds. `AudioService`
## finds this class by name to stop it at teardown, and a bridge check asks
## whether a throttle change arrived by asking the voice - so both have to get
## the answer without reaching through to `synth` themselves. The sample path
## reads it for the same reason: rpm -> layer has to come from the smoothed
## engine, or a physics step's noise is an octave of pitch noise.
func sounding_rpm() -> float:
	return synth.rpm()


## The load the voice is sounding, 0..1, and the other half of the throttle: a
## car can be at the same revs on the throttle and off it, and those are two
## different sounds. This is what opens the recorded engine by
## `EngineSamples.LOAD_SPAN_DB` and what closes the wastegate when it is let go
## of.
func sounding_load() -> float:
	return synth.load()


## The car's own redline, which is what the layer bands are fractions of. Zero or
## something non-finite means nobody has said, and the fallback is a real car's.
func set_redline(rpm: float) -> void:
	_redline = rpm if is_finite(rpm) and rpm > 0.0 else EngineSamples.DEFAULT_REDLINE


## Boost and throttle as the car reports them, once a physics frame, and the one
## event either of them can raise: the pedal coming up while there is still boost
## in the pipe. That is the wastegate letting go, and it is the only new sound in
## this class - everything else here is an engine.
func set_boost(boost: float, load: float) -> void:
	var b := 0.0 if not is_finite(boost) else maxf(boost, 0.0)
	var l := 0.0 if not is_finite(load) else clampf(load, 0.0, 1.0)
	if l < FLUTTER_LOAD and _boost_seen >= FLUTTER_BOOST and b < _boost_seen:
		_blow_off()
	_boost_seen = b


## How loud the release was: the boost that was let go, as a fraction of full
## boost. A turbo that was barely spooled does not make a noise worth hearing, and
## `car_body.gd` already scales engine torque by `boost`, so boost is this game's
## own word for how much pressure is in the pipe.
func _blow_off() -> void:
	if _flutter == null or not _sounding:
		return
	var b := clampf(_boost_seen, FLUTTER_BOOST, 1.0)
	_flutter.volume_db = clampf(linear_to_db(b), AudioBuses.SILENCE_DB, 6.0)
	_flutter.play()
	_flutter_left = _blowoff_secs()


## How long the release runs. OggVorbis reports a length only once the whole file
## is decoded, and `AudioStreamPlayer.playing` does not clear for a one-shot that
## has no length to count to - so the end of the sample is timed here instead of
## waited on. Read off the stream when it will say, and off the measured length of
## the file when it will not.
func _blowoff_secs() -> float:
	var s := _flutter.stream if _flutter != null else null
	if s != null and s.get_length() > 0.01:
		return s.get_length() + BLOWOFF_TAIL_S
	return FALLBACK_BLOWOFF_S


func _stop_layers() -> void:
	for p in _layers:
		p.stop()
	if _flutter != null:
		_flutter.stop()
	_flutter_left = 0.0


func _process(delta: float) -> void:
	if _flutter_left > 0.0:
		_flutter_left -= delta
	if sample_mode():
		_process_samples()
		return
	if _playback == null:
		return
	# Whatever the dummy driver does with the ring buffer, only ever fill what is
	# free: pushing past the end is dropped, and dropping the middle of a sweep
	# is the same click this class exists to avoid.
	var want := mini(MAX_BLOCK, _playback.get_frames_available())
	if want > 0:
		var frames := PackedFloat32Array()
		frames.resize(want)
		synth.render(frames)
		var out := PackedVector2Array()
		out.resize(want)
		for i in want:
			out[i] = Vector2(frames[i], frames[i])
		_playback.push_buffer(out)
	# The fade has landed and been committed, or the ring would not take it and
	# the budget is spent. Either way the player goes down now, which is the
	# half of this class that makes the Engine bus empty rather than quiet.
	if not _sounding:
		_tail -= 1
		if _tail <= 0:
			_playback = null
			set_process(false)
			stop()


## The recorded path. The generator is still rendered - into `_scratch`, where it
## is thrown away - because that is where the smoothing lives, and the two
## getters above are how the sample path asks where the engine is.
##
## The fade is the synth's, not a second one. `render` closes `_fade` per *sample*
## on a 0.06 s time constant, so the ramp the samples ride is the same curve the
## fallback closes on and it closes at the same rate. A copy of the constant
## applied once per frame instead closes roughly sixteen times too slowly - 0.06 s
## of smoothing sixty times a second - which is a fade you cannot hear at all.
func _process_samples() -> void:
	synth.render(_scratch)
	_track_layers()
	if not _sounding:
		_tail -= 1
		if _tail <= 0:
			for p in _layers:
				p.stop()
				p.volume_db = AudioBuses.SILENCE_DB
			set_process(false)


## rpm -> which layers, how far between them, and how fast each one has to play.
## Read every frame, so it is the frame rate and not the physics rate that
## decides how smooth a hand-over is.
func _track_layers() -> void:
	var fade := synth.fade()
	if fade <= 0.001:
		for p in _layers:
			p.volume_db = AudioBuses.SILENCE_DB
		return
	var rpm := sounding_rpm()
	var m := EngineSamples.layers_for(rpm / maxf(_redline, 1.0))
	var a := int(m["a"])
	var b := int(m["b"])
	var mix := clampf(float(m["mix"]), 0.0, 1.0)
	var hz := EngineSamples.target_hz(rpm, synth.cylinders)
	var db := EngineSamples.level_db(sounding_load()) + linear_to_db(fade)
	for i in _layers.size():
		var w := 0.0
		if b != a and i == b:
			w = mix
		elif i == a:
			w = 1.0 - mix
		if w <= 0.001:
			_layers[i].volume_db = AudioBuses.SILENCE_DB
			continue
		_layers[i].volume_db = clampf(db + linear_to_db(w), AudioBuses.SILENCE_DB, 6.0)
		_layers[i].pitch_scale = EngineSamples.pitch_scale(i, hz)


## Frames the engine is waiting to have played, for a debug HUD or a check that
## the generator is actually being fed. Zero unless the voice is sounding: a
## voice that is down is not holding a ring for anything.
##
## On the sample path the rings are the loops, so it is what is left of them -
## which is still "how much engine has not been heard yet", and is what
## `Audio/audio_check.gd` reads to know the voice is feeding something.
func queued_frames() -> int:
	if sample_mode():
		return _sample_queued()
	# `_playback` is nulled when the player is put down, so this is zero from the
	# moment the voice stops holding a ring - no separate `_sounding` test needed.
	return 0 if _playback == null else _playback.get_frames_available()


func _sample_queued() -> int:
	var total := 0
	for p in _layers:
		if not p.playing or p.stream == null:
			continue
		var left := p.stream.get_length() - p.get_playback_position()
		total += int(maxf(left, 0.0) * float(p.stream.get_mix_rate()))
	return total


## What the layers are doing right now, as the players actually have it, for a
## check that wants the mapping without re-deriving it from rpm itself:
## `{sounding_hz, volumes, scales, mode}` - the frequency each playing layer is
## sounding at (`pitch_scale` times the fundamental measured off its own file),
## its volume in dB, its pitch scale, and whether this is the sample path at all.
func layer_state() -> Dictionary:
	var hz: Array[float] = []
	var vol: Array[float] = []
	var scl: Array[float] = []
	for i in _layers.size():
		var p := _layers[i]
		scl.append(p.pitch_scale)
		var base := EngineSamples.LAYER_HZ[i] if i < EngineSamples.LAYER_HZ.size() else 0.0
		# A layer with its volume on the floor is not sounding, whatever
		# `playing` says: all four players run from the same `set_sounding(true)`
		# and only the ones the rpm band picked are above the floor.
		var audible := p.playing and p.volume_db > AudioBuses.SILENCE_DB + 0.5
		vol.append(p.volume_db)
		hz.append(base * p.pitch_scale if audible else 0.0)
	return {"sounding_hz": hz, "volumes": vol, "scales": scl, "mode": sample_mode()}


## Whether the wastegate is sounding right now.
func flutter_playing() -> bool:
	return _flutter != null and _flutter.playing and _flutter_left > 0.0
