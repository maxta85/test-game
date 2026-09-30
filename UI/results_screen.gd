class_name ResultsScreen
extends MenuShell
## Where a race ends up. Classification, what it paid, and three ways back out.
##
## The net figure is measured, not derived: the host snapshots the wallet before
## the race is committed to and hands it in here, so the number shown is the
## difference between the two. Re-deriving it from the payout formula would be
## one more place for the board to disagree with what the director actually paid
## - and it does disagree whenever entry is refused and the race is run free.

## Emitted for the two destinations that are not a retry.
signal screen_requested(screen: String)
## RETRY: the same route again. A retry is a new entry, so it goes back out
## through the same signal the first start did rather than inventing a second way
## for the host to wire up.
signal race_chosen(race_id: String)

const DESTINATIONS := ["race_select", "main_menu"]

var _def: RaceDef = null
var _banner: Label
var _sub: Label
var _table: VBoxContainer
var _money: Label
var _record: Label
var _retry: Button


## `before` is the wallet as it stood when the player committed to the race, and
## `previous_best` their best time on this route going in - the only way to know
## whether the run just set a record, because the director has already written
## the new one by the time anything can ask.
func show_result(def: RaceDef, race: RaceDirector, before: int, previous_best: float) -> void:
	_def = def
	refresh_status()
	var finished := _player_finished(race)
	_banner.text = "FINISHED" if finished else "RETIRED"
	_banner.add_theme_color_override("font_color",
		UIPalette.TEXT if finished else UIPalette.MAGENTA)
	_sub.text = def.display_name.to_upper() if def != null else ""

	_fill_table(race)

	var pos := _player_position(race)
	var paid: int = race.payout_for_position(pos) if race != null else 0
	var fee: int = def.entry_fee if def != null else 0
	var net := Cfg.money - before
	_money.text = "ENTRY  %s        PAID  %s        NET  %s" % [
		UIPalette.money(-fee), UIPalette.money(paid), UIPalette.money(net)]
	_money.add_theme_color_override("font_color",
		UIPalette.CASH if net >= 0 else UIPalette.MAGENTA)

	var now := _player_time(race)
	var record := now > 0.0 and (previous_best <= 0.0 or now < previous_best)
	_record.text = "NEW BEST  %s" % UIPalette.clock(now) if record else \
		("BEST  %s" % UIPalette.clock(now if now > 0.0 else previous_best))
	_record.add_theme_color_override("font_color",
		UIPalette.SODIUM if record else UIPalette.MERCURY)

	_retry.disabled = def == null


func on_shown() -> void:
	refresh_status()
	if _def != null:
		_sub.text = _def.display_name.to_upper()


# ----------------------------------------------------------------------- body

func _ready() -> void:
	super()
	set_title("RESULTS")
	set_kicker("CHEQUERED FLAG")
	set_hint("↑↓  SELECT        ENTER  CONFIRM        ESC  MAIN MENU")
	_body()
	focus_first()


func _body() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = MARGIN
	col.offset_right = -MARGIN
	col.offset_top = 0.0
	col.offset_bottom = 0.0
	col.add_theme_constant_override("separation", 4)
	body.add_child(col)

	_banner = UIPalette.label("", UIPalette.SIZE_HERO, UIPalette.TEXT)
	col.add_child(_banner)
	_sub = UIPalette.label("", UIPalette.SIZE_HEAD, UIPalette.SODIUM)
	col.add_child(_sub)
	col.add_child(UIPalette.spacer(16.0))
	col.add_child(UIPalette.rule())
	col.add_child(UIPalette.spacer(10.0))

	_table = VBoxContainer.new()
	_table.add_theme_constant_override("separation", 0)
	col.add_child(_table)

	col.add_child(UIPalette.spacer(14.0))
	col.add_child(UIPalette.rule())
	col.add_child(UIPalette.spacer(14.0))
	_money = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.CASH)
	col.add_child(_money)
	_record = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.MERCURY)
	col.add_child(_record)
	col.add_child(UIPalette.spacer(20.0))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 20)
	col.add_child(actions)
	_retry = _action("RETRY", actions)
	wire_row(_retry, _on_retry)
	for i in DESTINATIONS.size():
		var dest: String = DESTINATIONS[i]
		var b := _action(dest.replace("_", " ").to_upper(), actions)
		wire_row(b, _on_destination.bind(dest))


## Builds a screen action and adds it to the given row. Focus order is the
## caller's business, so they say when they want it walked.
func _action(label: String, into: Control) -> Button:
	var b := UIPalette.button(label, UIPalette.SIZE_ROW)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	into.add_child(b)
	return b


## One row per entrant in classification order, the player's row called out in
## sodium so a four-car result is findable without counting rows.
func _fill_table(race: RaceDirector) -> void:
	for c in _table.get_children():
		_table.remove_child(c)
		c.queue_free()
	_table.add_child(_cells(["POS", "DRIVER", "TIME", "BEST LAP"], true, false))
	_table.add_child(UIPalette.rule())
	if race == null:
		return
	for i in race.results.size():
		var r: Dictionary = race.results[i]
		var player: bool = i == 0
		_table.add_child(_cells([
			"%d" % int(r["pos"]),
			_driver_name(race, r["car"]),
			UIPalette.clock(float(r["time"])) if bool(r["finished"]) else "DNF",
			UIPalette.clock(float(r["best_lap"])),
		], false, player))
		_table.add_child(UIPalette.rule())


## Four fixed columns so the times line up on the decimal point. `expand` marks
## the one column that takes the slack, which is the driver's name.
func _cells(texts: Array, header: bool, player: bool) -> Control:
	var widths := [100.0, 0.0, 240.0, 240.0]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	for i in texts.size():
		var l := UIPalette.label(String(texts[i]), UIPalette.SIZE_BODY,
			_cell_colour(i, header, player))
		if float(widths[i]) > 0.0:
			l.custom_minimum_size = Vector2(float(widths[i]), 0.0)
		else:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
	return row


func _cell_colour(i: int, header: bool, player: bool) -> Color:
	if header:
		return UIPalette.FAINT
	if i == 1 and player:
		return UIPalette.SODIUM
	return UIPalette.TEXT


## The player's car is the one they brought; the rest are named from the roster,
## or "RIVAL n" when the field is a stub. A results board that prints a node id is
## worse than one that prints nothing clever.
func _driver_name(race: RaceDirector, car: Object) -> String:
	for i in race.entrants.size():
		if race.entrants[i] != car:
			continue
		if i == 0:
			return "YOU  ·  %s" % CarDB.display_name(Cfg.active_car).to_upper()
		if car is RaceEntrant and (car as RaceEntrant).car != null:
			var spec: CarSpec = (car as RaceEntrant).car.spec
			if spec != null:
				return String(spec.display_name).to_upper()
		return "RIVAL %d" % i
	return "RIVAL"


func _player_position(race: RaceDirector) -> int:
	if race == null or race.entrants.is_empty():
		return 0
	return race.position_of(race.entrants[0])


func _player_time(race: RaceDirector) -> float:
	if race == null or race.results.is_empty():
		return -1.0
	return float(race.results[0]["time"])


func _player_finished(race: RaceDirector) -> bool:
	return race != null and not race.results.is_empty() and bool(race.results[0]["finished"])


# ------------------------------------------------------------------ behaviour

func _on_retry() -> void:
	if _def != null:
		race_chosen.emit(_def.id)


func _on_destination(dest: String) -> void:
	screen_requested.emit(dest)
