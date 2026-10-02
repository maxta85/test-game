class_name CarSpec
extends Resource
## A single car definition. All the numbers the physics reads live here, so a car
## is data, not code - swapping the roster is editing a dictionary.
##
## Masses in kg, distances in metres, torques in Nm, angles in radians.

const AIR_DENSITY := 1.2041

@export var id := "unnamed"
@export var display_name := "UNNAMED"
@export var chassis_class := "hatch"     ## hatch / coupe / sedan / wagon / awd
@export var drive := "rwd"              ## fwd / rwd / awd
@export var year := 1994
@export var blurb := ""

# --- mass & geometry ---
@export var mass := 1200.0
@export var wheelbase := 2.47
@export var track_width := 1.48
@export var cg_height := 0.48           ## CoG height above the contact patch
@export var mass_bias_z := 0.06         ## + moves CoG rearward
@export var body_length := 4.2
@export var body_width := 1.7
@export var body_height := 1.3

# --- suspension ---
@export var spring_rate := 34000.0      ## N/m at the strut
@export var damper := 3600.0            ## N/(m/s)
@export var suspension_rest := 0.28
@export var suspension_travel := 0.16
@export var anti_roll := 9000.0

# --- tyres ---
@export var tyre_radius := 0.31
@export var tyre_peak_mu := 1.05        ## dry-ish; rain scales this down
@export var wheel_inertia := 1.05

# --- drift character ---
## A drift car is not a grippy car that spins. It is a car whose REAR tyre gives
## up more grip once it is alight, so the front axle at opposite lock has
## something to balance and the car settles at a steady angle instead of
## snapping straight.
##
## Left at its default it reduces exactly to the previous single-tyre behaviour.
@export var front_slide_tail := 0.72    ## front grip kept when sliding
@export var front_grip_scale := 1.0       ## front axle peak-grip multiplier
@export var rear_grip_scale := 1.0        ## rear axle peak-grip multiplier
@export var rear_slide_tail := 0.72     ## rear grip kept when sliding
@export var diff_lock := 0.0             ## 0 open, 1 spool. See CarBody.

# --- engine ---
@export var idle_rpm := 850.0
@export var redline := 7500.0
@export var engine_inertia := 0.20
@export var engine_brake_torque := 26.0
## Piecewise-linear [[rpm, Nm], ...] naturally-aspirated crank torque.
@export var torque_curve: Array = [
	[800, 150.0], [2000, 210.0], [3500, 262.0], [4800, 268.0],
	[6200, 248.0], [7200, 210.0], [7800, 120.0],
]

# --- turbo ---
@export var has_turbo := false
@export var turbo_threshold_rpm := 3200.0
@export var turbo_spool_time := 0.55     ## seconds to full spool from cold
@export var turbo_blowoff_time := 0.22   ## seconds to dump boost off throttle
@export var turbo_boost_multiplier := 0.75  ## extra torque fraction at full boost

# --- transmission ---
@export var gears: Array = [0.0, 3.32, 1.90, 1.31, 1.00, 0.79]  ## index 0 = neutral
@export var final_drive := 3.9
@export var shift_time := 0.18
@export var shift_up_rpm := 6600.0
@export var shift_down_rpm := 2400.0
@export var torque_split := 0.5         ## fraction of drive torque to the REAR axle (AWD only)

# --- brakes ---
@export var brake_torque := 2600.0       ## Nm at the wheel, total demand
@export var brake_bias := 0.62           ## fraction to the front
@export var handbrake_torque := 4200.0

# --- steering ---
@export var max_steer := 0.62            ## radians at full lock
@export var ackermann := 0.35

# --- aero ---
@export var drag_area := 0.70
@export var drag_coefficient := 0.34
@export var lift_area := 0.90
@export var downforce_coefficient := 0.12

# --- cosmetic / gameplay ---
@export var bearing_drag := 0.012
@export var price := 0
@export var start_position := Vector3(0, 0.4, 0)
@export var start_rotation := Vector3.ZERO
@export var default_paint := "primer_grey"
@export var default_wheel := "steel_14"
@export var body_style := "coupe"        ## which exterior kit to build


## Peak naturally-aspirated power, in kW, for the garage stat readout.
func peak_power_kw() -> float:
	var best := 0.0
	for p in torque_curve:
		best = maxf(best, float(p[1]))
	return best * redline / 1000.0 * 0.9


## Peak crank torque including full boost, in Nm.
func peak_torque_nm() -> float:
	var best := 0.0
	for p in torque_curve:
		best = maxf(best, float(p[1]))
	return best * (1.0 + turbo_boost_multiplier)


## Theoretical top speed (m/s) from power vs drag, ignoring gearing limits.
func top_speed_mps() -> float:
	var peak_w := peak_power_kw() * 1000.0
	var cda := 0.5 * AIR_DENSITY * drag_area * drag_coefficient
	if cda <= 0.0:
		return 0.0
	return pow(peak_w / cda, 1.0 / 3.0)


## 0-100 km/h in seconds, traction limited.
##
## The naive version - peak torque through the gearing, minus drag - is a lie for
## anything that is not a traction monster: it reported 2.5 s for a deliberately
## awful econobox because the number never asked whether the driven tyres could
## actually take that torque. Without a grip limit the whole roster saturates at
## the same "acceleration" and the garage bars are decoration.
##
## Integrated gear by gear from a standstill, the way the car actually does it,
## with the driven axle on a friction circle: whatever the engine asks for, the
## tyres can only deliver `mu * driven weight` of it.
func zero_to_hundred() -> float:
	var weight: float = mass * 9.8
	var axle_share: float = 0.45 if drive == "rwd" else (0.60 if drive == "fwd" else 0.5)
	# The most torque the driven tyres can put down, in Nm at the wheel.
	var traction: float = tyre_peak_mu * weight * axle_share * tyre_radius
	var target: float = 100.0 / 3.6
	var v: float = 0.5
	var t: float = 0.0
	var gear: int = 1
	while v < target and t < 30.0:
		var ratio: float = float(gears[gear]) * final_drive
		# Below idle the engine is still turning over, not making less torque.
		var rpm: float = maxf(v / maxf(tyre_radius, 0.05) * ratio * 60.0 / TAU, idle_rpm)
		if gear < gears.size() - 1 and rpm > shift_up_rpm:
			gear += 1
			continue
		var demand: float = TyreModel.torque_from_curve(torque_curve, rpm) * ratio
		# A turbo makes its boost over the first part of the pull, not instantly.
		if has_turbo:
			demand *= 1.0 + turbo_boost_multiplier * clampf(t / maxf(turbo_spool_time * 3.0, 0.1), 0.0, 1.0)
		var force: float = minf(demand, traction) / maxf(tyre_radius, 0.05)
		var drag: float = 0.5 * AIR_DENSITY * drag_area * drag_coefficient * v * v
		var a: float = maxf((force - drag - 0.014 * weight) / mass, 0.0)
		if a <= 0.0:
			break
		v += a * 0.01
		t += 0.01
	return t


## 0-100 kph on a surface with `mu` instead of this car's tyres. Approximate -
## the real number comes from the test rig - but it has to move in the right
## direction or the garage is lying about what rain does.
func zero_to_hundred_scaled(mu: float) -> float:
	return zero_to_hundred() * clampf(tyre_peak_mu / maxf(mu, 0.25), 0.6, 2.2)


func handling_rating() -> float:
	# 0..1, for the garage bars. Rewards grip and low mass, punishes a soft engine.
	return clampf(tyre_peak_mu * 2.0 / (mass / 1000.0) * 0.62, 0.0, 1.0)


func acceleration_rating() -> float:
	return clampf(zero_to_hundred() / 9.0, 1.0, 0.0)


func copy() -> CarSpec:
	return duplicate(true) as CarSpec
