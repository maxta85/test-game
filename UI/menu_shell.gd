class_name MenuShell
extends CanvasLayer
## The frame every front-of-house screen sits in: the night backdrop, the title
## block, the player's cash and car, the key hint along the bottom, and the focus
## order.
##
## Focus is owned here rather than left to the engine, and that is a measured
## decision. With a real window Godot walks focus on the arrow keys, but headless
## it does not - the built-in traversal never fires under `--headless`, so an
## engine-driven order is both unobservable in this project's own test runner and
## not necessarily the order a screen wants anyway (race select walks a column of
## races, then drops into the START button; the engine would offer no way to say
## that). An explicit list plus explicit arrow handling is the same amount of
## code, is testable end to end, and wraps the way a player expects.
##
## Screens subclass this, fill `body`, register their rows and never think about
## the backdrop again.

signal back_requested()

const MARGIN := 64.0
const HEADER_H := 186.0
const FOOTER_H := 76.0

var root: Control
## Between the header and the footer. Screens anchor their layout to this.
var body: Control
var focusables: Array[Control] = []

var _title: Label
var _kicker: Label
var _cash: Label
var _car: Label
var _hint: Label
var _note: Label


func _init() -> void:
	layer = 40


## Whether this screen paints the night behind it. False for anything that draws
## over the game rather than replacing it - the pause overlay - so it can skip the
## sky and dim the street instead. A method rather than a flag because the base
## `_ready` is what asks, and virtual dispatch has to work through it.
func painted() -> bool:
	return true


func _ready() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	if painted():
		_build_backdrop()
	root.add_child(UIPalette.viewfinder(36.0, 44.0))

	_build_header()
	_build_body()
	_build_footer()
	refresh_status()


# --------------------------------------------------------------------- chrome

## Cairns after dark, seen from the low end of a wet street: the sky gradient,
## the CBD on the horizon, the glow it throws up into the air, and the road
## taking all of it back as vertical smears. The smears are the point - the art
## direction says a night street is long vertical smears of light down wet
## tarmac, and the menu is the only place in the project that can show that
## without a camera in front of it.
func _build_backdrop() -> void:
	var sky := TextureRect.new()
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.texture = _sky_texture()
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(sky)
	var back := Backdrop.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(back)


## A dark curtain over whatever is behind, for overlays.
func dim(alpha: float = 0.74) -> void:
	var d := ColorRect.new()
	d.color = Color(0.0, 0.0, 0.0, alpha)
	d.set_anchors_preset(Control.PRESET_FULL_RECT)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(d)


func _build_header() -> void:
	var bar := Control.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = HEADER_H
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)

	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", int(MARGIN))
	m.add_theme_constant_override("margin_right", int(MARGIN))
	m.add_theme_constant_override("margin_top", 40)
	m.add_theme_constant_override("margin_bottom", 18)
	bar.add_child(m)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 32)
	m.add_child(row)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 2)
	row.add_child(left)

	_kicker = UIPalette.label("", UIPalette.SIZE_KICKER, UIPalette.SODIUM)
	left.add_child(_kicker)
	_title = UIPalette.label("", UIPalette.SIZE_TITLE, UIPalette.TEXT)
	left.add_child(_title)
	left.add_child(UIPalette.spacer(12.0))
	left.add_child(UIPalette.rule(UIPalette.SODIUM, 2.0))

	# Who you are and what you have, top right, on every screen: the two facts a
	# player wants without asking for them.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(340.0, 0.0)
	right.alignment = BoxContainer.ALIGNMENT_BEGIN
	right.add_theme_constant_override("separation", 4)
	row.add_child(right)
	_cash = UIPalette.label("", UIPalette.SIZE_STAT, UIPalette.CASH,
		HORIZONTAL_ALIGNMENT_RIGHT)
	right.add_child(_cash)
	_car = UIPalette.label("", UIPalette.SIZE_META, UIPalette.DIM,
		HORIZONTAL_ALIGNMENT_RIGHT)
	right.add_child(_car)
	right.add_child(UIPalette.spacer(6.0))
	right.add_child(UIPalette.rule(UIPalette.RULE, 1.0))


func _build_body() -> void:
	body = Control.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.offset_top = HEADER_H
	body.offset_bottom = -FOOTER_H
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(body)


func _build_footer() -> void:
	var bar := Control.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -FOOTER_H
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)
	bar.add_child(UIPalette.rule())

	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", int(MARGIN))
	m.add_theme_constant_override("margin_right", int(MARGIN))
	m.add_theme_constant_override("margin_top", 16)
	bar.add_child(m)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	m.add_child(row)
	_hint = UIPalette.label("↑↓  SELECT        ENTER  CONFIRM", UIPalette.SIZE_HINT,
		UIPalette.DIM)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_hint)
	_note = UIPalette.label("", UIPalette.SIZE_HINT, UIPalette.FAINT,
		HORIZONTAL_ALIGNMENT_RIGHT)
	row.add_child(_note)


func set_title(t: String) -> void:
	_title.text = t


func set_kicker(k: String) -> void:
	_kicker.text = k


## Overrides the footer legend. A screen that has no Back row should not lie
## about having one.
func set_hint(h: String) -> void:
	_hint.text = h


func set_note(n: String) -> void:
	_note.text = n


## Reads the player's wallet and their car. Called on every screen switch, so
## money that moved during a race is right the moment the results come up.
func refresh_status() -> void:
	_cash.text = UIPalette.money(Cfg.money)
	_car.text = CarDB.display_name(Cfg.active_car).to_upper()


# ---------------------------------------------------------------------- focus

## Adds a row to the focus order. Order of registration *is* the order the arrow
## keys walk, so screens register in reading order: down the list, then across to
## the actions.
func register(c: Control) -> void:
	focusables.append(c)


## A row that both takes the focus and does its job when pressed.
##
## The focus half is not redundant with Godot's own behaviour: focus following a
## click is a Viewport path, it does not fire under the headless runner, and a
## menu that behaves one way in the game and another in its own tests is a menu
## nobody can test. Grabbing the focus here makes the two the same thing.
func wire_row(b: Button, on_press: Callable) -> void:
	register(b)
	b.pressed.connect(func():
		b.grab_focus()
		on_press.call())


## Focuses the first row that can take it. No-op while the screen is hidden, so
## four screens building in one frame cannot fight over the focus.
func focus_first() -> void:
	if not visible:
		return
	_step(1, -1)


func focus_count() -> int:
	return focusables.size()


## Walks the focus order, skipping rows that are disabled, wrapping at both ends.
func focus_step(dir: int) -> void:
	_step(dir, 0)


func focused_row() -> Control:
	var vp := get_viewport()
	return vp.gui_get_focus_owner() if vp != null else null


func _step(dir: int, from: int) -> void:
	var n := focusables.size()
	if n == 0:
		return
	for k in n:
		var i := posmod(from + dir * (k + 1), n)
		var c := focusables[i]
		if c is Button and (c as Button).disabled:
			continue
		if c.has_focus():
			return
		c.grab_focus()
		return


## The whole point of owning focus: this is the one place a keypress becomes a
## row change, and it is the same path a test drives.
func _unhandled_input(e: InputEvent) -> void:
	if not visible or not (e is InputEventKey):
		return
	var k := e as InputEventKey
	if not k.pressed or k.echo:
		return
	var dir := 0
	match k.keycode:
		KEY_DOWN, KEY_S:
			dir = 1
		KEY_UP, KEY_W:
			dir = -1
		KEY_ESCAPE:
			back_requested.emit()
			get_viewport().set_input_as_handled()
			return
		_:
			return
	# Nothing focused yet: DOWN lands on the first row, UP on the last, which is
	# what "the focus starts at the top" means in both directions.
	var cur := focusables.find(focused_row())
	if cur < 0:
		cur = -1 if dir > 0 else focusables.size()
	_step(dir, cur)
	get_viewport().set_input_as_handled()


# ------------------------------------------------------------------- backdrop

static func _sky_texture() -> GradientTexture2D:
	var g := Gradient.new()
	# 0.58 is where Backdrop puts the horizon, so the gradient changes over the
	# skyline rather than halfway down the road.
	g.offsets = PackedFloat32Array([0.0, 0.575, 0.60, 1.0])
	g.colors = PackedColorArray([UIPalette.SKY_TOP, UIPalette.NIGHT,
		UIPalette.SKY_BOTTOM, UIPalette.SKY_BOTTOM])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 8
	t.height = 256
	t.fill_from = Vector2(0.0, 0.0)
	t.fill_to = Vector2(0.0, 1.0)
	return t


## The skyline and the wet road. Drawn from normalised coordinates off a fixed
## seed, so the menu is pixel-identical between runs - a backdrop that reshuffles
## every launch makes "did the art change?" unanswerable.
class Backdrop extends Control:
	const HORIZON := 0.58

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if w < 2.0 or h < 2.0:
			return
		var horizon := h * HORIZON
		var rng := RandomNumberGenerator.new()
		rng.seed = 0xCA12E5

		_skyline(rng, w, h, horizon)
		_glow(w, h, horizon)
		_road(rng, w, h, horizon)
		draw_rect(Rect2(0.0, horizon - 1.0, w, 2.0),
			Color(UIPalette.SODIUM.r, UIPalette.SODIUM.g, UIPalette.SODIUM.b, 0.16))

	## A band of boxes with a few lit windows. Cairns has a real CBD; giving the
	## sky a floor is what makes Manunda read as part of a city rather than a
	## void with a road in it.
	func _skyline(rng: RandomNumberGenerator, w: float, h: float, horizon: float) -> void:
		var x := -0.02
		while x < 1.0:
			var bw := rng.randf_range(0.018, 0.062)
			var bh := rng.randf_range(0.025, 0.115)
			var bx := x * w
			var by := horizon - bh * h
			draw_rect(Rect2(bx, by, bw * w, bh * h + 2.0), UIPalette.CBD)
			for c in int(bw * w / 11.0):
				for r in int(bh * h / 15.0):
					if rng.randf() > 0.32:
						continue
					var wx := bx + 5.0 + float(c) * 11.0
					var wy := by + 6.0 + float(r) * 15.0
					if wx + 4.0 > bx + bw * w - 4.0 or wy + 5.0 > horizon:
						continue
					var tint := UIPalette.SODIUM if rng.randf() < 0.78 else UIPalette.CYAN
					draw_rect(Rect2(wx, wy, 4.0, 5.0),
						Color(tint.r, tint.g, tint.b, rng.randf_range(0.12, 0.5)))
			x += bw + rng.randf_range(0.004, 0.016)

	## City light spilling up into the air. Wide, weak, and brightest at the
	## horizon - the failure mode the art direction warns about is fog being the
	## subject, so this is deliberately faint and sits behind the skyline.
	func _glow(w: float, h: float, horizon: float) -> void:
		var depth := h * 0.34
		for i in 30:
			var f := float(i) / 30.0
			draw_rect(Rect2(0.0, horizon - f * depth, w, depth / 30.0 + 1.0),
				Color(UIPalette.SODIUM.r, UIPalette.SODIUM.g, UIPalette.SODIUM.b,
					(1.0 - f) * (1.0 - f) * 0.06))

	## The road. Every smear is a light source, smeared by water.
	func _road(rng: RandomNumberGenerator, w: float, h: float, horizon: float) -> void:
		var road := h - horizon
		var scale := w / 1600.0
		for i in 34:
			var tint := UIPalette.SODIUM if rng.randf() < 0.62 else UIPalette.CYAN
			var a := rng.randf_range(0.025, 0.085)
			var sw := rng.randf_range(2.0, 24.0) * scale
			var sl := rng.randf_range(0.10, 0.80) * road
			var x := rng.randf() * w
			draw_rect(Rect2(x, horizon, sw, sl), Color(tint.r, tint.g, tint.b, a))
			# The soft halo around a bright smear; without it the streak reads as
			# a painted stripe rather than a reflection.
			draw_rect(Rect2(x - sw, horizon, sw * 3.0, sl * 0.4),
				Color(tint.r, tint.g, tint.b, a * 0.35))
