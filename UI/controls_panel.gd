class_name ControlsPanel
extends VBoxContainer
## The key map, read out of InputSetup so it cannot drift from what the game
## actually binds. A key legend that lies is worse than no legend.
##
## Used twice: on the main menu, where a player arriving at a street racer with no
## manual needs to find the pedals, and on the pause overlay, which is the one
## place mid-race that a player is guaranteed to be reading it. Two uses is the
## whole justification - one use would have been inlined.

## Display order is the order a player reaches for these, not the order they are
## declared in InputSetup. Each row names the actions behind it; the keys come
## from the bindings themselves.
const ROWS := [
	["Steer", ["steer_left", "steer_right"]],
	["Throttle", ["throttle"]],
	["Brake", ["brake"]],
	["Handbrake", ["handbrake"]],
	["Shift up", ["shift_up"]],
	["Shift down", ["shift_down"]],
	["Look behind", ["camera_toggle"]],
	["Recover car", ["reset_car"]],
	["Pause", ["ui_pause"]],
]


func _init() -> void:
	add_theme_constant_override("separation", 0)


func _ready() -> void:
	for row in ROWS:
		add_child(_line(String(row[0]), keys_for(row[1])))
	add_child(UIPalette.spacer(8.0))
	add_child(_line("Gamepad", "STICKS, TRIGGERS, SHOULDERS"))


## The primary key per action: InputSetup lists the keyboard binding first, and
## the second entry is the arrow-key alias of the same control, which would only
## make the legend noisier.
static func keys_for(actions: Array) -> String:
	var out := PackedStringArray()
	for a in actions:
		var keys: Array = InputSetup.ACTIONS.get(a, [])
		if not keys.is_empty():
			out.append(OS.get_keycode_string(int(keys[0])))
	return " / ".join(out)


## A legend row, not a button: focus_mode NONE so it never lands in the focus
## order, and every stylebox flattened so a mouse pass over it changes nothing.
func _line(action: String, keys: String) -> Control:
	var c := UIPalette.button(action, UIPalette.SIZE_BODY)
	c.focus_mode = Control.FOCUS_NONE
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for state in ["normal", "hover", "pressed", "disabled"]:
		c.add_theme_stylebox_override(state, _flat())

	var k := UIPalette.label(keys, UIPalette.SIZE_BODY, UIPalette.SODIUM,
		HORIZONTAL_ALIGNMENT_RIGHT)
	k.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	k.offset_left = -260.0
	k.offset_right = -18.0
	k.offset_top = 0.0
	k.offset_bottom = 42.0
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	c.add_child(k)
	return c


func _flat() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = UIPalette.RULE
	s.border_width_bottom = 1
	s.content_margin_left = 18.0
	s.content_margin_right = 18.0
	s.content_margin_top = 8.0
	s.content_margin_bottom = 8.0
	return s
