class_name RaceHUD
extends CanvasLayer
## In-race HUD. Deliberately sparse - speed, gear, revs, and the race state.
## A street racer's HUD should get out of the way; everything else lives in the
## garage and the menus.
##
## Built in code rather than as a .tscn because it is a dozen labels and a bar,
## and a code-built UI is far easier to read than a scene file of anchors.

var _speed: Label
var _gear: Label
var _revfill: ColorRect
var _lap: Label
var _time: Label
var _pos: Label
var _lights: Label
var _message: Label
var _cash: Label
var _wrong: Label

const REV_W := 320.0


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# --- bottom right: speed, gear, rev bar ---
	var speedbox := _panel(root, Vector2(0.70, 0.72), Vector2(0.30, 0.28))
	_speed = _label(speedbox, "0", 62, Color(0.95, 0.95, 0.92))
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_gear = _label(speedbox, "1", 34, Color(1.0, 0.68, 0.25))
	_gear.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var unit := _label(speedbox, "KM/H", 13, Color(0.6, 0.6, 0.6))
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var revbg := ColorRect.new()
	revbg.color = Color(0.10, 0.10, 0.12, 0.8)
	revbg.position = Vector2(0, -6)
	revbg.size = Vector2(REV_W, 9)
	speedbox.add_child(revbg)
	_revfill = ColorRect.new()
	_revfill.color = Color(1.0, 0.55, 0.15)
	_revfill.position = Vector2(1, -5)
	_revfill.size = Vector2(0, 7)
	revbg.add_child(_revfill)

	# --- top left: race state ---
	var infobox := _panel(root, Vector2(0.0, 0.0), Vector2(0.26, 0.30))
	_lap = _label(infobox, "LAP 1/3", 20, Color(0.85, 0.85, 0.82))
	_time = _label(infobox, "0:00.00", 24, Color(1.0, 0.85, 0.45))
	_pos = _label(infobox, "POS 1/2", 18, Color(0.7, 0.85, 1.0))
	_cash = _label(infobox, "$0", 16, Color(0.55, 0.9, 0.55))

	# --- centre: countdown and event messages ---
	_lights = _label(root, "", 110, Color(1.0, 0.25, 0.2))
	_lights.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_lights.position = Vector2(-60, 40)
	_message = _label(root, "", 26, Color(1.0, 0.9, 0.5))
	_message.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_message.position = Vector2(-260, 150)

	_wrong = _label(root, "WRONG WAY", 30, Color(1.0, 0.3, 0.2))
	_wrong.set_anchors_preset(Control.PRESET_CENTER)
	_wrong.position = Vector2(-110, 60)


func _panel(parent: Control, at: Vector2, size: Vector2) -> Control:
	var c := Control.new()
	c.position = Vector2(parent.size.x * at.x + 18, parent.size.y * at.y + 18)
	c.size = size
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c


func _label(parent: Control, text: String, size_px: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_constant_override("shadow_outline_size", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## `msg` sticks on screen for a couple of seconds, then clears itself.
func flash(msg: String) -> void:
	_message.text = msg


func update(car: CarBody, race: RaceDirector, delta: float) -> void:
	if car != null:
		_speed.text = str(int(round(car.speed_kph)))
		_gear.text = str(car.current_gear if car.current_gear > 0 else "R")
		var rev: float = clampf(car.engine_rpm / maxf(car.spec.redline, 1.0), 0.0, 1.0)
		_revfill.size = Vector2((REV_W - 2.0) * rev, 7)
		# Blue then red as you approach the limiter: the rev bar is the one
		# instrument the player actually needs mid-corner.
		_revfill.color = Color(0.35, 0.7, 1.0).lerp(Color(1.0, 0.2, 0.1), clampf((rev - 0.55) / 0.4, 0.0, 1.0))

	if race == null:
		return

	match race.state:
		RaceDirector.State.COUNTDOWN:
			var n := maxi(race.lights, 0)
			_lights.text = str(n) if n > 0 else "GO"
			_lights.add_theme_color_override("font_color",
				Color(0.2, 1.0, 0.3) if n == 0 else Color(1.0, 0.25, 0.2))
		_:
			_lights.text = ""

	if race.def != null:
		_lap.text = "LAP %d/%d" % [mini(race.laps(0) + 1, race.def.laps), race.def.laps]
	_time.text = "%.2f" % race.race_time
	var pos := 1
	for r in race.results:
		if r.get("car") == car:
			pos = int(r.get("pos", 1))
			break
	_pos.text = "POS %d/%d" % [pos, maxi(race.entrants.size(), 1)]
	_cash.text = "$%d" % Cfg.money
	_wrong.visible = race.is_wrong_way(0)
