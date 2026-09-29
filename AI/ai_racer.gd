class_name AIRacer
extends Node
## Placeholder driver so the first playable slice has an opponent. The real
## racing-line AI lands in Phase 5; this deliberately drives through the same
## throttle/brake/steer surface the player does, so it cannot cheat.

var car: CarBody
var graph: RoadGraph
## 0 = novice, 1 = flawless. Drives how close to the limit it dares.
@export var skill := 0.7

var _target: Vector3 = Vector3.ZERO
var _retarget_in := 0.0


func _physics_process(delta: float) -> void:
	if car == null or not is_instance_valid(car) or graph == null:
		return
	_retarget_in -= delta
	if _retarget_in <= 0.0:
		_retarget_in = 0.35
		var near: Dictionary = graph.nearest_road(car.global_position)
		if int(near["edge"]) >= 0:
			var e: Dictionary = graph.edges[int(near["edge"])]
			var along: float = float(near["dist_along"]) + 22.0
			_target = graph.point_on_edge(int(near["edge"]), along, true)

	var to_target: Vector3 = _target - car.global_position
	to_target.y = 0.0
	var dist := to_target.length()
	if dist < 6.0:
		car.throttle = 0.4
		car.steer = 0.0
		return

	var local: Vector3 = car.global_transform.basis.inverse() * to_target
	# Steer toward the point; invert because the car faces -Z.
	car.steer = clampf(-atan2(local.x, -local.z) * 1.6, -1.0, 1.0)

	# Slow for corners proportional to how hard we are turning.
	var turn: float = absf(car.steer)
	var target_kph: float = lerpf(150.0, 55.0, turn) * lerpf(0.65, 1.0, skill)
	if car.speed_kph > target_kph:
		car.throttle = 0.0
		car.brake = clampf((car.speed_kph - target_kph) / 40.0, 0.0, 1.0)
	else:
		car.throttle = 1.0
		car.brake = 0.0
	car.auto_shift()
