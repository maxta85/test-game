class_name ShotPoser
extends Node3D
## Moves the camera to fixed vantage points so renders can be compared like for
## like between passes. Without this, "it looks better" is unmeasurable because
## every screenshot frames something different.
##
## ./run.sh --shot NAME [PRESET]

const PRESETS := {
	# name: [cam_pos, cam_look_at, fov]
	"start":      [Vector3(-30, 6, 58), Vector3(10, 1.2, 40), 55.0],
	"street":     [Vector3(0, 3.2, -60), Vector3(0, 1.0, 30), 50.0],
	"downtown":   [Vector3(-70, 14, -40), Vector3(10, 2, 60), 60.0],
	"kerb":       [Vector3(14, 1.1, 62), Vector3(-6, 0.6, 20), 45.0],
	"carmeet":    [Vector3(-60, 8, 100), Vector3(-84, 1.5, 118), 55.0],
	"aerial":     [Vector3(0, 420, 340), Vector3(0, 0, 0), 60.0],
	"motorway":   [Vector3(0, 12, -420), Vector3(30, 2, -300), 55.0],
}

## Shots framed on the player's car rather than on a fixed point in the world,
## so they still work after the start grid moves. `[offset_from_car, look_at, fov]`
const CAR_SHOTS := {
	# Straight behind and a little up: the shot the player actually sees, so any
	# change to the chase camera shows up here. A coupe is 4.7 m long, so 5.2 m
	# of standoff put the tail deck across the whole frame; 7.6 m frames the car
	# with road either side of it.
	"carhero":    [Vector3(0.0, 2.1, -7.6), Vector3(0, 0.70, 0.0), 46.0],
	# Low three-quarter front: headlights, paint and stance in one frame.
	"carfront":   [Vector3(4.6, 1.2, -6.4), Vector3(0, 0.6, 0.0), 42.0],
	# High three-quarter rear: roofline, wheels, and how much the car is lit.
	"carhigh":    [Vector3(-5.0, 3.4, 7.2), Vector3(0, 0.7, 0.0), 44.0],
}


static func apply(node: Node, preset_name: String) -> bool:
	if CAR_SHOTS.has(preset_name):
		return _apply_to_car(node, CAR_SHOTS[preset_name])
	if not PRESETS.has(preset_name):
		return false
	var p: Array = PRESETS[preset_name]
	var cam := _camera_of(node)
	if cam == null:
		return false
	cam.global_position = p[0]
	cam.look_at(Vector3(p[1]), Vector3.UP)
	cam.fov = float(p[2])
	return true


## Car-relative shot. The camera is put where the car is *now*, so a preset does
## not go stale when the start grid or the route changes.
static func _apply_to_car(node: Node, p: Array) -> bool:
	var cam := _camera_of(node)
	if cam == null:
		return false
	var car: CarBody = null
	if node is ChaseCamera:
		car = (node as ChaseCamera).car()
	if car == null:
		return false
	# In the car's own frame: +Z is backwards, so -Z is behind its nose.
	var back: Vector3 = car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	var up: Vector3 = car.car_up()
	var anchor: Vector3 = car.global_position + back * p[0].z + up * p[0].y + right * p[0].x
	cam.global_position = anchor
	cam.look_at(car.global_position + up * float(p[1].y) - back * float(p[1].z), up)
	cam.fov = float(p[2])
	return true


static func _camera_of(node: Node) -> Camera3D:
	for c in node.get_children():
		if c is Camera3D:
			return c
	return null
