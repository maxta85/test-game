class_name AudioBuses
extends RefCounted
## The audio bus layout, built in code because a saved bus resource is an asset
## and this project has no assets.
##
## Everything reaches a bus by name through this class, so no caller hardcodes
## "Master/SFX" or an index that stops being right when a bus is inserted.
##
## ORIGINAL GAME CONTENT. There is no sample data anywhere in this file or any
## other under Audio/ - every sound in this game is arithmetic.

const MASTER := "Master"
const MUSIC := "Music"
const SFX := "SFX"
const ENGINE := "Engine"

## Bus name -> the bus it sends into, in creation order.
const LAYOUT := {
	MUSIC: MASTER,
	SFX: MASTER,
	ENGINE: MASTER,
}

## linear_to_db(0.0) is -inf, which a couple of drivers log as a warning.
const SILENCE_DB := -80.0


## Creates any bus in the layout that is missing and re-asserts the routing.
## Idempotent, so the director, a test, or both can call it and a bus that
## something else re-pointed gets put back - a mis-routed Engine bus is silent
## in a way nothing else in the game would ever report.
static func ensure() -> void:
	if AudioServer.get_bus_index(MASTER) < 0:
		# No Master means no audio server worth routing into. Returning quietly
		# is what keeps the dummy driver, and a machine with no sound card, from
		# turning every volume call into a crash.
		return
	for bus in LAYOUT:
		var idx := AudioServer.get_bus_index(String(bus))
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.get_bus_count() - 1
			AudioServer.set_bus_name(idx, String(bus))
		AudioServer.set_bus_send(idx, String(LAYOUT[bus]))


static func has_bus(bus: String) -> bool:
	return AudioServer.get_bus_index(bus) >= 0


## -1 for a bus that is not in the layout, so a typo fails loudly in a check
## instead of quietly sending everything to Master.
static func index_of(bus: String) -> int:
	return AudioServer.get_bus_index(bus)


## Linear 0..1, the form the rest of the game thinks in. Godot's bus volume is
## only in dB, so the conversion is done here once instead of at every call site
## that would otherwise get it slightly wrong.
static func volume(bus: String) -> float:
	var idx := index_of(bus)
	return 0.0 if idx < 0 else _to_linear(AudioServer.get_bus_volume_db(idx))


static func set_volume(bus: String, linear: float) -> void:
	var idx := index_of(bus)
	if idx < 0 or not is_finite(linear):
		return
	AudioServer.set_bus_volume_db(idx, _to_db(linear))


static func volume_db(bus: String) -> float:
	var idx := index_of(bus)
	return SILENCE_DB if idx < 0 else AudioServer.get_bus_volume_db(idx)


static func set_volume_db(bus: String, db: float) -> void:
	var idx := index_of(bus)
	if idx < 0 or not is_finite(db):
		return
	AudioServer.set_bus_volume_db(idx, maxf(db, SILENCE_DB))


static func is_muted(bus: String) -> bool:
	var idx := index_of(bus)
	return idx >= 0 and AudioServer.is_bus_mute(idx)


static func set_muted(bus: String, muted: bool) -> void:
	var idx := index_of(bus)
	if idx >= 0:
		AudioServer.set_bus_mute(idx, muted)


## Master, in linear 0..1, which is what a settings slider wants.
static func master_volume() -> float:
	return volume(MASTER)


# dB is the only scale the bus has, and it cannot represent silence: -inf is
# not a number a mixer can do arithmetic on, so the bottom of the fader is a
# floor instead.
static func _to_db(linear: float) -> float:
	var v := clampf(linear, 0.0, 1.0)
	return SILENCE_DB if v <= 0.0 else linear_to_db(v)


static func _to_linear(db: float) -> float:
	return 0.0 if db <= SILENCE_DB else clampf(db_to_linear(db), 0.0, 1.0)
