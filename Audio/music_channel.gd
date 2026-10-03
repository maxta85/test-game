class_name MusicChannel
extends RefCounted
## The music bus's player, and the only place play, duck and fade happen.
##
## It owns no node. It wraps the bed player `AudioService` already makes, rather
## than making one of its own, because that player's name, bus, trim and
## boot-time level are not incidental: `Audio/audio_check.gd:241` asserts
## `Bed_Music` exists, is playing, sits on the Music bus and loops, and
## `Tests/test_sound.gd:128` reads the Music bus meter and wants it above the
## bed floor. A second player would have been a second music bus path - the
## exact thing this class exists to be the single answer to - and would have
## broken both.
##
## Why a `RefCounted` rather than a node: it needs to be stepped once per frame
## to close a fade, and `AudioService._process` already does that. A node would
## be a second thing in the service's tree that nothing asked for.
##
## The music itself is not this class's business and deliberately not its
## decision. `AudioBeds` synthesises a bed; whether it is the owner's soundtrack
## is the owner's. What lives here is the three things every soundtrack needs
## whoever wrote it: a way to start it, a way to get it out of the way under
## something else, and a way to move its level without a click.
##
## ORIGINAL GAME CONTENT.

## The bed this channel drives. One name, because one bed is the music.
const BED := "music"

## How far down the music goes when something else wants the room, in dB. Nine
## is about a third of the way down: audible underneath, not gone. A duck that
## silences the bed is a fade, and `fade_to` is already there.
const DUCK_DB := -9.0
## What a fade moves at when nobody asked for a length, in dB per second. Fast
## enough to be out of the way, slow enough that the bed is not a step.
const FADE_DB_PER_SEC := 12.0
## Below this a fade is finished. A tenth of a decibel is four hundredths of a
## percent of full scale; nothing audible is left above it.
const DONE_DB := 0.01

## The bed player. Public so a check can read the real player, and so
## `AudioService` can keep its own teardown pointing at the same node.
var bed: AudioStreamPlayer = null
## The bed's resting trim, in dB - the level it plays at when nothing is asking
## for it to be somewhere else.
var trim_db: float = 0.0

## True while a check has asked for the placeholder instead of the bed.
var placeholder_mode: bool = false

var _target_db: float = 0.0
var _rate_db_per_sec: float = 0.0
var _ducked: bool = false
var _real_stream: AudioStream = null


func _init(player: AudioStreamPlayer, bed_trim_db: float) -> void:
	bed = player
	trim_db = bed_trim_db
	_target_db = bed_trim_db
	if bed != null and is_instance_valid(bed):
		_target_db = bed.volume_db


## Starts the bed if it is not already running, and fades it back to its resting
## level. Fades rather than sets, so `play()` after a `fade_out()` is a fade in
## and not a jump: the bed is a loop, and a loop that starts at full level is a
## step in the middle of a bar.
func play() -> void:
	if bed == null or not is_instance_valid(bed):
		return
	if not bed.playing:
		bed.play()
	fade_to(trim_db)


## Stops the bed and puts its level back, so a `play()` after this is not a fade
## in from wherever a duck left it.
func stop() -> void:
	if bed == null or not is_instance_valid(bed):
		return
	bed.stop()
	bed.volume_db = trim_db
	_target_db = trim_db
	_rate_db_per_sec = 0.0
	_ducked = false


## Walks the bed to `db` over `seconds`, or at the default rate with `seconds` at
## zero. A negative or non-finite request is refused and leaves the bed where it
## is: a fade aimed at a NaN never arrives, and a fade that never arrives is a
## silent soundtrack with no explanation.
func fade_to(db: float, seconds: float = 0.0) -> void:
	if not is_finite(db):
		return
	db = maxf(db, AudioBuses.SILENCE_DB)
	var here := bed.volume_db if (bed != null and is_instance_valid(bed)) else _target_db
	_target_db = db
	if seconds > 0.0 and is_finite(seconds):
		_rate_db_per_sec = maxf(absf(db - here) / seconds, 0.0)
	else:
		_rate_db_per_sec = 0.0


## Ducks under something else, or undoes it. Idempotent both ways, because a
## caller asking every frame is the normal way to use this.
func duck(on: bool) -> void:
	if on == _ducked:
		return
	_ducked = on
	fade_to(trim_db + (DUCK_DB if on else 0.0))


## One frame of the walk. Called by `AudioService._process` at the top, before
## anything that can return early, so a fade closes whether or not the menus
## have turned up yet.
func tick(delta: float) -> void:
	if bed == null or not is_instance_valid(bed):
		return
	# At the target with no fade in flight is the state this is in almost every
	# frame of a session where nothing has asked for a duck - and writing the
	# property anyway would be a write per frame to a node the audio server is
	# mixing, changing nothing. Returning is the whole of the common case.
	if _rate_db_per_sec <= 0.0:
		if absf(bed.volume_db - _target_db) > DONE_DB:
			bed.volume_db = _target_db
		return
	bed.volume_db = move_toward(bed.volume_db, _target_db,
			_rate_db_per_sec * maxf(delta, 0.0))


## Swaps the real bed for a silent loop of the same shape, and back. For a check
## that wants to measure this channel - the duck depth, the fade rate, the
## routing - without also asserting something about what the music sounds like,
## which is the owner's call and would make the check fail the day they change
## it. The real stream is held, not regenerated, so switching back is exact.
func use_placeholder(on: bool) -> void:
	if bed == null or not is_instance_valid(bed) or on == placeholder_mode:
		return
	if on:
		_real_stream = bed.stream
		bed.stream = AudioBeds.placeholder(BED)
	else:
		bed.stream = _real_stream
		_real_stream = null
	placeholder_mode = on


## Everything a check needs about this channel, and nothing that depends on the
## music: the bed's identity, where it is routed, its shape, and where its level
## is and is going. `meta` is copied out of `AudioBeds.RECIPES` rather than
## repeated here, so the two cannot disagree about how long the bed is.
func state() -> Dictionary:
	var recipe: Dictionary = AudioBeds.RECIPES.get(BED, {})
	var wav := bed.stream as AudioStreamWAV if (bed != null and is_instance_valid(bed)) else null
	var here := bed.volume_db if (bed != null and is_instance_valid(bed)) else 0.0
	return {
		"bed": BED,
		"bus": AudioBuses.MUSIC,
		"playing": bed.playing if (bed != null and is_instance_valid(bed)) else false,
		"placeholder": placeholder_mode,
		"trim_db": trim_db,
		"level_db": here,
		"target_db": _target_db,
		"ducked": _ducked,
		"duck_db": DUCK_DB,
		"fading": _rate_db_per_sec > 0.0 and absf(here - _target_db) > DONE_DB,
		"fade_db_per_sec": _rate_db_per_sec,
		"loop_seconds": float(recipe.get("dur", 0.0)),
		"gain": float(recipe.get("gain", 0.0)),
		"mix_hz": AudioBeds.MIX_HZ,
		"samples": (wav.data.size() / 2) if wav != null else 0,
	}