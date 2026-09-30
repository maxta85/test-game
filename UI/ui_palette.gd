class_name UIPalette
extends RefCounted
## The front door's visual language, in one place.
##
## Colours are lifted from ART_DIRECTION.md so the menus and the street are the
## same night: a deep blue-black ground, sodium warm for anything the player can
## act on, cool mercury for anything informational, and saturated colour only on
## small bright things.
##
## Every widget in UI/ is built from these factories rather than from the default
## theme. That is the whole point of the file: a VBoxContainer of stock Buttons is
## the failure this project is explicitly not shipping, and the difference is
## about a hundred lines of styling that belongs in one place.

const NIGHT := Color(0.019608, 0.027451, 0.047059)      ## #05070c page ground
const SKY_TOP := Color(0.015686, 0.023529, 0.043137)    ## #04060b the top of the sky
const SKY_BOTTOM := Color(0.082353, 0.062745, 0.047059) ## #15100c the road, taking the sodium
const CBD := Color(0.031373, 0.050980, 0.094118)       ## #080d18 distant skyline silhouette
const PANEL := Color(0.047059, 0.066667, 0.105882)      ## #0c111b a card
const RULE := Color(0.137255, 0.192157, 0.290196)       ## #23314a hairlines, dividers, empty state
const SODIUM := Color(1.000000, 0.627451, 0.239216)     ## #ffa03d warm accent: actionable, live
const MERCURY := Color(0.721569, 0.831373, 1.000000)    ## #b8d4ff cool informational
const CYAN := Color(0.200000, 0.878431, 0.878431)       ## #33e0e0
const MAGENTA := Color(1.000000, 0.239216, 0.478431)    ## #ff3d7a
const CASH := Color(0.443137, 0.827451, 0.501961)       ## #71d380 the wallet
const TEXT := Color(0.898039, 0.894118, 0.878431)       ## #e5e4e0
const DIM := Color(0.541176, 0.584314, 0.658824)        ## #8a95a8 secondary type
const FAINT := Color(0.223529, 0.258824, 0.309804)      ## #39424f tertiary type, disabled
const FOCUS_TEXT := Color(1.0, 0.850980, 0.627451)     ## #ffd9a0 a focused row's label

# Type scale. One ladder, used everywhere: a screen that invents its own sizes
# is how a set of menus stops looking like one product.
const SIZE_KICKER := 15
const SIZE_HINT := 15
const SIZE_META := 17
const SIZE_BODY := 20
const SIZE_ROW := 23
const SIZE_STAT := 26
const SIZE_HEAD := 32
const SIZE_TITLE := 58
const SIZE_HERO := 84

static var _font: SystemFont = null


## One monospace family for the whole front of house. A tuner reads in mono, and
## more practically the numbers line up in a column without per-label fiddling.
## SystemFont rather than a bundled .ttf: no asset to ship or license, and it
## degrades to whatever monospace the platform has.
static func font() -> Font:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray([
			"DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "monospace"])
	return _font


static func label(text: String, size: int, colour: Color = TEXT,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A menu row: no fill, no rounded corner, a hairline underneath. The focus state
## is a warm bar down the left edge, so which row is live is legible at a glance
## and without a mouse.
static func button(text: String, size: int = SIZE_ROW) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", font())
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", SODIUM)
	b.add_theme_color_override("font_focus_color", Color(1.0, 0.850980, 0.627451))
	b.add_theme_color_override("font_pressed_color", SODIUM)
	b.add_theme_color_override("font_disabled_color", FAINT)
	b.add_theme_stylebox_override("normal", _row(Color(0, 0, 0, 0), RULE, 1))
	b.add_theme_stylebox_override("hover", _row(_tint(SODIUM, 0.10), SODIUM, 1))
	b.add_theme_stylebox_override("pressed", _row(_tint(SODIUM, 0.22), SODIUM, 1))
	b.add_theme_stylebox_override("focus", _focus_row())
	b.add_theme_stylebox_override("disabled",
		_row(Color(0, 0, 0, 0), _tint(RULE, 0.4), 1))
	return b


## A card. `accent` draws the border in sodium, for the one panel on screen that
## is asking for the click.
static func panel(accent: bool = false, alpha: float = 0.90) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = _tint(PANEL, alpha)
	s.border_color = SODIUM if accent else RULE
	s.set_border_width_all(1)
	s.content_margin_left = 28.0
	s.content_margin_right = 28.0
	s.content_margin_top = 22.0
	s.content_margin_bottom = 22.0
	return s


## A vertical hairline used to separate columns and stat groups.
static func rule(colour: Color = RULE, weight: float = 1.0) -> ColorRect:
	var r := ColorRect.new()
	r.color = colour
	r.custom_minimum_size = Vector2(0.0, weight)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func spacer(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, height)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## A 1 px outline inset from the screen edge, like a viewfinder. It costs four
## rectangles and it is the difference between "a dark page" and "a frame".
static func viewfinder(inset: float, arm: float, colour: Color = FAINT) -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for corner in [Vector2(inset, inset), Vector2(-inset, inset),
			Vector2(inset, -inset), Vector2(-inset, -inset)]:
		var rightward: bool = corner.x < 0.0
		var downward: bool = corner.y > 0.0
		var h := ColorRect.new()
		h.color = colour
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.anchor_left = 0.0 if rightward else 1.0
		h.anchor_right = 0.0 if rightward else 1.0
		h.anchor_top = 0.0 if not downward else 1.0
		h.anchor_bottom = 0.0 if not downward else 1.0
		h.offset_left = corner.x if rightward else corner.x - arm
		h.offset_right = corner.x
		h.offset_top = corner.y
		h.offset_bottom = corner.y + (1.0 if downward else -1.0)
		c.add_child(h)
		var v := ColorRect.new()
		v.color = colour
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.anchor_left = 0.0 if rightward else 1.0
		v.anchor_right = 0.0 if rightward else 1.0
		v.anchor_top = 0.0 if not downward else 1.0
		v.anchor_bottom = 0.0 if not downward else 1.0
		v.offset_left = corner.x
		v.offset_right = corner.x + (1.0 if rightward else -1.0)
		v.offset_top = corner.y if downward else corner.y - arm
		v.offset_bottom = corner.y
		c.add_child(v)
	return c


## Race clock. Minutes always present, hundredths always two, so a column of
## finishing times lines up on the decimal point.
static func clock(t: float) -> String:
	if t < 0.0:
		return "--:--.--"
	var whole := int(t)
	var m := whole / 60
	return "%d:%05.2f" % [m, t - float(m) * 60.0]


static func money(n: int) -> String:
	return "-$%d" % -n if n < 0 else "$%d" % n


static func metres(m: float) -> String:
	return "%.0f m" % m if m < 1000.0 else "%.2f km" % (m / 1000.0)


static func _tint(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


static func _row(fill: Color, border: Color, weight: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.border_width_bottom = weight
	s.content_margin_left = 18.0
	s.content_margin_right = 18.0
	s.content_margin_top = 11.0
	s.content_margin_bottom = 11.0
	return s


static func _focus_row() -> StyleBoxFlat:
	var s := _row(_tint(SODIUM, 0.14), SODIUM, 1)
	s.border_width_left = 4
	# 4 px narrower margin, not a 4 px shift: the row's text must not move when
	# it takes the focus, or the list visibly jitters as the player walks it.
	s.content_margin_left = 14.0
	return s
