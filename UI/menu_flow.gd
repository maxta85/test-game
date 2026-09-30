class_name MenuFlow
extends CanvasLayer
## The front door, as one object. The entry point the game boots into, and the
## only UI type `Game/main.gd` has to know about.
##
##     var menus := MenuFlow.create(graph)      # or MenuFlow.create()
##     add_child(menus)
##     menus.race_start_requested.connect(_start_race)
##     menus.garage_requested.connect(_open_garage)
##     menus.quit_requested.connect(_quit)
##
## It owns the four screens, routes between them, and is the one place that knows
## how they fit together. It does *not* own starting a race, pausing the game or
## opening the garage: those need the world, which the host has and this does not.
## The host calls `show_results(race)` when a race finishes and `set_paused(true)`
## when ESC goes down mid-race.
##
## Money is snapshotted the moment the player commits to a race, because the
## director pays out during the race and the results board has to know what the
## bank said beforehand to show an honest net.

signal race_start_requested(race_id: String)
signal garage_requested()
signal quit_requested()

## Set by `set_paused`. The host stops the world; this only says so.
var paused: bool = false

var _graph: RoadGraph
var _screen: MenuShell = null
var _main: MainMenu
var _select: RaceSelect
var _results: ResultsScreen
var _pause: PauseMenu
var _race_id: String = ""
var _entry_money: int = 0
var _entry_best: float = 0.0


## Builds a menu set. Pass the road graph the game already built - the race list
## is generated from it, and regenerating is ~240 ms on the real map. With no
## graph it builds one, which is what the test suite and a cold `MenuFlow.new()`
## want.
static func create(graph: RoadGraph = null) -> MenuFlow:
	var f := MenuFlow.new()
	f._graph = graph
	return f


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _graph == null:
		_graph = _build_graph()

	_main = MainMenu.new()
	_main.name = "MainMenu"
	add_child(_main)
	_main.start_requested.connect(show_race_select)
	_main.garage_requested.connect(_on_garage)
	_main.quit_requested.connect(_on_quit)

	# setup() before add_child, not after: the screen builds its race list in
	# _ready, and by then the host's graph has to have arrived.
	_select = RaceSelect.new()
	_select.name = "RaceSelect"
	_select.setup(_graph)
	add_child(_select)
	_select.race_chosen.connect(_on_race_chosen)
	_select.back_requested.connect(show_main_menu)

	_results = ResultsScreen.new()
	_results.name = "ResultsScreen"
	add_child(_results)
	_results.race_chosen.connect(_on_race_chosen)
	_results.screen_requested.connect(show_named)
	_results.back_requested.connect(show_main_menu)

	_pause = PauseMenu.new()
	_pause.name = "PauseMenu"
	add_child(_pause)
	_pause.resume_requested.connect(_on_resume)
	_pause.restart_requested.connect(_on_restart)
	_pause.quit_to_menu_requested.connect(_on_pause_quit)
	_pause.back_requested.connect(_on_resume)

	show_main_menu()


## Pausing stops the world, so the flow must not be left holding a tree that is
## frozen: a stray `paused = true` here would hang every later test in the repo.
func _exit_tree() -> void:
	paused = false
	if is_inside_tree():
		get_tree().paused = false


# ---------------------------------------------------------------- navigation

## Which screen is up, for a host that needs to know and for tests that assert it.
func screen_name() -> String:
	if _screen == null or not _screen.visible:
		return "hidden"
	if _screen == _main:
		return "main_menu"
	if _screen == _select:
		return "race_select"
	if _screen == _results:
		return "results"
	return "pause"


func show_main_menu() -> void:
	_enter(_main)
	_main.on_shown()


func show_race_select() -> void:
	_enter(_select)
	_select.on_shown()


## The host calls this the moment a race finishes.
func show_results(race: RaceDirector) -> void:
	if race == null:
		return
	_results.show_result(race.def, race, _entry_money, _entry_best)
	_enter(_results)
	_results.on_shown()


## ESC mid-race. `set_paused(true)` is what actually stops the world.
##
## Resuming does *not* return to the main menu: ESC during a race means "stop",
## and the way out of a race is the explicit QUIT TO MAIN MENU row. A pause that
## navigated somewhere on the way out would put the player in a menu they did not
## ask for, on the wrong side of a race they are still driving.
func set_paused(on: bool) -> void:
	paused = on
	if get_tree() != null:
		get_tree().paused = on
	if on:
		_enter(_pause)
		_pause.on_shown()
	else:
		close()


## Hides every screen: the game is playing, or the race is about to be.
func close() -> void:
	paused = false
	if is_inside_tree():
		get_tree().paused = false
	for s: MenuShell in [_main, _select, _results, _pause]:
		if s != null:
			s.visible = false
	_screen = null


func menu_visible() -> bool:
	return _screen != null and _screen.visible


## The runnable routes on this map, for a host that wants to build a race without
## going through the screen.
func races() -> Array:
	return _select.races if _select != null else []


## The four screens, for a host that wants to read or override part of one.
func main_menu() -> MainMenu:
	return _main


func race_select() -> RaceSelect:
	return _select


func results() -> ResultsScreen:
	return _results


func pause() -> PauseMenu:
	return _pause


## The screen currently up, or null.
func screen() -> MenuShell:
	return _screen


func show_named(name: String) -> void:
	match name:
		"race_select":
			show_race_select()
		"results":
			_enter(_results)
		_:
			show_main_menu()


## The screens are built in `_ready`, which runs the moment the flow is added to
## the tree - before the host's autoloads have finished their own first frame. A
## save loaded there, or any host state set after `create()`, would be one frame
## late on the front page, so read it once more when a frame is really being
## served. One shot: the explicit `on_shown()` calls in `show_*` cover every
## later navigation.
func _process(_delta: float) -> void:
	set_process(false)
	if _screen != null and _screen.visible:
		show_named(screen_name())


func _enter(s: MenuShell) -> void:
	for other in [_main, _select, _results, _pause]:
		if other != null:
			other.visible = other == s
	_screen = s
	if s.has_method("focus_first"):
		s.focus_first()


# ------------------------------------------------------------------ behaviour

## A race is being committed to. Snapshot the wallet and the record *now*: the
## director charges the entry and banks the payout during the race, so by the
## time the results board is asked there is no way left to work out what the
## player started with.
func _on_race_chosen(race_id: String) -> void:
	_race_id = race_id
	_entry_money = Cfg.money
	_entry_best = 0.0
	var d := _find(race_id)
	if d != null:
		_entry_best = float(Cfg.get_race_record(race_id).get("best_time", 0.0))
	close()
	race_start_requested.emit(race_id)


func _on_restart() -> void:
	set_paused(false)
	if _race_id != "":
		_on_race_chosen(_race_id)


func _on_resume() -> void:
	set_paused(false)


## Quitting a race from the pause overlay is the one place the flow both stops the
## pause and navigates, so it has to unpause *and* show the menu rather than
## returning to a frozen tree with a menu nobody can move in.
func _on_pause_quit() -> void:
	set_paused(false)
	show_main_menu()


func _on_garage() -> void:
	garage_requested.emit()


func _on_quit() -> void:
	quit_requested.emit()


func _find(race_id: String) -> RaceDef:
	for d in races():
		if String(d.id) == race_id:
			return d
	return null


## The host may not have built a graph; the real map is preferred and the authored
## block is the fallback, which is the same order `Game/main.gd` uses.
func _build_graph() -> RoadGraph:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors() if OSMLayout.available() else ManundaLayout.corridors())
	return g
