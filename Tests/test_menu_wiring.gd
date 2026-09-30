extends RefCounted
## Cold boot -> main menu -> garage -> a car of the player's own choosing -> race
## -> results -> the money moved. Run with: ./test.sh menu_wiring
##
## `Tests/test_ui.gd` proves the menus navigate and emit. This proves something is
## on the other end of those signals: it boots the real `Game/main.gd`, drives it
## the way the game does - the flow's own signals, the garage screen's own button -
## and asserts against the real world, the real director and the real wallet, never
## against the host's private state. Before this suite the whole slice was
## reachable only by hand: six references to `UI/` existed in the codebase and none
## of them were in the game.
##
## The one thing stubbed is the driving. The player's car is stepped along the
## route the director is scoring rather than driven round Cairns for two minutes -
## the director reads position and facing and nothing else, no throttle and no
## speed, so that is the input a real lap produces at a fraction of the cost. The
## countdown, the checkpoints, the line and the payout are all the real ones.

var t: TestHarness
var tree: SceneTree
var main: Node3D
## The profile as this suite found it. `Cfg` is a singleton the whole run shares,
## and the header a menu screen shows is only re-read when a screen comes up - so a
## suite that leaves a car selected changes what the next suite's screens say.
var _was_money := 0
var _was_active := ""


func run(t: TestHarness) -> void:
	self.t = t
	tree = t.tree
	await _cold_boot(t)
	await _the_garage(t)
	await _the_race(t)
	await _the_pause(t)
	await _the_results(t)
	await _teardown(t)


## The game as it boots for a player who has never driven before.
func _cold_boot(t: TestHarness) -> void:
	_was_money = int(Cfg.money)
	_was_active = String(Cfg.active_car)
	main = load("res://Game/main.gd").new()
	tree.root.add_child(main)
	# `Cfg._ready()` runs on the first served frame, not at add_child, and a save
	# this machine has seen would hand it a wallet of its own. Once the tree is
	# really ticking, the profile is this suite's to set.
	await tree.process_frame
	Cfg.money = 1500
	Cfg.owned_cars = ["kairo_s13", "hayate_turbo"]
	Cfg.active_car = "kairo_s13"

	t.ok(main.menus != null, "a cold boot brings the menus up")
	t.eq(String(main.menus.screen_name()), "main_menu", "and lands on the main menu")
	t.eq(String(main.race.state_name()), "idle", "with no race running")
	t.fails(main.hud.visible, "and the HUD out of the way")
	t.ok(main.player_car != null, "and the player already in a car")
	t.ok(main.player_car.spec != null, "with a spec for it")
	t.gt(float(main.menus.races().size()), 0.0, "and a board of routes to pick from (%d)" % main.menus.races().size())
	for d in main.menus.races():
		t.ok(d.valid(), "%s is a route that exists on this map" % d.display_name)


## The garage is a host screen: the flow routes the four menu screens and reports
## that the player asked for this one, and nothing in `UI/` builds it.
func _the_garage(t: TestHarness) -> void:
	main.menus.garage_requested.emit()
	await tree.process_frame
	t.ok(main.garage_screen != null, "the garage request opens the garage")
	t.ok(main.garage_screen.visible, "in front of the player")
	t.fails(main.menus.menu_visible(), "with the menus out of the way")
	t.fails(main.hud.visible, "and the HUD still down")

	# Browsing is not choosing: the screen draws whatever car it is handed and
	# reads the profile through `garage.selected()`, so nothing moves until
	# something commits the choice. That something is the host, which is what
	# `car_selected` is for.
	main.garage_screen.car_selected.emit("hayate_turbo")
	t.eq(String(Cfg.active_car), "hayate_turbo", "the car the garage showed is the one on the profile")

	var old_body: CarBody = main.player_car
	var go := _button(main.garage_screen, "START RACE")
	t.ok(go != null, "the garage has a way to commit")
	if go == null:
		return
	go.pressed.emit()
	await tree.process_frame
	t.eq(String(main.player_car.spec.id), "hayate_turbo", "and the committed car is the one being driven")
	t.ok(main.player_car != old_body, "on a body built for it")
	t.fails(is_instance_valid(old_body) and old_body.spec == main.player_car.spec,
		"not the one that was there before")
	t.fails(main.garage_screen.visible, "the garage closes behind it")
	t.eq(String(main.menus.screen_name()), "race_select", "and the board is up to pick a route from")


## The board committed to a route: the entry is paid, the chosen car is on the
## grid, the lights go out.
func _the_race(t: TestHarness) -> void:
	var board: Array = main.menus.races()
	var d: RaceDef = board[0]
	var fee := int(d.entry_fee)
	var purse := int(Cfg.money)

	main.menus.race_select().race_chosen.emit(String(d.id))
	await tree.process_frame
	t.eq(String(main.race.state_name()), "countdown", "the chosen route goes to the lights")
	t.eq(String(main.race.def.id), String(d.id), "and it is the one that was chosen")
	t.eq(String(main.player_car.spec.id), "hayate_turbo", "in the car the garage was left in")
	t.eq(main.race.entrants.size(), 2, "against the one rival on the grid")
	t.eq(int(Cfg.money), purse - fee, "the entry fee is paid on entry")
	t.ok(main.hud.visible, "with the HUD up")
	t.fails(main.menus.menu_visible(), "and the menus out of the way")

	# COUNTDOWN_TIME is 3.0 s, so 180 ticks at 60 Hz, not 90 - the run ends the
	# lights out before it has counted them.
	for i in int(RaceDirector.COUNTDOWN_TIME * 60.0) + 30:
		await t.ticks(1)
		if main.race.state == RaceDirector.State.RACING:
			break
	t.eq(String(main.race.state_name()), "racing", "the lights go out")


## ESC is the host's job. The flow has the pause board and cannot stop the world;
## a menu that shows over a race still running would be a lie about the state.
func _the_pause(t: TestHarness) -> void:
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	await t.ticks(2)

	t.ok(main.menus.paused, "ESC mid-race raises the pause board")
	t.eq(String(main.menus.screen_name()), "pause", "which is the screen up")
	t.ok(tree.paused, "and the world is stopped")

	var clock := float(main.race.race_time)
	for i in 30:
		await t.ticks(1)
	t.eq(float(main.race.race_time), clock, "the race clock does not move while paused")

	main.menus.set_paused(false)
	await t.ticks(2)
	t.fails(main.menus.paused, "and resuming puts it back")
	t.fails(tree.paused, "world and all")


## Drive it in, then check what the player is left with.
func _the_results(t: TestHarness) -> void:
	var d: RaceDef = main.race.def
	var fee := int(d.entry_fee)
	var purse := int(Cfg.money) + fee
	await _drive_it_in()
	await t.ticks(2)

	t.eq(String(main.race.state_name()), "finished", "the race finishes")
	t.eq(String(main.menus.screen_name()), "results", "and the results come up by themselves")
	t.fails(main.hud.visible, "with the HUD out of the way")
	t.ok(main.race.results.size() > 0, "off a real classification")
	var names := ""
	for r in main.race.results:
		var e: RaceEntrant = r["car"]
		if e != null and e.car != null:
			names += String(e.car.name) + " "
	t.ok(names.contains("PlayerCar"), "and the player is classified in it (%s)" % names.strip_edges())

	var paid := int(main.race.payout_for_position(_place_of_the_player()))
	t.eq(int(Cfg.money), purse - fee + paid,
		"the payout lands on top of the entry the player paid (%d - %d + %d)" % [purse, fee, paid])
	t.ok(Cfg.get_race_record(String(d.id)).has("best_time"), "and the time is on the profile")

	var board := _text_of(main.menus.results().root)
	t.ok(board.contains(UIPalette.money(paid - fee)),
		"the results show the net the race was worth (%s)" % UIPalette.money(paid - fee))
	t.ok(board.contains(String(d.display_name).to_upper()), "and the route they raced")


## Steps the car along the route the director is scoring. Velocity goes with it so
## the body reads as moving: parked against the scenery, `main.gd` decides it is
## stuck, recovers it to the nearest road, and the run stops being the route's.
func _drive_it_in() -> void:
	var car: CarBody = main.player_car
	var pts: Array = main.race.route_points()
	if pts.size() < 2:
		return
	var y := car.global_position.y
	for lap in int(main.race.def.laps):
		# One step past the end of the route, or the last pass never puts the car
		# back through the line it started on.
		for i in range(pts.size() + 1):
			var a: Vector2 = pts[i % pts.size()]
			var b: Vector2 = pts[(i + 1) % pts.size()]
			car.global_position = Vector3(a.x, y, a.y)
			car.linear_velocity = Vector3(b.x - a.x, 0.0, b.y - a.y).normalized() * 12.0
			await t.ticks(1)
			if main.race.state == RaceDirector.State.FINISHED:
				return


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


func _teardown(t: TestHarness) -> void:
	await t.drop(main)
	main = null
	Cfg.money = _was_money
	Cfg.active_car = _was_active
