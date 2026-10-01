extends Node
## Global autoload: constants, player progression, and save/load.
##
## Progression lives here rather than in a system node so that it survives scene
## changes without any plumbing, and so tests can drive it without a world.

signal money_changed(amount: int)
signal progress_changed()

const SAVE_PATH := "user://cairns_after_dark.save"
const SAVE_VERSION := 1

## Car ids the player owns, and the car currently selected.
var money: int = 500
var owned_cars: Array[String] = []
var active_car: String = "kairo_s13"
## Race ids with at least one completed run, best lap / best time in seconds.
var races_completed: Dictionary = {}
## Installed upgrade ids, keyed by car id: { "engine3": 1, ... }
var upgrades: Dictionary = {}
## Cosmetic choices, keyed by car id: { "paint": "midnight", "wheel": "mesh" }
var cosmetics: Dictionary = {}
## Highest police pursuit level the player has survived.
var heat_record: int = 0

const STARTING_CARS := ["kairo_s13", "hayate_turbo"]


func _ready() -> void:
	InputSetup.install()
	if not FileAccess.file_exists(SAVE_PATH):
		_reset_new_game()


func _reset_new_game() -> void:
	money = 500
	owned_cars = _default_cars()
	active_car = "kairo_s13"
	races_completed = {}
	upgrades = {}
	cosmetics = {}
	heat_record = 0


static func _default_cars() -> Array[String]:
	var out: Array[String] = []
	for c in STARTING_CARS:
		out.append(c)
	return out


func add_money(amount: int) -> void:
	money = maxi(0, money + amount)
	money_changed.emit(money)


func spend_money(amount: int) -> bool:
	if money < amount:
		return false
	money -= amount
	money_changed.emit(money)
	return true


func owns_car(car_id: String) -> bool:
	return car_id in owned_cars


func buy_car(car_id: String, price: int) -> bool:
	if owns_car(car_id):
		return true
	if not spend_money(price):
		return false
	owned_cars.append(car_id)
	progress_changed.emit()
	return true


func get_upgrades(car_id: String) -> Dictionary:
	return upgrades.get(car_id, {})


func install_upgrade(car_id: String, upgrade_id: String, level: int = 1) -> void:
	if not upgrades.has(car_id):
		upgrades[car_id] = {}
	upgrades[car_id][upgrade_id] = level
	progress_changed.emit()


func get_cosmetics(car_id: String) -> Dictionary:
	return cosmetics.get(car_id, {})


func set_cosmetic(car_id: String, key: String, value: String) -> void:
	if not cosmetics.has(car_id):
		cosmetics[car_id] = {}
	cosmetics[car_id][key] = value
	progress_changed.emit()


func record_race(race_id: String, best_time: float, best_lap: float = 0.0) -> void:
	var entry: Dictionary = races_completed.get(race_id, {})
	var improved := true
	if entry.has("best_time") and entry["best_time"] <= best_time:
		improved = false
	if improved or not entry.has("best_time"):
		entry["best_time"] = best_time
	if best_lap > 0.0 and (not entry.has("best_lap") or entry["best_lap"] <= best_lap):
		entry["best_lap"] = best_lap
	entry["completed"] = true
	races_completed[race_id] = entry
	progress_changed.emit()


func get_race_record(race_id: String) -> Dictionary:
	return races_completed.get(race_id, {})


## The spec the player is actually driving: base car + every installed upgrade.
## Lives here rather than in CarDB so the data layer stays free of global state.
func active_spec() -> CarSpec:
	return CarDB.apply_upgrades(CarDB.get_spec(active_car), get_upgrades(active_car))


## A fully-built spec for any owned car, used by the garage preview.
func spec_for(car_id: String) -> CarSpec:
	if owns_car(car_id):
		return CarDB.apply_upgrades(CarDB.get_spec(car_id), get_upgrades(car_id))
	return CarDB.get_spec(car_id)


func save_game() -> bool:
	var data := {
		"version": SAVE_VERSION,
		"money": money,
		"owned_cars": owned_cars,
		"active_car": active_car,
		"races_completed": races_completed,
		"upgrades": upgrades,
		"cosmetics": cosmetics,
		"heat_record": heat_record,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("save failed: %s" % error_string(FileAccess.get_open_error()))
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


func load_game() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("save corrupt: not a dictionary - quarantined")
		_quarantine(-1)
		return false
	var d: Dictionary = parsed
	var found := int(d.get("version", 0))
	if found != SAVE_VERSION:
		# Deliberate, not silent. This used to be a `push_error` and a bare
		# `return false`, which left the player's file unreadable and their
		# balance on the 500 defaults with nothing but an error in a log to say
		# so. The file is moved aside rather than deleted, so nothing is thrown
		# away, and `money` - the one field whose meaning has not changed since
		# v1 - comes back with it. Everything else is a new career, which is the
		# honest outcome when the layout is one this build cannot read. Whoever
		# bumps SAVE_VERSION writes that migration here.
		push_error("save is version %d, this build writes %d - quarantined, not discarded"
			% [found, SAVE_VERSION])
		_quarantine(found)
		money = int(d.get("money", money))
		money_changed.emit(money)
		return false

	money = int(d.get("money", 500))
	active_car = String(d.get("active_car", "kairo_s13"))
	# The saved list, and only the saved list. Seeding `_default_cars()` here and
	# appending the file's own list on top of it handed the starting cars back
	# twice on the first read and once more on every boot after that, because the
	# bloated list is what gets written back out. `Garage` carried a `_dedupe_owned`
	# to paper over it; the empty-list case below is the only repair wanted.
	var cars: Array[String] = []
	for c in Array(d.get("owned_cars", [])):
		cars.append(String(c))
	owned_cars = cars
	races_completed = Dictionary(d.get("races_completed", {}))
	upgrades = Dictionary(d.get("upgrades", {}))
	cosmetics = Dictionary(d.get("cosmetics", {}))
	heat_record = int(d.get("heat_record", 0))

	# Guard against a hand-edited save handing the player a car that does not exist.
	var known: Array = CarDB.ALL_IDS
	owned_cars = owned_cars.filter(func(c): return c in known)
	if owned_cars.is_empty():
		owned_cars = _default_cars()
	if not active_car in owned_cars:
		active_car = owned_cars[0]

	money_changed.emit(money)
	progress_changed.emit()
	return true


## Moves a save this build will not read to a sibling file instead of leaving it
## where every boot fails on it again, and instead of deleting it: the player has
## a career in there. The version it was written at is in the name, so a folder
## of quarantines says which build stranded which save.
func _quarantine(found: int) -> void:
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(SAVE_PATH),
		ProjectSettings.globalize_path("%s.v%d.quarantined" % [SAVE_PATH, found]))
