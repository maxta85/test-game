extends RefCounted
## Referenced as `const DriftDriver := preload("res://Tests/drift_driver.gd")`.
## Deliberately NOT `class_name`: global class names live in
## `.godot/global_script_class_cache.cfg`, which only an editor import refreshes,
## so a new `class_name` file fails to parse under `test.sh` with
## "Identifier not declared in the current scope". preload has no such cache.
## The autopilot both drift harnesses drive with, and the only one.
##
## It exists because the number suite and the frame harness disagreed by 5x on the
## same car - 9.0 deg of body slip in `Tests/test_drift.gd` against 50.3 deg in
## `Tests/drift_flight.gd` - and the cause was the DRIVERS, not the physics. Each
## had grown its own. The suite drove a bare countersteer term on a straight line;
## the flight harness added pure-pursuit steering on top, and pure pursuit is what
## puts the car MID-CORNER when it flicks, which is where a handbrake flick
## actually works. Straight-line flick, straight-line result.
##
## One driver, shared, means any remaining disagreement between a headless number
## and a rendered frame is a physics finding. Two drivers means it is always
## ambiguous which one is lying.
##
## Sign conventions (car_body.gd:9, :43): +X right, -Z forward, steer -1 is full
## right, so countersteering a slide of `+beta` is negative steer.

## The course. Both harnesses use this exact geometry so the manoeuvre the suite
## measures headlessly is the manoeuvre the harness shoots.
const ROUTE := [
	Vector3(0, 0, 0), Vector3(0, 0, -160), Vector3(-95, 0, -235),
	Vector3(-95, 0, -395), Vector3(75, 0, -430), Vector3(150, 0, -300),
	Vector3(60, 0, -215), Vector3(60, 0, -60), Vector3(0, 0, 0),
]
## Radius at which a waypoint counts as reached and the autopilot advances.
const LEG_REACHED := 26.0
## A handbrake flick, on a fixed schedule so a slide is always inside the
## captured window even on a short run. This is a real input on the real car, not
## a scripted pose: the frames show what the tyre model did with it.
const FLICK_FROM := 170
const FLICK_TO := 194


## One frame of driving.
static func drive(car: CarBody, i: int, route: Array = ROUTE) -> void:
	var leg: int = int(car.get_meta("leg", 0))
	var target: Vector3 = route[leg]
	var to_target: Vector3 = target - car.global_position
	to_target.y = 0.0
	var fwd: Vector3 = car.forward()
	var right: Vector3 = car.right()
	var ahead: float = fwd.dot(to_target)
	var side: float = right.dot(to_target)
	# Pure pursuit: the further off-heading we are, the harder we ask.
	var pursuit := clampf(side / maxf(to_target.length(), 1.0) * 2.2, -1.0, 1.0)
	# Countersteer, scaled by how sideways we already are.
	var counter := clampf(-rad_to_deg(car.slip_angle_body) / 25.0, -1.0, 1.0)
	var beta := rad_to_deg(car.slip_angle_body)
	var damp := clampf(car.angular_velocity.y / 1.2, -0.5, 0.5)
	car.steer = clampf(pursuit + counter - damp, -1.0, 1.0)
	# Throttle: lift mid-hairpin, back on out of it.
	var tight := to_target.length() < 70.0
	car.throttle = 0.35 if absf(beta) > 22.0 else (0.95 if not tight else 0.45)
	car.brake = 0.0
	var scheduled: bool = (i % 240 >= FLICK_FROM and i % 240 < FLICK_TO) and car.speed_kph > 40.0
	car.handbrake = 1.0 if ((scheduled or tight) and absf(beta) < 8.0) else 0.0
	if car.handbrake > 0.0:
		# Steer INTO the entry, which is what breaks the rear away.
		car.steer = clampf(0.6 * signf(side if absf(side) > 0.5 else 1.0), -1.0, 1.0)


## Advance to the next waypoint if the current one has been reached.
static func advance(car: CarBody, route: Array = ROUTE) -> void:
	var leg: int = int(car.get_meta("leg", 0))
	var nxt: Vector3 = route[(leg + 1) % route.size()]
	var d := Vector2(nxt.x - car.global_position.x, nxt.z - car.global_position.z).length()
	if d < LEG_REACHED:
		car.set_meta("leg", (leg + 1) % route.size())


## Ready-to-use driver for the number suite: the autopilot on the shared course.
static func make() -> Callable:
	return func(c: CarBody, i: int) -> void:
		c.auto_shift()
		drive(c, i)
		advance(c)
