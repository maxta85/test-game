class_name MainMenu
extends MenuShell
## The front door. Title, the car you are driving, the money you have, and the
## things a player can do from here.
##
## The garage is a signal, not a screen: another agent owns `Systems/garage/**`
## and this must not guess at its class name or its path. The button emits, and
## the host wires it. Every other row works with nothing connected.

signal start_requested()
signal garage_requested()
signal quit_requested()

const ROW_LABELS := ["START RACE", "GARAGE", "CONTROLS", "QUIT"]

var _rows: Array[Button] = []
var _car_name: Label
var _car_blurb: Label
var _car_specs: Label
var _progress: Label
var _controls_card: PanelContainer = null


func _ready() -> void:
	super()
	set_title("CAIRNS AFTER DARK")
	set_kicker("MANUNDA, CAIRNS  ·  AFTER HOURS")
	set_hint("↑↓  SELECT        ENTER  CONFIRM")
	set_note("v0.1")
	_body()
	focus_first()


## Everything a player sees here is derived state, and some of it (money, which
## car, how many routes are done) can change while this screen is behind another
## one, so the host calls this whenever it shows.
func on_shown() -> void:
	refresh_status()
	_refresh_card()
	_progress.text = "%d of 5 routes run" % Cfg.races_completed.size()
	_hide_controls()


# ----------------------------------------------------------------------- body

func _body() -> void:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = MARGIN
	row.offset_right = -MARGIN
	row.offset_top = 16.0
	row.offset_bottom = -16.0
	row.add_theme_constant_override("separation", 56)
	body.add_child(row)

	row.add_child(_menu_column())
	row.add_child(_vrule())
	row.add_child(_car_card())


## Uppercase rows at a size that reads as a front page, with a gap before QUIT so
## the one row that ends the game is not the fourth thing you hit by accident.
func _menu_column() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(500.0, 0.0)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 4)
	for i in ROW_LABELS.size():
		if i == 3:
			col.add_child(UIPalette.spacer(30.0))
		var b := UIPalette.button(ROW_LABELS[i], UIPalette.SIZE_HEAD)
		col.add_child(b)
		_rows.append(b)
		wire_row(b, _on_row.bind(i))

	col.add_child(UIPalette.spacer(40.0))
	col.add_child(UIPalette.rule(UIPalette.RULE, 1.0))
	col.add_child(UIPalette.spacer(12.0))
	_progress = UIPalette.label("", UIPalette.SIZE_META, UIPalette.DIM)
	col.add_child(_progress)
	col.add_child(UIPalette.label(
		"Five routes are open on the real street grid. Win one, bank it.",
		UIPalette.SIZE_META, UIPalette.FAINT))
	return col


## The car, handed over the way a night racer is handed a car: the numbers that
## matter, read off the same spec the physics runs on, so the card cannot flatter
## a car the player will not drive.
func _car_card() -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIPalette.panel())
	card.custom_minimum_size = Vector2(540.0, 0.0)
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	card.add_child(col)
	col.add_child(UIPalette.label("DRIVING TONIGHT", UIPalette.SIZE_KICKER, UIPalette.SODIUM))
	col.add_child(UIPalette.spacer(8.0))
	_car_name = UIPalette.label("", UIPalette.SIZE_HERO, UIPalette.TEXT)
	col.add_child(_car_name)
	col.add_child(UIPalette.spacer(12.0))
	col.add_child(UIPalette.rule())
	col.add_child(UIPalette.spacer(12.0))
	_car_blurb = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.DIM)
	_car_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_car_blurb.custom_minimum_size = Vector2(470.0, 0.0)
	col.add_child(_car_blurb)
	col.add_child(UIPalette.spacer(16.0))
	_car_specs = UIPalette.label("", UIPalette.SIZE_BODY, UIPalette.MERCURY)
	col.add_child(_car_specs)
	_refresh_card()
	return card


## Year, drive, mass, and the project's own traction-limited 0-100. Deliberately
## not `peak_power_kw()`: that is peak torque times redline, so it prints 1854 kW
## for a car whose torque curve says 271 Nm and calls it power. A number the
## front page cannot stand behind is worse than no number.
func _refresh_card() -> void:
	var spec := Cfg.active_spec()
	_car_name.text = CarDB.display_name(Cfg.active_car).to_upper()
	_car_blurb.text = CarDB.tagline(Cfg.active_car)
	_car_specs.text = "%d   %s DRIVE   %.0f kg   0-100 in %.1f s" % [
		spec.year, spec.drive.to_upper(), spec.mass, spec.zero_to_hundred()]


# ------------------------------------------------------------------ behaviour

func _on_row(i: int) -> void:
	match i:
		0:
			start_requested.emit()
		1:
			garage_requested.emit()
		2:
			_show_controls() if _controls_card == null else _hide_controls()
		3:
			quit_requested.emit()


## The key map is a reference, not a destination, so it opens in place over the
## menu rather than becoming a fifth screen, and the same row closes it. It is
## registered in the focus order like everything else, so ESC is not the only way
## out.
func _show_controls() -> void:
	_controls_card = PanelContainer.new()
	_controls_card.add_theme_stylebox_override("panel", UIPalette.panel(true, 0.97))
	_controls_card.set_anchors_preset(Control.PRESET_CENTER)
	_controls_card.offset_left = -320.0
	_controls_card.offset_right = 320.0
	_controls_card.offset_top = -240.0
	_controls_card.offset_bottom = 240.0
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_controls_card.add_child(col)
	col.add_child(UIPalette.label("CONTROLS", UIPalette.SIZE_HEAD, UIPalette.TEXT))
	col.add_child(UIPalette.spacer(10.0))
	col.add_child(ControlsPanel.new())
	body.add_child(_controls_card)
	_rows[2].text = "CLOSE CONTROLS"
	_rows[2].grab_focus()


func _hide_controls() -> void:
	if _controls_card == null:
		return
	body.remove_child(_controls_card)
	_controls_card.queue_free()
	_controls_card = null
	_rows[2].text = ROW_LABELS[2]


func _vrule() -> Control:
	var c := ColorRect.new()
	c.color = UIPalette.RULE
	c.custom_minimum_size = Vector2(1.0, 0.0)
	c.size_flags_vertical = Control.SIZE_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c
