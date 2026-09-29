class_name RaceEntrant
extends RefCounted
## Adapter between a `CarBody` and `RaceDirector`.
##
## The director is pure logic and speaks in `position: Vector3` / `facing:
## Vector3` so it can be driven by a plain test stub. A `CarBody` is a physics
## body: its `position` is local, it has no `facing`, and it must be fed inputs
## rather than teleported. This bridges the two without either side knowing about
## the other, which is why the race system's 99 tests keep passing untouched.
##
## The director writes `position` to place the car on the grid. Here that is
## routed through `CarBody.reset_to` so the car is placed legally - velocity
## zeroed, wheels settled - instead of being shoved into the world.

var car: CarBody

## Set by the director when it places the car; consumed once.
var _pending_place := false
var _pending_pos := Vector3.ZERO
var _pending_yaw := 0.0


func _init(c: CarBody) -> void:
	car = c


## World position. The director reads this to score progress.
var position: Vector3:
	get:
		return car.global_position if car != null else Vector3.ZERO
	set(v):
		if car == null:
			return
		# Godot -Z is forward, and the grid's facing is what sets the yaw.
		_pending_place = true
		_pending_pos = v


## Unit heading on the ground plane. The director reads this for wrong-way
## detection and writes it when placing the car.
var facing: Vector3:
	get:
		return car.forward() if car != null else Vector3.FORWARD
	set(v):
		if car == null:
			return
		var d := Vector3(v.x, 0.0, v.z)
		if d.length_squared() < 0.0001:
			return
		_pending_yaw = atan2(-d.x, -d.z)


## Applies any placement the director asked for. Called once per frame from the
## game loop, before the car simulates, so the placement is legal and settled.
func sync() -> void:
	if car == null or not _pending_place:
		return
	_pending_place = false
	car.reset_to(_pending_pos + Vector3(0, 0.5, 0), Vector3(0, _pending_yaw, 0))


func is_on_ground() -> bool:
	return car != null and car.wheels_on_ground >= 3
