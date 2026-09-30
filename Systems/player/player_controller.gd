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
	car.steer = Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	car.handbrake = Input.get_action_strength("handbrake")

	if auto_gearbox:
		car.auto_shift()
	else:
		if Input.is_action_just_pressed("shift_up"):
			car.shift_up()
		if Input.is_action_just_pressed("shift_down"):
			car.shift_down()


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
