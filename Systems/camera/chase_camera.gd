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


func cycle_mode() -> void:
	mode = (int(mode) + 1) % Mode.size()
	if _car:
		_snap()


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

	# Drift shake: a little roll and judder when the car is sideways.
	_shake = maxf(_shake - delta * 3.2, 0.0)
	var slip: float = clampf(absf(_car.slip_angle_body) * 0.55, 0.0, 0.06)
	_shake = maxf(_shake, slip)
	var jitter := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * _shake * 0.05
	_camera.position = Vector3(0, 0, 0) + jitter
	_camera.rotate_object_local(Vector3.UP, _shake * 0.12)
