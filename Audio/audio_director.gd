class_name AudioDirector
extends Node
## The one thing other systems talk to.
##
## A game system that can make a noise should not have to know the noise is
## three oscillators and a filter, so the whole surface is: play a cue, feed
## the engine, set a volume, tell me what the countdown is doing. Every call is
## safe at any time, including before this node is in the tree and including
## with no audio device at all - the race director polls `lights` and the car
## pushes rpm at 60 Hz from the first frame, before the audio exists.
##
## Add it to the tree from `Game/main.gd`; other systems reach it through
## `AudioDirector.instance` rather than a hardcoded node path. It is not an
## autoload because the bus layout is built in code (see AudioBuses) and an
## autoload would be one more thing to fail before a sound is possible.

## Enough players that cues overlap: a three-car pile-up wants three hits at
## once, not one hit and two dropped sounds.
const VOICE_POOL := 6

## The most recently dispatched cue, "" if none has been. Cheap enough to show
## in a debug HUD, and it is how the check sees that a countdown fired without
## having to trust what a driver does with a stream.
var last_cue: String = ""
var cues_played: int = 0

static var instance: AudioDirector = null

var _voice: EngineVoice = null
var _pool: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _lights: int = 0
var _lights_seen: bool = false


func _ready() -> void:
	AudioBuses.ensure()
	instance = self
	_voice = EngineVoice.new()
	_voice.name = "EngineVoice"
	add_child(_voice)
	for i in VOICE_POOL:
		var p := AudioStreamPlayer.new()
		p.name = "Cue%d" % i
		# On the SFX bus, which is the only reason the bus exists: a mixer that
		# can duck the effects cannot duck cues that went to Master.
		p.bus = AudioBuses.SFX
		add_child(p)
		_pool.append(p)


func _exit_tree() -> void:
	if instance == self:
		instance = null


## Plays a synthesised cue by name. False for a name that is not in the bank,
## so a typo is visible to the caller instead of being silently nothing.
##
## `gain_db` is for the cues that are not the same size as each other - an
## impact's loudness is the speed the car arrived at, and a thud at 20 kph heard
## at the same level as one at 90 is a lie about the crash. It is written on
## every play because the pool is reused: a level left on a recycled player
## would come back with the next cue.
func play_cue(name: String, gain_db: float = 0.0) -> bool:
	var s := AudioCues.stream(name)
	if s == null:
		return false
	var p := _free_player()
	if p == null:
		return false
	p.stream = s
	if is_finite(gain_db):
		p.volume_db = clampf(gain_db, AudioBuses.SILENCE_DB, 6.0)
	p.play()
	last_cue = name
	cues_played += 1
	return true


## rpm in revolutions per minute, load as 0..1. Called every frame with
## whatever the car happens to have, so it never throws on the first frame's
## zeroed rpm and never has to be guarded by the caller.
func set_engine(rpm: float, load: float) -> void:
	if _voice != null:
		_voice.synth.running = true
		_voice.synth.set_engine(rpm, load)


## Fades the engine out rather than cutting it, and leaves the voice running
## silent so the fade can finish on its own.
func stop_engine() -> void:
	if _voice != null:
		_voice.synth.set_running(false)


## The countdown hook. `RaceDirector.lights` is 3, 2, 1 through the countdown
## and 0 from GO, and its own comment says it drives the revving audio, so
## handing that integer straight over is what keeps the lights and the beeps
## from drifting apart.
##
## Fires on a change only, and GO only after a light has actually been seen: a
## director sitting at 0 on the grid must not fire a GO at race load, and one
## polled at 60 Hz must not fire sixty beeps.
##
## A value that is not a light is dropped without moving `_lights`, so a
## director that reports garbage once does not get a second GO when it comes
## back to 0.
func set_lights(n: int) -> void:
	if n < 0 or n > 3 or n == _lights:
		return
	_lights = n
	if n > 0:
		_lights_seen = true
	match n:
		3:
			play_cue("count_3")
		2:
			play_cue("count_2")
		1:
			play_cue("count_1")
		0:
			if _lights_seen:
				play_cue("go")


## Linear 0..1. A non-finite value leaves the mix alone: a NaN reaching the
## server would be a warning per bus, and muting a player's audio because one
## frame computed a division by zero is worse than ignoring the frame.
func set_master_volume(linear: float) -> void:
	if is_finite(linear):
		AudioBuses.set_volume(AudioBuses.MASTER, linear)


func set_bus_volume(bus: String, linear: float) -> void:
	if is_finite(linear):
		AudioBuses.set_volume(bus, linear)


func set_bus_muted(bus: String, muted: bool) -> void:
	AudioBuses.set_muted(bus, muted)


## The engine synth, for a caller that wants to read it. Null before _ready.
func engine_synth() -> EngineSynth:
	return _voice.synth if _voice != null else null


## A player that is not busy, or the oldest one if they all are. Stealing by age
## rather than dropping the cue matters most under the dummy driver, where
## nothing is ever drained and the pool would otherwise be full after six
## sounds for the whole test run.
##
## Null before _ready, which is a cue asked for too early rather than a crash:
## the car pushes rpm on the first frame, and callers do not wait for us.
func _free_player() -> AudioStreamPlayer:
	if _pool.is_empty():
		return null
	for p in _pool:
		if not p.playing:
			return p
	var oldest := _pool[_next_voice]
	_next_voice = (_next_voice + 1) % _pool.size()
	return oldest
