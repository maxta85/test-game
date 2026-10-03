class_name AudioBridge
extends Node
## The link between a race and the audio system: polls the race director's
## lights and the car's drivetrain every physics frame and pushes both into an
## `AudioDirector`.
##
## Deliberately the thin part. `RaceDirector.lights` already documents itself as
## driving the revving audio, and `AudioDirector.set_lights` already fires once
## per change, so a second copy of the countdown in here would only be another
## thing to drift out of step with the lights it is supposed to follow.
##
## It makes the `AudioDirector` if there is not one already, so wiring audio into
## a scene is adding this node and naming the two things it drives. Asking
## `main.gd` to construct an `AudioDirector` as well would make the wiring two
## steps, and the step nobody remembers is how a working audio system ends up
## with nothing calling it.
##
## ORIGINAL GAME CONTENT.

## True while something the bridge was driving has gone and nothing has taken
## its place. Validity of the references alone cannot answer that - see
## `_physics_process`.
var lost: bool = false

## Set when another bridge got here first and this one stopped polling. Not the
## same thing as `lost`: nothing it was driving has gone away, this one simply
## has nothing to say.
var standing_down: bool = false

## The race being scored. Null is the ordinary state before a race is entered.
var race: RaceDirector = null
## The player's car. Its `engine_rpm` and `throttle` are the whole of what the
## engine voice is fed.
var car: CarBody = null

## Resolved in `_ready`: whichever director was already in the tree, or the one
## this node made. Public so a debug HUD can reach the same one the bridge does.
var director: AudioDirector = null

## Master volume, 0..1 - the knob a settings menu turns. Applying it here rather
## than in the menu is what makes wiring that menu a one-liner.
@export_range(0.0, 1.0, 0.01) var master_volume: float = 1.0:
	set(value):
		master_volume = value
		if director != null:
			director.set_master_volume(value)

var _warned: bool = false
## Whether each slot was ever filled.
var _had_race: bool = false
var _had_car: bool = false


func _ready() -> void:
	director = AudioDirector.instance
	if director == null:
		director = AudioDirector.new()
		director.name = "AudioDirector"
		add_child(director)
	director.set_master_volume(master_volume)
	_stand_down_duplicate()


## A second bridge in the same tree would be a second engine voice and a second
## poll of the same car, so whoever is second stops. This is not defensive
## coding: the game wires audio from an autoload, and a host that also builds a
## bridge in its own `_ready` is making a reasonable choice that must not
## double the engine.
func _stand_down_duplicate() -> void:
	var other := get_tree().root.find_children("*", "AudioBridge", true, false)
	for n in other:
		if n != self and n is AudioBridge and not (n as AudioBridge).lost and is_instance_valid((n as AudioBridge).director):
			push_warning("AudioBridge: a second bridge is already in the tree - this one is standing down.")
			set_physics_process(false)
			standing_down = true
			return


## Physics rate, not the render rate: rpm is drivetrain state and the lights are
## race state, and both of those advance with the simulation.
func _physics_process(_delta: float) -> void:
	# A freed node is a dangling reference rather than a null, so `is_instance_valid`
	# is the test - but validity alone cannot tell a car that has never arrived
	# from one that has gone, and only the second is a fault. The two `_had` flags
	# are what tell them apart.
	_had_race = _had_race or race != null
	_had_car = _had_car or car != null
	lost = _gone(race, _had_race, "race director") or _gone(car, _had_car, "car")
	# Null is not a fault. The bridge is in the tree for the whole session and
	# there is no race on screen until one is entered and no car until one is
	# spawned, so a frame with nothing to read is most frames of a normal game.
	# A `lost` slot is the other thing: something that was here is gone, and that
	# is a fault, and everything downstream stays quiet until it is handed a
	# replacement.
	if lost:
		return
	# Each half needs only its own half of the world. The lights are race state
	# and the engine is car state, and gating them on each other mutes an engine
	# that is running: a car on the grid before a race director exists idles,
	# and a countdown with a car and no director still counts down.
	if race != null:
		director.set_lights(race.lights)
	if car != null:
		# `throttle` is the engine's load: the demand the driver is putting through
		# the drivetrain, already a 0..1 fraction, and the number the tyre model
		# turns into torque. Nothing is smoothed on the way in - the synth puts
		# every parameter it is handed through a one-pole, which is what the noise
		# on rpm arriving at 60 Hz needs, and a second filter in here would only
		# delay the pitch by the same amount it was meant to remove the noise from.
		#
		# `spec.redline` and `boost` are handed over rather than looked up by the
		# audio side, for the same reason: they are the car's own drivetrain
		# state, they are already public, and an engine sample's layer bands are
		# fractions of one and its wastegate is a function of the other.
		director.set_engine(car.engine_rpm, car.throttle, car.spec.redline, car.boost)


## A slot that was filled and is now invalid. A slot that was never filled is not
## a failure, and is not this function's business.
##
## The argument is a Variant rather than an Object for a reason that is not
## obvious: a freed node is not null, it is a dangling reference that fails a
## typed parameter check before the function is ever entered, so a `node: Object`
## signature turns this whole branch into a thrown error on the first frame
## after a car is freed - which is the one frame it exists to survive.
##
## Warned once per bridge: cars are rebuilt between races and a director is
## replaced on every restart, so this is ordinary, and a warning on all sixty
## frames of every race afterwards is how a real warning stops being read.
func _gone(node: Variant, was_set: bool, label: String) -> bool:
	if not was_set or (node != null and is_instance_valid(node)):
		return false
	if not _warned:
		_warned = true
		push_warning("AudioBridge: the %s is gone - the audio stays silent until another is set." % label)
	return true
