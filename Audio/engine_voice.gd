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

const MIX_RATE := 44100.0
## Frames handed to the audio thread in one go. Bigger is not better: a block
## that arrives late is a block of the wrong pitch.
const MAX_BLOCK := 1024

var synth := EngineSynth.new()

var _playback: AudioStreamGeneratorPlayback = null


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.25
	stream = gen
	bus = AudioBuses.ENGINE
	synth.mix_rate = MIX_RATE
	play()
	# Only valid once playing, and only for a generator stream; asking before
	# either is an error the engine logs, not one it returns.
	_playback = get_stream_playback()
	set_process(_playback != null)


func _process(_delta: float) -> void:
	if _playback == null:
		return
	# Whatever the dummy driver does with the ring buffer, only ever fill what is
	# free: pushing past the end is dropped, and dropping the middle of a sweep
	# is the same click this class exists to avoid.
	var want := mini(MAX_BLOCK, _playback.get_frames_available())
	if want <= 0:
		return
	var frames := PackedFloat32Array()
	frames.resize(want)
	synth.render(frames)
	var out := PackedVector2Array()
	out.resize(want)
	for i in want:
		out[i] = Vector2(frames[i], frames[i])
	_playback.push_buffer(out)


## Frames the engine is waiting to have played, for a debug HUD or a check that
## the generator is actually being fed.
func queued_frames() -> int:
	return 0 if _playback == null else _playback.get_frames_available()
