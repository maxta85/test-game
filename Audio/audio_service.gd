class_name AudioService
extends Node
## Everything the game hears, wired to the car and the menus. One autoload.
##
## `AudioDirector` is the surface other systems talk to and `AudioBridge` is the
## thin link from a race to it, and between them they covered the engine and the
## countdown. What they do not have is a way to exist: nothing constructed
## either of them, so 1047 lines of working synthesis sat in the tree with no
## consumer. This is that consumer - it makes the bridge, starts the beds, and
## feeds the car into both.
##
## An autoload rather than a line in `Game/main.gd`, because the beds want to be
## running from the first frame - the main menu is a night street too - and
## because the car and the menus do not exist yet when an autoload is ready, so
## the wiring here is discovery: ask again until there is something to drive.
##
## The car and the director are found rather than handed in, which is why this
## does not need a single edit in the host. The host is also free to hand them
## in instead: `service.set_car(car)` overrides the search, and a second
## `AudioBridge` standing itself down is one line away if the host would rather
## own the node outright.
##
## ORIGINAL GAME CONTENT.

## The mix, in the order a night drive is heard: the car is the foreground and
## everything else is a bed under it. Without these the beds sit where the
## synthesis put them, and the ambience is louder than the music.
const MIX := {
	AudioBuses.ENGINE: 0.9,
	AudioBuses.SFX: 1.0,
	AudioBuses.MUSIC: 0.55,
	AudioBuses.AMBIENCE: 0.45,
}

## Trim on each bed, in dB, after the bus. The tyre loop is synthesised loud
## because it is the one sound here that has to cut through an engine at full
## load, and it is quiet in the mix until the tyres are actually sliding.
const MUSIC_DB := -3.0
const NIGHT_DB := -4.0
const TYRE_DB := -6.0

## Cylinders per car, which is what sets an engine's pitch: a four-stroke fires
## cylinders/2 times a revolution, so a four idles near 27 Hz and a six near
## 40 Hz, and that is the difference between the two sounds you can hear without
## knowing what an engine is. Authored here rather than in `CarSpec` because the
## spec has no cylinder field and adding one would put an audio decision into a
## physics resource - but the gate asserts this table covers every car, so a new
## one cannot fall through to the default silently.
const CYLINDERS := {
	"kairo_mx90": 4,    ## econobox four, and it never leaves idle
	"kaze_type_r": 4,   ## high-revving VTEC four: the same idle, a different top
	"kairo_s13": 4,     ## the turbo four this whole game is named after
	"shinobi_rs": 6,    ## all-pounds AWD six
	"akuma_gt": 6,      ## mid-engined six
	"tatsuya_gt": 6,    ## straight six, and the fastest thing in the garage
	"hayate_turbo": 4,  ## old big-torque turbo four
}
## For a car this table has never heard of. Four is the default because that is
## what the cars in it mostly are, not because it is right.
const DEFAULT_CYLINDERS := 4

## A wheel carrying less than this is in the air, and a wheel in the air does
## not squeal. The same 100 N `car_body.gd` uses to decide a wheel is spinning
## at all, so a squeal and a wheelspin are talking about the same tyre.
const LOADED_N := 100.0
## How far into a slide before there is a squeal, and how loud a full one is.
const SLIP_FLOOR := 0.12
## A locked-up skid is a different noise from a squeal, and this much of it is
## the difference.
const SLIP_FULL := 0.85
## Impact cooldown. A kerb is a stream of contacts and a stream of thumps is a
## machine gun, so a scrape is one hit.
const IMPACT_COOLDOWN := 0.18
## Below this closing speed a contact is a bump, not a crash.
const IMPACT_KPH := 12.0
## How far the tyre voice is allowed to move in one physics frame, in dB. A full
## slide is 74 dB above silence, so this is a tenth of the travel per frame: a
## fade, not a cut.
const TYRE_SLEW_DB := 6.0

## Host-level menu signals. The screens' own signals are consumed inside
## `MenuFlow`, so these three plus the screen changing is every press that does
## anything.
const HOST_CLICKS := ["race_start_requested", "garage_requested", "quit_requested"]

static var instance: AudioService = null

var bridge: AudioBridge = null
## The music bus's player and its play/duck/fade, in one place. Public because
## this is the game's audio surface: a menu that wants the music quieter says so
## here rather than reaching for the bed player, and a check reads `state()`.
var music: MusicChannel = null

var _owned: AudioDirector = null
var _music: AudioStreamPlayer = null
var _night: AudioStreamPlayer = null
var _tyre: AudioStreamPlayer = null
var _car: CarBody = null
var _car_id: String = ""
var _gear: int = -99
var _tyre_target := AudioBuses.SILENCE_DB
var _impact_lock := 0.0
var _menus: MenuFlow = null
var _screen: String = ""


func _ready() -> void:
	instance = self
	AudioBuses.ensure()
	for bus in MIX:
		AudioBuses.set_volume(String(bus), float(MIX[bus]))

	_music = _start_bed("music", AudioBuses.MUSIC, MUSIC_DB)
	# The channel wraps the player made above rather than making its own, so the
	# bed's name, bus, trim and level at boot are exactly what they were: the
	# music is playing before anything asks it to be louder or quieter.
	music = MusicChannel.new(_music, MUSIC_DB)
	_night = _start_bed("night", AudioBuses.AMBIENCE, NIGHT_DB)
	# The tyre voice is made playing, and silent: a loop that starts when the
	# player wants to hear it is a loop that clicks on the way in.
	_tyre = _start_bed("tyre", AudioBuses.SFX, AudioBuses.SILENCE_DB)

	_owned = AudioDirector.new()
	_owned.name = "AudioServiceDirector"
	add_child(_owned)

	bridge = AudioBridge.new()
	bridge.name = "AudioBridge"
	add_child(bridge)
	# It resolves to the static on its own, which is this director, but handing it
	# over keeps the engine on one node even if something else registers a
	# director later.
	bridge.director = _owned


func _exit_tree() -> void:
	if instance == self:
		instance = null
	# Two halves of the same leak, and both are about still holding a playback at
	# teardown: the players have to be stopped and unstreamed for the audio
	# server to let go of them, and the synthesised beds are held by a static
	# cache that survives this node by design.
	if _owned != null:
		_owned.stop_engine()
		var voice := _owned.find_child("EngineVoice", true, false) as EngineVoice
		if voice != null:
			# A hard stop, not the voice's own: at teardown there is no next
			# frame for a fade-out to finish in, and a ring that outlives the
			# process is a warning rather than a sound.
			voice.stop()
			voice.stream = null
	for bed in [_music, _night, _tyre]:
		if bed != null:
			bed.stop()
			bed.stream = null
	AudioBeds._cache.clear()
	# ...and the server releases a playback on its own mix step, which a process
	# on the way out does not get another of: the players are correctly stopped
	# by the line above and the hold is still there at ObjectDB teardown, which
	# is a leak warning over three loops that were never wrong. Waiting is the
	# only thing that makes the release happen, and this runs once.
	OS.delay_msec(300)


# ------------------------------------------------------------------- per frame

## The menus are built by the host's `_ready`, which is after every autoload, so
## the click wiring is retried until there is something to wire.
func _process(delta: float) -> void:
	# Before anything that can return early: a fade closes on its own frames, not
	# on the frames the menus happen to exist for.
	if music != null:
		music.tick(delta)
	if _menus == null or not is_instance_valid(_menus):
		_menus = _find_menus()
		if _menus == null:
			return
		for s in HOST_CLICKS:
			if _menus.has_signal(s):
				_menus.connect(s, _on_ui)
	# Every navigation between screens is a screen change, not a signal the host
	# sees, and that is the click.
	var now: String = _menus.screen_name()
	if now != _screen:
		_screen = now
		_on_ui()


## Physics rate, like the bridge: rpm, gear and slip are drivetrain state and
## advance with the simulation, not with the renderer.
func _physics_process(delta: float) -> void:
	_impact_lock = maxf(0.0, _impact_lock - delta)
	var car := _player_car()
	if car == null:
		# Nothing to drive means nothing to hear. A voice left on is an engine
		# holding the revs the car had when it was freed and a tyre squealing at
		# full level forever, which is the same dead sound as one that never
		# starts. Both of those are `EngineVoice.set_sounding` and `_slip_to`'s
		# problem rather than this branch's: the engine's fade used to be asked
		# for here and then left to a generator ring nobody was emptying, so the
		# Engine bus measured -20 dB with no car in the world and was still
		# there 4000 frames after one was freed.
		_director().stop_engine()
		_slip_to(0.0)
		return
	bridge.car = car
	# Only when there is one: a host that handed its director in through
	# `set_race` must not have it overwritten by a discovery that found none.
	var race := _race()
	if race != null:
		bridge.race = race

	if car.current_gear != _gear:
		_gear = car.current_gear
		var d := _director()
		if d != null and car.engine_rpm > 0.0:
			d.play_cue("shift")

	_slip_to(_slip(car))


# --------------------------------------------------------------------- sources

## A looping bed on its own bus, playing from the first frame.
func _start_bed(name: String, bus: String, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = "Bed_" + name.capitalize()
	p.stream = AudioBeds.stream(name)
	p.bus = bus
	p.volume_db = volume_db
	add_child(p)
	p.play()
	return p


func _on_ui() -> void:
	var d := _director()
	if d != null:
		d.play_cue("ui_ok")


## A contact on the car. Severity is read off the car's own speed: a RigidBody3D
## does not report impulse without a contact monitor, which is turned on when
## the car is picked up, and the speed at the moment of contact is the honest
## proxy for how hard it was anyway.
func _on_impact(_body: Node) -> void:
	if _impact_lock > 0.0 or _car == null or not is_instance_valid(_car):
		return
	if _car.speed_kph < IMPACT_KPH:
		return
	_impact_lock = IMPACT_COOLDOWN
	var d := _director()
	if d != null:
		d.play_cue("hit", _impact_db())


func _impact_db() -> float:
	# Loudness off the closing speed, so a wall at 90 kph is not the same thump
	# as a post at 20. Capped, because the difference between 30 and 120 kph is
	# not the difference a mixer can carry.
	var v := clampf(_car.speed_kph / 90.0, 0.0, 1.0)
	return -18.0 * (1.0 - v)


# ------------------------------------------------------------------ discovery

## The player's car. Mid-race that is entrant 0, which is the one the director
## documents as the player. Before a race there is no entrant list, so it is the
## first CarBody in the tree - the host adds the player's body before the
## rival's - and the engine idles at the grid waiting for a start.
func _player_car() -> CarBody:
	if _car != null and is_instance_valid(_car):
		return _car
	var race := _race()
	if race != null:
		for e in race.entrants:
			if e is RaceEntrant and (e as RaceEntrant).car != null:
				return _attach((e as RaceEntrant).car)
	for n in get_tree().root.find_children("*", "CarBody", true, false):
		return _attach(n as CarBody)
	return null


## The director is a RefCounted owned by the host and not a node anywhere in the
## tree, so the one thing that can be read is the host's own reference to it.
## A host that would rather hand it over calls `set_race`.
func _race() -> RaceDirector:
	var scene := get_tree().current_scene
	var r: Object = scene.get("race") if scene != null else null
	return r as RaceDirector


## Found by type rather than by reading the host's fields: the menus are nodes,
## so there is a node search for them.
func _find_menus() -> MenuFlow:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	for n in scene.find_children("*", "MenuFlow", true, false):
		return n as MenuFlow
	return null


## Everything that has to happen once per car rather than once per frame: the
## voice, the gear the shift cue counts from, and the contact monitor.
func _attach(car: CarBody) -> CarBody:
	_car = car
	_gear = car.current_gear
	# The garage swaps the car mid-session, and a contact monitor is a property
	# of the body rather than of the game, so it belongs on each new one.
	_car.contact_monitor = true
	_car.max_contacts_reported = 8
	if not _car.body_entered.is_connected(_on_impact):
		_car.body_entered.connect(_on_impact)
	_set_voice(_car)
	return _car


## Engine pitch for this car, and a line saying which car is making it, because
## the whole point of the table is that swapping cars changes the sound and
## nothing else in the game shows you that it did.
func _set_voice(car: CarBody) -> void:
	var id: String = car.spec.id if car.spec != null else ""
	if id == _car_id:
		return
	_car_id = id
	var d := _director()
	if d == null:
		return
	var synth := d.engine_synth()
	if synth != null:
		synth.cylinders = int(CYLINDERS.get(id, DEFAULT_CYLINDERS))


## How hard the tyres are being abused, 0..1. Read from the wheels rather than
## from the body's slip angle because the body angle is what the car is doing
## and this is what the contact patches are doing, and the two come apart
## exactly when a handbrake slide is on: a big body angle with the rears barely
## moving, which is a drift and not a squeal.
func _slip(car: CarBody) -> float:
	var worst := 0.0
	for w in car.wheels():
		if float(w["load"]) < LOADED_N:
			continue
		worst = maxf(worst,
			absf(float(w["slip_angle"])) * 0.55 + absf(float(w["sr_smooth"])) * 0.9)
	return clampf((worst - SLIP_FLOOR) / maxf(SLIP_FULL - SLIP_FLOOR, 0.001), 0.0, 1.0)


## The tyre voice, walked toward its target rather than set to it. The tyres go
## from straight to a full slide inside one physics frame, and a bed that changes
## level by 40 dB in a frame is a click, which is the one thing a tyre loop must
## not be.
func _slip_to(slip: float) -> void:
	_tyre_target = _tyre_db(slip)
	_tyre.volume_db = move_toward(_tyre.volume_db, _tyre_target, TYRE_SLEW_DB)
	_tyre.pitch_scale = 0.9 + 0.5 * slip


## Slip as a level: silence with the tyres straight, and -6 dB at a full slide.
## Not a floor just above zero, because a floor is still audible - at -40 dB the
## SFX bus measured -46 dB with a car parked on the grid doing nothing, which is
## a squeal from a car that is not sliding. The slew above is what stops the gap
## at the other end from being a step.
func _tyre_db(slip: float) -> float:
	return AudioBuses.SILENCE_DB if slip <= 0.0 else linear_to_db(clampf(slip, 0.0, 1.0)) + TYRE_DB


## Its own director, held by reference and never `AudioDirector.instance`: every
## car builds a director for its own engine voice, so the static is whoever
## registered last, and setting cylinders through it would retune whichever car
## happened to be built last.
func _director() -> AudioDirector:
	return _owned


# ------------------------------------------------------- the host's way in

## For a host that would rather hand the car and the director over than be
## searched for. Both are optional: whatever is set here wins, and the rest is
## still discovered.
func set_car(car: CarBody) -> void:
	_car = null
	_attach(car)


func set_race(race: RaceDirector) -> void:
	if bridge != null:
		bridge.race = race


## Whether the bridge is there at all. Not something a caller needs in order to
## work - everything below tolerates a null bridge - and it is here so a host can
## say out loud that the game is silent instead of discovering it in play. The
## bridge is built in this autoload's `_ready`, so this is false only if the
## autoload did not run or was replaced, and both are worth a warning.
func has_bridge() -> bool:
	return bridge != null and is_instance_valid(bridge) and bridge.director != null
