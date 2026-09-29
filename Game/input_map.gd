class_name InputSetup
extends RefCounted
## Registers every input action in code.
##
## Deliberately not in project.godot: the serialised InputEvent form there is
## painful to hand-edit, and defining actions in one readable table lets the
## keyboard and gamepad bindings live side by side.

const ACTIONS := {
	# name: [keys, joypad buttons, joypad axes (axis, +dir, -dir)]
	"throttle": [KEY_W, KEY_UP],       # A / RT
	"brake":    [KEY_S, KEY_DOWN],     # B / LT
	"steer_left":  [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"handbrake": [KEY_SPACE],
	"shift_up":   [KEY_E],
	"shift_down": [KEY_Q],
	"camera_toggle": [KEY_C],
	"reset_car":    [KEY_R],
	"ui_pause":     [KEY_ESCAPE, KEY_P],
	"ui_confirm":   [KEY_ENTER, KEY_SPACE],
	"ui_back":      [KEY_ESCAPE],
	"garage_left":  [KEY_A, KEY_LEFT],
	"garage_right": [KEY_D, KEY_RIGHT],
	"map_zoom_in":  [KEY_EQUAL],
	"map_zoom_out": [KEY_MINUS],
}

const JOY_BUTTONS := {
	"throttle": JOY_BUTTON_A,
	"brake": JOY_BUTTON_B,
	"handbrake": JOY_BUTTON_X,
	"shift_up": JOY_BUTTON_RIGHT_SHOULDER,
	"shift_down": JOY_BUTTON_LEFT_SHOULDER,
	"camera_toggle": JOY_BUTTON_Y,
	"reset_car": JOY_BUTTON_BACK,
	"ui_pause": JOY_BUTTON_START,
	"ui_confirm": JOY_BUTTON_A,
	"ui_back": JOY_BUTTON_B,
}

## Left stick steering is analogue; RT/LT are analogue triggers.
const JOY_AXES := {
	"steer_left":  [JOY_AXIS_LEFT_X, -1.0],
	"steer_right": [JOY_AXIS_LEFT_X, 1.0],
}


static func install() -> void:
	for action in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for key in ACTIONS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)

	for action in JOY_BUTTONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		var ev := InputEventJoypadButton.new()
		ev.button_index = JOY_BUTTONS[action]
		InputMap.action_add_event(action, ev)

	for action in JOY_AXES:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		var spec: Array = JOY_AXES[action]
		var ev := InputEventJoypadMotion.new()
		ev.axis = spec[0]
		ev.axis_value = spec[1]
		InputMap.action_add_event(action, ev)

	# Analog triggers, full range, for throttle and brake.
	for action in ["throttle", "brake"]:
		var axis := JOY_AXIS_TRIGGER_RIGHT if action == "throttle" else JOY_AXIS_TRIGGER_LEFT
		var ev := InputEventJoypadMotion.new()
		ev.axis = axis
		ev.axis_value = 1.0
		InputMap.action_add_event(action, ev)
