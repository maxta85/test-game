class_name EngineVoice
extends AudioStreamPlayer
## An EngineSynth wired to a generator on the Engine bus, and nothing else.
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

var synth := EngineSynth.new()

var _playback: AudioStreamGeneratorPlayback = null
var _sounding: bool = false
var _tail: int = 0


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
		play()
		# Only valid once playing, and only for a generator stream; asking before
		# either is an error the engine logs, not one it returns.
		_playback = get_stream_playback()
		synth.set_running(true)
		set_process(_playback != null)
	else:
		synth.set_running(false)
		_tail = TAIL_BLOCKS


## True between `set_sounding(true)` and the end of the fade-out. For a check
## that has to tell a voice which has been told to stop from one that has
## finished stopping.
func sounding() -> bool:
	return _sounding


func _process(_delta: float) -> void:
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


## Frames the engine is waiting to have played, for a debug HUD or a check that
## the generator is actually being fed. Zero unless the voice is sounding: a
## voice that is down is not holding a ring for anything.
func queued_frames() -> int:
	# `_playback` is nulled when the player is put down, so this is zero from the
	# moment the voice stops holding a ring - no separate `_sounding` test needed.
	return 0 if _playback == null else _playback.get_frames_available()
