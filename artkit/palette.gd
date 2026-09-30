class_name ArtKitPalette
extends RefCounted
## The colour vocabulary of Cairns After Dark, as named roles.
##
## Every colour in the game comes from here. No other file is allowed to write a
## hex literal, because a hex literal in `world_builder.gd` is a colour nobody
## chose, and a street whose colours were chosen one at a time at 3am is the
## single-hue-orange failure ART_DIRECTION.md opens by naming.
##
## The nine LIGHT roles are lifted verbatim out of the palette table in
## `ART_DIRECTION.md`, including the label the doc uses, and `artkit_check.gd`
## reads that table back and fails if the two ever drift. Below them are the
## emission colours the materials use but the doc does not name - lit glass, an
## interior glow, a luminaire lens, a lane marking - and they are light roles too,
## because a role is a light role exactly when saturated colour is allowed to
## stand next to its name. Everything else is a SURFACE role, and the rule those
## follow is the doc's rule:
##
##     saturated colour is a light source, not a surface.
##
## So a surface role is never a saturated hue. A cream Queensland wall is
## `render_wall_a` at #35322c - a dark warm neutral that reads as cream the
## moment a sodium lamp hits it. Paint the wall cream in the albedo and the
## wall is a flat grey block in daylight and a blown-out orange slab under a
## lamp; both are wrong. The lamp supplies the colour, the surface supplies the
## value. That is why the surface roles are compressed into a narrow dark band
## and why the saturation budget is spent entirely on the light roles.
##
## Usage:
##     var m := ArtKitMaterials.get_("asphalt_wet_b")   # resolves via palette
##     ArtKitPalette.color("sodium")                     # -> Color(1, 0.63, 0.24)
##
## The one place a hex is allowed to be a hex literal is this file.

## role -> {"hex": "rrggbb", "use": where it belongs, "doc": the label used in
## ART_DIRECTION.md's palette table ("" if the doc does not name it),
## "emits": true for the seven light roles (absent otherwise)}.
##
## Every entry needs a non-empty `use`. A role nobody can place is a role that
## will be placed at random.
const ROLES: Dictionary = {
	# --- light sources. The doc's table, verbatim. -----------------------------
	# These are the only saturated colours in the game.
	"night_base": {
		"hex": "0a0d16",
		"use": "sky zenith, the clear-colour, and the floor of every unlit surface",
		"doc": "Base night",
	},
	"city_glow": {
		"hex": "1a2438",
		"use": "the cool band low on the horizon behind the CBD silhouette",
		"doc": "City glow",
	},
	"sodium": {
		"hex": "ffa03d",
		"use": "streetlights, porch lights, car park floods - the warm side of the contrast",
		"doc": "Sodium",
		"emits": true,
	},
	"mercury": {
		"hex": "b8d4ff",
		"use": "shopfront glazing, car yards, floodlit industrial, bus shelter panels",
		"doc": "Mercury / shopfront",
		"emits": true,
	},
	"neon_cyan": {
		"hex": "33e0e0",
		"use": "signage only. Never a wall, never a roof, never a car",
		"doc": "Neon accents",
		"emits": true,
	},
	"neon_magenta": {
		"hex": "ff3d7a",
		"use": "signage only, and sparingly. The doc calls the accents out as accents",
		"doc": "Neon accents",
		"emits": true,
	},
	"neon_red": {
		"hex": "ff2d2d",
		"use": "signage only - hotel vacancy, takeaway, kebab",
		"doc": "Neon accents",
		"emits": true,
	},
	"tail_light": {
		"hex": "ff1a0a",
		"use": "every car's tail lights, always on, brighter under braking",
		"doc": "Tail lights",
		"emits": true,
	},
	"headlight": {
		"hex": "fff2d8",
		"use": "every car's headlights, always on, and the road cone they throw",
		"doc": "Headlights",
		"emits": true,
	},

	# --- road surfaces. Four wet values because a street is never one tone. ---
	"asphalt_wet_a": {
		"hex": "14161c",
		"use": "fresh-sealed carriageway. The darkest and glossiest of the four",
		"doc": "",
	},
	"asphalt_wet_b": {
		"hex": "191a21",
		"use": "the default carriageway. This is the value most of a street wears",
		"doc": "",
	},
	"asphalt_wet_c": {
		"hex": "1e1f24",
		"use": "worn wheel tracks, where the seal has been polished off the aggregate",
		"doc": "",
	},
	"asphalt_wet_d": {
		"hex": "23242b",
		"use": "old overlay and patched repairs. The lightest, the least reflective",
		"doc": "",
	},
	"asphalt_dry": {
		"hex": "26262b",
		"use": "shoulders, the industrial yard, car park aprons - not rain-slicked",
		"doc": "",
	},

	# --- kerbs, footpaths, concrete. ------------------------------------------
	"concrete_a": {
		"hex": "2e2e30",
		"use": "kerb faces, the workhorse",
		"doc": "",
	},
	"concrete_b": {
		"hex": "35353a",
		"use": "footpaths, driveways, the lighter poured slabs",
		"doc": "",
	},
	"concrete_c": {
		"hex": "3a3a40",
		"use": "gutter edges and kerb ramps. Reads as the cleanest concrete in the scene",
		"doc": "",
	},
	"kerb_paint": {
		"hex": "6b6a63",
		"use": "painted kerb. Queensland paints no-stopping kerbs and nothing else",
		"doc": "",
	},
	"paint_white": {
		"hex": "8c8a80",
		"use": "lane markings, crosswalk stripes, give-way bars",
		"doc": "",
		"emits": true,
	},
	"paint_yellow": {
		"hex": "7a5c18",
		"use": "the solid centreline on arterials, and edge lines on curves",
		"doc": "",
		"emits": true,
	},

	# --- corrugated iron. Five values: Queensland re-roofs are never one age. --
	"roof_iron_a": {
		"hex": "2a2b2c",
		"use": "new-ish Colorbond, the neutral dark grey",
		"doc": "",
	},
	"roof_iron_b": {
		"hex": "33302c",
		"use": "brown and cream Colorbond, the most common suburban colour",
		"doc": "",
	},
	"roof_iron_c": {
		"hex": "3a3129",
		"use": "rusted-through old iron. Cairns humidity is unkind to corrugated",
		"doc": "",
	},
	"roof_iron_d": {
		"hex": "2c3334",
		"use": "the green-grey that reads as 'pale green roof'. Cairns has thousands",
		"doc": "",
	},
	"roof_iron_e": {
		"hex": "3b3a35",
		"use": "whitewashed and sun-bleached. The value that makes a suburb read tropical",
		"doc": "",
	},

	# --- rendered walls. Six, because it is forty years of paint. --------------
	"render_wall_a": {
		"hex": "35322c",
		"use": "cream. The default Queenslander",
		"doc": "",
	},
	"render_wall_b": {
		"hex": "2f3730",
		"use": "pale mint",
		"doc": "",
	},
	"render_wall_c": {
		"hex": "3a342c",
		"use": "sand and tan",
		"doc": "",
	},
	"render_wall_d": {
		"hex": "2b2f31",
		"use": "slate grey",
		"doc": "",
	},
	"render_wall_e": {
		"hex": "3c3229",
		"use": "pale terracotta. The one warm wall value, and it wants a cool lamp",
		"doc": "",
	},
	"render_wall_f": {
		"hex": "333433",
		"use": "off-white, the wall that picks up sodium hardest",
		"doc": "",
	},
	"brick": {
		"hex": "3a2a24",
		"use": "brick veneer and the older CBD infill",
		"doc": "",
	},
	"industrial_metal": {
		"hex": "2f3338",
		"use": "pre-painted shed cladding, roller doors, silo and stack",
		"doc": "",
	},

	# --- vegetation. Four, so a verge is not one green. -----------------------
	"foliage_a": {
		"hex": "16240f",
		"use": "palm fronds. The darkest green in the scene, on purpose",
		"doc": "",
	},
	"foliage_b": {
		"hex": "1b2a12",
		"use": "broadleaf canopy and street trees",
		"doc": "",
	},
	"foliage_c": {
		"hex": "232c14",
		"use": "dry scrub and dead frond skirt. Warmer, so it separates from live",
		"doc": "",
	},
	"foliage_d": {
		"hex": "1d2410",
		"use": "low bush and vine. Lifts off foliage_a so a hedge is not a hole",
		"doc": "",
	},
	"grass": {
		"hex": "17220f",
		"use": "the ground plane beyond the kerb, and tufts on the verge",
		"doc": "",
	},
	"dirt": {
		"hex": "2a2118",
		"use": "bald earth under trees, gravel aprons, the creek line",
		"doc": "",
	},

	# --- hard goods. ----------------------------------------------------------
	"bark": {
		"hex": "26221c",
		"use": "palm and rainforest tree trunks",
		"doc": "",
	},
	"timber": {
		"hex": "2e2620",
		"use": "power poles, hardwood paling fences, treated pine",
		"doc": "",
	},
	"steel_galv": {
		"hex": "33383c",
		"use": "streetlight columns, bins, bus shelter frames, drain grates, signs",
		"doc": "",
	},
	"rust": {
		"hex": "3a2418",
		"use": "aged steel - the shed roof lip, the pole foot, the bin hinge",
		"doc": "",
	},
	"sign_face": {
		"hex": "1a1a1e",
		"use": "the unlit back of a sign panel. Reads as a hole at night, correctly",
		"doc": "",
	},
	"glass_dark": {
		"hex": "0b0d10",
		"use": "an unlit window. Most of the street is dark and that mix is the point",
		"doc": "",
	},
	"water": {
		"hex": "0a1a1c",
		"use": "open drainage channels, the Barron, anything the Wet Tropics never dries",
		"doc": "",
	},
	"cbd_glass": {
		"hex": "121620",
		"use": "the tower bodies on the horizon. A black rectangle is worse than no tower",
		"doc": "",
	},

	# --- car. The hero object, and the object the lead's night render got wrong:
	# --- a car that is "harshly and uniformly illuminated in a near pitch-black
	# --- void" is a car whose paint albedo is too light. These are six dark
	# --- values with a little hue in them, not six colours. Saturation is spent
	# --- on the light roles; a red car at night is a dark red car under a sodium
	# --- lamp, and the *reflection* is what tells you it is red.
	"car_paint_a": {
		"hex": "0e1014",
		"use": "the default hero car. Near-black neutral: maximum shape from any light",
		"doc": "",
	},
	"car_paint_b": {
		"hex": "141418",
		"use": "graphite. A shade lighter than the default for a second vehicle",
		"doc": "",
	},
	"car_paint_c": {
		"hex": "180f10",
		"use": "dark maroon. Reads as red only in the highlight, which is correct",
		"doc": "",
	},
	"car_paint_d": {
		"hex": "0d1418",
		"use": "deep blue. The cool counterweight to the sodium on the road",
		"doc": "",
	},
	"car_paint_e": {
		"hex": "101a12",
		"use": "bottle green, the classic",
		"doc": "",
	},
	"car_paint_f": {
		"hex": "1a1a1c",
		"use": "silver. The lightest value in the kit and still only 0.10 luma",
		"doc": "",
	},
	"tyre": {
		"hex": "0a0a0b",
		"use": "rubber. The darkest thing on the car, and what visually plants it on the road",
		"doc": "",
	},
	"car_glass": {
		"hex": "080a0c",
		"use": "a car's side and rear glass. Tinted to near black so it reads as a window, not a hole",
		"doc": "",
	},
	"chrome": {
		"hex": "9aa0a6",
		"use": "bumper trim and exhaust. The one legitimately mirror-like thing on a car",
		"doc": "",
	},
	"plate": {
		"hex": "9a978c",
		"use": "a number plate. Light, retroreflectively so, and faintly self-lit so it reads at a distance",
		"doc": "",
		"emits": true,
	},

	# --- emissive. Warm interiors, the lens in a lamp, the window grid on the
	# --- horizon. Distinct from the light roles but in the same family.
	"interior_warm": {
		"hex": "f0a860",
		"use": "the glow behind a lit window. The room, not the glass",
		"doc": "",
		"emits": true,
	},
	"glass_lit": {
		"hex": "ffd9a8",
		"use": "a lit domestic window pane. Deliberately paler than interior_warm - the glass washes it out",
		"doc": "",
		"emits": true,
	},
	"glass_shop": {
		"hex": "cfe0ff",
		"use": "shopfront glazing. Mercury and fluorescent, the cool counterweight to sodium",
		"doc": "",
		"emits": true,
	},
	"lamp_lens": {
		"hex": "ffb15a",
		"use": "the luminaire lens itself. Not the same value as the sodium it emits",
		"doc": "",
		"emits": true,
	},
	"cbd_window": {
		"hex": "9fb4e8",
		"use": "the lit window grid on the CBD silhouette. Most bands lit, some not",
		"doc": "",
		"emits": true,
	},
}

## Cached Color objects, so `color()` is a dictionary hit rather than a
## `Color.html()` parse on every material build.
static var _cache: Dictionary = {}


## Every role name, in declaration order.
static func roles() -> PackedStringArray:
	var out := PackedStringArray()
	for r in ROLES:
		out.append(String(r))
	return out


## True if the role exists. Always check with this rather than letting a typo
## become a silent black surface - `Color.html("")` is opaque black and a black
## building at night is invisible in a screenshot and obvious in a log.
static func has(role: String) -> bool:
	return ROLES.has(role)


## The colour for a role, or magenta if the role does not exist. Magenta, not
## black: an unknown role must be impossible to miss in a render.
static func color(role: String) -> Color:
	if _cache.has(role):
		return _cache[role]
	if not ROLES.has(role):
		push_error("ArtKitPalette: unknown role '%s'" % role)
		return Color(1, 0, 1)
	var c := Color.html(String(ROLES[role]["hex"]))
	_cache[role] = c
	return c


## The raw hex string, for the check that compares us against ART_DIRECTION.md.
static func hex_of(role: String) -> String:
	if not ROLES.has(role):
		return ""
	return String(ROLES[role]["hex"])


## Where a role is meant to be used. Prose, but it is data: the check fails on
## an empty one, which is how a role stops being a decision and starts being a
## value somebody typed.
static func use_of(role: String) -> String:
	if not ROLES.has(role):
		return ""
	return String(ROLES[role]["use"])


## The label this role carries in ART_DIRECTION.md's palette table, or "" if the
## doc does not name it. Only the light roles are named there.
static func doc_label(role: String) -> String:
	if not ROLES.has(role):
		return ""
	return String(ROLES[role]["doc"])


## The seven roles that emit rather than reflect, i.e. the roles any
## `emission` in the library, and any light colour in the game, must come from.
static func light_roles() -> PackedStringArray:
	return PackedStringArray([
		"sodium", "mercury", "neon_cyan", "neon_magenta", "neon_red",
		"tail_light", "headlight",
	])


## Does this role emit? The doc's rule is "saturated colour is a light source,
## not a surface", so this flag is what keeps a wall from being painted cyan.
## It is data, not a second hand-written list, so adding a role to the table and
## forgetting this is the only way to break it - and the check catches that.
static func is_light(role: String) -> bool:
	if not ROLES.has(role):
		return false
	return bool(ROLES[role].get("emits", false))


## How saturated a colour is: the spread between its strongest and weakest
## channel, 0.0 for grey. `artkit_check.gd` uses this to prove the split holds -
## every emitting role must be more saturated than every reflecting one.
static func saturation(role: String) -> float:
	var c := color(role)
	return maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))


## Pick a surface value from a family, wrapping. `variant("asphalt_wet", 2)`
## gives the same answer every time, which is what makes a batch reproducible.
static func variant(family: String, index: int) -> Color:
	var keys: Array = family_keys(family)
	if keys.is_empty():
		push_error("ArtKitPalette: unknown family '%s'" % family)
		return Color(1, 0, 1)
	return color(String(keys[posmod(index, keys.size())]))


## The roles in a named family, in declaration order. Families are expressed as
## a prefix so a family cannot disagree with the role it names.
static func family_keys(family: String) -> Array:
	var out: Array = []
	for r in ROLES:
		if String(r).begins_with(family):
			out.append(r)
	return out


## The families the library is built from, with their sizes. Used by the check to
## prove variation exists (a family of one is a family that is not varied) and by
## the materials library to build one material per role.
const FAMILIES: PackedStringArray = [
	"asphalt_wet_", "roof_iron_", "render_wall_", "foliage_", "car_paint_",
]
