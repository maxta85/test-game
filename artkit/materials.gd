class_name ArtKitMaterials
extends RefCounted
## The shared material library. This is where most of the visual gain is, and
## most of the gain is *not* in making one material good - it is in having forty
## that are deliberately different from each other.
##
## ## The problem this solves
##
## The world used to build every surface from one flat colour per call site. A
## street was one tone of asphalt, every house was one tone of wall. That is not
## a texture problem, it is a *value* problem: with one value everywhere, nothing
## in frame has a silhouette, which is precisely the failure ART_DIRECTION.md
## describes ("lift everything until nothing has a silhouette"). Fixing it needs
## neighbouring surfaces to differ, and that means families.
##
## ## Families
##
## Every family is a group of palette roles that differ in albedo and/or
## roughness, so a street picks different members of the family per block instead
## of tiling one member over 31.7 km. `variants("asphalt_wet")` is the public
## entry point and wraps, so a caller never runs off the end of a family.
##
## ## Roughness variation is the other half
##
## A wet road is not one roughness. ART_DIRECTION.md asks for 0.10-0.18 with a
## broken-up noise so reflections are "streaky rather than a sheet of plastic".
## The four asphalt values sit at the ends of that band and each drives its
## roughness from its own noise seed, so the streaks differ per patch instead of
## being one repeated 8 m tile for the whole city.
##
## ## Caching, and why it is the draw-call story
##
## `get_()` returns the same `StandardMaterial3D` instance for the same key,
## every time. Two thousand houses therefore share six wall materials, not two
## thousand. Combined with `ArtKitBatch` - which is what actually collapses them
## into MultiMeshes - the whole static world fits in the draw-call budget
## written down in `standards.md`. Do not construct a `StandardMaterial3D`
## inline in a generator: it silently breaks both the material count and every
## batch, because two materials that are equal by value are two materials as far
## as a MultiMesh is concerned.

## Triplanar detail scale for the road: one noise tile per ~16 m.
const ROAD_UV := 0.0625
## Corrugation pitch, in metres per UV unit. Real Colorbond is 0.076 m; at the
## UV scale below that lands at about one rib per 8 cm on a wall-sized quad.
const CORRUGATION_UV := 13.0

static var _cache: Dictionary = {}
static var _noise_cache: Dictionary = {}


## The material for a key, built on first request and cached forever. Returns
## null and errors on an unknown key, because a missing material that silently
## becomes the default white is a lit white box in a dark scene.
static func get_(key: String) -> StandardMaterial3D:
	if _cache.has(key):
		return _cache[key]
	var m: StandardMaterial3D = _build(key)
	if m == null:
		push_error("ArtKitMaterials: unknown material '%s'" % key)
		return null
	_cache[key] = m
	return m


## Every key in the library, in a stable order. The check uses this to prove the
## library is varied rather than assuming it.
static func keys() -> PackedStringArray:
	var all: Array = []
	for k in _SPECS:
		all.append(String(k))
	all.sort()
	var out := PackedStringArray()
	for k in all:
		out.append(String(k))
	return out


## The keys in a family, in palette declaration order so `variants()` is stable.
static func family_keys(family: String) -> PackedStringArray:
	var out := PackedStringArray()
	for r in ArtKitPalette.family_keys(family):
		out.append("surface_" + String(r))
	return out


## A member of a family, wrapping. `variants("roof_iron", 7)` is always the same
## material, which is what makes a batch reproducible across runs.
static func variants(family: String, index: int) -> StandardMaterial3D:
	var keys := family_keys(family)
	if keys.is_empty():
		push_error("ArtKitMaterials: unknown family '%s'" % family)
		return null
	return get_(keys[posmod(index, keys.size())])


## How many distinct members a family has. A family of one is a family that is
## not varied, and the check treats that as a failure.
static func family_size(family: String) -> int:
	return family_keys(family).size()


# ------------------------------------------------------------------- noise

## A seamless procedural noise texture, cached by its parameters. Cached because
## a 256x256 NoiseTexture2D costs real time to generate and the same aggregate
## noise is wanted on every road quad in the city.
static func noise_tex(size: int, freq: float, octaves: int, seed_value: int,
		as_normal: bool = false, lo: float = 0.0, hi: float = 1.0) -> NoiseTexture2D:
	var key := "%d/%f/%d/%d/%s/%f/%f" % [size, freq, octaves, seed_value,
			str(as_normal), lo, hi]
	if _noise_cache.has(key):
		return _noise_cache[key]
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = freq
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	var tex := NoiseTexture2D.new()
	tex.width = size
	tex.height = size
	tex.seamless = true
	tex.as_normal_map = as_normal
	tex.noise = n
	# A ramp rather than raw noise. Raw FastNoiseLite output averages ~0.5 and
	# silently halves every albedo written against it, which is how a road stays
	# invisible no matter how bright the lamps get. The ramp keeps the speckle
	# and loses only the span.
	if not as_normal:
		var ramp := Gradient.new()
		ramp.set_color(0, Color(lo, lo, lo))
		ramp.set_color(1, Color(hi, hi, hi))
		tex.color_ramp = ramp
	_noise_cache[key] = tex
	return tex


# ------------------------------------------------------------------- the spec

## key -> build recipe. Written as data so the check can read the *intent* of
## each material - its roughness, whether it emits, which palette role it uses -
## without instantiating anything, and assert the library matches that intent.
## Emission energy at or above which a material counts as a light source for the
## albedo rule below, and as a bloom tier for `standards.md`. 0.5 sits in a real
## gap: the loudest faint self-lit surface is lane paint at 0.09 and the quietest
## source is a CBD window band at 1.1.
const BLOOM_FLOOR := 0.5

## How far a source's albedo is knocked down. Chosen so the brightest emitter in
## the library lands at 0.14 luminance, under the 0.18 ceiling the check enforces.
const SOURCE_ALBEDO_SCALE := 0.15

## ## The bloom budget
##
## Overexposure is about *area*, not energy. A 6.0 lens on a 0.3 m lens housing is
## a point of light; 6.0 on a two-metre panel is a floodlight that bleaches the
## frame. So every source declares a tier, and each tier declares the largest
## emitter it is allowed to be used on. `artkit_check.gd` asserts that every
## emissive material sits on a declared tier, and the tier's extent is what a
## consumer is expected to honour when it scales a lens.
##
## Read it as: energy buys you visibility, extent buys you a blown-out frame, and
## you may only spend one of them.
const BLOOM_TIERS: Dictionary = {
	6.0: {"max_extent_m": 0.7, "roles": ["headlight", "lamp_lens", "lamp_lens_cool"]},
	4.0: {"max_extent_m": 0.5, "roles": ["tail_light"]},
	3.4: {"max_extent_m": 2.0, "roles": ["neon_cyan", "neon_magenta"]},
	3.0: {"max_extent_m": 1.2, "roles": ["neon_red"]},
	1.9: {"max_extent_m": 12.0, "roles": ["glass_shop"]},
	1.5: {"max_extent_m": 12.0, "roles": ["glass_lit"]},
	1.1: {"max_extent_m": 40.0, "roles": ["cbd_window"]},
	0.55: {"max_extent_m": 12.0, "roles": ["interior_warm"]},
	0.09: {"max_extent_m": 999.0, "roles": ["paint_white", "paint_yellow", "plate"]},
}


## The bloom tier a material sits on, or an empty dictionary if it is not a source.
## Consumers scale lenses against `max_extent_m` rather than guessing.
static func bloom_tier(key: String) -> Dictionary:
	var e := emission_energy_of(key)
	var best: Dictionary = {}
	var best_energy := -1.0
	for energy in BLOOM_TIERS:
		if absf(float(energy) - e) < 0.001 and float(energy) > best_energy:
			best_energy = float(energy)
			best = BLOOM_TIERS[energy]
	return best


## Perceptual luminance of a material's albedo, 0..1. The night rules are all
## statements about this number, because "too bright at night" means exactly this.
static func albedo_luma(key: String) -> float:
	var c := albedo_of(key)
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


const _SPECS: Dictionary = {
	# ---- road. The hero surface: ART_DIRECTION.md gets four words about it. ---
	"surface_asphalt_wet_a": {"role": "asphalt_wet_a", "rough": 1.0, "noise_seed": 11, "speckle": [0.78, 1.0], "normal": 0.22, "uv": 0.0625, "spec": 1.0, "wet": [0.10, 0.14]},
	"surface_asphalt_wet_b": {"role": "asphalt_wet_b", "rough": 1.0, "noise_seed": 12, "speckle": [0.74, 1.0], "normal": 0.26, "uv": 0.0625, "spec": 1.0, "wet": [0.11, 0.15]},
	"surface_asphalt_wet_c": {"role": "asphalt_wet_c", "rough": 1.0, "noise_seed": 13, "speckle": [0.70, 1.0], "normal": 0.30, "uv": 0.0625, "spec": 1.0, "wet": [0.12, 0.16]},
	"surface_asphalt_wet_d": {"role": "asphalt_wet_d", "rough": 1.0, "noise_seed": 14, "speckle": [0.66, 1.0], "normal": 0.34, "uv": 0.0625, "spec": 1.0, "wet": [0.13, 0.18]},
	"surface_asphalt_dry": {"role": "asphalt_dry", "rough": 0.74, "noise_seed": 15, "speckle": [0.62, 1.0], "normal": 0.42, "uv": 0.08},

	# ---- markings. Emissive, faintly: a night road's paint is the one surface
	# ---- that has to survive being unlit, and a hint of emission is cheaper
	# ---- than doubling every streetlight.
	"paint_white": {"role": "paint_white", "rough": 0.22, "emit": 0.09, "emit_role": "paint_white"},
	"paint_yellow": {"role": "paint_yellow", "rough": 0.24, "emit": 0.09, "emit_role": "paint_yellow"},
	"kerb_paint": {"role": "kerb_paint", "rough": 0.46, "emit": 0.0},

	# ---- concrete. Three values because a kerb, a footpath and a gutter run
	# ---- side by side and are never the same pour.
	"concrete_a": {"role": "concrete_a", "rough": 0.82, "speckle": [0.82, 1.0], "normal": 0.26, "uv": 0.12},
	"concrete_b": {"role": "concrete_b", "rough": 0.78, "speckle": [0.80, 1.0], "normal": 0.24, "uv": 0.12},
	"concrete_c": {"role": "concrete_c", "rough": 0.72, "speckle": [0.78, 1.0], "normal": 0.22, "uv": 0.12},

	# ---- corrugated iron. Roughness is the whole variation here: the same
	# ---- albedo at 0.28 and 0.55 catches a sodium lamp completely differently,
	# ---- and a roof that is uniformly 0.42 across 2198 buildings is a roof.
	"surface_roof_iron_a": {"role": "roof_iron_a", "rough": 0.28, "metal": 0.42, "corrugate": true},
	"surface_roof_iron_b": {"role": "roof_iron_b", "rough": 0.34, "metal": 0.38, "corrugate": true},
	"surface_roof_iron_c": {"role": "roof_iron_c", "rough": 0.55, "metal": 0.18, "corrugate": true},
	"surface_roof_iron_d": {"role": "roof_iron_d", "rough": 0.40, "metal": 0.30, "corrugate": true},
	"surface_roof_iron_e": {"role": "roof_iron_e", "rough": 0.50, "metal": 0.10, "corrugate": true},

	# ---- rendered walls. Six values, and the roughness spread across them is
	# ---- what stops a street of them looking like six copies of one house.
	"surface_render_wall_a": {"role": "render_wall_a", "rough": 0.86, "speckle": [0.86, 1.0], "normal": 0.16, "uv": 0.1},
	"surface_render_wall_b": {"role": "render_wall_b", "rough": 0.80, "speckle": [0.84, 1.0], "normal": 0.16, "uv": 0.1},
	"surface_render_wall_c": {"role": "render_wall_c", "rough": 0.90, "speckle": [0.88, 1.0], "normal": 0.16, "uv": 0.1},
	"surface_render_wall_d": {"role": "render_wall_d", "rough": 0.74, "speckle": [0.82, 1.0], "normal": 0.16, "uv": 0.1},
	"surface_render_wall_e": {"role": "render_wall_e", "rough": 0.88, "speckle": [0.87, 1.0], "normal": 0.16, "uv": 0.1},
	"surface_render_wall_f": {"role": "render_wall_f", "rough": 0.68, "speckle": [0.80, 1.0], "normal": 0.16, "uv": 0.1},
	"brick": {"role": "brick", "rough": 0.92, "speckle": [0.76, 1.0], "normal": 0.34, "uv": 0.18},
	"industrial_metal": {"role": "industrial_metal", "rough": 0.46, "metal": 0.55},

	# ---- vegetation. Two-sided and a touch self-lit: a streetlight behind a
	# ---- frond should bleed a little through it. Emission at 0.05 is well
	# ---- under the threshold where foliage starts looking like a light box.
	"surface_foliage_a": {"role": "foliage_a", "rough": 0.88, "leaf": true, "transmit": 0.05},
	"surface_foliage_b": {"role": "foliage_b", "rough": 0.84, "leaf": true, "transmit": 0.055},
	"surface_foliage_c": {"role": "foliage_c", "rough": 0.94, "leaf": true, "transmit": 0.03},
	"surface_foliage_d": {"role": "foliage_d", "rough": 0.90, "leaf": true, "transmit": 0.04},
	"grass": {"role": "grass", "rough": 0.95, "leaf": true, "transmit": 0.02, "speckle": [0.70, 1.0], "normal": 0.5, "uv": 0.25},
	"dirt": {"role": "dirt", "rough": 0.97, "speckle": [0.68, 1.0], "normal": 0.55, "uv": 0.3},

	# ---- hard goods.
	"bark": {"role": "bark", "rough": 0.93, "speckle": [0.72, 1.0], "normal": 0.5, "uv": 0.4},
	"timber": {"role": "timber", "rough": 0.88, "speckle": [0.78, 1.0], "normal": 0.3, "uv": 0.35},
	"steel_galv": {"role": "steel_galv", "rough": 0.38, "metal": 0.72},
	"rust": {"role": "rust", "rough": 0.88, "metal": 0.10},
	"sign_face": {"role": "sign_face", "rough": 0.55},
	"wire": {"role": "night_base", "rough": 0.5, "metal": 0.3, "dark": true},
	"water": {"role": "water", "rough": 0.04, "metal": 0.28, "alpha": 0.88},

	# ---- glass. Dark by default: most of a residential street at 1am has
	# ---- unlit windows and that mix of lit/unlit is what makes the lit ones
	# ---- mean anything.
	"glass_dark": {"role": "glass_dark", "rough": 0.06, "metal": 0.15, "spec": 1.0},
	"glass_lit": {"role": "glass_lit", "rough": 0.10, "metal": 0.10, "emit": 1.5, "emit_role": "glass_lit"},
	"glass_shop": {"role": "glass_shop", "rough": 0.09, "metal": 0.12, "emit": 1.9, "emit_role": "glass_shop"},
	"interior_warm": {"role": "interior_warm", "rough": 0.9, "emit": 0.55, "emit_role": "interior_warm"},

	# ---- emitters. Every one of these is a palette light role or a lamp lens;
	# ---- the check asserts that, because an emissive material with a colour
	# ---- nobody chose is how a street ends up orange.
	"lamp_lens": {"role": "lamp_lens", "rough": 0.22, "emit": 6.0, "emit_role": "lamp_lens"},
	"lamp_lens_cool": {"role": "mercury", "rough": 0.22, "emit": 5.0, "emit_role": "mercury"},
	"neon_cyan": {"role": "neon_cyan", "rough": 0.25, "emit": 3.4, "emit_role": "neon_cyan"},
	"neon_magenta": {"role": "neon_magenta", "rough": 0.25, "emit": 3.4, "emit_role": "neon_magenta"},
	"neon_red": {"role": "neon_red", "rough": 0.25, "emit": 3.0, "emit_role": "neon_red"},
	# ---- the hero object. Read `standards.md` "Night presentation" before
	# ---- touching any of these numbers: they are the ones a render got wrong.
	#
	# Car paint is a dielectric with a clearcoat, not a metal, so `metal` stays at
	# 0 and the brightness comes from `spec` (F0 reflectance) plus low roughness.
	# Setting metallic on paint is the classic mistake: it makes a body panel look
	# like a chrome bumper, and a chrome bumper takes no shape from a light at all
	# because it has no diffuse term left to shade.
	#
	# Roughness is the interesting one. 0.06-0.16 is what makes the body read as a
	# shaped object: a highlight runs along a shoulder line and the flank falls off
	# into the dark, so the panel has a *gradient*. A "correct" matte 0.4 paint
	# under one overhead source reads flat, and flat is what the vision model
	# called "uniformly illuminated". Smoothness is the fix, not brightness.
	"car_paint_a": {"role": "car_paint_a", "rough": 0.09, "spec": 1.0, "flake": 0.05},
	"car_paint_b": {"role": "car_paint_b", "rough": 0.12, "spec": 1.0, "flake": 0.05},
	"car_paint_c": {"role": "car_paint_c", "rough": 0.10, "spec": 1.0, "flake": 0.06},
	"car_paint_d": {"role": "car_paint_d", "rough": 0.13, "spec": 1.0, "flake": 0.05},
	"car_paint_e": {"role": "car_paint_e", "rough": 0.11, "spec": 1.0, "flake": 0.06},
	"car_paint_f": {"role": "car_paint_f", "rough": 0.16, "spec": 1.0, "flake": 0.04},
	"tyre": {"role": "tyre", "rough": 0.92, "spec": 0.18},
	"car_glass": {"role": "car_glass", "rough": 0.05, "metal": 0.10, "spec": 1.0},
	"chrome": {"role": "chrome", "rough": 0.08, "metal": 1.0},
	"plate": {"role": "plate", "rough": 0.35, "emit": 0.09, "emit_role": "plate"},
	"contact_shadow": {"role": "night_base", "unshaded_mul": true, "core": 0.18},

	"cbd_glass": {"role": "cbd_glass", "rough": 0.42, "metal": 0.2},
	"cbd_window": {"role": "cbd_window", "rough": 0.3, "emit": 1.1, "emit_role": "cbd_window"},
	"tail_light": {"role": "tail_light", "rough": 0.2, "emit": 4.0, "emit_role": "tail_light"},
	"headlight": {"role": "headlight", "rough": 0.2, "emit": 6.0, "emit_role": "headlight"},
}


static func _build(key: String) -> StandardMaterial3D:
	if not _SPECS.has(key):
		return null
	var spec: Dictionary = _SPECS[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = ArtKitPalette.color(String(spec.get("role", "")))
	if bool(spec.get("dark", false)):
		m.albedo_color = m.albedo_color * 0.6
	m.roughness = float(spec.get("rough", 0.8))
	m.metallic = float(spec.get("metal", 0.0))
	if spec.has("spec"):
		m.metallic_specular = float(spec["spec"])
	else:
		m.metallic_specular = 0.5

	# Aggregate / render speckle. `speckle` is the ramp the noise is compressed
	# into, so the material keeps its authored albedo and gains the aggregate on
	# top rather than being averaged down by raw noise.
	if spec.has("speckle"):
		var ramp: Array = spec["speckle"]
		m.albedo_texture = noise_tex(256, 0.9, 4, int(spec.get("noise_seed", 11)),
				false, float(ramp[0]), float(ramp[1]))
		var uv := float(spec.get("uv", 0.1))
		m.uv1_scale = Vector3(uv, uv, uv)
		m.uv1_triplanar = true
	if float(spec.get("normal", 0.0)) > 0.0:
		m.normal_enabled = true
		m.normal_texture = noise_tex(256, 1.7, 5, int(spec.get("noise_seed", 11)) + 500, true)
		m.normal_scale = float(spec["normal"])

	# Wet asphalt. `ART_DIRECTION.md` asks for "a broken-up roughness noise so
	# reflections are streaky rather than a sheet of plastic", and that is a
	# roughness *texture*, not a roughness scalar - a scalar gives every road in
	# the city the same mirror. The ramp is the wet/dry variation across the
	# carriageway: near-specular in the puddles, matt where the water has gone.
	# `rough` is left at 1.0 because it multiplies this texture.
	if spec.has("wet"):
		var wet: Array = spec["wet"]
		m.roughness_texture = noise_tex(256, 2.4, 4, int(spec.get("noise_seed", 11)) + 900,
				false, float(wet[0]), float(wet[1]))
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED

	# Corrugation. Stripes in UV rather than a modelled rib, because 2198
	# buildings with modelled ribs is 2198 buildings of wasted triangles and at
	# street distance nobody can tell.
	if bool(spec.get("corrugate", false)):
		var cu := CORRUGATION_UV
		m.uv1_scale = Vector3(1.0, cu, cu)
		m.uv1_triplanar = false
		# A vertical albedo stripe is what actually reads as ribbing under a
		# raking light, so the corrugation is albedo as well as roughness.
		m.albedo_color = m.albedo_color.lightened(0.06)

	# Foliage: two-sided, and a little self-lit so a lamp behind a frond bleeds
	# through rather than the frond reading as a hole in the light.
	if bool(spec.get("leaf", false)):
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		var t := float(spec.get("transmit", 0.05))
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = t

	# ## An emitter's brightness belongs to emission, never to albedo
	#
	# A material with emission energy above BLOOM_FLOOR is a light source, and a
	# light source's *albedo* has to be dark. This is the single most important
	# rule in the file and it was learned from a render, not from a document.
	#
	# The lead's night frame of the hero car came back described as "harshly and
	# uniformly illuminated in a near pitch-black void", with "extreme bloom and
	# overexposure from a glowing overhead source". The car was fine. The library
	# was not: `headlight` had albedo #fff2d8 - luminance 0.95 - *and* emission at
	# 6.0. That is a white slab. It reflects the overhead light diffusely, so it is
	# lit as hard and as flatly as everything else, and then it glows on top of
	# that, so it clips. Ten of the brightest materials in this library were all
	# emitters with a bright albedo, which is not a coincidence: the emission
	# colour is the one you reach for when picking an emitter's colour, and then
	# it lands in the albedo as well.
	#
	# Darkening the albedo to SOURCE_ALBEDO_MAX leaves the emission, the energy and
	# the bloom behaviour exactly as authored. What disappears is the diffuse
	# slab, and with it the "uniformly illuminated" half of the complaint. The
	# emitter goes back to being a small bright thing in a dark scene, which is
	# what ART_DIRECTION.md asks for: "a beam visible, never the thing that lights
	# the scene", "every lamp a small, bright, saturated point - not a wide dim
	# wash".
	#
	# The carve-out is the faint self-lit surfaces below BLOOM_FLOOR - lane paint
	# at 0.09, foliage at 0.05. Those are not sources, and a white lane marking has
	# to be white or it is not a lane marking.
	var emit_e := float(spec.get("emit", 0.0))
	if emit_e > BLOOM_FLOOR:
		m.albedo_color = m.albedo_color * SOURCE_ALBEDO_SCALE
		m.albedo_color.a = 1.0
	if emit_e > 0.0:
		m.emission_enabled = true
		m.emission = ArtKitPalette.color(String(spec.get("emit_role", spec.get("role", ""))))
		m.emission_energy_multiplier = emit_e

	if spec.has("alpha"):
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a = float(spec["alpha"])

	# ## Contact darkening
	#
	# A multiply decal. Unshaded, multiplied into whatever is under it, white at
	# the rim and dark in the middle, so it darkens the road under a car and
	# blends to nothing at the edge with no alpha sorting and no light of its own.
	#
	# This is the answer to "the car floats in a void". A shadow map needs a light
	# with a shadow budget and it costs a render pass; a multiply decal costs one
	# quad and two triangles, works with no lights at all, and - the reason it
	# matters - is the only contact cue that survives when the car's own lights are
	# the brightest thing in frame. Contact darkening is what tells the eye the
	# tyre is *touching* the tarmac rather than hovering over it.
	if bool(spec.get("unshaded_mul", false)):
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.albedo_texture = _radial_falloff(float(spec.get("core", 0.18)))
		m.albedo_color = Color(1, 1, 1, 1)
	return m


## A radial gradient, white at the rim and `core` at the centre, cached by core.
## stdlib only - a GradientTexture2D is a generated texture, not a file.
static var _falloffs: Dictionary = {}


static func _radial_falloff(core: float) -> GradientTexture2D:
	var key := "%.3f" % core
	if _falloffs.has(key):
		return _falloffs[key]
	var g := Gradient.new()
	g.set_color(0, Color(core, core * 0.92, core * 1.05))
	g.set_color(1, Color(1, 1, 1, 1))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 256
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 1.0)
	_falloffs[key] = t
	return t


# ----------------------------------------------------------------- inspection

## The albedo a key actually ends up with, or Color(0,0,0,0) if the key is
## unknown. The check compares these across the library: N materials that all
## came out the same colour is a failure, not a pass.
static func albedo_of(key: String) -> Color:
	var m := get_(key)
	return m.albedo_color if m != null else Color(0, 0, 0, 0)


static func roughness_of(key: String) -> float:
	var m := get_(key)
	return m.roughness if m != null else -1.0


static func emission_of(key: String) -> Color:
	var m := get_(key)
	if m == null or not m.emission_enabled:
		return Color(0, 0, 0, 0)
	return m.emission


static func emission_energy_of(key: String) -> float:
	var m := get_(key)
	if m == null or not m.emission_enabled:
		return 0.0
	return m.emission_energy_multiplier


## The palette role a material's albedo came from, so a caller can reason about
## the library without poking at StandardMaterial3D internals.
static func role_of(key: String) -> String:
	if not _SPECS.has(key):
		return ""
	return String(_SPECS[key].get("role", ""))