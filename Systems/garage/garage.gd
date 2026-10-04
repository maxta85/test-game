class_name Garage
extends RefCounted
## The garage: which cars the player owns, which one they are taking out tonight,
## what is bolted to it, and what all of that cost. No scene tree, no rendering -
## `GarageScreen` draws this, the tests drive this, and the race layer reads it.
##
## Nothing in here re-derives a car's physics. The stat card reads the same
## `CarSpec` the physics runs on, upgrades are priced by `UpgradeDB` and applied
## by `CarDB.apply_upgrades`, and the money is Cfg's - the one balance the race
## director already pays into. One currency, one save file, one source of truth.

# --- the car roster ----------------------------------------------------------
# Deliberately not stored here. `roster()` reads CarDB.ALL_IDS, so a car added
# to the roster shows up in the garage without anyone editing this file.

## Measured against what is in the repo rather than wished for: five cars, five
## glb files, all five fits usable. kairo_mx90 and kaze_type_r are both
## front-drive hatchbacks and there is no front-drive car in the library at all.

## Bar reference maxima, for the stat bars on the card.
##
## Fixed, not derived from whatever is in the roster right now: a bar that
## renormalises itself when you fit a part cannot tell you the part helped.
## Chosen from the measured spread of the seven cars (79-479 kW, 4.9-7.2 s to
## 100, 0.86-1.18 peak mu) with headroom at both ends.
const BAR_TOP := {
	"power": 500.0,   ## kW
	"kwt": 200.0,     ## kW per tonne
	"grip": 1.4,      ## peak friction coefficient
	"top": 400.0,     ## km/h, geared
}
## 0-100 runs the other way: a quick car is a full bar, so this band is inverted.
const BAR_ACCEL_SLOW := 8.0
const BAR_ACCEL_FAST := 4.0

var _cfg: Object = null


func _init(wallet: Object = null) -> void:
	_cfg = wallet if wallet != null else _autoload()
	_load_profile()


# ------------------------------------------------------------------- lifecycle

## The Cfg autoload, fetched off the scene tree. The bare `Cfg` identifier would
## do here too, and does: measured under the suite's `--script` runner,
## `Cfg` and `root.get_node_or_null("Cfg")` are the same object, which
## `Tests/test_1economy.gd` asserts so this paragraph cannot rot back into a lie.
## The path is for the null, not for the name - a `Garage` built before the tree
## is up comes up with no wallet, and every method below answers 0 or "" rather
## than crashing. Same reason and same shape as `RaceDirector._money()`.
static func _autoload() -> Object:
	var loop := Engine.get_main_loop()
	return loop.root.get_node_or_null("Cfg") if loop is SceneTree else null


## Reads the profile, once, on boot.
##
## Two things are repaired here, both of them Cfg's normal case rather than edge
## cases: a profile that has been written and never read comes up with nothing
## owned, and a selection can point at a car the player does not have. The
## garage's entry point is `race_spec()`, so a selection that resolves to a real
## car is the one thing boot has to guarantee.
func _load_profile() -> void:
	if _cfg == null:
		return
	if _cfg.owned_cars.is_empty() and not _cfg.load_game():
		for c in _cfg.STARTING_CARS:
			_cfg.buy_car(c, 0)
	var mine := owned_cars()
	if not mine.is_empty() and not owns(selected()):
		_cfg.active_car = String(mine[0])


## Writes the profile. Every mutation ends here, so money, owned cars, upgrades
## and the selected car are on disk before the frame it happened in returns.
func save() -> bool:
	return _cfg != null and _cfg.save_game()


# ------------------------------------------------------------------- the money

## The same balance the race director pays the player's winnings into.
func money() -> int:
	return int(_cfg.money) if _cfg != null else 0


# ------------------------------------------------------------------- the roster

## Every car the project has. Read from CarDB so the garage cannot drift away
## from the physics.
func roster() -> Array:
	return CarDB.all()


func roster_ids() -> Array:
	return CarDB.ALL_IDS.duplicate()


func in_roster(car_id: String) -> bool:
	return car_id in CarDB.ALL_IDS


func owns(car_id: String) -> bool:
	return _cfg != null and _cfg.owns_car(car_id)


## The cars the player has, in the order they were acquired.
func owned_cars() -> Array:
	return [] if _cfg == null else _cfg.owned_cars.duplicate()


## What a car costs. Cfg's number - the roster's own price - not a garage copy.
func price(car_id: String) -> int:
	return int(CarDB.get_spec(car_id).price)


func can_afford(car_id: String) -> bool:
	return money() >= price(car_id)


# ----------------------------------------------------------------- the selection

func selected() -> String:
	return String(_cfg.active_car) if _cfg != null else ""


## Takes a car out. Only a car the player actually owns can be selected, and the
## choice is written to disk before it returns.
func select(car_id: String) -> bool:
	if not owns(car_id):
		return false
	_cfg.active_car = car_id
	save()
	return true


## Buys a car and takes it out. Refuses anything not in the roster, and a car the
## player cannot afford costs them nothing.
func buy(car_id: String) -> bool:
	if not in_roster(car_id):
		return false
	if not _cfg.buy_car(car_id, price(car_id)):
		return false
	return select(car_id)


# ------------------------------------------------------------------ the physics

## THE ENTRY POINT for `Game/main.gd`.
##
##     var spec: CarSpec = garage.race_spec()
##
## The car the player picked with every installed upgrade applied - the same
## `CarSpec` the physics runs on, built by `CarDB.apply_upgrades` from the same
## dict Cfg holds, so the garage preview and the car on the road cannot disagree.
## `spec.id` is the car id, so one call gives both the id and the spec.
func race_spec() -> CarSpec:
	return spec_for(selected())


## A fully-built spec for any car in the roster: base car plus that car's
## installed upgrades. An unowned car gets its stock spec, which is what the
## garage shows in the list.
func spec_for(car_id: String) -> CarSpec:
	return CarDB.apply_upgrades(CarDB.get_spec(car_id), _cfg.get_upgrades(car_id))


# ------------------------------------------------------------------- the stats

## The stat card.
##
## Two of these deliberately do not use the CarSpec helpers, because both were
## measured and both are wrong for this roster:
##
##   * power. `CarSpec.peak_power_kw()` multiplies peak torque by redline as if
##     that torque were held to the limiter, which reports 869 kW for a 935 kg
##     1992 econobox. Integrating T*w over the torque curve the physics itself
##     integrates gives 79 kW for the same car, and 479 kW for the twin-turbo
##     trophy car at the other end.
##   * top speed. `CarSpec.top_speed_mps()` solves power against drag and ignores
##     the gearbox entirely, so it reports 650-985 km/h for a roster that is
##     gearing limited at 150-300. The geared figure is the speed the car can
##     actually reach, and it is what the bar shows.
##
## Mass, grip and 0-100 are the spec's own numbers, untouched.
func stats(car_id: String) -> Dictionary:
	var s := spec_for(car_id)
	var kw := peak_power_kw(s)
	return {
		"id": car_id,
		"name": s.display_name,
		"year": s.year,
		"drive": s.drive.to_upper(),
		"chassis": s.chassis_class,
		"power_kw": kw,
		"torque_nm": s.peak_torque_nm(),
		"mass_kg": s.mass,
		"kwt": kw / maxf(s.mass / 1000.0, 0.001),
		"zero_to_100": s.zero_to_hundred(),
		"top_kph": geared_top_kph(s),
		"grip": s.tyre_peak_mu,
		"turbo": s.has_turbo,
		"blurb": s.blurb,
		"tagline": CarDB.tagline(car_id),
		"bars": _bars(s, kw),
	}


## Peak crank power in kW, integrated over the torque curve with the boost the
## car would actually be making. P = T * omega, the same curve the engine model
## integrates through the gearbox.
static func peak_power_kw(s: CarSpec) -> float:
	var gain: float = (1.0 + s.turbo_boost_multiplier) if s.has_turbo else 1.0
	var best := 0.0
	for p in s.torque_curve:
		best = maxf(best, float(p[1]) * float(p[0]) * TAU / 60.0 / 1000.0)
	return best * gain


## Speed the car can actually reach: the rev limiter in top gear.
## Redline, top ratio, final drive and tyre radius, all from the spec.
static func geared_top_kph(s: CarSpec) -> float:
	if s.gears.size() < 2 or s.tyre_radius <= 0.0:
		return 0.0
	var ratio: float = maxf(float(s.gears[s.gears.size() - 1]), 0.001) * s.final_drive
	return s.redline * TAU / 60.0 / ratio * s.tyre_radius * 3.6


## Bar fills, 0..1, against the fixed reference bands at the top of this file.
func _bars(s: CarSpec, kw: float) -> Dictionary:
	return {
		"power": clampf(kw / float(BAR_TOP.power), 0.0, 1.0),
		"kwt": clampf(kw / maxf(s.mass / 1000.0, 0.001) / float(BAR_TOP.kwt), 0.0, 1.0),
		"grip": clampf(inverse_lerp(0.8, float(BAR_TOP.grip), s.tyre_peak_mu), 0.0, 1.0),
		"top": clampf(inverse_lerp(150.0, float(BAR_TOP.top), geared_top_kph(s)), 0.0, 1.0),
		"accel": clampf(inverse_lerp(BAR_ACCEL_SLOW, BAR_ACCEL_FAST, s.zero_to_hundred()), 0.0, 1.0),
	}


# ------------------------------------------------------------------- the bodies

## res:// path of the glb for a car, or "" when it has none.
##
## The mapping is CarVisual.MODELS, not a copy of it. There used to be a second
## table in this file and the two disagreed about akuma_gt and hayate_turbo, so
## the garage labelled one car "GLTF: EVO_V" while a Silvia S15 rendered. One
## source of truth, in the one place that actually draws the mesh.
##
## Measured, not assumed: a mapping is only believed if CarFit says the fit is
## usable and the file is actually on disk.
static func model_path(car_id: String) -> String:
	var stem: String = CarVisual.MODELS.get(car_id, "")
	if stem.is_empty() or not bool(CarFit.ALL.get(stem, {}).get("usable", false)):
		return ""
	var path := "res://assets/cars/%s.glb" % stem
	return path if FileAccess.file_exists(path) else ""


func has_model(car_id: String) -> bool:
	return not model_path(car_id).is_empty()


## What the garage says about a car's body. Never a mystery box: either the glb
## that is going on screen, or the fact that there is not one and the procedural
## body is standing in for it.
static func body_label(car_id: String) -> String:
	var path := model_path(car_id)
	if path.is_empty():
		return "NO GLTF MODEL - PROCEDURAL BODY"
	return "GLTF: %s" % path.get_file().get_basename().to_upper()


# ---------------------------------------------------------------- the upgrades

## The upgrade ids in one category, from UpgradeDB's own catalogue.
func upgrade_ids(cat: String) -> Array:
	return UpgradeDB.upgrades_in_category(cat)


func level_of(car_id: String, uid: String) -> int:
	return int(_cfg.get_upgrades(car_id).get(uid, 0))


## What the next level of an upgrade costs, or 0 when it is maxed or unknown.
func next_cost(car_id: String, uid: String) -> int:
	return UpgradeDB.cost_for_level(uid, level_of(car_id, uid) + 1)


## Everything the screen needs to draw one upgrade row, so the screen never has
## to know how pricing works.
func offer(car_id: String, uid: String) -> Dictionary:
	var u := UpgradeDB.get_upgrade(uid)
	var level := level_of(car_id, uid)
	var maxed := level >= UpgradeDB.max_level(uid)
	var cost := 0 if maxed else UpgradeDB.cost_for_level(uid, level + 1)
	return {
		"id": uid,
		"name": String(u.get("name", uid)),
		"cat": String(u.get("cat", "")),
		"stat": String(u.get("stat", "")),
		"desc": String(u.get("desc", "")),
		"level": level,
		"max": UpgradeDB.max_level(uid),
		"cost": cost,
		"maxed": maxed,
		"affordable": not maxed and money() >= cost,
	}


## Buys the next level of an upgrade on the selected car.
##
## The charge is `UpgradeDB.cost_for_level` for the level actually being bought
## - the catalogue's own number, not a garage copy of it - and the level goes
## through Cfg so `CarDB.apply_upgrades` builds the car from the same dict the
## physics reads. There is no refund: parts are permanent, which is what makes
## the money mean something.
func install(uid: String) -> bool:
	var car := selected()
	var next := level_of(car, uid) + 1
	if next > UpgradeDB.max_level(uid):
		return false
	if not _cfg.spend_money(UpgradeDB.cost_for_level(uid, next)):
		return false
	_cfg.install_upgrade(car, uid, next)
	return save()
