class_name CarDB
extends RefCounted
## The car roster.
##
## Every car is a fictional marque inspired by a broad era and segment - no
## manufacturer names, no badges, no copied bodywork. What they *are* is
## accurate: a 1990s front-drive shed is genuinely a different car to drive from a
## 2000s all-pounds-of-boost AWD coupe, and the numbers here are tuned to make
## that difference come through in the hands.

const ALL_IDS := [
	"kairo_mx90", "kaze_type_r", "kairo_s13",
	"shinobi_rs", "akuma_gt", "tatsuya_gt", "hayate_turbo",
]


static func _s(id: String, d: Dictionary) -> CarSpec:
	var s := CarSpec.new()
	s.id = id
	for k in d:
		s.set(k, d[k])
	return s


static func all() -> Array:
	var out: Array = []
	for c in ALL_IDS:
		out.append(get_spec(c))
	return out


static func get_spec(id: String) -> CarSpec:
	match id:
		"kairo_mx90": return _kairo_mx90()
		"kaze_type_r": return _kaze_type_r()
		"kairo_s13": return _kairo_s13()
		"shinobi_rs": return _shinobi_rs()
		"akuma_gt": return _akuma_gt()
		"tatsuya_gt": return _tatsuya_gt()
		"hayate_turbo": return _hayate_turbo()
	return CarSpec.new()


static func display_name(id: String) -> String:
	var s := get_spec(id)
	return s.display_name if s != null else id.to_upper()


## Human-readable summary used by the garage and the race-select screen.
static func tagline(id: String) -> String:
	match id:
		"kairo_mx90": return "Front-drive econobox. Slow, but it will not spin."
		"kaze_type_r": return "High-revving front-drive hatch. Point it, hang on."
		"kairo_s13": return "Rear-drive coupe with an angle. Slide it on command."
		"shinobi_rs": return "All-pounds turbo hatch. Launches, then keeps pulling."
		"akuma_gt": return "Mid-engined-feel AWD coupe. Brutally effective."
		"tatsuya_gt": return "The one everybody wants. Fast everywhere."
		"hayate_turbo": return "Rear-drive turbo with a spooling problem."
	return ""


# --------------------------------------------------------------------------
# 1992 KAIRO MX90 - the starter beater. Cheap, slow, indestructible, FWD.
# Deliberately awful power-to-weight so the player has something to build.
static func _kairo_mx90() -> CarSpec:
	return _s("kairo_mx90", {
		"display_name": "KAIRO MX90", "chassis_class": "hatch", "drive": "fwd",
		"year": 1992, "blurb": "Three owners, all of them used. FWD means no spin, which is the point.",
		"mass": 935.0, "wheelbase": 2.42, "track_width": 1.42, "cg_height": 0.53,
		"mass_bias_z": 0.02, "body_length": 3.94, "body_width": 1.66, "body_height": 1.42,
		"spring_rate": 30000.0, "damper": 3000.0, "suspension_rest": 0.26, "suspension_travel": 0.17,
		"anti_roll": 6500.0, "tyre_radius": 0.295, "tyre_peak_mu": 0.86, "wheel_inertia": 0.95,
		"idle_rpm": 800.0, "redline": 6800.0, "engine_inertia": 0.16,
		"engine_brake_torque": 22.0,
		"torque_curve": [[800, 96.0], [2000, 124.0], [3600, 142.0], [5000, 140.0], [6400, 118.0], [7000, 78.0]],
		"has_turbo": false,
		"gears": [0.0, 3.545, 1.904, 1.310, 1.000, 0.790],
		"final_drive": 4.06, "shift_time": 0.22, "shift_up_rpm": 5900.0, "shift_down_rpm": 2200.0,
		"torque_split": 0.0,
		"brake_torque": 1750.0, "brake_bias": 0.66, "handbrake_torque": 2600.0,
		"max_steer": 0.66, "ackermann": 0.30,
		"drag_area": 0.68, "drag_coefficient": 0.36, "lift_area": 0.80, "downforce_coefficient": 0.02,
		"body_style": "hatch", "default_paint": "faded_white", "default_wheel": "steel_13",
		"price": 0,
	})


# --------------------------------------------------------------------------
# 1997 KAZE TYPE-R - front-drive hot hatch. Grippy, revvy, rotates on lift.
static func _kaze_type_r() -> CarSpec:
	return _s("kaze_type_r", {
		"display_name": "KAZE TYPE-R", "chassis_class": "hatch", "drive": "fwd",
		"year": 1997, "blurb": "Fifteen hundred revs of angry noise and a limited-slip front end.",
		"mass": 1050.0, "wheelbase": 2.47, "track_width": 1.48, "cg_height": 0.47,
		"mass_bias_z": 0.10, "body_length": 4.21, "body_width": 1.69, "body_height": 1.40,
		"spring_rate": 42000.0, "damper": 4300.0, "suspension_rest": 0.27, "suspension_travel": 0.15,
		"anti_roll": 11000.0, "tyre_radius": 0.305, "tyre_peak_mu": 1.12, "wheel_inertia": 1.0,
		"idle_rpm": 900.0, "redline": 8200.0, "engine_inertia": 0.19,
		"engine_brake_torque": 30.0,
		"torque_curve": [[900, 118.0], [2500, 168.0], [4500, 196.0], [6800, 198.0], [7800, 178.0], [8300, 120.0]],
		"has_turbo": false,
		"gears": [0.0, 3.166, 1.904, 1.392, 1.031, 0.815],
		"final_drive": 4.06, "shift_time": 0.15, "shift_up_rpm": 7300.0, "shift_down_rpm": 3000.0,
		"torque_split": 0.0,
		"brake_torque": 2400.0, "brake_bias": 0.64, "handbrake_torque": 3200.0,
		"max_steer": 0.60, "ackermann": 0.42,
		"drag_area": 0.69, "drag_coefficient": 0.34, "lift_area": 0.85, "downforce_coefficient": 0.05,
		"body_style": "hatch", "default_paint": "storm_white", "default_wheel": "mesh_15",
		"price": 12000,
	})


# --------------------------------------------------------------------------
# 1993 KAIRO S13 - the player's starting car. RWD, light, drifts on command.
static func _kairo_s13() -> CarSpec:
	return _s("kairo_s13", {
		"display_name": "KAIRO S13", "chassis_class": "coupe", "drive": "rwd",
		"year": 1993, "blurb": "Rear-drive, faded panels, and the cheapest way to learn an angle.",
		"mass": 1215.0, "wheelbase": 2.475, "track_width": 1.49, "cg_height": 0.48,
		"mass_bias_z": 0.05, "body_length": 4.52, "body_width": 1.69, "body_height": 1.29,
		"spring_rate": 38000.0, "damper": 4000.0, "suspension_rest": 0.28, "suspension_travel": 0.16,
		"anti_roll": 9500.0, "tyre_radius": 0.305, "tyre_peak_mu": 1.12, "wheel_inertia": 1.05,
		"idle_rpm": 850.0, "redline": 7600.0, "engine_inertia": 0.21,
		"engine_brake_torque": 27.0,
		"torque_curve": [[850, 152.0], [2000, 214.0], [3500, 265.0], [4800, 271.0], [6200, 250.0], [7200, 212.0], [7800, 130.0]],
		"has_turbo": true, "turbo_threshold_rpm": 3400.0, "turbo_spool_time": 0.50,
		"turbo_blowoff_time": 0.20, "turbo_boost_multiplier": 0.62,
		"gears": [0.0, 3.321, 1.902, 1.308, 1.000, 0.762],
		"final_drive": 3.90, "shift_time": 0.17, "shift_up_rpm": 6800.0, "shift_down_rpm": 2600.0,
		"rear_slide_tail": 0.50, "diff_lock": 1.0,
		"torque_split": 1.0,
		"brake_torque": 2650.0, "brake_bias": 0.60, "handbrake_torque": 4400.0,
		"max_steer": 0.64, "ackermann": 0.38,
		"drag_area": 0.70, "drag_coefficient": 0.33, "lift_area": 0.92, "downforce_coefficient": 0.08,
		"body_style": "coupe", "default_paint": "primer_grey", "default_wheel": "steel_15",
		"price": 0,
	})


# --------------------------------------------------------------------------
# 1994 SHINOBI RS - AWD turbo hatch. Launches hard, then hangs on.
static func _shinobi_rs() -> CarSpec:
	return _s("shinobi_rs", {
		"display_name": "SHINOBI RS", "chassis_class": "hatch", "drive": "awd",
		"year": 1994, "blurb": "All four wheels, one loud blow-off, no manners.",
		"mass": 1290.0, "wheelbase": 2.52, "track_width": 1.51, "cg_height": 0.49,
		"mass_bias_z": 0.07, "body_length": 4.33, "body_width": 1.72, "body_height": 1.40,
		"spring_rate": 40000.0, "damper": 4200.0, "suspension_rest": 0.28, "suspension_travel": 0.16,
		"anti_roll": 10000.0, "tyre_radius": 0.31, "tyre_peak_mu": 1.05, "wheel_inertia": 1.05,
		"idle_rpm": 850.0, "redline": 7400.0, "engine_inertia": 0.22,
		"engine_brake_torque": 29.0,
		"torque_curve": [[850, 160.0], [2200, 232.0], [3800, 288.0], [5200, 296.0], [6400, 272.0], [7200, 226.0], [7700, 140.0]],
		"has_turbo": true, "turbo_threshold_rpm": 3200.0, "turbo_spool_time": 0.44,
		"turbo_blowoff_time": 0.18, "turbo_boost_multiplier": 0.70,
		"gears": [0.0, 3.545, 2.200, 1.541, 1.213, 1.000, 0.793],
		"final_drive": 4.11, "shift_time": 0.19, "shift_up_rpm": 6700.0, "shift_down_rpm": 2700.0,
		"torque_split": 0.45,
		"brake_torque": 2900.0, "brake_bias": 0.58, "handbrake_torque": 4600.0,
		"max_steer": 0.62, "ackermann": 0.36,
		"drag_area": 0.71, "drag_coefficient": 0.34, "lift_area": 0.90, "downforce_coefficient": 0.10,
		"body_style": "hatch", "default_paint": "midnight_blue", "default_wheel": "mesh_16",
		"price": 28000,
	})


# --------------------------------------------------------------------------
# 1996 AKUMA GT - AWD coupe, mid-90s, quietly brutal.
static func _akuma_gt() -> CarSpec:
	return _s("akuma_gt", {
		"display_name": "AKUMA GT", "chassis_class": "coupe", "drive": "awd",
		"year": 1996, "blurb": "The one the local crews respect, and fear, in equal measure.",
		"mass": 1385.0, "wheelbase": 2.57, "track_width": 1.53, "cg_height": 0.46,
		"mass_bias_z": 0.09, "body_length": 4.61, "body_width": 1.76, "body_height": 1.27,
		"spring_rate": 46000.0, "damper": 4700.0, "suspension_rest": 0.27, "suspension_travel": 0.15,
		"anti_roll": 13000.0, "tyre_radius": 0.315, "tyre_peak_mu": 1.10, "wheel_inertia": 1.1,
		"idle_rpm": 900.0, "redline": 7800.0, "engine_inertia": 0.24,
		"engine_brake_torque": 32.0,
		"torque_curve": [[900, 178.0], [2400, 268.0], [4000, 330.0], [5400, 342.0], [6600, 316.0], [7400, 262.0], [8000, 150.0]],
		"has_turbo": true, "turbo_threshold_rpm": 3000.0, "turbo_spool_time": 0.38,
		"turbo_blowoff_time": 0.16, "turbo_boost_multiplier": 0.78,
		"gears": [0.0, 3.483, 2.015, 1.390, 1.000, 0.762, 0.690],
		"final_drive": 3.70, "shift_time": 0.14, "shift_up_rpm": 7000.0, "shift_down_rpm": 2900.0,
		"torque_split": 0.40,
		"brake_torque": 3400.0, "brake_bias": 0.56, "handbrake_torque": 5200.0,
		"max_steer": 0.60, "ackermann": 0.34,
		"drag_area": 0.72, "drag_coefficient": 0.32, "lift_area": 0.98, "downforce_coefficient": 0.18,
		"body_style": "coupe", "default_paint": "gunmetal", "default_wheel": "mesh_17",
		"price": 52000,
	})


# --------------------------------------------------------------------------
# 2001 TATSUYA GT - early-2000s AWD turbo coupe. The trophy car.
static func _tatsuya_gt() -> CarSpec:
	return _s("tatsuya_gt", {
		"display_name": "TATSUYA GT", "chassis_class": "coupe", "drive": "awd",
		"year": 2001, "blurb": "Twin-turbo, all-wheel drive, and a ride height that will not see a kerb.",
		"mass": 1420.0, "wheelbase": 2.60, "track_width": 1.55, "cg_height": 0.44,
		"mass_bias_z": 0.10, "body_length": 4.66, "body_width": 1.79, "body_height": 1.26,
		"spring_rate": 52000.0, "damper": 5200.0, "suspension_rest": 0.25, "suspension_travel": 0.14,
		"anti_roll": 15500.0, "tyre_radius": 0.32, "tyre_peak_mu": 1.18, "wheel_inertia": 1.15,
		"idle_rpm": 900.0, "redline": 8000.0, "engine_inertia": 0.26,
		"engine_brake_torque": 34.0,
		"torque_curve": [[900, 186.0], [2400, 296.0], [4000, 372.0], [5600, 388.0], [6800, 358.0], [7600, 296.0], [8200, 170.0]],
		"has_turbo": true, "turbo_threshold_rpm": 2800.0, "turbo_spool_time": 0.30,
		"turbo_blowoff_time": 0.14, "turbo_boost_multiplier": 0.88,
		"gears": [0.0, 3.626, 2.200, 1.541, 1.213, 1.000, 0.852, 0.724],
		"final_drive": 3.54, "shift_time": 0.12, "shift_up_rpm": 7200.0, "shift_down_rpm": 3100.0,
		"torque_split": 0.38,
		"brake_torque": 3800.0, "brake_bias": 0.55, "handbrake_torque": 5600.0,
		"max_steer": 0.58, "ackermann": 0.32,
		"drag_area": 0.73, "drag_coefficient": 0.31, "lift_area": 1.02, "downforce_coefficient": 0.24,
		"body_style": "coupe", "default_paint": "pearl_white", "default_wheel": "mesh_18",
		"price": 96000,
	})


# --------------------------------------------------------------------------
# 1998 HAYATE TURBO - RWD turbo coupe with a laggy big single. Spins, then bites.
static func _hayate_turbo() -> CarSpec:
	return _s("hayate_turbo", {
		"display_name": "HAYATE TURBO", "chassis_class": "coupe", "drive": "rwd",
		"year": 1998, "blurb": "One enormous turbo, no help whatsoever. Boost arrives late and hits hard.",
		"mass": 1290.0, "wheelbase": 2.52, "track_width": 1.50, "cg_height": 0.47,
		"mass_bias_z": 0.04, "body_length": 4.61, "body_width": 1.73, "body_height": 1.30,
		"spring_rate": 41000.0, "damper": 4100.0, "suspension_rest": 0.28, "suspension_travel": 0.16,
		"anti_roll": 10000.0, "tyre_radius": 0.31, "tyre_peak_mu": 1.04, "wheel_inertia": 1.08,
		"idle_rpm": 850.0, "redline": 7200.0, "engine_inertia": 0.24,
		"engine_brake_torque": 30.0,
		"torque_curve": [[850, 168.0], [2200, 250.0], [3600, 302.0], [5000, 310.0], [6200, 284.0], [7000, 234.0], [7500, 140.0]],
		"has_turbo": true, "turbo_threshold_rpm": 3800.0, "turbo_spool_time": 0.85,
		"turbo_blowoff_time": 0.28, "turbo_boost_multiplier": 0.66,
		"gears": [0.0, 3.321, 1.902, 1.308, 1.000, 0.762],
		"final_drive": 3.90, "shift_time": 0.18, "shift_up_rpm": 6500.0, "shift_down_rpm": 2500.0,
		"rear_slide_tail": 0.52, "diff_lock": 1.0,
		"torque_split": 1.0,
		"brake_torque": 2800.0, "brake_bias": 0.60, "handbrake_torque": 4500.0,
		"max_steer": 0.64, "ackermann": 0.38,
		"drag_area": 0.71, "drag_coefficient": 0.33, "lift_area": 0.94, "downforce_coefficient": 0.09,
		"body_style": "coupe", "default_paint": "racing_green", "default_wheel": "steel_16",
		"price": 34000,
	})


## Applies installed upgrades to a base spec, returning a modified copy.
## Pure function: takes the base spec plus the player's upgrade dict, so the
## garage preview and the actual car can never disagree.
static func apply_upgrades(base: CarSpec, upgrade_levels: Dictionary) -> CarSpec:
	var s := base.copy()
	for uid in upgrade_levels:
		UpgradeDB.apply(s, uid, int(upgrade_levels[uid]))
	return s
