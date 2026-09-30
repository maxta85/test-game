class_name RaceSelect
extends MenuShell
## Choosing a route. The list on the left, everything the player needs to decide
## on the right, and the money it costs stated before they commit to it.
##
## Races that could not be generated from the real street network are not shown.
## That is not tidiness: on the OSM grid `RaceDef.catalogue` returns a touge run
## with an empty path, and offering a player a "route" that does not exist is the
## one bug this screen exists to prevent.

signal race_chosen(race_id: String)

var graph: RoadGraph
## Only the ones that are actually runnable on this map.
var races: Array = []
var selected: int = 0

var _rows: Array[Button] = []
var _pips: Array[ColorRect] = []
var _name: Label
var _kind: Label
var _stats: Label
var _fee: Label
var _best: Label
var detail: Control
var _start: Button
var _detail_title: Label


## Hands in the road graph and works out which of its races are runnable. Called
## by the host before the screen is added; without it the screen builds its own
## list from `graph` in _ready.
func setup(g: RoadGraph) -> void:
	graph = g
	races = setup_races()


func _ready() -> void:
	super()
	set_title("CHOOSE A ROUTE")
	set_kicker("TONIGHT'S BOARD")
	set_note("")
	set_hint("↑↓  BROWSE        ENTER  START        ESC  BACK")
	if races.is_empty():
		races = setup_races()
	_body()
	focus_first()


## The catalogue, minus anything the map could not produce.
func setup_races() -> Array:
	var out: Array = []
	if graph == null:
		return out
	for d in RaceDef.catalogue(graph):
		if d.valid():
			out.append(d)
	return out


# ----------------------------------------------------------------------- body

func _body() -> void:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = MARGIN
	row.offset_right = -MARGIN
	row.offset_top = 8.0
	row.offset_bottom = -8.0
	row.add_theme_constant_override("separation", 48)
	body.add_child(row)
	row.add_child(_list())
	detail = _detail()
	row.add_child(detail)


func _list() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(560.0, 0.0)
	col.add_theme_constant_override("separation", 0)
	col.add_child(UIPalette.label("ROUTES", UIPalette.SIZE_KICKER, UIPalette.SODIUM))
	col.add_child(UIPalette.spacer(10.0))
	for i in races.size():
		var d: RaceDef = races[i]
		var b := UIPalette.button(d.display_name.to_upper(), UIPalette.SIZE_ROW)
		b.custom_minimum_size = Vector2(0.0, 62.0)
		var kind := UIPalette.label(d.kind_name().to_upper(), UIPalette.SIZE_META,
			UIPalette.FAINT, HORIZONTAL_ALIGNMENT_RIGHT)
		kind.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		kind.offset_left = -200.0
		kind.offset_right = -18.0
		kind.offset_top = 0.0
		kind.offset_bottom = 62.0
		kind.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_child(kind)
		col.add_child(b)
		_rows.append(b)
		# Focus drives selection, not the other way round: whichever way the player
		# arrives - arrow key, Tab, or a mouse click - the details follow them.
		b.focus_entered.connect(_select.bind(i))
		wire_row(b, _select.bind(i))
	if races.is_empty():
		col.add_child(UIPalette.label(
			"No route could be generated from this map.",
			UIPalette.SIZE_BODY, UIPalette.MAGENTA))
	return col


func _detail() -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIPalette.panel())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	card.add_child(col)

	_detail_title = UIPalette.label("", UIPalette.SIZE_HEAD, UIPalette.TEXT)
	col.add_child(_detail_title)
	_kind = UIPalette.label("", UIPalette.SIZE_META, UIPalette.SODIUM)
	col.add_child(_kind)
	col.add_child(UIPalette.spacer(14.0))
	col.add_child(UIPalette.rule())
	col.add_child(UIPalette.spacer(14.0))

	_stats = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.TEXT)
	col.add_child(_stats)
	col.add_child(UIPalette.spacer(16.0))
	col.add_child(_difficulty())
	col.add_child(UIPalette.spacer(20.0))
	col.add_child(UIPalette.rule())
	col.add_child(UIPalette.spacer(16.0))

	_fee = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.CASH)
	col.add_child(_fee)
	_best = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.MERCURY)
	col.add_child(_best)
	col.add_child(UIPalette.spacer(22.0))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 20)
	col.add_child(actions)
	_start = UIPalette.button("START RACE", UIPalette.SIZE_ROW)
	_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_start)
	wire_row(_start, _start_pressed)
	return card


## Difficulty as pips rather than a number: "3" is a spreadsheet, five lit blocks
## is something a player reads while deciding.
func _difficulty() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(UIPalette.label("DIFFICULTY", UIPalette.SIZE_META, UIPalette.FAINT))
	for i in 5:
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(26.0, 10.0)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pip)
		_pips.append(pip)
	return row


# ------------------------------------------------------------------ selection

func _select(i: int) -> void:
	if races.is_empty():
		return
	selected = clampi(i, 0, races.size() - 1)
	var d: RaceDef = races[selected]
	_detail_title.text = d.display_name.to_upper()
	_kind.text = "%s   ·   %s" % [d.kind_name().to_upper(),
		("LAPPED  %d" % d.laps) if d.closed else "POINT TO POINT"]
	_stats.text = "%s   ·   %d opponents   ·   %d entrants" % [
		UIPalette.metres(d.length_m(graph)), maxi(d.opponents, 0), maxi(d.opponents, 0) + 1]

	for p in _pips.size():
		var lit := p < d.difficulty
		_pips[p].color = UIPalette.SODIUM if lit else Color(UIPalette.RULE.r,
			UIPalette.RULE.g, UIPalette.RULE.b, 0.55)

	var afford := d.entry_fee <= Cfg.money
	_fee.text = "ENTRY  %s      PAYOUT  %s" % [
		UIPalette.money(-d.entry_fee), UIPalette.money(d.payout)]
	_fee.add_theme_color_override("font_color",
		UIPalette.CASH if afford else UIPalette.MAGENTA)
	if not afford:
		_fee.text += "      NOT ENOUGH CASH"

	var rec := Cfg.get_race_record(d.id)
	_best.text = ("YOUR BEST  %s   (lap %s)" % [UIPalette.clock(float(rec.get("best_time", -1.0))),
		UIPalette.clock(float(rec.get("best_lap", -1.0)))]) if rec.has("best_time") \
		else "NOT RUN YET"

	_start.disabled = not afford
	_start.text = "START RACE" if afford else "NEED %s" % UIPalette.money(
		d.entry_fee - Cfg.money)
	refresh_status()


func _start_pressed() -> void:
	if _start.disabled:
		return
	var d: RaceDef = races[selected]
	race_chosen.emit(d.id)


## Called by the host every time this screen is shown: the wallet moved while it
## was away, and an entry that was affordable a race ago may not be now.
func on_shown() -> void:
	refresh_status()
	if not races.is_empty():
		_select(selected)


## The commit button, so a host or a test can ask whether the selected route is
## currently enterable instead of hunting for it in the tree.
func start_button() -> Button:
	return _start


func selected_race() -> RaceDef:
	return races[selected] if not races.is_empty() else null
