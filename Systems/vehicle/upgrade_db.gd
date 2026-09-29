class_name UpgradeDB
extends RefCounted
## Upgrade catalogue. Each entry mutates a CarSpec copy in place.
##
## `apply` is a pure-ish function on a spec the caller already copied, so the
## garage preview and the car you actually drive are computed by the same code
## and cannot disagree.

const CAT_PERFORMANCE := "performance"
const CAT_BODY := "body"
const CAT_WHEELS := "wheels"
const CAT_PAINT := "paint"
const CAT_DAMAGE := "damage"

## id -> { name, cat, levels, costs:[..], stat (human string), apply: Callable }
const CATALOG := {
	# ---------------------------------------------------------- performance
	"engine1": {
		"name": "CAMS + PORTED MANIFOLD", "cat": CAT_PERFORMANCE, "max": 3,
		"costs": [800, 2200, 6000], "stat": "Power",
		"desc": "Another 12% at the top end per level. This is the single biggest upgrade.",
	},
	"turbo1": {
		"name": "LARGE FRONT INTERCOOLER", "cat": CAT_PERFORMANCE, "max": 2,
		"costs": [700, 2500], "stat": "Boost response",
		"desc": "Spools 30% faster per level. Turns lag into a shove.",
	},
	"exhaust1": {
		"name": "STRAIGHT-PIPE EXHAUST", "cat": CAT_PERFORMANCE, "max": 2,
		"costs": [450, 1400], "stat": "Exhaust note",
		"desc": "Loud, and a little more torque because nothing is left behind.",
	},
	"ecu1": {
		"name": "PIGGYBACK ECU", "cat": CAT_PERFORMANCE, "max": 3,
		"costs": [900, 2800, 7500], "stat": "Power",
		"desc": "Buys back 10% of what the turbo wastes. Do this before more boost.",
	},
	"clutch1": {
		"name": "KAVO PRO KAVO CLUTCH", "cat": CAT_PERFORMANCE, "max": 2,
		"costs": [600, 1800], "stat": "Shift speed",
		"desc": "Short 20% per level. Fewer milliseconds of nothing.",
	},
	"gearbox1": {
		"name": "CLOSE-RATIO GEARBOX", "cat": CAT_PERFORMANCE, "max": 1,
		"costs": [3200], "stat": "Gear spacing",
		"desc": "Tighter ratios: the engine never drops out of its powerband.",
	},
	"susp1": {
		"name": "COILOVERS", "cat": CAT_PERFORMANCE, "max": 3,
		"costs": [850, 2400, 6800], "stat": "Grip / ride height",
		"desc": "Stiffer springs, faster damping, lower and flatter per level.",
	},
	"brakes1": {
		"name": "SLOTTED DISCS + PADS", "cat": CAT_PERFORMANCE, "max": 3,
		"costs": [550, 1500, 3600], "stat": "Braking",
		"desc": "Shorter stops and far less fade on the second half of a long street.",
	},
	"tyres1": {
		"name": "SEMI-SLICK COMPOUND", "cat": CAT_PERFORMANCE, "max": 3,
		"costs": [600, 1700, 4200], "stat": "Grip",
		"desc": "+9% peak grip per level. Wears out in wet and costs you in the rain.",
	},
	"weight1": {
		"name": "STRIP THE INTERIOR", "cat": CAT_PERFORMANCE, "max": 2,
		"costs": [500, 1200], "stat": "Weight",
		"desc": "-35 kg per level. The oldest trick there is, and it still works.",
	},

	# ------------------------------------------------------------------ body
	"bumper_f": {
		"name": "FRONT LIP", "cat": CAT_BODY, "max": 1, "costs": [450], "stat": "Downforce",
		"desc": "Ugly, cheap, and adds a little front-end grip at speed.",
	},
	"spoiler": {
		"name": "WING", "cat": CAT_BODY, "max": 2, "costs": [400, 1100], "stat": "Downforce",
		"desc": "Genuine rear downforce per level. Worth it on the fast sections.",
	},
	"skirts": {
		"name": "SIDE SKIRTS", "cat": CAT_BODY, "max": 1, "costs": [350], "stat": "Aero",
		"desc": "Tidies the sills and shaves a little drag.",
	},
	"bonnet": {
		"name": "BONNET VENT", "cat": CAT_BODY, "max": 1, "costs": [250], "stat": "Look",
		"desc": "Functional if you are running a big intercooler. Mostly for the look.",
	},
	"headlights": {
		"name": "PROJECTOR HEADLIGHTS", "cat": CAT_BODY, "max": 1, "costs": [550], "stat": "Night vision",
		"desc": "Brighter, wider beam. On a wet Manunda street this is a real upgrade.",
	},
	"taillights": {
		"name": "SMOKED TAIL LIGHTS", "cat": CAT_BODY, "max": 1, "costs": [300], "stat": "Look",
		"desc": "Smoked lens. Looks better. Legally dubious.",
	},
	"fenders": {
		"name": "BOLT-ON FENDERS", "cat": CAT_BODY, "max": 1, "costs": [480], "stat": "Track",
		"desc": "Extra width for the tyres. Fit the semi-slicks first.",
	},
	"exhaust_tip": {
		"name": "BIG EXHAUST TIP", "cat": CAT_BODY, "max": 1, "costs": [180], "stat": "Look",
		"desc": "Chrome. That is the entire contribution of this item.",
	},

	# ---------------------------------------------------------------- wheels
	"wheel_set": {
		"name": "ALLOY WHEELS", "cat": CAT_WHEELS, "max": 3, "costs": [500, 1400, 3200], "stat": "Grip / weight",
		"desc": "Lighter and wider per level, which is unsprung mass you stop paying for.",
	},
	"ride_height": {
		"name": "DROP SUSPENSION", "cat": CAT_WHEELS, "max": 3, "costs": [350, 900, 2100], "stat": "Centre of gravity",
		"desc": "Lowers the CoG per level. Less roll, sharper turn-in, worse ride over kerbs.",
	},
	"camber": {
		"name": "NEGATIVE CAMBER", "cat": CAT_WHEELS, "max": 3, "costs": [300, 850, 1900], "stat": "Cornering",
		"desc": "More front bite per level, at the cost of straight-line stability.",
	},

	# ----------------------------------------------------------------- paint
	"paint": {
		"name": "RESPRAY", "cat": CAT_PAINT, "max": 1, "costs": [900], "stat": "Finish",
		"desc": "Colour and finish changeable in the garage menu once installed.",
	},

	# --------------------------------------------------------------- damage
	"panel_repair": {
		"name": "PANEL REPAIR", "cat": CAT_DAMAGE, "max": 3, "costs": [400, 1100, 2500], "stat": "Condition",
		"desc": "Straightens the dents. Restores lost drag and a little top-end.",
	},
}


static func get_upgrade(uid: String) -> Dictionary:
	return CATALOG.get(uid, {})


static func max_level(uid: String) -> int:
	return int(get_upgrade(uid).get("max", 0))


static func cost_for_level(uid: String, level: int) -> int:
	var costs: Array = get_upgrade(uid).get("costs", [])
	if level <= 0 or level > costs.size():
		return 0
	return int(costs[level - 1])


static func upgrades_in_category(cat: String) -> Array:
	var out: Array = []
	for uid in CATALOG:
		if CATALOG[uid].get("cat", "") == cat:
			out.append(uid)
	out.sort()
	return out


## Mutates `s` in place. Keep this in sync with the cost table above.
static func apply(s: CarSpec, uid: String, level: int) -> void:
	if level <= 0:
		return
	var curve: Array = s.torque_curve.duplicate(true)
	match uid:
		"engine1":
			var gain: float = 1.0 + 0.12 * level
			for p in curve:
				p[1] = float(p[1]) * gain
			s.torque_curve = curve
			s.redline += 120.0 * level
		"ecu1":
			for p in curve:
				p[1] = float(p[1]) * (1.0 + 0.10 * level)
			s.torque_curve = curve
		"turbo1":
			s.turbo_spool_time *= pow(0.70, level)
			s.turbo_boost_multiplier += 0.10 * level
		"exhaust1":
			for p in curve:
				p[1] = float(p[1]) * (1.0 + 0.05 * level)
			s.torque_curve = curve
			s.engine_brake_torque *= 0.85
		"clutch1":
			s.shift_time *= pow(0.80, level)
		"gearbox1":
			var g: Array = s.gears.duplicate()
			# Pull every ratio closer to its own geometric mean: same spread, wider usable band.
			for i in range(1, g.size()):
				var prev := float(g[i - 1])
				g[i] = sqrt(prev * float(g[i]))
			s.gears = g
		"susp1":
			s.spring_rate *= 1.0 + 0.22 * level
			s.damper *= 1.0 + 0.20 * level
			s.anti_roll *= 1.0 + 0.25 * level
			s.suspension_rest -= 0.015 * level
			s.cg_height -= 0.008 * level
		"brakes1":
			s.brake_torque *= 1.0 + 0.18 * level
		"tyres1":
			s.tyre_peak_mu *= 1.0 + 0.09 * level
		"weight1":
			s.mass -= 35.0 * level
		"bumper_f":
			s.lift_area += 0.12
			s.downforce_coefficient += 0.04
		"spoiler":
			s.lift_area += 0.18 * level
			s.downforce_coefficient += 0.10 * level
		"skirts":
			s.drag_area -= 0.01
		"fenders":
			s.track_width += 0.03
		"wheel_set":
			s.wheel_inertia *= pow(0.82, level)
			s.tyre_peak_mu *= 1.0 + 0.03 * level
		"ride_height":
			s.cg_height -= 0.022 * level
			s.suspension_travel -= 0.01 * level
		"camber":
			# More front bite, a touch less straight-line stability.
			s.tyre_peak_mu *= 1.0 + 0.035 * level
			s.max_steer -= 0.02 * level
		"panel_repair":
			s.drag_coefficient *= pow(0.93, level)
		# Purely cosmetic items change the mesh, not the physics.
		"headlights", "taillights", "bonnet", "exhaust_tip", "paint":
			pass


## Summary stats used by the garage screen.
static func summarise(spec: CarSpec) -> Dictionary:
	return {
		"power_kw": spec.peak_power_kw(),
		"torque_nm": spec.peak_torque_nm(),
		"weight_kg": spec.mass,
		"zero_to_100": spec.zero_to_hundred(),
		"top_kph": spec.top_speed_mps() * 3.6,
		"grip": spec.tyre_peak_mu,
		"handling": spec.handling_rating(),
		"acceleration": spec.acceleration_rating(),
		"power_to_weight": spec.power_to_weight(),
	}
