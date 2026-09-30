extends RefCounted
## Front-of-house UI. Run with: ./test.sh ui
##
## These drive the menus the way a player does - focus a row, press Enter, click
## it, assert the screen changed - rather than checking that nodes exist. That
## distinction is not pedantry: the interesting menu failures (a row that is
## present but unreachable, a button that fires but changes nothing, a screen that
## comes back stale) are all invisible to a structural assertion.
##
## Measured, not assumed. The measurements and what they forced:
##   - the headless root viewport is 1600x1600, not the 1600x900 the game runs at,
##     so this suite has been checking a different aspect ratio from the game the
##     whole time; a layout that hard-codes a position fails here and nowhere else
##   - `Input.parse_input_event` reaches a focused Button and reaches
##     `_unhandled_input`; `Input.action_press` reaches neither
##   - `Viewport.push_input` delivers a real mouse click; `Input.parse_input_event`
##     does not
##   - Godot's own arrow-key focus traversal never fires headless, which is why
##     MenuShell owns the focus order instead of delegating it
##   - on the real OSM map `RaceDef.catalogue` returns a touge run with an empty
##     path, which is why the board filters on `valid()`

## The only thing RaceDirector needs from an entrant, so the results board can be
## shown without building a physics world.
class StubCar extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var facing: Vector3 = Vector3.FORWARD


var t: TestHarness
var tree: SceneTree
var flow: MenuFlow
var g: RoadGraph


func run(t: TestHarness) -> void:
	self.t = t
	tree = t.tree
	g = RoadGraph.new()
	g.build(OSMLayout.corridors() if OSMLayout.available() else ManundaLayout.corridors())
	flow = MenuFlow.create(g)
	tree.root.add_child(flow)
	# `Cfg._ready()` runs on the first processed frame, not at add_child, and on a
	# save it has never seen it hands out a starting slot. Once the tree is
	# actually ticking, the wallet is ours to set.
	await tree.process_frame
	Cfg.money = 2000
	Cfg.owned_cars = ["kairo_s13", "hayate_turbo"]
	Cfg.active_car = "kairo_s13"
	# The header is painted from Cfg when the screens are built, which happened
	# during add_child above - before the wallet was ours to set. Re-show the
	# front page so the chrome is derived from the state the rest of the suite
	# assumes, exactly as it would be if the host opened the menu after a save.
	flow.show_main_menu()
	await tree.process_frame

	await _boot(t)
	await _main_menu(t)
	await _race_select(t)
	await _mouse(t)
	await _affordability(t)
	await _results(t)
	await _pause(t)
	await _layout_is_not_guessed(t)
	await _teardown(t)


# ----------------------------------------------------------------- test driver

## Focus a row and press Enter, exactly as a player does. Focus is set explicitly
## because walking it with the arrow keys is the screen's job, and is asserted
## separately in _main_menu and _pause.
func _enter_on(c: Control) -> void:
	c.grab_focus()
	await tree.process_frame
	await _key(KEY_ENTER)


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await tree.process_frame


## A real left click at a control's centre, through the viewport's input queue.
func _click(c: Control) -> void:
	var p := c.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = p
		ev.global_position = p
		tree.root.push_input(ev, true)
		await tree.process_frame


func _focused() -> Control:
	var o := tree.root.gui_get_focus_owner()
	return o if o != null and is_instance_valid(o) else null


func _focused_text() -> String:
	var o := _focused()
	return String((o as Button).text) if o is Button else ""


## A screen's row by position in its focus order.
func _row(s: MenuShell, i: int) -> Button:
	return s.focusables[i] as Button


## Everything a screen is showing, as one string, so an assertion can be about
## what the player reads rather than about which node holds it.
func _text_of(c: Node) -> String:
	var out: Array[String] = []
	_collect_text(c, out)
	return "|".join(out)


func _collect_text(c: Node, out: Array[String]) -> void:
	if c is Label or c is Button:
		var s := String((c as Label).text) if c is Label else String((c as Button).text)
		if s != "":
			out.append(s)
	for child in c.get_children():
		_collect_text(child, out)


func _show(name: String) -> void:
	flow.set_paused(false)
	if name == "pause":
		flow.set_paused(true)
	else:
		flow.show_named(name)
	await tree.process_frame


# ---------------------------------------------------------------------- cases

## The flow lands on the main menu by itself, with the runnable routes in hand.
func _boot(t: TestHarness) -> void:
	t.eq(flow.screen_name(), "main_menu", "the game lands on the main menu")
	t.ok(flow.menu_visible(), "the menu is on screen")
	t.gt(float(flow.races().size()), 2.0,
		"the race board has routes to pick from (%d)" % flow.races().size())
	for d in flow.races():
		t.ok(d.valid(), "%s is a route that exists on this map" % d.display_name)
	t.eq(_row(flow.main_menu(), 0).text, "START RACE", "the first row is START RACE")
	t.eq(flow.main_menu().focus_count(), 4, "every main-menu row is in the focus order")
	t.eq(_focused_text(), "START RACE", "the menu opens with START RACE under the cursor")

	# The header is the player's persistent state, and it has to be right before a
	# race is ever run.
	var header := _text_of(flow.main_menu().root)
	t.ok(header.contains(UIPalette.money(2000)), "the wallet is on the front page")
	t.ok(header.contains("KAIRO S13"), "and so is the car being driven")


## Walking the menu with the arrow keys and committing with Enter. This is the
## spine of the front door: main menu -> race select -> a race id.
func _main_menu(t: TestHarness) -> void:
	var menu := flow.main_menu()

	await _key(KEY_DOWN)
	t.eq(_focused_text(), "GARAGE", "DOWN moves down one row")
	await _key(KEY_UP)
	t.eq(_focused_text(), "START RACE", "UP moves back up")
	await _key(KEY_UP)
	t.eq(_focused_text(), "QUIT", "UP from the first row wraps round to the last")
	await _key(KEY_DOWN)
	t.eq(_focused_text(), "START RACE", "and DOWN from the last wraps round to the first")

	# The garage is somebody else's screen: its row must ask the host for it rather
	# than silently doing nothing or guessing at a class name.
	var garage: Array[String] = []
	flow.garage_requested.connect(func(): garage.append("asked"))
	await _enter_on(_row(menu, 1))
	t.eq(garage, ["asked"], "GARAGE hands the request to the host")
	t.eq(flow.screen_name(), "main_menu", "and stays where it is until the host answers")

	# CONTROLS is a reference, not a page: it opens in place, closes from the same
	# row, and the focus stays on the row that opened it.
	await _enter_on(_row(menu, 2))
	t.ok(_text_of(menu.body).contains("CONTROLS"), "the key map opens over the menu")
	t.ok(_text_of(menu.body).contains("Throttle"), "and it lists what is bound")
	# The focus has to stay on the row that opened the legend. If it does not,
	# the next arrow key throws the player straight out of the screen they just
	# opened, and the arrow they pressed meant nothing.
	t.eq(_focused(), _row(menu, 2), "opening the key map does not steal the focus")
	await _enter_on(_row(menu, 2))
	t.fails(_text_of(menu.body).contains("Throttle"), "the same row closes it again")
	t.eq(_row(menu, 2).text, "CONTROLS", "and puts its own label back")

	await _enter_on(_row(menu, 0))
	t.eq(flow.screen_name(), "race_select", "START RACE opens the race board")


## Browsing routes with the keyboard moves the detail panel with the player, and
## the panel describes the route being looked at rather than the previous one.
func _race_select(t: TestHarness) -> void:
	var sel := flow.race_select()
	t.eq(sel.focus_count(), sel.races.size() + 1,
		"every route plus START is in the focus order")
	t.eq(_focused_text(), sel.races[0].display_name.to_upper(),
		"the board opens on the first route")

	await _key(KEY_DOWN)
	var second: RaceDef = sel.races[1]
	var first: RaceDef = sel.races[0]
	t.eq(_focused_text(), second.display_name.to_upper(), "DOWN moves to the next route")
	t.eq(sel.selected, 1, "and the board follows the focus")
	var panel := _text_of(sel.detail)
	t.ok(panel.contains(second.display_name.to_upper()), "the detail panel shows that route")
	t.fails(panel.contains(first.display_name.to_upper()),
		"and is no longer showing the one before it")
	t.ok(panel.contains(second.kind_name().to_upper()), "the panel names the kind of race")
	t.ok(panel.contains("ENTRY"), "the panel states the entry fee")
	t.ok(panel.contains("PAYOUT"), "and what it pays")
	t.ok(panel.contains(UIPalette.metres(second.length_m(g))), "and how far it is")
	t.between(float(second.difficulty), 1.0, 5.0, "difficulty is on the 1..5 scale")

	# The last route, then one past the end: the order wraps. The focus is already
	# on route `sel.selected`, so count what is left rather than guessing.
	for i in sel.focus_count() - 1 - sel.selected:
		await _key(KEY_DOWN)
	t.eq(_focused(), sel.start_button(), "the walk ends on START RACE")
	await _key(KEY_DOWN)
	t.eq(_focused_text(), sel.races[0].display_name.to_upper(), "and wraps to the top")

	await _key(KEY_ESCAPE)
	t.eq(flow.screen_name(), "main_menu", "ESC goes back to the main menu")
	await _enter_on(_row(flow.main_menu(), 0))
	t.eq(flow.screen_name(), "race_select", "and START RACE brings the board back")


## Nothing is mouse-only, and nothing is keyboard-only either: every destination
## is a real click target as well as a real focus target.
func _mouse(t: TestHarness) -> void:
	var menu := flow.main_menu()
	await _click(_row(menu, 0))
	t.eq(flow.screen_name(), "race_select", "a click on START RACE opens the board")

	var sel := flow.race_select()
	await _click(_row(sel, 1))
	t.eq(sel.selected, 1, "a click on a route selects it, not just hovers it")
	t.eq(_focused_text(), sel.races[1].display_name.to_upper(),
		"and brings the focus with it, so Enter works next")
	var row3 := _row(sel, sel.races.size() - 1)
	await _click(row3)
	t.eq(sel.selected, sel.races.size() - 1, "a click further down the list works too")

	# Back to the front page, so the next case starts where a player would be.
	flow.show_main_menu()
	await tree.process_frame


## The entry fee is a real gate. A route the player cannot enter has to say so on
## the board and has to be impossible to start, not discovered as a failed race.
func _affordability(t: TestHarness) -> void:
	var sel := flow.race_select()
	var started: Array[String] = []
	flow.race_start_requested.connect(func(id: String): started.append(id))

	Cfg.money = 0
	sel.on_shown()
	await tree.process_frame
	t.ok(sel.start_button().disabled, "START is not offered on a route nobody can enter")
	t.ok(_text_of(sel.body).contains("NOT ENOUGH CASH"),
		"and the board says why rather than just greying out")

	# Even if the focus somehow lands on it, walking the whole order must not
	# reach a disabled row.
	var landed := false
	for i in sel.focus_count() + 2:
		await _key(KEY_DOWN)
		if _focused() == sel.start_button():
			landed = true
	t.fails(landed, "the focus walk never lands on a disabled START")
	await _key(KEY_ENTER)
	t.eq(started, [], "so no race can be started from a board the player cannot pay for")

	Cfg.money = 2000
	sel.on_shown()
	await tree.process_frame
	t.fails(sel.start_button().disabled, "affording it again re-opens the start")
	t.eq(sel.start_button().text, "START RACE", "and the label goes back to normal")


## A finished race: the classification reads, the net is the measured difference
## between the wallet before and after, and the way out works.
func _results(t: TestHarness) -> void:
	var sel := flow.race_select()
	var d: RaceDef = sel.races[1]
	var started: Array[String] = []
	flow.race_start_requested.connect(func(id: String): started.append(id))
	flow.show_race_select()
	await tree.process_frame

	# Commit the way a player does, so the flow snapshots the wallet exactly where
	# it claims to.
	var bank := Cfg.money
	await _enter_on(_row(sel, 1))
	await _enter_on(sel.start_button())
	t.eq(started, [d.id], "START RACE asks the host for that route's id")
	t.eq(flow.screen_name(), "hidden", "and the menus get out of the way for it")
	t.eq(Cfg.money, bank, "nothing has been charged yet - that is the director's job")

	# Run it to the flag with stub cars, the way test_race does.
	var dr := _run_race(d)
	t.eq(dr.state_name(), "finished", "the race ran to the flag")
	var paid: int = dr.payout_for_position(dr.position_of(dr.entrants[0]))
	var net := Cfg.money - bank

	flow.show_results(dr)
	t.eq(flow.screen_name(), "results", "the results come up when the race is over")
	var board := _text_of(flow.results().body)
	t.ok(board.contains("FINISHED"), "a race run to the flag says FINISHED")
	t.fails(board.contains("RETIRED"), "and does not also claim a retirement")
	t.ok(board.contains("YOU"), "the player's row is on the board")
	t.ok(board.contains(d.display_name.to_upper()), "and the route is named")
	t.ok(board.contains("PAID  %s" % UIPalette.money(paid)), "the payout is shown")
	t.ok(board.contains("NET  %s" % UIPalette.money(net)),
		"and the net is what actually moved in the wallet")

	# A record is judged against what the player had going in, not against the
	# record the director has already written for this run.
	flow.results().show_result(d, dr, bank, 0.0)
	t.ok(_text_of(flow.results().body).contains("NEW BEST"),
		"a run better than the profile's best is a new best")
	flow.results().show_result(d, dr, bank, 0.01)
	t.fails(_text_of(flow.results().body).contains("NEW BEST"),
		"a run slower than a best already on the profile is not")

	# The three ways out all go somewhere.
	flow.show_named("race_select")
	t.eq(flow.screen_name(), "race_select", "RACE SELECT is somewhere to go")
	flow.show_named("main_menu")
	t.eq(flow.screen_name(), "main_menu", "and so is MAIN MENU")

	# RETRY asks for the same route again - a retry is a new entry, so it comes
	# back through the same signal the first one did.
	started.clear()
	flow.show_named("results")
	await tree.process_frame
	await _enter_on(_row(flow.results(), 0))
	t.eq(started, [d.id], "RETRY asks the host to run the same route again")
	flow.show_main_menu()
	await tree.process_frame


## A stub-driven race, the whole way to the flag. Laps are driven through every
## checkpoint rather than teleported onto the line, because a results board tested
## against a race that skipped the rules proves nothing about the board.
func _run_race(d: RaceDef) -> RaceDirector:
	var dr := RaceDirector.new()
	dr.wallet = Cfg
	dr.try_enter(d)
	var field: Array = [StubCar.new(), StubCar.new()]
	assert(dr.start(d, g, field), "the test race should start")
	dr.tick(4.0)
	var dir := dr.line_direction()
	for lap in maxi(d.laps, 1):
		for p in dr.route_points():
			field[0].position = Vector3(p.x, 0.0, p.y)
			field[0].facing = Vector3(dir.x, 0.0, dir.y)
			dr.tick(0.05)
	dr.tick(0.05)
	return dr


## Pause: it stops the world, every row goes somewhere, and it does not leave the
## tree frozen. A stray pause here would hang every later suite in the repo.
func _pause(t: TestHarness) -> void:
	t.fails(tree.paused, "the world is running before any pause")
	flow.set_paused(true)
	await tree.process_frame
	t.eq(flow.screen_name(), "pause", "the pause overlay comes up")
	t.ok(tree.paused, "and the world stops")
	t.ok(flow.paused, "the flow is the one that asked for it")
	t.eq(_focused_text(), "RESUME", "the focus starts on RESUME")
	t.ok(_text_of(flow.pause().body).contains("RESTART RACE"), "RESTART RACE is on the board")
	t.ok(_text_of(flow.pause().body).contains("QUIT TO MAIN MENU"), "and so is the way out")
	t.ok(_text_of(flow.pause().body).contains("Throttle"),
		"the controls are on the one screen where a player is guaranteed to want them")

	await _key(KEY_DOWN)
	t.eq(_focused_text(), "RESTART RACE", "DOWN reaches RESTART RACE")
	await _key(KEY_DOWN)
	t.eq(_focused_text(), "QUIT TO MAIN MENU", "and QUIT TO MAIN MENU")

	await _key(KEY_ESCAPE)
	t.eq(flow.screen_name(), "hidden", "ESC again goes back to the race")
	t.fails(tree.paused, "and the world runs again")
	t.fails(flow.menu_visible(), "with the menus out of the way")

	# Quitting a race is the explicit row, not a side effect of stopping.
	flow.set_paused(true)
	await tree.process_frame
	await _enter_on(_row(flow.pause(), 2))
	t.eq(flow.screen_name(), "main_menu", "QUIT TO MAIN MENU lands on the front page")
	t.fails(tree.paused, "and leaves the world running, so the menu is usable")

	flow.set_paused(true)
	await tree.process_frame
	await _enter_on(_row(flow.pause(), 0))
	t.fails(tree.paused, "RESUME releases the world")
	t.fails(flow.menu_visible(), "and puts the menus away")


## A layout that only works at 1600x900 is a layout that is broken. This suite runs
## at 1600x1600, so "everything is anchored, nothing is a hard-coded position" is
## the property under test: every screen and every row has to land inside the
## viewport that actually exists, at whatever size that is.
func _layout_is_not_guessed(t: TestHarness) -> void:
	var vp := tree.root.get_visible_rect().size
	t.near(vp.x, 1600.0, 1.0, "the headless viewport is measured, not assumed")
	for name in ["main_menu", "race_select", "results", "pause"]:
		await _show(name)
		var s := flow.screen()
		t.eq(flow.screen_name(), name, "%s is the screen that is up" % name)
		_inside(t, s.body, vp, "%s body" % name)
		for i in s.focus_count():
			_inside(t, s.focusables[i], vp, "%s row %d is on screen" % [name, i])
	flow.show_main_menu()
	await tree.process_frame


func _inside(t: TestHarness, c: Control, vp: Vector2, label: String) -> void:
	var r := c.get_global_rect()
	t.ok(r.position.x >= -1.0 and r.position.y >= -1.0
			and r.end.x <= vp.x + 1.0 and r.end.y <= vp.y + 1.0,
		"%s (%d,%d %dx%d)" % [label, r.position.x, r.position.y, r.size.x, r.size.y])


func _teardown(t: TestHarness) -> void:
	flow.set_paused(false)
	flow.queue_free()
	await tree.process_frame
	t.fails(tree.paused, "the tree is running again after the UI suite is done")
	t.fails(is_instance_valid(flow), "and the flow let go of the tree")
