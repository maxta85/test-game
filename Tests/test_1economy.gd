extends RefCounted
## The economy, end to end, with real state: the balance in `Cfg`, the file on
## disk, and races run through the host that actually ships. Run with:
## ./test.sh 1economy
##
## `Tests/test_menu_wiring.gd` proves the menu chain is connected. This proves the
## money moved, because "connected" and "correct" are different claims and only
## the second one is worth anything to a player. Every case here boots the real
## `Game/main.gd`, presses the real keys, clicks the real buttons and reads
## `Cfg` and the save file back afterwards - no numbers asserted twice, no
## "the signal fired" standing in for "the player got paid".
##
## Each path prints its own ledger (start, fee, payout, end) into the run log,
## so a regression in the economy shows up as a wrong figure rather than as one
## opaque failure.
##
## The leading `1` is load-bearing, like the `0` in `test_0reachability.gd`:
## `run_tests.gd` sorts suites by filename and this one is second so it boots the
## real world with the least churned shared state in front of it. Godot 4.3
## segfaults in `main.gd`'s `_spawn_player()` when the physics and render state
## has already been turned over by several suites; second is the earliest slot
## after the guard that boots a world at all.
##
## Only the driving is stubbed, the same way `test_menu_wiring` does it: the
## player's car is stepped along the route the director scores, which is the
## input a real lap produces because the director reads position and facing and
## nothing else.

var t: TestHarness
var tree: SceneTree
var main: Node3D
var board: Array = []

## The profile and the save file as this suite found them. `Cfg` is a singleton
## the whole run shares and the save is on the player's machine, so both are put
## back exactly as they were.
var _was: Dictionary = {}
var _save_existed := false
var _save_text := ""

const WALLET_FIELDS := ["money", "active_car", "heat_record"]
const WALLET_CONTAINERS := ["owned_cars", "races_completed", "upgrades", "cosmetics"]


func run(t: TestHarness) -> void:
	self.t = t
	tree = t.tree
	_snapshot()
	await _cold_boot()
	_the_autoload_lookup_is_the_same_object()
	await _browse_commits_the_choice()
	await _a_broke_player_cannot_start_a_race()
	await _a_finished_race_pays_out()
	await _the_save_round_trips_a_restart()
	await _quitting_mid_race_keeps_the_books_straight()
	await _the_save_round_trips_a_restart()
	await _a_version_bump_is_handled_not_swallowed()
	await _teardown()


# ------------------------------------------------------------------------ setup

## The player as a returning one with money and a save on disk: the only state
## where the interesting questions exist.
func _snapshot() -> void:
	for f in WALLET_FIELDS:
		_was[f] = Cfg.get(f)
	for f in WALLET_CONTAINERS:
		_was[f] = (Cfg.get(f) as Variant).duplicate(true)
	_save_existed = FileAccess.file_exists(Cfg.SAVE_PATH)
	if _save_existed:
		var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.READ)
		_save_text = f.get_as_text()
		f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Cfg.SAVE_PATH))


## A new boot of the real entry point, with a known wallet once the tree is
## really ticking. `Cfg._ready()` runs on the first served frame, not at
## `add_child`, so anything set before that can be overwritten by the profile.
func _cold_boot() -> void:
	main = load("res://Game/main.gd").new()
	tree.root.add_child(main)
	await tree.process_frame
	_new_game(3000)
	board = main.menus.races()

	t.eq(String(main.menus.screen_name()), "main_menu", "cold boot lands on the main menu")
	t.eq(String(main.race.state_name()), "idle", "with no race running")
	t.ok(board.size() > 0, "and a board of routes (%d)" % board.size())


## Puts the profile back to a known starting point without touching the save on
## disk, which is what this suite snapshots for the version-bump case.
func _new_game(money: int) -> void:
	Cfg.money = money
	Cfg.owned_cars.clear()
	for c in Cfg.STARTING_CARS:
		Cfg.owned_cars.append(String(c))
	Cfg.active_car = "kairo_s13"
	Cfg.upgrades = {}
	Cfg.cosmetics = {}
	Cfg.races_completed = {}
	Cfg.heat_record = 0


## Empties the profile the way Cfg comes up on a boot where a save exists and has
## not been read yet - which is how every returning player starts.
func _forget_profile() -> void:
	Cfg.money = 0
	Cfg.owned_cars.clear()
	Cfg.active_car = ""
	Cfg.upgrades = {}
	Cfg.cosmetics = {}
	Cfg.races_completed = {}
	Cfg.heat_record = 0


## The money the save file on disk is holding, or -1 when there is no file.
func _saved_money() -> int:
	if not FileAccess.file_exists(Cfg.SAVE_PATH):
		return -1
	var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	var d: Variant = JSON.parse_string(txt)
	return int(d["money"]) if d is Dictionary and d.has("money") else -1


func _ledger(label: String, parts: Array) -> void:
	var out := ""
	for p in parts:
		out += "%s=%s " % [str(p[0]), str(p[1])]
	print("  [ledger] %s: %s" % [label, out.strip_edges()])


# ------------------------------------------------------------------ the autoload

## `Systems/garage/garage.gd` and `Systems/race/race_director.gd` both say in a
## comment that a bare `Cfg` is not registered under `--script`, and both work
## anyway. It is not: they are the same object. This asserts that, so the comment
## cannot rot back into a lie about which of the two lookups is the honest one.
func _the_autoload_lookup_is_the_same_object() -> void:
	var loop := Engine.get_main_loop()
	var by_path: Object = loop.root.get_node_or_null("Cfg") if loop is SceneTree else null
	t.ok(by_path != null, "the Cfg autoload is on the tree under --script")
	t.ok(by_path == Cfg, "and it is the same object the bare Cfg identifier names")


# --------------------------------------------------------------------- the garage

## Browsing a car has to land somewhere. `GarageScreen` draws whatever it is
## handed and then reads the profile back through `garage.selected()`, so if
## nothing commits the choice, every press steps off the car already selected
## and the cursor cannot move at all.
##
## Driven with the real A/D keys, on the real screen, in the real host - because
## the cursor was broken in three separate ways at once and only the whole chain
## finds all of them.
func _browse_commits_the_choice() -> void:
	_ledger("browse start", [["start", Cfg.money], ["selected", Cfg.active_car]])
	t.eq(String(main.garage.selected()), "kairo_s13", "the garage comes up on the starting car")

	main.menus.garage_requested.emit()
	await tree.process_frame
	t.ok(main.garage_screen.visible, "the garage opens in front of the player")

	var ids: Array = main.garage.roster_ids()
	var start_at := int(ids.find(String(Cfg.active_car)))
	# Four steps right of kairo_s13 (index 2) is hayate_turbo (index 6), the
	# player's other car. The three in between are cars they do not own, so the
	# cursor has to walk past them rather than jam on the first one.
	var steps := (int(ids.find("hayate_turbo")) - start_at + ids.size()) % ids.size()
	for i in steps:
		await _key(KEY_D)
	t.eq(String(main.garage.selected()), "hayate_turbo",
		"D x%d walks the cursor past the three unowned cars and commits the second one" % steps)
	t.eq(String(Cfg.active_car), "hayate_turbo", "and the choice is on the profile")
	t.eq(_saved_money(), int(Cfg.money),
		"the profile is already on disk ($%d)" % int(Cfg.money))
	t.eq(_saved_active_car(), "hayate_turbo", "with the chosen car in the file too")

	# Back the other way, so the cursor is not just a one-way ratchet.
	await _key(KEY_A)
	await _key(KEY_A)
	await _key(KEY_A)
	await _key(KEY_A)
	t.eq(String(main.garage.selected()), "kairo_s13", "A walks it back to the starting car")
	t.eq(String(Cfg.active_car), "kairo_s13", "committed on the way back as well")

	# A car the player does not own is shown but not taken out - the host's
	# documented refusal. Assert it so it stays a decision rather than an accident.
	var unowned := String(ids[0])
	if not main.garage.owns(unowned):
		await _key(KEY_A)
		await _key(KEY_A)
		t.eq(String(main.garage.selected()), "kairo_s13",
			"browsing an unowned car does not take it out (%s)" % unowned)
		t.eq(String(Cfg.active_car), "kairo_s13", "and leaves the committed car alone")

	# Take the second car out, through the screen's own button.
	var go := _button(main.garage_screen, "START RACE")
	t.ok(go != null, "the garage has a way to commit")
	if go != null:
		go.pressed.emit()
	await tree.process_frame
	t.eq(String(main.player_car.spec.id), "kairo_s13", "the committed car is the one being driven")


func _saved_active_car() -> String:
	if not FileAccess.file_exists(Cfg.SAVE_PATH):
		return ""
	var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return String(d["active_car"]) if d is Dictionary else ""


# -------------------------------------------------------------- the entry fee

## Two gates, and both have to hold: the board will not offer a race the player
## cannot pay for, and if that is driven around anyway the host refuses and the
## player keeps their money.
func _a_broke_player_cannot_start_a_race() -> void:
	var d: RaceDef = board[0]
	var fee := int(d.entry_fee)
	_ledger("broke", [["start", 3000], ["fee", fee]])

	_new_game(fee - 1)
	main.menus.show_race_select()
	await tree.process_frame

	var sel: RaceSelect = main.menus.race_select()
	t.eq(_place_of(d), sel.selected, "the board is up on the route under test")
	var start: Button = sel.start_button()
	t.ok(start.disabled, "the board will not offer a race the player cannot pay for")
	t.ok(_text_of(sel).contains("NEED"), "and says what is missing rather than just greying out")

	# Drive around the button, the way a stale board or a hotkey would.
	sel.race_chosen.emit(String(d.id))
	await tree.process_frame
	t.eq(String(main.race.state_name()), "idle", "the host refuses the unpaid entry")
	t.eq(int(Cfg.money), fee - 1, "and charges nothing for it")
	t.eq(String(main.menus.screen_name()), "race_select", "putting the player back on the board")
	t.fails(main.hud.visible, "with no race and no HUD")

	# Exactly enough is enough.
	_new_game(fee)
	main.menus.show_race_select()
	await tree.process_frame
	t.fails(main.menus.race_select().start_button().disabled,
		"the same route opens once the fee is covered exactly")

	# And a free race is never gated.
	var freebies := 0
	for r in board:
		if int(r.entry_fee) == 0:
			freebies += 1
	t.eq(freebies, 0, "every route on the board costs something this player has to weigh")


# ------------------------------------------------------------------- the payout

## The whole point of the loop: fee out, payout in, net on the balance and on
## the board, and the file on disk to match.
func _a_finished_race_pays_out() -> void:
	var d: RaceDef = board[0]
	var fee := int(d.entry_fee)
	var start := 3000
	_new_game(start)
	main.menus.show_race_select()
	await tree.process_frame

	main.menus.race_select().race_chosen.emit(String(d.id))
	await tree.process_frame
	t.eq(String(main.race.state_name()), "countdown", "the route goes to the lights")
	t.eq(int(Cfg.money), start - fee, "the entry fee is debited once, on entry")

	for i in int(RaceDirector.COUNTDOWN_TIME * 60.0) + 30:
		await t.ticks(1)
		if main.race.state == RaceDirector.State.RACING:
			break
	t.eq(String(main.race.state_name()), "racing", "the lights go out")

	await _drive_it_in()
	await t.ticks(2)
	t.eq(String(main.race.state_name()), "finished", "the race finishes")
	t.eq(String(main.menus.screen_name()), "results", "and the results come up by themselves")

	var place := _place_of_the_player()
	var paid := int(main.race.payout_for_position(place))
	var end := start - fee + paid
	_ledger("race", [["start", start], ["fee", fee], ["place", place], ["payout", paid], ["end", end]])
	t.eq(int(Cfg.money), end, "the payout lands on top of the fee the player paid")
	t.eq(_saved_money(), end, "and the host wrote it to disk ($%d)" % end)
	t.ok(Cfg.get_race_record(String(d.id)).has("best_time"), "the time is on the profile")

	var board_text := _text_of(main.menus.results().root)
	t.ok(board_text.contains(UIPalette.money(paid - fee)),
		"the results board shows the net the race was worth (%s)" % UIPalette.money(paid - fee))
	t.ok(board_text.contains(String(d.display_name).to_upper()), "and the route they raced")

	# Second place is worth less than first, so the number on the board is a
	# classification and not a constant.
	var two: int = main.race.payout_for_position(2)
	if main.race.entrants.size() > 1:
		t.gt(float(paid), float(two), "the winner is paid more than second (%d > %d)" % [paid, two])


# ------------------------------------------------------------------- persistence

## The save, read back the way a returning player's boot reads it: a profile
## that has been written and never read, and a fresh `Garage` to repair it.
func _the_save_round_trips_a_restart() -> void:
	# The file, not `Cfg.money`. Walking out of a race is not quitting the game,
	# so it writes nothing, which leaves the in-memory balance legitimately ahead
	# of the one on disk - reading memory here tested the wrong number.
	var on_disk := _saved_money()
	t.gt(float(on_disk), 0.0, "the save holds a balance ($%d)" % on_disk)

	_forget_profile()
	t.eq(int(Cfg.money), 0, "the profile is empty, the way a boot starts")

	var after := Garage.new()
	t.eq(int(after.money()), on_disk, "and the balance comes back off disk ($%d)" % on_disk)
	t.eq(String(after.selected()), String(Cfg.active_car),
		"so does the car that was selected (%s)" % after.selected())
	t.eq(after.owned_cars(), Cfg.owned_cars, "and the owned list, no duplicates")
	t.ok(after.owns("kairo_s13") and after.owns("hayate_turbo"),
		"including the two the player started with")

	# Reading it again must not grow anything: the starting cars are in the save,
	# and a reader that seeds its own defaults on top of them doubles them every
	# boot. Measured before this suite: a three-car save read back as five.
	var before: Array = after.owned_cars().duplicate()
	_forget_profile()
	var twice := Garage.new()
	t.eq(twice.owned_cars(), before, "a second boot reads the same list, not a longer one")
	t.eq(int(twice.money()), on_disk, "and the same balance")


# ------------------------------------------------------------------- quitting

## Walking out of a race mid-run. The fee is spent and stays spent, nothing is
## paid for a race that was never finished, and going back in costs a second fee
## rather than riding on the entry that was already paid.
func _quitting_mid_race_keeps_the_books_straight() -> void:
	var d: RaceDef = board[0]
	var fee := int(d.entry_fee)
	var start := 3000
	_new_game(start)
	main.menus.show_race_select()
	await tree.process_frame

	main.menus.race_select().race_chosen.emit(String(d.id))
	await tree.process_frame
	for i in int(RaceDirector.COUNTDOWN_TIME * 60.0) + 30:
		await t.ticks(1)
		if main.race.state == RaceDirector.State.RACING:
			break
	var after_fee := start - fee
	t.eq(int(Cfg.money), after_fee, "the entry is paid before there is anything to quit")
	await _key(KEY_ESCAPE)
	await t.ticks(2)
	t.ok(main.menus.paused, "ESC mid-race raises the pause board")
	var on_disk_before := _saved_money()
	main.menus.pause().quit_to_menu_requested.emit()
	await t.ticks(2)
	t.fails(main.menus.paused, "quitting to the menu unpauses the world")
	t.fails(tree.paused, "and leaves it running")
	t.eq(String(main.menus.screen_name()), "main_menu", "and the player is back on the front page")
	t.eq(int(Cfg.money), after_fee, "quitting mid-race pays nothing and refunds nothing")
	t.eq(main.race.results.size(), 0, "and no phantom classification was written")
	# Walked away from is not quit-the-game: the balance already on disk is left
	# exactly as it was, so a crash on the way out cannot bank a half-finished
	# race. Compared before/after rather than against a literal, because what the
	# file holds at this point is whatever the last real write put there.
	t.eq(_saved_money(), on_disk_before, "nothing is written to disk on a quit that is not the game quitting")
	_ledger("quit mid-race", [["start", start], ["fee", fee], ["payout", 0], ["end", after_fee],
		["on_disk", on_disk_before]])

	# Going back in is a new entry, so it is charged again. A director that kept
	# the paid entry across `reset()` and skipped the fee would be handing out
	# free races to anyone who quits on purpose.
	main.menus.show_race_select()
	await tree.process_frame
	main.menus.race_select().race_chosen.emit(String(d.id))
	await tree.process_frame
	t.eq(String(main.race.state_name()), "countdown", "the same route goes back on the grid")
	t.eq(int(Cfg.money), after_fee - fee, "for a second fee, not the first one again ($%d)" % (after_fee - fee))
	main.race.reset()


# -------------------------------------------------------------- the version bump

## `Cfg` rejects a save whose version is not this build's. That used to mean a
## `push_error` and a return, with the player's file left unreadable and their
## balance reset to the 500 defaults behind an error nobody sees. It has to be a
## decision instead: the file is moved aside rather than deleted, and the money
## in it - the one field whose meaning has not changed - comes back.
func _a_version_bump_is_handled_not_swallowed() -> void:
	var banked := 31415
	_write_save({
		"version": Cfg.SAVE_VERSION + 1,
		"money": banked,
		"active_car": "kairo_s13",
		"owned_cars": ["kairo_s13", "hayate_turbo"],
		"races_completed": {}, "upgrades": {}, "cosmetics": {}, "heat_record": 0,
	})
	_forget_profile()

	t.fails(Cfg.load_game(), "a save from another build is not loaded as if it were this one")
	t.eq(int(Cfg.money), banked, "but the bank in it is not thrown away ($%d)" % banked)
	t.fails(FileAccess.file_exists(Cfg.SAVE_PATH), "and the file is moved out of the way, not left to fail again")
	t.ok(FileAccess.file_exists(_quarantine_path(Cfg.SAVE_VERSION + 1)),
		"to a quarantine path, so it is still on the machine to recover")

	# The boot that follows is a new career, not a crash and not a silent reset
	# with the player's cars intact.
	var fresh := Garage.new()
	t.ok(fresh.owns("kairo_s13") and fresh.owns("hayate_turbo"),
		"a boot off a quarantined save still hands the player their starting cars")
	t.eq(int(fresh.money()), banked, "and keeps the balance the old save was holding")
	t.ok(fresh.selected() in CarDB.ALL_IDS, "with a real car selected (%s)" % fresh.selected())

	# And the quarantine does not fire on a good save.
	t.ok(Cfg.save_game(), "the new career writes over the empty path")
	_forget_profile()
	t.ok(Cfg.load_game(), "and reads back without quarantining anything")
	t.eq(int(Cfg.money), banked, "keeping the same balance (%d)" % banked)


func _write_save(data: Dictionary) -> void:
	var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


func _quarantine_path(version: int) -> String:
	return "%s.v%d.quarantined" % [Cfg.SAVE_PATH, version]


# ------------------------------------------------------------------- plumbing

## Steps the car along the route the director is scoring. Velocity goes with it
## so the body reads as moving: parked against scenery, `main.gd` decides the
## car is stuck, recovers it to the nearest road, and the run stops being the
## route's.
func _drive_it_in() -> void:
	var car: CarBody = main.player_car
	var pts: Array = main.race.route_points()
	if pts.size() < 2:
		return
	var y := car.global_position.y
	for lap in int(main.race.def.laps):
		for i in range(pts.size() + 1):
			var a: Vector2 = pts[i % pts.size()]
			var b: Vector2 = pts[(i + 1) % pts.size()]
			car.global_position = Vector3(a.x, y, a.y)
			car.linear_velocity = Vector3(b.x - a.x, 0.0, b.y - a.y).normalized() * 12.0
			await t.ticks(1)
			if main.race.state == RaceDirector.State.FINISHED:
				return


func _place_of(d: RaceDef) -> int:
	var sel: RaceSelect = main.menus.race_select()
	for i in sel.races.size():
		if String(sel.races[i].id) == String(d.id):
			return i
	return -1


func _place_of_the_player() -> int:
	for r in main.race.results:
		if r["car"] is RaceEntrant and (r["car"] as RaceEntrant).car == main.player_car:
			return int(r["pos"])
	return 1


## The first button under `node` whose label carries `text`.
func _button(node: Node, text: String) -> Button:
	for c in node.get_children():
		if c is Button and String(c.text).to_upper().contains(text):
			return c
		var deeper := _button(c, text)
		if deeper != null:
			return deeper
	return null


## Every string in the subtree, which is how a screen is read when it is a set of
## labels rather than one text property.
func _text_of(node: Node) -> String:
	var out := ""
	for c in node.get_children():
		if c is Label or c is Button:
			out += String(c.text) + "\n"
		out += _text_of(c)
	return out


## A key press and its release, through the real InputMap.
func _key(key: int) -> void:
	var down := InputEventKey.new()
	down.keycode = key
	down.physical_keycode = key
	down.pressed = true
	Input.parse_input_event(down)
	await tree.process_frame
	var up := InputEventKey.new()
	up.keycode = key
	up.physical_keycode = key
	up.pressed = false
	Input.parse_input_event(up)
	await tree.process_frame


# -------------------------------------------------------------------- teardown

## The run shares one `Cfg` and one save file with every other suite. Anything
## this suite changed is put back, or the next suite asserts against a wallet
## that only exists in this file.
func _teardown() -> void:
	if main != null and is_instance_valid(main):
		if tree.paused:
			tree.paused = false
		await t.drop(main)
	main = null
	if FileAccess.file_exists(Cfg.SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Cfg.SAVE_PATH))
	for v in range(0, Cfg.SAVE_VERSION + 3):
		var q := _quarantine_path(v)
		if FileAccess.file_exists(q):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(q))
	if _save_existed:
		var f := FileAccess.open(Cfg.SAVE_PATH, FileAccess.WRITE)
		f.store_string(_save_text)
		f.close()
	for f in WALLET_FIELDS:
		Cfg.set(f, _was[f])
	for f in WALLET_CONTAINERS:
		Cfg.set(f, _was[f])