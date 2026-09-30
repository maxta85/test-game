class_name ChaseCamera
extends Node3D
## Third-person chase camera.
##
## Reacts to acceleration, braking, drift, speed and impacts, because a camera
## that is nailed to the car's tail is the fastest way to make a good car feel
## bad. The lag is deliberate: it is what lets you read the car's rotation.

enum Mode { CHASE, CLOSE, FAR, HOOD, COCKPIT }

@export var mode: Mode = Mode.CHASE
@export var target_path: NodePath

const OFFSETS := {
	Mode.CHASE: Vector3(0.0, 2.35, 6.4),
	Mode.CLOSE: Vector3(0.0, 1.75, 4.1),
	Mode.FAR: Vector3(0.0, 3.4, 9.2),
	Mode.HOOD: Vector3(0.0, 1.28, 0.35),
	Mode.COCKPIT: Vector3(-0.32, 1.14, -0.15),
}

## When true this node stops driving the camera entirely, so a fixed viewpoint
## (a screenshot, a photo mode) can take the wheel without being fought.
var tracking := true

var _camera: Camera3D
var _car: CarBody
var _look_ahead := Vector3.ZERO
var _shake := 0.0
var _fov := 66.0
## How far back the camera currently sits along its ray, after occlusion. Kept
## between frames so it can snap in and ease out.
var _clear_dist := 0.0
## Smoothed, speed-gated drift lean, -1 (sliding one way) .. +1 (the other).
var _lean := 0.0
## Phase of the shake oscillator, in cycles.
var _shake_phase := 0.0

## Knock envelope: per second, and per second of the oscillator.
const SHAKE_DECAY := 3.2
const SHAKE_HZ := 11.0
const SHAKE_POS := 0.045    ## metres of camera offset per unit of shake
const SHAKE_ROLL := 0.10    ## radians of roll per unit of shake
## Full lean happens at this much body slip angle, in radians (~6 degrees).
const DRIFT_LEAN := 0.11
## Radians of roll at full lean. Small on purpose: the car's own body roll
## already arrives through `up`, and a chase camera is a rigid mount, not a
## person leaning out of the window.
const DRIFT_ROLL := 0.012


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.fov = _fov
	_camera.near = 0.12
	_camera.far = 900.0
	add_child(_camera)
	if target_path:
		_car = get_node_or_null(target_path) as CarBody


func set_car(car: CarBody) -> void:
	_car = car


## The car being followed, or null. Screenshot tooling needs it to frame a shot
## relative to the car rather than to an absolute point in the world.
func car() -> CarBody:
	return _car


func cycle_mode() -> void:
	mode = (int(mode) + 1) % Mode.size()
	if _car:
		_snap()


## Pulls the camera in when something is between it and the car.
##
## A chase camera at a fixed offset spends most of its life in a palm trunk, a
## power pole or the side of a house, and the player loses the entire frame. The
## fix is a ray from just above the car to the wanted position: on a hit, sit in
## front of whatever it found. In is instant (a wall between you and the camera
## has to be gone *now*), out is slow (easing back out reads as the camera
## finding its footing rather than as a jump cut).
func _clear_of_obstacles(want: Vector3, up: Vector3, delta: float, snap: bool) -> Vector3:
	if not is_inside_tree() or get_world_3d() == null:
		return want
	var pivot: Vector3 = _car.global_position + up * 1.05
	var to_cam: Vector3 = want - pivot
	var dist: float = to_cam.length()
	if dist < 0.01:
		return want
	var dir: Vector3 = to_cam / dist

	var q := PhysicsRayQueryParameters3D.create(pivot, want)
	q.collision_mask = OCCLUDER_MASK
	q.exclude = [_car.get_rid()]
	var clear: float = dist
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		clear = maxf((hit["position"] as Vector3).distance_to(pivot) - 0.30, 0.9)

	# Snap in, ease out.
	if clear < _clear_dist or snap:
		_clear_dist = clear
	else:
		_clear_dist = minf(clear, _clear_dist + maxf(dist - _clear_dist, 0.0) * clampf(delta * 2.2, 0.0, 1.0) + delta * 0.8)
	return pivot + dir * _clear_dist


## World geometry, cars and traffic. Anything that can be between the camera and
## the car counts, because a pole and a parked car are equally ruinous on screen.
const OCCLUDER_MASK := 1 | 2 | 4


## Called by the car on impact so the camera can be knocked about.
func impulse(strength: float) -> void:
	_shake = minf(_shake + strength, 2.5)


func _snap() -> void:
	if not tracking:
		return
	_update(0.0, true)


func _process(delta: float) -> void:
	if not tracking:
		return
	_update(delta, false)


func _update(delta: float, snap: bool) -> void:
	if _car == null or not is_instance_valid(_car):
		return

	var offset: Vector3 = OFFSETS.get(mode, OFFSETS[Mode.CHASE])
	var up: Vector3 = _car.car_up()
	var back: Vector3 = _car.global_transform.basis.z
	var basis := Basis.looking_at(-back, up).scaled(Vector3.ONE)
	var want: Vector3 = _car.global_position + (basis * offset)

	# Never let the camera go through the road.
	want.y = maxf(want.y, 0.75)
	want = _clear_of_obstacles(want, up, delta, snap)

	if snap or delta <= 0.0:
		global_position = want
	else:
		# Position lags, rotation is instant. Lagged position plus a rigid look-at
		# is what gives a chase camera its sense of weight.
		var t: float = 1.0 - exp(-11.0 * delta)
		global_position = global_position.lerp(want, t)

	# Look slightly ahead of the car, and further ahead the faster you go, so
	# fast corners open up before you reach them.
	var vel: Vector3 = _car.linear_velocity
	var lead: Vector3 = vel * clampf(0.34 - _car.speed_mps * 0.0016, 0.06, 0.34)
	_look_ahead = _look_ahead.lerp(lead, clampf(delta * 5.0, 0.0, 1.0))
	var aim: Vector3 = _car.global_position + up * 0.85 + _look_ahead
	_camera.look_at(aim, up)

	# Field of view opens with speed: cheap, and it sells acceleration hard.
	var speed_t: float = clampf(_car.speed_kph / 240.0, 0.0, 1.0)
	var want_fov: float = 64.0 + speed_t * 16.0
	if mode == Mode.HOOD or mode == Mode.COCKPIT:
		want_fov = 72.0 + speed_t * 10.0
	_fov = lerpf(_fov, want_fov, clampf(delta * 3.0, 0.0, 1.0))
	_camera.fov = _fov

	# ---------------------------------------------------------------- shake
	# Two separate things, kept separate on purpose.
	#
	# `_shake` is an EVENT: only impulse() adds to it, and it bleeds off at
	# SHAKE_DECAY per second, so a knock is over in about a third of a second
	# and the camera is dead still the rest of the time. The old code floored it
	# at the car's slip angle, which meant the camera never stopped shaking
	# while the car was at all sideways - the shake was a state, not an event.
	#
	# `_lean` is drift: a low-passed roll into the corner. The raw slip angle at
	# 60 Hz is not a camera move; filtering it is the whole difference between
	# leaning and twitching. It is gated on speed, because a car shuffling about
	# in a car park has plenty of slip and should not set the horizon rocking.
	_shake = maxf(_shake - delta * SHAKE_DECAY, 0.0)
	# fposmod, not raw +=: a single-precision phase runs into 7 significant
	# digits after an hour of racing and the knock turns into a step function.
	_shake_phase = fposmod(_shake_phase + delta * SHAKE_HZ, 1.0)
	_lean = lerpf(_lean, clampf(_car.slip_angle_body / DRIFT_LEAN, -1.0, 1.0), 1.0 - exp(-9.0 * delta))
	var speed_gate: float = clampf(_car.speed_mps / 10.0, 0.0, 1.0)

	# Band-limited noise: three incommensurate sines. A knock has its energy at
	# a few Hz; randf_range() every frame has energy right up at the frame rate,
	# and the eye reads that as a vibration motor rather than as an impact.
	var th := _shake_phase * TAU
	var knock := Vector3(sin(th), sin(th * 1.41 + 1.1), sin(th * 0.79 + 2.3))
	_camera.position = knock * (_shake * SHAKE_POS)
	# Roll: lean into the corner, plus a little of whatever is being knocked
	# about. The car's own body roll already reaches the camera through `up`.
	_camera.rotate_object_local(Vector3.UP, _lean * speed_gate * DRIFT_ROLL + _shake * SHAKE_ROLL)
