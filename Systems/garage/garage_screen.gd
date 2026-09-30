class_name GarageScreen
extends Control
## The garage screen: pick a car, read what it actually does, bolt something to
## it, see what that costs. Draws a `Garage` and changes nothing itself - every
## action is a call on the state, so what the screen shows and what the save
## file says cannot drift apart.
##
## Built in code rather than as a .tscn, the same call the HUD makes: it is a
## handful of labels and bars, and a code-built UI is far easier to read.
##
## Wiring it up:
##     var garage := Garage.new()
##     add_child(GarageScreen.new(garage))
##     screen.start_race.connect(_on_start_race)
##     screen.closed.connect(_back_to_menu)

signal car_selected(car_id: String)
## Emitted when the player commits. `spec` is `garage.race_spec()`.
signal start_race(car_id: String, spec: CarSpec)
signal closed()

const LIST_W := 330.0
const PREVIEW_W := 540.0
const PAD := 20.0
## Bar row pitch, and the order the stat card reads them in.
const BAR_ROWS := [
	["0-100", "accel"], ["TOP KPH", "top"], ["POWER", "power"],
	["PWR/TONNE", "kwt"], ["GRIP", "grip"],
]

var garage: Garage

var _list: ItemList
var _parts: ItemList
var _preview: SubViewportContainer
var _title: Label
var _tagline: Label
var _body: Label
var _money: Label
var _status: Label
var _bars: Array = []      ## [{ "label": Label, "bar": ProgressBar }]


func _init(g: Garage = null) -> void:
	garage = g if g != null else Garage.new()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.04, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_text("GARAGE", 30, Color(0.92, 0.93, 0.95), Vector2(PAD, PAD), Vector2(400.0, 40.0))
	_money = _text("", 24, Color(0.55, 0.9, 0.55), Vector2(0.0, PAD), Vector2(420.0, 34.0))
	_money.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_list = ItemList.new()
	_list.position = Vector2(PAD, PAD + 52.0)
	_list.size = Vector2(LIST_W, 470.0)
	add_child(_list)
	_list.item_selected.connect(_on_row)

	_preview = SubViewportContainer.new()
	_preview.position = Vector2(LIST_W + PAD * 2.0, PAD + 44.0)
	_preview.size = Vector2(PREVIEW_W, 250.0)
	_preview.stretch = true
	add_child(_preview)
	_build_preview()

	_title = _text("", 26, Color(1.0, 0.85, 0.45), Vector2(0.0, 0.0), Vector2(PREVIEW_W, 34.0))
	_tagline = _text("", 13, Color(0.72, 0.74, 0.78), Vector2(0.0, 34.0), Vector2(PREVIEW_W, 40.0))
	_tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body = _text("", 12, Color(0.85, 0.86, 0.90), Vector2(0.0, 78.0), Vector2(74.0, 160.0))

	# The card's left edge, shared by the number column and the bars beside it.
	var card := Vector2(LIST_W + PAD * 2.0, PAD + 316.0)
	_title.position = card
	_tagline.position = card + Vector2(0.0, 34.0)
	_body.position = card + Vector2(0.0, 78.0)
	_money.position = Vector2(card.x + PREVIEW_W - 420.0, PAD)

	for i in BAR_ROWS.size():
		_bars.append(_bar_row(card + Vector2(78.0, 78.0 + float(i) * 28.0)))

	_parts = ItemList.new()
	_parts.position = Vector2(PAD, PAD + 530.0)
	_parts.size = Vector2(LIST_W + PREVIEW_W, 160.0)
	add_child(_parts)
	_parts.item_selected.connect(_on_part)

	_status = _text("", 15, Color(0.6, 0.85, 1.0), Vector2(PAD, PAD + 700.0), Vector2(900.0, 26.0))

	var go := Button.new()
	go.text = "START RACE"
	go.size = Vector2(150.0, 32.0)
	go.position = Vector2(PAD + LIST_W + PREVIEW_W - 150.0, PAD + 698.0)
	add_child(go)
	go.pressed.connect(_on_start)

	_rebuild()
	_select(garage.selected())
	_show(garage.selected())
	_status.text = "A / D  change car      ENTER  fit selected part      ESC  back"


# ------------------------------------------------------------------- the widgets

## A label, parented and placed in one call - the layout above is a list of
## these and nothing else.
func _text(txt: String, size: int, col: Color, at: Vector2, box: Vector2) -> Label:
	var l := Label.new()
	l.text = txt
	l.position = at
	l.size = box
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _bar_row(at: Vector2) -> Dictionary:
	var name := _text(String(BAR_ROWS[_bars.size()][0]), 13, Color(0.68, 0.70, 0.74),
		at, Vector2(78.0, 20.0))
	var bar := ProgressBar.new()
	bar.position = at + Vector2(82.0, 2.0)
	bar.size = Vector2(PREVIEW_W - 90.0, 16.0)
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.add_theme_stylebox_override("background", _flat(Color(0.10, 0.11, 0.14)))
	bar.add_theme_stylebox_override("fill", _flat(Color(0.30, 0.62, 0.95)))
	add_child(bar)
	return {"label": name, "bar": bar}


func _flat(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	return sb


# ------------------------------------------------------------------ the preview

## A small lit stage. The glb if this car has one and it will load, otherwise the
## procedural body built from the spec - and the card always names which, so the
## player is never looking at an unlabelled mystery box.
func _build_preview() -> void:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_2X
	_preview.add_child(vp)

	var cam := Camera3D.new()
	cam.position = Vector3(4.6, 2.1, 5.2)
	cam.rotation_degrees = Vector3(-13.0, 41.0, 0.0)
	cam.fov = 46.0
	vp.add_child(cam)
	cam.current = true

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.95, 0.88)
	key.light_energy = 1.6
	key.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	vp.add_child(key)

	var fill := OmniLight3D.new()
	fill.light_color = MatLib.MERCURY
	fill.omni_range = 14.0
	fill.light_energy = 2.2
	fill.position = Vector3(-2.5, 3.0, -2.0)
	vp.add_child(fill)


## Puts a car in the preview. Freezing it means the car is a still to look at
## rather than something the player watches turn.
##
## The glb is only loaded on a real renderer. Headless has no mesh storage behind
## the SubViewport, and building 40,000 vertices of bodywork to draw nothing is
## pure cost - so a headless run gets the procedural body, which is the same
## thing a car with no model gets anyway.
func _set_car(car_id: String) -> void:
	var vp := _preview.get_child(0) as SubViewport
	for c in vp.get_children():
		if c is Node3D and not (c is Camera3D or c is Light3D):
			vp.remove_child(c)
			c.queue_free()

	var path := Garage.model_path(car_id) if DisplayServer.get_name() != "headless" else ""
	var scene: Resource = load(path) if path != "" else null
	if scene is PackedScene:
		vp.add_child((scene as PackedScene).instantiate())
		return
	var vis := CarVisual.new()
	vp.add_child(vis)
	vis.build(garage.spec_for(car_id))


# ---------------------------------------------------------------------- the view

func _rebuild() -> void:
	_list.clear()
	for c in garage.roster():
		var spec: CarSpec = c
		# A car with no glb is selectable anyway, but it says so on the row.
		var line: String = spec.display_name
		line += "   (owned)" if garage.owns(spec.id) else "   $%s" % _commas(garage.price(spec.id))
		line += "" if garage.has_model(spec.id) else "  [no model]"
		_list.add_item(line)
	_money.text = "$%s" % _commas(garage.money())

	var car := garage.selected()
	_parts.clear()
	for uid in garage.upgrade_ids(UpgradeDB.CAT_PERFORMANCE):
		var o := garage.offer(car, String(uid))
		_parts.add_item("%d/%d  $%-6s  %-16s  %s" % [
			int(o["level"]), int(o["max"]),
			"MAX" if bool(o["maxed"]) else _commas(int(o["cost"])),
			String(o["name"]), String(o["stat"])])


func _select(car_id: String) -> void:
	_list.select(garage.roster_ids().find(car_id))


## Draws the card for a car. Read-only: the stat card never changes the state.
func _show(car_id: String) -> void:
	if not garage.in_roster(car_id):
		return
	var s := garage.stats(car_id)
	_title.text = "%s   %d   %s" % [s["name"], int(s["year"]), s["drive"]]
	_tagline.text = "%s\n%s" % [s["tagline"], Garage.body_label(car_id)]
	_body.text = "POWER\n  %d kW\nTORQUE\n  %d Nm\nMASS\n  %d kg\nPWR/TONNE\n  %d kW/t" % [
		int(round(s["power_kw"])), int(round(s["torque_nm"])),
		int(round(s["mass_kg"])), int(round(s["kwt"]))]
	for i in _bars.size():
		var key: String = BAR_ROWS[i][1]
		(_bars[i]["bar"] as ProgressBar).value = float(s["bars"][key])
		(_bars[i]["bar"] as ProgressBar).tooltip_text = _readout(s, key)
	_set_car(car_id)
	car_selected.emit(car_id)


func _readout(s: Dictionary, key: String) -> String:
	match key:
		"accel": return "%.1f s" % s["zero_to_100"]
		"top": return "%d km/h" % int(round(s["top_kph"]))
		"power": return "%d kW" % int(round(s["power_kw"]))
		"kwt": return "%d kW/t" % int(round(s["kwt"]))
		"grip": return "mu %.2f" % s["grip"]
	return ""


# --------------------------------------------------------------------- the input

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("garage_right"):
		_move(1)
	elif event.is_action_pressed("garage_left"):
		_move(-1)
	elif event.is_action_pressed("ui_confirm"):
		_buy_part()
	elif event.is_action_pressed("ui_back"):
		closed.emit()
	else:
		return
	get_viewport().set_input_as_handled()


func _move(step: int) -> void:
	var ids := garage.roster_ids()
	if ids.is_empty():
		return
	_select(String(ids[clampi(ids.find(garage.selected()) + step, 0, ids.size() - 1)]))


func _on_row(index: int) -> void:
	var ids := garage.roster_ids()
	if index >= 0 and index < ids.size():
		_show(String(ids[index]))


func _on_part(index: int) -> void:
	var ids := garage.upgrade_ids(UpgradeDB.CAT_PERFORMANCE)
	if index >= 0 and index < ids.size():
		_buy_part(String(ids[index]))


## Fits a part to the selected car. `uid` empty means whatever the parts list has
## highlighted. Everything the screen says about the outcome comes back from the
## state, so the caption and the save file cannot disagree.
func _buy_part(uid: String = "") -> void:
	if uid.is_empty():
		var ids := garage.upgrade_ids(UpgradeDB.CAT_PERFORMANCE)
		var at := _parts.get_selected_items()
		if at.is_empty() or int(at[0]) >= ids.size():
			return
		uid = String(ids[int(at[0])])
	var o := garage.offer(garage.selected(), uid)
	if bool(o["maxed"]):
		_status.text = "%s is already at maximum." % o["name"]
	elif not garage.install(uid):
		_status.text = "Not enough money for %s ($%s)." % [o["name"], _commas(int(o["cost"]))]
	else:
		_status.text = "Fitted %s for $%s." % [o["name"], _commas(int(o["cost"]))]
	_show(garage.selected())
	_rebuild()


func _on_start() -> void:
	start_race.emit(garage.selected(), garage.race_spec())


## Thousands separators, so a six figure car price reads as one.
static func _commas(n: int) -> String:
	var digits := str(absi(n))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return ("-" if n < 0 else "") + out
