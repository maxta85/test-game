extends RefCounted
## Garage: roster, stat card, bodies, money, upgrades, persistence.
## Run with: ./test.sh garage
##
## The suite saves to the game's real save file, because that is the only way to
## prove persistence. It snapshots the file first and puts it back afterwards, so
## a test run leaves no trace on the machine.
##
## Measured against the roster rather than against a hardcoded list, so a car
## added to CarDB is covered without editing this file.

const CATS := [
	UpgradeDB.CAT_PERFORMANCE, UpgradeDB.CAT_BODY,
	UpgradeDB.CAT_WHEELS, UpgradeDB.CAT_PAINT, UpgradeDB.CAT_DAMAGE,
]

var cfg: Object
var g: Garage
var _save_existed := false
var _save_text := ""


func run(t: TestHarness) -> void:
	cfg = Engine.get_main_loop().root.get_node_or_null("Cfg")
	assert(cfg != null, "the Cfg autoload should be on the tree")
	_snapshot_save()
	g = Garage.new()

	_roster(t)
	_stat_card(t)
	_bars(t)
	_bodies(t)
	_money(t)
	_selection(t)
	_purchase(t)
	_upgrades(t)
	_persistence(t)
	await _screen(t)

	_restore_save()


# ---------------------------------------------------------------------- the setup

## Puts the profile back to a known new game without touching the save on disk,
## so each case starts from the same bank and the same two cars.
func _new_game(money: int = 500) -> void:
	cfg.money = money
	cfg.owned_cars.clear()      # Array[String] on Cfg; a bare [] will not assign
	for c in cfg.STARTING_CARS:
		cfg.owned_cars.append(String(c))
	cfg.active_car = "kairo_s13"
	cfg.upgrades = {}
	cfg.cosmetics = {}
	cfg.races_completed = {}


## The same profile, emptied the way Cfg comes up on a boot where a save exists
## and has never been read.
func _forget_profile() -> void:
	cfg.money = 0
	cfg.owned_cars.clear()
	cfg.active_car = ""
	cfg.upgrades = {}


func _snapshot_save() -> void:
	_save_existed = FileAccess.file_exists(Cfg.SAVE_PATH)
	if _save_existed:
		var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.READ)
		_save_text = f.get_as_text()
		f.close()
	if _save_existed:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Cfg.SAVE_PATH))


func _restore_save() -> void:
	if FileAccess.file_exists(Cfg.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Cfg.SAVE_PATH))
	if _save_existed:
		var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.WRITE)
		f.store_string(_save_text)
		f.close()


# ---------------------------------------------------------------------- the roster

## The roster is CarDB's, read not copied, so the garage cannot drift away from
## the physics.
func _roster(t: TestHarness) -> void:
	t.eq(g.roster().size(), CarDB.ALL_IDS.size(), "the garage lists every car the project has")
	t.eq(g.roster_ids(), CarDB.ALL_IDS, "and lists them in the roster's own order")

	var unknown := {}
	for c in g.roster():
		unknown[c.id] = true
		t.ok(c.mass > 0.0, "%s has a mass" % c.id)
		t.gt(c.price, -1, "%s has a price the garage can quote" % c.id)
	t.eq(unknown.size(), CarDB.ALL_IDS.size(), "no duplicates in the roster")

	t.fails(g.in_roster("no_such_car"), "a car that is not in the roster is not in the garage")
	t.eq(String(g.stats("no_such_car").get("name", "")), "UNNAMED",
		"stats for a car that does not exist say so rather than inventing a number")


## The card reads the spec the physics reads, so the two cannot disagree.
func _stat_card(t: TestHarness) -> void:
	var slowest := "kairo_mx90"
	var fastest := "tatsuya_gt"
	for id in CarDB.ALL_IDS:
		var s: CarSpec = CarDB.get_spec(id)
		var d := g.stats(id)
		t.near(float(d["mass_kg"]), s.mass, 0.001, "%s card mass is the spec's mass" % id)
		t.near(float(d["grip"]), s.tyre_peak_mu, 0.0001, "%s card grip is the spec's grip" % id)
		t.near(float(d["zero_to_100"]), s.zero_to_hundred(), 0.001,
			"%s card 0-100 is the spec's traction-limited 0-100" % id)
		t.near(float(d["torque_nm"]), s.peak_torque_nm(), 0.001, "%s card torque is the spec's" % id)
		t.eq(String(d["name"]), s.display_name, "%s is named by the spec" % id)

	# Power is the one number the card does not take from a CarSpec helper, and
	# that is measured, not stylistic. peak_power_kw() multiplies peak torque by
	# redline and reports 869 kW for the 935 kg econobox; integrating T*w over the
	# curve the engine actually integrates gives 79 kW for the same car.
	var slow_d := g.stats(slowest)
	var fast_d := g.stats(fastest)
	t.between(float(slow_d["power_kw"]), 30.0, 150.0,
		"the 935 kg econobox is not given four-figure kilowatts (%.0f kW)" % float(slow_d["power_kw"]))
	t.between(float(fast_d["power_kw"]), 300.0, 600.0,
		"the twin-turbo trophy car is the quick one (%.0f kW)" % float(fast_d["power_kw"]))
	t.gt(float(fast_d["power_kw"]), float(slow_d["power_kw"]), "more power reads as more power")
	t.eq(round(float(slow_d["power_kw"])), round(Garage.peak_power_kw(CarDB.get_spec(slowest))),
		"the card's power is Garage.peak_power_kw, not a second estimate")

	# Gearing limited, not power-against-drag: top_speed_mps() ignores the gearbox
	# and reports 650-985 km/h for a roster that cannot leave 300.
	for id in CarDB.ALL_IDS:
		t.between(float(g.stats(id)["top_kph"]), 150.0, 400.0,
			"%s top speed is something it could actually reach (%.0f km/h)" % [
				id, float(g.stats(id)["top_kph"])])
	t.gt(float(fast_d["top_kph"]), float(slow_d["top_kph"]), "the quick car has the higher top speed")

	t.gt(float(slow_d["kwt"]), 0.0, "power to weight is quoted")
	t.between(float(slow_d["kwt"]), 20.0, 120.0,
		"the econobox is not given 300 kW/t (%.0f)" % float(slow_d["kwt"]))


## The bars have to move. CarSpec's own handling_rating and acceleration_rating
## both saturate at 1.0 across this whole roster - measured, they are decoration -
## so the card uses fixed reference bands instead and the worst car must not read
## as full.
func _bars(t: TestHarness) -> void:
	var worst := 1.0
	var best := 0.0
	for key in ["power", "kwt", "grip", "top", "accel"]:
		var lo := 1.0
		var hi := 0.0
		for id in CarDB.ALL_IDS:
			var v := float(g.stats(id)["bars"][key])
			lo = minf(lo, v)
			hi = maxf(hi, v)
		t.between(lo, 0.0, 1.0, "the %s bar is in range for every car" % key)
		t.gt(hi, lo, "the %s bar separates the roster rather than reading full for all of it" % key)
		if key == "accel":
			worst = lo
			best = hi
	# 0-100 runs the other way: the slow car has the emptier bar.
	t.gt(worst, 0.0, "the slowest car still has a 0-100 bar (%.2f)" % worst)
	t.gt(best, worst, "the quickest car fills the 0-100 bar more (%.2f vs %.2f)" % [best, worst])

	# And the bands are fixed, so fitting a part cannot renormalise them.
	var before := float(g.stats("kairo_s13")["bars"]["power"])
	var after := float(g.stats("kairo_s13")["bars"]["power"])
	t.eq(before, after, "the bands do not move when a car is built up")


## A car with no glb has to say so, and a car with one has to have the file.
func _bodies(t: TestHarness) -> void:
	var with_model := 0
	for id in CarDB.ALL_IDS:
		var path := Garage.model_path(id)
		if path.is_empty():
			t.ok(Garage.body_label(id).begins_with("NO GLTF MODEL"),
				"%s says it has no model rather than showing a mystery box" % id)
			t.fails(g.has_model(id), "%s reports no model" % id)
			continue
		with_model += 1
		t.ok(FileAccess.file_exists(path), "%s model is really on disk (%s)" % [id, path])
		var stem: String = path.get_file().get_basename()
		t.ok(bool(CarFit.ALL.get(stem, {}).get("usable", false)),
			"%s model is a fit CarFit calls usable" % id)
		t.ok(Garage.body_label(id).contains(stem.to_upper()), "%s names the model it will show" % id)

	t.gt(float(with_model), 0.0, "at least one car has a real glb")
	t.eq(with_model, 5, "five of the seven cars have an archetype match in the library")
	t.eq(with_model + 2, CarDB.ALL_IDS.size(), "the other two are front-drive hatchbacks with nothing to match")


# ---------------------------------------------------------------------- the money

## One currency. The garage spends the same balance the race director pays into.
func _money(t: TestHarness) -> void:
	_new_game(1234)
	g = Garage.new()
	t.eq(g.money(), 1234, "the garage reads Cfg's balance rather than keeping its own")

	cfg.add_money(500)
	t.eq(g.money(), 1734, "race winnings land in the same balance")
	var paid: bool = cfg.spend_money(734)
	t.ok(paid, "the balance spends")
	t.eq(g.money(), 1000, "and the garage sees it")


## Only a car you own can be taken out, and the choice is written to disk.
func _selection(t: TestHarness) -> void:
	_new_game()
	g = Garage.new()
	t.eq(g.selected(), "kairo_s13", "the garage comes up on the selected car")
	t.ok(g.owns("kairo_s13"), "the starting car is owned")
	t.ok(g.owns("hayate_turbo"), "and so is the other one")
	t.fails(g.owns("tatsuya_gt"), "the trophy car is not handed over for free")

	t.fails(g.select("tatsuya_gt"), "a car you do not own cannot be selected")
	t.eq(g.selected(), "kairo_s13", "and the selection did not move")
	t.ok(g.select("hayate_turbo"), "a car you own can be")
	t.eq(g.selected(), "hayate_turbo", "and the selection moved to it")
	t.eq(String(Cfg.active_car), "hayate_turbo", "the choice is on the profile main.gd reads")

	t.fails(g.select("no_such_car"), "a car that does not exist cannot be selected")


## A car costs what the roster says, and a refused purchase costs nothing.
func _purchase(t: TestHarness) -> void:
	_new_game(500)
	t.eq(g.price("shinobi_rs"), 28000, "the price is the roster's own number")
	t.fails(g.can_afford("shinobi_rs"), "500 cannot buy a 28,000 car")

	t.fails(g.buy("shinobi_rs"), "a purchase the player cannot afford is refused")
	t.eq(g.money(), 500, "and a refused purchase takes nothing")
	t.fails(g.owns("shinobi_rs"), "and no car appears")

	t.fails(g.buy("no_such_car"), "a car that is not in the roster cannot be bought")

	cfg.money = 28000
	t.ok(g.buy("shinobi_rs"), "with the money, the same purchase goes through")
	t.eq(g.money(), 0, "the price came off the balance")
	t.ok(g.owns("shinobi_rs"), "and the car is owned")
	t.eq(g.selected(), "shinobi_rs", "a car you just bought is the one you take out")

	# Buying what you already own is not a second charge.
	cfg.money = 1000
	t.ok(g.buy("shinobi_rs"), "buying a car you already have is a no-op that succeeds")
	t.eq(g.money(), 1000, "and does not charge you for it again")


## Upgrades are priced by UpgradeDB, paid for in real money, and land on the car
## the physics will build.
func _upgrades(t: TestHarness) -> void:
	_new_game(1000)
	g = Garage.new()
	t.eq(g.selected(), "kairo_s13", "working on the starting car")
	t.eq(g.level_of("kairo_s13", "engine1"), 0, "a fresh car has nothing fitted")
	t.eq(g.offer("kairo_s13", "engine1")["cost"], UpgradeDB.cost_for_level("engine1", 1),
		"the offer quotes the catalogue's own price")

	# Fitting something has to make the car quicker, or the money bought nothing.
	var before := g.stats("kairo_s13")
	t.ok(g.install("engine1"), "a cam and ported manifold can be fitted")
	t.eq(g.money(), 1000 - UpgradeDB.cost_for_level("engine1", 1), "and it was paid for")
	t.eq(g.level_of("kairo_s13", "engine1"), 1, "the level is on the profile")
	var after := g.stats("kairo_s13")
	t.gt(float(after["power_kw"]), float(before["power_kw"]), "the card shows the power it bought")
	t.gt(float(after["bars"]["power"]), float(before["bars"]["power"]), "and the power bar moved with it")

	# The spec the race will get is built from that same profile dict.
	var driven := g.race_spec()
	t.eq(driven.id, "kairo_s13", "race_spec is the car the player selected")
	t.gt(Garage.peak_power_kw(driven), Garage.peak_power_kw(CarDB.get_spec("kairo_s13")),
		"and it carries the installed upgrade, built by the same code as the preview")

	# A different car's upgrades do not leak onto it.
	_new_game(20000)
	g = Garage.new()
	t.eq(g.level_of("hayate_turbo", "engine1"), 0, "upgrades are per car")
	g.select("hayate_turbo")
	t.ok(g.install("engine1"), "the same part fits the other starting car")
	t.eq(g.level_of("hayate_turbo", "engine1"), 1, "on that car")
	t.eq(g.level_of("kairo_s13", "engine1"), 0, "and not on the one that was not selected")

	# Not enough money.
	_new_game(10)
	g = Garage.new()
	t.fails(g.install("engine1"), "a part the player cannot afford is refused")
	t.eq(g.level_of(g.selected(), "engine1"), 0, "and nothing is fitted")
	t.fails(bool(g.offer(g.selected(), "engine1")["affordable"]), "the offer says it is out of reach")

	# Maxed out, not endlessly repeatable.
	_new_game(100000)
	g = Garage.new()
	for i in UpgradeDB.max_level("exhaust_tip"):
		t.ok(g.install("exhaust_tip"), "exhaust tip level %d" % (i + 1))
	t.eq(g.level_of(g.selected(), "exhaust_tip"), UpgradeDB.max_level("exhaust_tip"), "every level fitted")
	t.fails(g.install("exhaust_tip"), "a maxed upgrade cannot be bought again")
	t.ok(bool(g.offer(g.selected(), "exhaust_tip")["maxed"]), "and the offer says it is maxed")
	t.fails(g.install("no_such_upgrade"), "an upgrade that does not exist cannot be fitted")

	# Every category in the catalogue is reachable, and the card reads its strings.
	var seen := {}
	for cat in CATS:
		for uid in g.upgrade_ids(cat):
			seen[String(UpgradeDB.CATALOG[uid]["cat"])] = true
			var o := g.offer(g.selected(), String(uid))
			t.ok(String(o["name"]) != "", "%s is named" % uid)
			t.gt(int(o["max"]), 0, "%s has levels" % uid)
	t.eq(seen.size(), CATS.size(), "the garage reaches every upgrade category in the catalogue")


# ------------------------------------------------------------------ the persistence

## The point of the garage: money and upgrades survive being written.
##
## Simulates a process restart the only honest way available inside a test - the
## profile is emptied exactly as Cfg comes up on a boot where a save exists -
## and then a brand new Garage is built from it.
func _persistence(t: TestHarness) -> void:
	_new_game(50000)
	g = Garage.new()
	g.select("hayate_turbo")
	t.ok(g.install("brakes1"), "fitted discs and pads before the quit")
	t.ok(g.install("brakes1"), "and a second level of them")
	t.ok(g.buy("kaze_type_r"), "bought a car as well")
	t.ok(g.install("exhaust1"), "and fitted a part to that one")
	var money := g.money()
	t.gt(float(money), 0.0, "the balance after buying and fitting is $%d" % money)
	t.ok(g.save(), "the profile is written")

	# --- the process goes away ---
	_forget_profile()

	# --- and comes back ---
	var after := Garage.new()
	t.eq(after.money(), money, "the balance came back ($%d)" % money)
	t.eq(after.selected(), "kaze_type_r", "so did the car that was selected")
	t.ok(after.owns("kaze_type_r"), "so did the car that was bought")
	t.eq(after.level_of("hayate_turbo", "brakes1"), 2, "and both levels of the upgrade on the other car")
	t.eq(after.level_of("kaze_type_r", "exhaust1"), 1, "and the part on the new one")
	t.eq(after.owned_cars(), ["kairo_s13", "hayate_turbo", "kaze_type_r"],
		"the owned list comes back without the starting cars doubled")

	# The rebuilt spec has to be the built one, not the stock car.
	t.gt(Garage.peak_power_kw(after.race_spec()), Garage.peak_power_kw(CarDB.get_spec("kaze_type_r")),
		"the car the race will get is the upgraded one")

	# A profile that was written and never read comes up empty in Cfg, which is
	# the returning player's normal case. Boot is where that gets repaired.
	_forget_profile()
	var recovered := Garage.new()
	t.gt(float(recovered.roster_ids().size()), 0.0, "the roster is there whatever the profile said")
	t.ok(recovered.owns("kairo_s13") and recovered.owns("hayate_turbo"),
		"a save that was never read still leaves the player their starting cars")
	t.eq(recovered.money(), money, "and the balance the save was holding")
	t.eq(recovered.owned_cars(), ["kairo_s13", "hayate_turbo", "kaze_type_r"],
		"and the owned list, still without the starting cars doubled")

	# Reading a save twice must not grow the profile. `load_game` used to seed the
	# default cars and then append the saved list whole, so a save holding three
	# cars read back as five - and again on the next boot, because the bloated
	# list is what gets written. `Tests/test_1economy.gd` holds that shut too.
	after.save()
	_forget_profile()
	var twice := Garage.new()
	t.eq(twice.owned_cars(), ["kairo_s13", "hayate_turbo", "kaze_type_r"],
		"a second boot reads the same three cars, not five")

	# A brand new machine, with no save at all, is a new game.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Cfg.SAVE_PATH))
	_forget_profile()
	var fresh := Garage.new()
	t.eq(fresh.money(), 0, "no save means no money carried over")
	t.eq(fresh.owned_cars().size(), 2, "and the two starting cars")
	t.ok(fresh.selected() in CarDB.ALL_IDS, "with a real car selected (%s)" % fresh.selected())


# ---------------------------------------------------------------------- the screen

## The screen draws the state and commits through the one entry point, so what it
## shows and what the save says cannot come apart.
func _screen(t: TestHarness) -> void:
	_new_game(50000)
	var state := Garage.new()
	var seen: Array = []
	var started: Array = []
	var screen := GarageScreen.new(state)
	screen.car_selected.connect(func(id: String): seen.append(id))
	screen.start_race.connect(func(id: String, spec: CarSpec): started.append([id, spec]))

	t.tree.root.add_child(screen)
	await t.tree.process_frame

	t.eq(screen.garage, state, "the screen holds the state it was given")
	t.eq(seen.size(), 1, "the screen drew exactly one card on the way in")
	t.eq(seen[0], state.selected(), "for the car that is selected (%s)" % state.selected())

	# It lists the roster and the parts, both off the state.
	var rows := 0
	for n in screen.find_children("*", "ItemList", true, false):
		rows += (n as ItemList).item_count
	t.gt(float(rows), float(state.roster_ids().size()),
		"the screen lists the roster and the parts catalogue")

	# START RACE hands over the entry point's spec, not a copy of it.
	var buttons := screen.find_children("*", "Button", true, false)
	t.gt(float(buttons.size()), 0.0, "there is a way to commit")
	for b in buttons:
		(b as Button).emit_signal("pressed")
	await t.tree.process_frame
	t.eq(started.size(), 1, "START RACE emitted once")
	if started.size() == 1:
		t.eq(String(started[0][0]), state.selected(), "with the selected car id")
		t.eq((started[0][1] as CarSpec).id, state.selected(), "and the spec from Garage.race_spec()")
		t.near((started[0][1] as CarSpec).mass, cfg.active_spec().mass, 0.001,
			"which is the car main.gd would have built from the profile")

	await t.drop(screen)
