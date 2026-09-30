class_name PauseMenu
extends MenuShell
## The overlay that comes up when the player presses ESC mid-race.
##
## The one screen that draws *over* the game instead of replacing it, so it skips
## the night backdrop and dims the street instead. The game behind it is stopped
## by the host: this only owns the menu, because whether a pause should halt the
## simulation is the host's decision, not a UI widget's.

signal resume_requested()
signal restart_requested()
signal quit_to_menu_requested()

var _rows: Array[Button] = []


## This is an overlay, not a page: the street stays behind it.
func painted() -> bool:
	return false


func _ready() -> void:
	super()
	dim(0.74)
	set_title("PAUSED")
	set_kicker("THE STREET WAITS")
	set_hint("ESC  RESUME        ↑↓  SELECT        ENTER  CONFIRM")
	set_note("")
	_body()
	focus_first()


## Stops the rows walking off the resume button when the game comes back.
func on_shown() -> void:
	refresh_status()
	if not _rows.is_empty():
		_rows[0].grab_focus()


func _body() -> void:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = MARGIN
	row.offset_right = -MARGIN
	row.offset_top = 8.0
	row.offset_bottom = -8.0
	row.add_theme_constant_override("separation", 56)
	body.add_child(row)

	var actions := VBoxContainer.new()
	actions.custom_minimum_size = Vector2(440.0, 0.0)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	actions.add_theme_constant_override("separation", 4)
	row.add_child(actions)
	for label in ["RESUME", "RESTART RACE", "QUIT TO MAIN MENU"]:
		var b := UIPalette.button(label, UIPalette.SIZE_HEAD)
		actions.add_child(b)
		_rows.append(b)
		wire_row(b, _on_row.bind(label))

	row.add_child(_legend())


## The controls, on the one screen where a player who has just lost the plot of
## the car needs them.
func _legend() -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIPalette.panel())
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	card.add_child(col)
	col.add_child(UIPalette.label("CONTROLS", UIPalette.SIZE_HEAD, UIPalette.TEXT))
	col.add_child(UIPalette.spacer(10.0))
	col.add_child(ControlsPanel.new())
	return card


func _on_row(label: String) -> void:
	match label:
		"RESUME":
			resume_requested.emit()
		"RESTART RACE":
			restart_requested.emit()
		_:
			quit_to_menu_requested.emit()
