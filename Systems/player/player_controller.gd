class_name PlayerController
extends Node
## Reads input and drives the car. Deliberately thin: the AI uses the same
## throttle/brake/steer surface, so anything the player can do an opponent can
## do, and vice versa. No cheating in either direction.

@export var car_path: NodePath
@export var camera_path: NodePath
@export var auto_gearbox := true

var car: CarBody
var camera: ChaseCamera


func _ready() -> void:
	if car_path:
		car = get_node_or_null(car_path) as CarBody
	if camera_path:
		camera = get_node_or_null(camera_path) as ChaseCamera
	if camera and car:
		camera.set_car(car)


func _unhandled_input(event: InputEvent) -> void:
	if not camera:
		return
	if event.is_action_pressed("camera_toggle"):
		camera.cycle_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("reset_car"):
		reset_to_road()
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	if car == null or not is_instance_valid(car):
		return

	car.throttle = Input.get_action_strength("throttle")
	car.brake = Input.get_action_strength("brake")
	# Positive steer turns LEFT on CarBody, not right. This was reversed, so
	# holding right sent the car left - the player could not drive. Measured,
	# not assumed: steer = +0.5 for 2 s yaws ~1.5 rad toward -X from a -Z
	# heading, and right is +X. The physics convention is kept as-is because
	# AIRacer is written against it; only this mapping was wrong.
	car.steer = _steer_value(_delta)
	car.handbrake = Input.get_action_strength("handbrake")

	if auto_gearbox:
		car.auto_shift()
	else:
		if Input.is_action_just_pressed("shift_up"):
			car.shift_up()
		if Input.is_action_just_pressed("shift_down"):
			car.shift_down()


## Steering a KEYBOARD cannot express, and a stick already can.
##
## `Game/input_map.gd` binds `steer_left`/`steer_right` to KEY_A/KEY_LEFT **and** to
## `JOY_AXIS_LEFT_X`. A key's `get_action_strength` is exactly 1.0 or 0.0, so on a
## keyboard the driver could only command FULL LOCK or centre. Measured on Hoare
## Street through the real input path: **39.5 m of 1399.5 m (3%)**, peak |steer| 1.00.
## A stick resting between the stops returns a fraction, so the gamepad path was
## already proportional and is deliberately left alone.
##
## So the value is RAMPED rather than passed through: a tap gives a small angle and a
## hold gives full lock, which is the whole difference between a keyboard and a stick.
##
## ## THE RATE IS PER SECOND, NOT PER FRAME
##
## `rate * delta`, never `rate` alone. This project has been bitten by exactly this:
## the vehicle suite's numbers are written in 60 Hz frames, and doubling
## `physics_ticks_per_second` halves every one of them, so a per-frame ramp would make
## the car twice as steer-responsive on a faster machine. Measured per second, the ramp
## takes the same wall time at any tick rate.
##
## ## CENTRING IS FASTER THAN STEERING, ON PURPOSE
##
## `STEER_CENTRE_RATE` is larger than `STEER_RATE`. A driver who has turned too much
## must be able to let go and have the car come back, and a ramp that ramps out as
## slowly as it ramps in makes every correction a two-handed commitment.
## Recoverability is worth more than a fine adjustment rate.
##
## ## BOUNDED BY CONSTRUCTION
##
## `move_toward` cannot step past `want`, and `want` is the difference of two action
## strengths, so the result is inside [-1, 1] with no separate clamp needed. An
## unclamped ramp is how a steering bug turns into a car that cannot be driven.
const STEER_RATE := 3.2
const STEER_CENTRE_RATE := 5.0
## Above this the reading is treated as analogue and passed straight through. A stick
## between the stops returns a fraction; a key never does, so anything not at the stops
## came from an axis or a trigger.
const ANALOGUE_EPS := 0.02

var _steer := 0.0


func _steer_value(delta: float) -> float:
	var want := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var digital: bool = absf(want) >= 1.0 - ANALOGUE_EPS or absf(want) <= ANALOGUE_EPS
	if not digital:
		# A stick or a trigger: already proportional, and ramping it would only add
		# lag to the one input path that works.
		_steer = want
		return want
	var rate := STEER_CENTRE_RATE if absf(want) <= ANALOGUE_EPS else STEER_RATE
	_steer = move_toward(_steer, want, rate * maxf(delta, 0.0))
	return _steer


## The steering value currently being sent to the car. Public so a test can read the
## ramp without reaching into privates.
func steer_value() -> float:
	return _steer

## Puts the car back on the nearest road, pointing the right way. Everyone needs
## this in a street-racing game about memorising a city.
func reset_to_road() -> void:
	if car == null or car.get_parent() == null:
		return
	var graph: RoadGraph = car.get_parent().get("graph")
	if graph == null:
		return
	var near: Dictionary = graph.nearest_road(car.global_position)
	if int(near["edge"]) < 0:
		return
	var e: Dictionary = graph.edges[int(near["edge"])]
	var p: Vector2 = graph.node_pos(int(e["a"]))
	var q: Vector2 = graph.node_pos(int(e["b"]))
	var dir: Vector2 = (q - p).normalized()
	if dir.dot(Vector2(car.global_position.x, car.global_position.z) - p) < 0.0:
		dir = -dir
	var pos := Vector3(near["point"].x, 0.4, near["point"].z)
	var yaw: float = atan2(-dir.x, -dir.y)
	car.reset_to(pos, Vector3(0, yaw, 0))
