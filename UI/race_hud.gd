class_name RaceHUD
extends CanvasLayer
## In-race HUD. Deliberately sparse - speed, gear, revs, and the race state.
## A street racer's HUD should get out of the way; everything else lives in the
## garage and the menus.
##
## Built in code rather than as a .tscn because it is a dozen labels and a bar,
## and a code-built UI is far easier to read than a scene file of anchors.

## The map. Built here rather than in `Game/main.gd` because a HUD element is
## this class's business, and the host only has to hand it the graph and the
## entrants it already has.
var minimap: Minimap

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
var _message_time := 0.0
## The last completed round: one line of summary under the race state, and the
## classification itself on a board below it. Driven off `race.last_round()` in
## `update()` rather than pushed in by the host, so the HUD shows the same history
## whether it was wired by `Game/main.gd` or by a test with a director and nothing
## else.
var _round: Label
var _board: VBoxContainer
var _board_box: Control
var _round_shown: RoundResult = null

const REV_W := 320.0
const PAD := 22.0
## Minimap edge length in pixels. 236 fits a 1080p frame beside the speed block
## without crowding it, and at that size the 2.6 x 2.8 km network fits whole -
## which is the point, since a map cropped to the street you are on cannot tell
## you where the route goes.
const MAP := 236.0


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# --- bottom right: speed, gear, rev bar ---
	var speedbox := _box(root, Control.PRESET_BOTTOM_RIGHT, Vector2(PAD, PAD), Vector2(REV_W, 104.0))
	_revfill = _rev_bar(speedbox)
	_speed = _label(speedbox, "0", 62, Color(0.95, 0.95, 0.92))
	_speed.position = Vector2(0, 0)
	_speed.size = Vector2(REV_W - 62.0, 74.0)
	_speed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_gear = _label(speedbox, "1", 34, Color(1.0, 0.68, 0.25))
	_gear.position = Vector2(0, 14)
	_gear.size = Vector2(REV_W - 150.0, 44.0)
	_gear.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var unit := _label(speedbox, "KM/H", 13, Color(0.6, 0.6, 0.6))
	unit.position = Vector2(0, 72)
	unit.size = Vector2(REV_W, 18)
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# --- top left: race state ---
	var infobox := _box(root, Control.PRESET_TOP_LEFT, Vector2(PAD, PAD), Vector2(300.0, 140.0))
	_lap = _label(infobox, "LAP 1/3", 20, Color(0.85, 0.85, 0.82))
	_lap.position = Vector2(0, 0)
	_time = _label(infobox, "0:00.00", 24, Color(1.0, 0.85, 0.45))
	_time.position = Vector2(0, 24)
	_pos = _label(infobox, "POS 1/2", 18, Color(0.7, 0.85, 1.0))
	_pos.position = Vector2(0, 54)
	_cash = _label(infobox, "$0", 16, Color(0.55, 0.9, 0.55))
	_cash.position = Vector2(0, 80)
	# What the last round paid and what the balance came out at. Without this the
	# wallet is a number that only ever goes down, and a player who cannot see the
	# round pay them has no reason to enter the next one.
	_round = _label(infobox, "", 15, Color(0.75, 0.8, 0.95))
	_round.position = Vector2(0, 102)
	_round.size = Vector2(300.0, 22)

	# --- the classification, under the race state ---
	# Shown once a round has been decided and hidden again on the next entry, so a
	# race is never read through somebody else's result.
	_board_box = _box(root, Control.PRESET_TOP_LEFT, Vector2(PAD, PAD + 152.0), Vector2(300.0, 0.0))
	_board_box.visible = false
	_board = VBoxContainer.new()
	_board.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_board.add_theme_constant_override("separation", 1)
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_box.add_child(_board)

	# --- top right: money ---
	var cashbox := _box(root, Control.PRESET_TOP_RIGHT, Vector2(PAD, PAD), Vector2(150.0, 28.0))
	_cash = _label(cashbox, "$0", 18, Color(0.55, 0.9, 0.55))
	_cash.size = cashbox.size
	_cash.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# --- bottom left: the map ---
	# Bottom left because the speed block owns the bottom right and the race
	# state owns the top left, and this is the fourth corner. A street racer's
	# map belongs where the driver's eye already is for the rev counter, and the
	# HUD's own top-left numbers are read in glances, not watched.
	var mapbox := _box(root, Control.PRESET_BOTTOM_LEFT, Vector2(PAD, PAD), Vector2(MAP, MAP))
	minimap = Minimap.new()
	minimap.name = "Minimap"
	minimap.set_anchors_preset(Control.PRESET_FULL_RECT)
	minimap.size = Vector2(MAP, MAP)
	minimap.visible = false
	mapbox.add_child(minimap)

	# --- centre: countdown and event messages ---
	_lights = _box_label(root, Control.PRESET_CENTER_TOP, Vector2(0, 40.0), 110, Color(1.0, 0.25, 0.2))
	_message = _box_label(root, Control.PRESET_CENTER_TOP, Vector2(0, 150.0), 26, Color(1.0, 0.9, 0.5))
	_wrong = _box_label(root, Control.PRESET_CENTER, Vector2(0, -20.0), 30, Color(1.0, 0.3, 0.2))


## A fixed-size box pinned to a viewport corner by anchors and offsets.
##
## Positions were the bug: every panel was placed from `parent.size`, which is
## still zero while `_ready` runs, so the whole HUD piled up in the top left and
## the "wrong way" text hung off the edge of the screen. Anchors resolve against
## the real viewport whatever size it turns out to be.
func _box(parent: Control, preset: int, margin: Vector2, size: Vector2) -> Control:
	var c := Control.new()
	c.set_anchors_preset(preset)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var right: bool = preset == Control.PRESET_TOP_RIGHT or preset == Control.PRESET_BOTTOM_RIGHT
	var bottom: bool = preset == Control.PRESET_BOTTOM_LEFT or preset == Control.PRESET_BOTTOM_RIGHT
	var centre: bool = preset == Control.PRESET_CENTER or preset == Control.PRESET_CENTER_TOP
	if centre:
		c.offset_left = -size.x * 0.5
		c.offset_right = size.x * 0.5
	elif right:
		c.offset_left = -size.x - margin.x
		c.offset_right = -margin.x
	else:
		c.offset_left = margin.x
		c.offset_right = margin.x + size.x
	if preset == Control.PRESET_BOTTOM_LEFT or preset == Control.PRESET_BOTTOM_RIGHT or preset == Control.PRESET_CENTER_BOTTOM:
		c.offset_top = -size.y - margin.y
		c.offset_bottom = -margin.y
	else:
		c.offset_top = margin.y
		c.offset_bottom = margin.y + size.y
	parent.add_child(c)
	return c


## A single centred label pinned to a corner, for the things that own the middle
## of the screen: the countdown, the event message, wrong way.
func _box_label(parent: Control, preset: int, at: Vector2, size_px: int, colour: Color) -> Label:
	var box := _box(parent, preset, at, Vector2(520, float(size_px) * 1.5))
	var l := _label(box, "", size_px, colour)
	l.position = Vector2.ZERO
	l.size = box.size
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _rev_bar(parent: Control) -> ColorRect:
	var revbg := ColorRect.new()
	revbg.color = Color(0.10, 0.10, 0.12, 0.8)
	revbg.position = Vector2(0, 94)
	revbg.size = Vector2(REV_W, 9)
	parent.add_child(revbg)
	var fill := ColorRect.new()
	fill.color = Color(1.0, 0.55, 0.15)
	fill.position = Vector2(1, 95)
	fill.size = Vector2(0, 7)
	revbg.add_child(fill)
	return fill


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
	_message_time = 2.5


func update(car: CarBody, race: RaceDirector, delta: float) -> void:
	if _message_time > 0.0:
		_message_time -= delta
		if _message_time <= 0.0:
			_message.text = ""
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

	# The round that was just decided, if any. Read every frame rather than pushed
	# in, because the HUD already reads the director for everything else and this
	# way the history cannot be shown for a race the director did not run.
	_sync_round(race)

	# The map follows the car and the field, from the same graph the streets are
	# built from. Hidden until a race actually has a route on it, so an empty map
	# is never on screen in the menus.
	if minimap != null:
		minimap.visible = race.def != null
		if car != null:
			minimap.set_player(car.global_position, car.forward())
		# Entrant 0 is the player, who is the centre of a rotating map; the rest
		# are the field.
		var field: Array = []
		for i in range(1, race.entrants.size()):
			field.append(race.entrants[i])
		minimap.set_rivals(field)


# ---------------------------------------------------------------- the round board

## Puts the director's last concluded round on screen, once. Re-rendering on every
## frame would be the expensive way to say nothing has changed, so the round being
## shown is compared by identity and the board is only rebuilt when it differs.
func _sync_round(race: RaceDirector) -> void:
	var round: RoundResult = race.last_round() if race != null else null
	if round == null:
		_clear_board()
		return
	if round == _round_shown:
		return
	_round_shown = round
	_round.text = round.headline()
	_fill_board(round)


## The classification, one label per row, in the order the round recorded. Built
## from the round rather than from `race.results` so the board shows what was
## written down, which is the thing a later round must not be able to rewrite.
func _fill_board(round: RoundResult) -> void:
	for c in _board.get_children():
		_board.remove_child(c)
		c.queue_free()
	var rows: Array = round.board_rows()
	# Through `offset_bottom` rather than `size`: the box is anchored, and setting
	# `size` on an anchored Control in the tree fights the anchor every frame.
	_board_box.offset_bottom = _board_box.offset_top + 20.0 + 18.0 * float(rows.size())
	for i in rows.size():
		var text: String = String(rows[i])
		var l := _label(_board, text, 15, _board_colour(i, text))
		l.size = Vector2(300.0, 18.0)
	_board_box.visible = rows.size() > 0


## The player's own row in sodium, as the results board does it, so a four-car
## classification is findable without counting rows in two places.
func _board_colour(i: int, text: String) -> Color:
	if text.begins_with("P1 "):
		return Color(1.0, 0.9, 0.55)
	if text.contains(" YOU "):
		return Color(0.65, 0.8, 1.0)
	return Color(0.72, 0.72, 0.7)


func _clear_board() -> void:
	if _round_shown == null and _board_box != null and not _board_box.visible:
		return
	_round_shown = null
	if _round != null:
		_round.text = ""
	for c in _board.get_children():
		_board.remove_child(c)
		c.queue_free()
	if _board_box != null:
		_board_box.visible = false


## What the HUD is showing, read back. Tests and a host both need to be able to ask
## without walking the label tree, and the answer has to be the text on the screen
## rather than a re-derivation of it.
func round_text() -> String:
	return _round.text if _round != null else ""


## The classification rows as rendered, in order.
func board_rows() -> Array:
	var out: Array = []
	for c in _board.get_children():
		if c is Label:
			out.append((c as Label).text)
	return out


## True when a concluded round is on screen.
func board_visible() -> bool:
	return _board_box != null and _board_box.visible
