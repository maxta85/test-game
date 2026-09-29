class_name CivilianCars
extends RefCounted
## The civilian roster: what actually drives around Manunda at 11pm.
##
## Separate from CarDB on purpose. CarDB is the player's garage - seven cars you
## can buy, race and tune. This is the anonymous traffic you crash into, and it
## has a different job: a stream of identical sedans is the single loudest tell
## that a city is fake. So these span the segments you really see on a
## Queensland arterial at night - sedans, SUVs, utes, a panel van, a couple of
## hatchbacks and a tray truck that is always in a hurry - and each one gets a
## different silhouette and a genuinely different drive from its numbers.
##
## The driving behaviour is NOT stored separately. TrafficCar derives its
## acceleration, braking and cruising speed from mass, gearing, grip and
## torque, so a 2.4 t van with no turbo is automatically slower to accelerate,
## slower to stop and more cruise-happy than a 1.2 t hatchback. One source of
## truth, no chance of the traffic disagreeing with the physics.
##
## ORIGINAL GAME CONTENT. Fictional marques, invented models.

const ALL_IDS := [
	"corvo_hatch", "wandoo_sedan", "quill_mini", "binda_suv",
	"tallow_ute", "reef_ute", "milgate_van", "barra_truck",
]


static func all() -> Array:
	var out: Array = []
	for id in ALL_IDS:
		out.append(get_spec(id))
	return out


static func get_spec(id: String) -> CarSpec:
	match id:
		"corvo_hatch": return _corvo_hatch()
		"wandoo_sedan": return _wandoo_sedan()
		"quill_mini": return _quill_mini()
		"binda_suv": return _binda_suv()
		"tallow_ute": return _tallow_ute()
		"reef_ute": return _reef_ute()
		"milgate_van": return _milgate_van()
		"barra_truck": return _barra_truck()
	return CarSpec.new()


static func random_id(rng: RandomNumberGenerator) -> String:
	return String(ALL_IDS[rng.randi_range(0, ALL_IDS.size() - 1)])


## Weighted so the common stuff is common. Sedans, hatchbacks and utes are most
## of the late-night traffic; the tray truck is a rarity that makes the streets
## feel used rather than simulated.
static func random_weighted_id(rng: RandomNumberGenerator) -> String:
	var r := rng.randf()
	if r < 0.24:
		return "wandoo_sedan"
	elif r < 0.44:
		return "corvo_hatch"
	elif r < 0.62:
		return "binda_suv"
	elif r < 0.76:
		return "reef_ute"
	elif r < 0.85:
		return "tallow_ute"
	elif r < 0.95:
		return "quill_mini"
	elif r < 0.99:
		return "milgate_van"
	return "barra_truck"


static func _s(id: String, d: Dictionary) -> CarSpec:
	var s := CarSpec.new()
	s.id = id
	for k in d:
		s.set(k, d[k])
	return s


# --------------------------------------------------------------------------
# The numbers below are only there to be believable. What the traffic system
# actually consumes is mass, body_length/width/height, tyre_peak_mu and
# whatever CarSpec derives from them - the torque curves and gearboxes are set
# so that zero_to_hundred() lands where the vehicle class actually sits.


# 2007 CORVO G - the family hatchback. Small, light, FWD, always slightly
# behind. The most common thing on a suburban street.
static func _corvo_hatch() -> CarSpec:
	return _s("corvo_hatch", {
		"display_name": "CORVO G", "chassis_class": "hatch", "drive": "fwd",
		"year": 2007, "blurb": "Three kids, a pram, and a permanent 5 km/h deficit.",
		"mass": 1180.0, "wheelbase": 2.55, "track_width": 1.50, "cg_height": 0.52,
		"mass_bias_z": 0.04, "body_length": 4.06, "body_width": 1.74, "body_height": 1.52,
		"spring_rate": 31000.0, "damper": 3100.0, "suspension_rest": 0.27, "suspension_travel": 0.17,
		"anti_roll": 7800.0, "tyre_radius": 0.305, "tyre_peak_mu": 0.98, "wheel_inertia": 0.95,
		"idle_rpm": 780.0, "redline": 6500.0, "engine_inertia": 0.17,
		"engine_brake_torque": 24.0,
		"torque_curve": [[800, 112.0], [2200, 153.0], [3800, 176.0], [5200, 170.0], [6200, 142.0], [6800, 91.0]],
		"has_turbo": false,
		"gears": [0.0, 3.545, 1.904, 1.310, 1.000, 0.790],
		"final_drive": 4.06, "shift_time": 0.22, "shift_up_rpm": 5600.0, "shift_down_rpm": 2200.0,
		"torque_split": 0.0,
		"brake_torque": 2200.0, "brake_bias": 0.64, "handbrake_torque": 3400.0,
		"max_steer": 0.64, "ackermann": 0.34,
		"drag_area": 0.72, "drag_coefficient": 0.35, "lift_area": 0.86, "downforce_coefficient": 0.03,
		"body_style": "hatch", "default_paint": "silver", "default_wheel": "steel_14",
		"price": 0,
	})


# 2003 WANDOO SE - the mid-size sedan. Longer, softer, lazier, and the thing
# most people picture when they picture traffic.
static func _wandoo_sedan() -> CarSpec:
	return _s("wandoo_sedan", {
		"display_name": "WANDOO SE", "chassis_class": "sedan", "drive": "fwd",
		"year": 2003, "blurb": "Four doors, a boot full of nothing, 60 on the odometer.",
		"mass": 1420.0, "wheelbase": 2.72, "track_width": 1.55, "cg_height": 0.54,
		"mass_bias_z": 0.02, "body_length": 4.72, "body_width": 1.80, "body_height": 1.44,
		"spring_rate": 33000.0, "damper": 3300.0, "suspension_rest": 0.28, "suspension_travel": 0.16,
		"anti_roll": 8600.0, "tyre_radius": 0.315, "tyre_peak_mu": 0.96, "wheel_inertia": 1.02,
		"idle_rpm": 750.0, "redline": 6200.0, "engine_inertia": 0.19,
		"engine_brake_torque": 25.0,
		"torque_curve": [[750, 113.0], [2000, 160.0], [3400, 190.0], [4600, 187.0], [5800, 159.0], [6500, 100.0]],
		"has_turbo": false,
		"gears": [0.0, 3.545, 2.050, 1.390, 1.000, 0.760],
		"final_drive": 3.90, "shift_time": 0.24, "shift_up_rpm": 5400.0, "shift_down_rpm": 2100.0,
		"torque_split": 0.0,
		"brake_torque": 2500.0, "brake_bias": 0.63, "handbrake_torque": 3800.0,
		"max_steer": 0.62, "ackermann": 0.32,
		"drag_area": 0.76, "drag_coefficient": 0.34, "lift_area": 0.90, "downforce_coefficient": 0.03,
		"body_style": "sedan", "default_paint": "midnight_blue", "default_wheel": "steel_15",
		"price": 0,
	})


# 2011 QUILL MINI - the city car. Extremely short, extremely slow, and it turns
# up in the tightest streets where nothing else fits.
static func _quill_mini() -> CarSpec:
	return _s("quill_mini", {
		"display_name": "QUILL MINI", "chassis_class": "hatch", "drive": "fwd",
		"year": 2011, "blurb": "Four metres of car and a boot the size of a shopping bag.",
		"mass": 940.0, "wheelbase": 2.35, "track_width": 1.44, "cg_height": 0.50,
		"mass_bias_z": 0.03, "body_length": 3.62, "body_width": 1.64, "body_height": 1.50,
		"spring_rate": 28000.0, "damper": 2800.0, "suspension_rest": 0.25, "suspension_travel": 0.18,
		"anti_roll": 6200.0, "tyre_radius": 0.290, "tyre_peak_mu": 0.94, "wheel_inertia": 0.88,
		"idle_rpm": 820.0, "redline": 6800.0, "engine_inertia": 0.14,
		"engine_brake_torque": 19.0,
		"torque_curve": [[820, 57.0], [2400, 81.0], [4000, 92.0], [5400, 88.0], [6400, 72.0], [7000, 45.0]],
		"has_turbo": false,
		"gears": [0.0, 3.626, 1.850, 1.350, 1.000, 0.760],
		"final_drive": 4.30, "shift_time": 0.20, "shift_up_rpm": 6000.0, "shift_down_rpm": 2300.0,
		"torque_split": 0.0,
		"brake_torque": 1750.0, "brake_bias": 0.68, "handbrake_torque": 2800.0,
		"max_steer": 0.70, "ackermann": 0.28,
		"drag_area": 0.64, "drag_coefficient": 0.37, "lift_area": 0.76, "downforce_coefficient": 0.02,
		"body_style": "hatch", "default_paint": "lemon", "default_wheel": "steel_13",
		"price": 0,
	})


# 2001 BINDA LX - the SUV. Tall, heavy, slow in a straight line and quicker to
# change direction than anything else on the road, which is exactly how they
# drive.
static func _binda_suv() -> CarSpec:
	return _s("binda_suv", {
		"display_name": "BINDA LX", "chassis_class": "wagon", "drive": "awd",
		"year": 2001, "blurb": "Drives like a barge and parks like it was issued a permit.",
		"mass": 1950.0, "wheelbase": 2.74, "track_width": 1.58, "cg_height": 0.62,
		"mass_bias_z": 0.04, "body_length": 4.78, "body_width": 1.86, "body_height": 1.80,
		"spring_rate": 38000.0, "damper": 3800.0, "suspension_rest": 0.32, "suspension_travel": 0.19,
		"anti_roll": 10500.0, "tyre_radius": 0.335, "tyre_peak_mu": 0.99, "wheel_inertia": 1.15,
		"idle_rpm": 720.0, "redline": 6000.0, "engine_inertia": 0.24,
		"engine_brake_torque": 30.0,
		"torque_curve": [[720, 134.0], [1800, 183.0], [3000, 213.0], [4200, 220.0], [5400, 195.0], [6200, 134.0]],
		"has_turbo": false,
		"gears": [0.0, 3.826, 2.200, 1.541, 1.000, 0.740],
		"final_drive": 4.30, "shift_time": 0.26, "shift_up_rpm": 5000.0, "shift_down_rpm": 2000.0,
		"torque_split": 0.4,
		"brake_torque": 3200.0, "brake_bias": 0.62, "handbrake_torque": 4600.0,
		"max_steer": 0.58, "ackermann": 0.30,
		"drag_area": 0.86, "drag_coefficient": 0.36, "lift_area": 1.05, "downforce_coefficient": 0.05,
		"body_style": "suv", "default_paint": "pearl_white", "default_wheel": "steel_16",
		"price": 0,
	})


# 1996 TALLOW SG - the single-cab ute. Narrow, long, rattling, and driven by
# someone who has somewhere to be.
static func _tallow_ute() -> CarSpec:
	return _s("tallow_ute", {
		"display_name": "TALLOW SG", "chassis_class": "ute", "drive": "rwd",
		"year": 1996, "blurb": "A tray, a toolchest and a dog, none of which are in the spec sheet.",
		"mass": 1520.0, "wheelbase": 3.10, "track_width": 1.56, "cg_height": 0.60,
		"mass_bias_z": 0.02, "body_length": 5.02, "body_width": 1.79, "body_height": 1.75,
		"spring_rate": 40000.0, "damper": 3600.0, "suspension_rest": 0.33, "suspension_travel": 0.20,
		"anti_roll": 9000.0, "tyre_radius": 0.330, "tyre_peak_mu": 0.93, "wheel_inertia": 1.12,
		"idle_rpm": 700.0, "redline": 5400.0, "engine_inertia": 0.25,
		"engine_brake_torque": 31.0,
		"torque_curve": [[700, 80.0], [1800, 110.0], [3000, 125.0], [4200, 122.0], [5000, 101.0], [5600, 62.0]],
		"has_turbo": false,
		"gears": [0.0, 3.626, 2.200, 1.541, 1.213, 1.000, 0.790],
		"final_drive": 4.55, "shift_time": 0.28, "shift_up_rpm": 4400.0, "shift_down_rpm": 1800.0,
		"torque_split": 1.0,
		"brake_torque": 2900.0, "brake_bias": 0.62, "handbrake_torque": 4600.0,
		"max_steer": 0.60, "ackermann": 0.30,
		"drag_area": 0.88, "drag_coefficient": 0.40, "lift_area": 1.00, "downforce_coefficient": 0.0,
		"body_style": "ute", "default_paint": "faded_white", "default_wheel": "steel_15",
		"price": 0,
	})


# 2005 REEF CRUZ - the double-cab ute. Same idea as the single cab, but it is
# the one with three child seats in it, so it corners like a bus.
static func _reef_ute() -> CarSpec:
	return _s("reef_ute", {
		"display_name": "REEF CRUZ", "chassis_class": "ute", "drive": "rwd",
		"year": 2005, "blurb": "Tow bar, tonneau, and a canopy that has seen things.",
		"mass": 2100.0, "wheelbase": 3.22, "track_width": 1.62, "cg_height": 0.64,
		"mass_bias_z": 0.02, "body_length": 5.30, "body_width": 1.90, "body_height": 1.83,
		"spring_rate": 44000.0, "damper": 3900.0, "suspension_rest": 0.34, "suspension_travel": 0.20,
		"anti_roll": 10000.0, "tyre_radius": 0.345, "tyre_peak_mu": 0.92, "wheel_inertia": 1.20,
		"idle_rpm": 700.0, "redline": 5200.0, "engine_inertia": 0.29,
		"engine_brake_torque": 36.0,
		"torque_curve": [[700, 107.0], [1800, 149.0], [3000, 171.0], [4000, 174.0], [4800, 148.0], [5400, 88.0]],
		"has_turbo": false,
		"gears": [0.0, 3.826, 2.200, 1.541, 1.213, 1.000, 0.760],
		"final_drive": 4.30, "shift_time": 0.30, "shift_up_rpm": 4200.0, "shift_down_rpm": 1700.0,
		"torque_split": 1.0,
		"brake_torque": 3400.0, "brake_bias": 0.60, "handbrake_torque": 5200.0,
		"max_steer": 0.58, "ackermann": 0.30,
		"drag_area": 0.98, "drag_coefficient": 0.42, "lift_area": 1.08, "downforce_coefficient": 0.0,
		"body_style": "ute", "default_paint": "storm_grey", "default_wheel": "steel_16",
		"price": 0,
	})


# 2006 MILGATE LV - the panel van. The tallest thing in traffic, blind directly
# behind it, and the reason you do not merge into that lane.
static func _milgate_van() -> CarSpec:
	return _s("milgate_van", {
		"display_name": "MILGATE LV", "chassis_class": "van", "drive": "fwd",
		"year": 2006, "blurb": "No rear window at all, which is a design choice made by nobody.",
		"mass": 2400.0, "wheelbase": 3.20, "track_width": 1.62, "cg_height": 0.86,
		"mass_bias_z": 0.03, "body_length": 5.40, "body_width": 1.94, "body_height": 2.20,
		"spring_rate": 46000.0, "damper": 4000.0, "suspension_rest": 0.36, "suspension_travel": 0.18,
		"anti_roll": 11000.0, "tyre_radius": 0.340, "tyre_peak_mu": 0.90, "wheel_inertia": 1.30,
		"idle_rpm": 680.0, "redline": 5000.0, "engine_inertia": 0.30,
		"engine_brake_torque": 34.0,
		"torque_curve": [[680, 105.0], [1800, 142.0], [2800, 157.0], [3800, 153.0], [4600, 128.0], [5200, 77.0]],
		"has_turbo": false,
		"gears": [0.0, 4.170, 2.340, 1.480, 1.000, 0.760],
		"final_drive": 4.30, "shift_time": 0.32, "shift_up_rpm": 4000.0, "shift_down_rpm": 1600.0,
		"torque_split": 0.0,
		"brake_torque": 3600.0, "brake_bias": 0.64, "handbrake_torque": 5400.0,
		"max_steer": 0.56, "ackermann": 0.26,
		"drag_area": 1.24, "drag_coefficient": 0.44, "lift_area": 1.30, "downforce_coefficient": 0.0,
		"body_style": "van", "default_paint": "primer_grey", "default_wheel": "steel_16",
		"price": 0,
	})


# 1999 BARRA 3T - the tray truck. Over the speed limit everywhere, forever.
# It is a rare spawn, and when one goes past at 60 in a 40 it recalibrates
# your sense of what the speed limit means.
static func _barra_truck() -> CarSpec:
	return _s("barra_truck", {
		"display_name": "BARRA 3T", "chassis_class": "truck", "drive": "rwd",
		"year": 1999, "blurb": "Three and a half tonnes of momentum and no interest in stopping.",
		"mass": 4200.0, "wheelbase": 3.60, "track_width": 1.74, "cg_height": 0.98,
		"mass_bias_z": 0.0, "body_length": 6.20, "body_width": 2.10, "body_height": 2.65,
		"spring_rate": 72000.0, "damper": 5600.0, "suspension_rest": 0.40, "suspension_travel": 0.18,
		"anti_roll": 15000.0, "tyre_radius": 0.395, "tyre_peak_mu": 0.88, "wheel_inertia": 1.85,
		"idle_rpm": 620.0, "redline": 4200.0, "engine_inertia": 0.46,
		"engine_brake_torque": 52.0,
		"torque_curve": [[620, 133.0], [1400, 174.0], [2200, 190.0], [3000, 184.0], [3800, 147.0], [4400, 87.0]],
		"has_turbo": false,
		"gears": [0.0, 5.130, 2.760, 1.690, 1.000, 0.790],
		"final_drive": 4.70, "shift_time": 0.40, "shift_up_rpm": 3400.0, "shift_down_rpm": 1400.0,
		"torque_split": 1.0,
		"brake_torque": 6400.0, "brake_bias": 0.58, "handbrake_torque": 9000.0,
		"max_steer": 0.54, "ackermann": 0.22,
		"drag_area": 1.90, "drag_coefficient": 0.52, "lift_area": 1.70, "downforce_coefficient": 0.0,
		"body_style": "truck", "default_paint": "fleet_white", "default_wheel": "steel_16",
		"price": 0,
	})
