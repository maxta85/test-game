extends SceneTree
##
## A car that is being driven must not fall asleep.
##
##   /home/coder/tools/godot --headless --fixed-fps 60 --path . \
##       --script res://Systems/vehicle/sleep_check.gd
##
## WHY THIS EXISTS
##
## t125 measured an AI car with `is_sleeping() == true`, four wheels down and 3409 N
## on the rear tyres, while its rear wheels were turning at 61 rad/s with a slip
## ratio of 15.37 and 2.9-3.3 kN of longitudinal force. A sleeping `RigidBody3D`
## ignores applied force entirely, so the drive stopped for no visible reason. The
## cause is Godot's default: `can_sleep` is true and a body that stops moving is put
## to sleep, and a driver holding throttle against a stationary car never sees it
## happen.
##
## WHY IT IS BUILT THIS WAY
##
## No world, no OSM, no `WorldBuilder`. A `StaticBody3D` box the size of a car park
## is the ground, and the whole check runs in about a second. That is deliberate: the
## real world build costs 100 s of CPU, and a check that takes 100 s does not get run
## before a change, which is the only time it is worth anything. The claim being
## tested - "a commanded car does not sleep" - does not need a city.
##
## THE SCENARIO IS THE REAL ONE. Throttle and brake together: a car stopped at a light
## with the driver's foot down and a hand on the wheel. It is being driven, in every
## sense that matters to the player, and it is not moving. That is the state a sleep
## bug hides in, because a car under power accelerates and never sleeps - so a test
## that only drives forward passes against code with this defect in it.
##
## Also measured here, because a fix for "does not sleep" that quietly changes how a
## car settles would be a bad trade: the spawn settle (load, contact, height) with no
## input at all, which the street probe depends on.

const FRAMES := 120
const GROUND_SIZE := 400.0
## Deliberately generous so nothing here is a tuning threshold.
const MOVED_M := 0.5


func _initialize() -> void:
	var fails := 0
	print("[sleep] a commanded car must not sleep")
	print("[sleep] no world build: a StaticBody3D box is the ground")
	print("")

	# --- 1. Settle with NO input, and record what the car does.
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_SIZE, 1.0, GROUND_SIZE)
	shape.shape = box
	ground.add_child(shape)
	get_root().add_child(ground)
	ground.global_position = Vector3(0.0, -0.5, 0.0)

	var car := _car()
	get_root().add_child(car)
	car.reset_to(Vector3(0.0, 0.60, 0.0), Vector3.ZERO)
	for _i in 40:
		await process_frame
	var rl: Dictionary = car.get_wheel("RL")
	var settle_load := float(rl.get("load", -1.0))
	var settle_contact := bool(rl.get("contact", false))
	var settle_y := car.global_position.y
	print("[sleep] settle with no input:")
	print("[sleep]   rear load %.0f N, contact %s, y=%.3f, can_sleep %s, is_sleeping %s" % [
		settle_load, str(settle_contact), settle_y, str(car.can_sleep), str(car.is_sleeping())])

	# --- 2. Command it: throttle AND brake. Driven, and not moving.
	car.throttle = 1.0
	car.brake = 1.0
	car.steer = 0.5
	var pos0 := car.global_position
	var slept_frame := -1
	for i in FRAMES:
		await process_frame
		if car.is_sleeping() and slept_frame < 0:
			slept_frame = i
	print("")
	print("[sleep] commanded (throttle 1.0, brake 1.0, steer 0.5) for %d frames:" % FRAMES)
	print("[sleep]   is_sleeping()      : %s" % str(car.is_sleeping()))
	print("[sleep]   first sleeping frame: %s" % ["never" if slept_frame < 0 else str(slept_frame)])
	print("[sleep]   moved              : %.3f m" % car.global_position.distance_to(pos0))
	print("[sleep]   speed              : %.3f m/s" % float(car.speed_mps))

	if car.is_sleeping():
		print("")
		print("FAIL: a car being driven went to sleep on frame %d." % slept_frame)
		print("      A sleeping RigidBody3D ignores applied force, so throttle, brake and")
		print("      steer all become no-ops with nothing on screen to say so.")
		fails += 1
	else:
		print("")
		print("PASS: a car being driven stayed awake for %d frames." % FRAMES)

	# --- 3. Release everything and confirm it CAN sleep again, so the fix is scoped
	#        to a driven car and is not "never sleep".
	car.throttle = 0.0
	car.brake = 0.0
	car.steer = 0.0
	for _i in 10:
		await process_frame
	var slept_after := -1
	for i in 240:
		await process_frame
		if car.is_sleeping():
			slept_after = i
			break
	print("")
	print("[sleep] released and left alone: first sleeping frame %s" % [
		"never (within 240 frames)" if slept_after < 0 else str(slept_after)])
	if slept_after < 0:
		print("NOTE: the idle car did not sleep inside 240 frames. Godot's sleep timer is")
		print("      longer than that, so this is not evidence the fix disabled sleep - it")
		print("      is evidence the check cannot observe it either way here.")

	# --- 4. The settle behaviour must be untouched by any of the above.
	var rl2: Dictionary = car.get_wheel("RL")
	print("")
	print("[sleep] settle before any input : rear load %.0f N, contact %s, y=%.3f" % [
		settle_load, str(settle_contact), settle_y])
	print("[sleep] settle after the run    : rear load %.0f N, contact %s, y=%.3f" % [
		float(rl2.get("load", -1.0)), str(bool(rl2.get("contact", false))), car.global_position.y])

	print("")
	print("SLEEP_FAILS=%d" % fails)
	quit(fails)


func _car() -> CarBody:
	var car := CarBody.new()
	car.name = "SleepProbeCar"
	car.spec = CarDB.get_spec("kairo_s13")
	return car
