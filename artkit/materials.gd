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


# ============================================================== real PBR sets
#
# t181. Everything below this line replaces a procedural ramp with a scanned surface
# for the residential palette, and `standards.md` §5 has been rewritten to match.
#
# ## WHAT CHANGED, AND WHY IT HAD TO HAPPEN HERE
#
# A `FastNoiseLite` ramp is not a surface. It has no scale, no plank pitch, no lap
# joint, no weathering direction, and - the thing that shows first - no *feature size*.
# `surface_render_wall_*` drew six values of speckle over a wall-sized quad, which is a
# gradient with no detail in it, and a roof drew its corrugation as a stripe in UV
# because modelling 2198 ribs is 2198 buildings of wasted triangles. Both were fakes
# that read as fakes at street distance.
#
# The sets are CC0 photo-scans from ambientCG, fetched and colour-managed by
# `artkit/textures/fetch_pbr.py`. This file does three things with them and no more:
#
#   1. LOADS each map ONCE per process, so two materials sharing a set share a
#      `Texture2D` *resource*. This is the memoisation rule and it is not optional: a
#      per-material `Image.load()` is not just wasteful, it makes every material a
#      different texture and every batch a different signature.
#   2. WIDENS the two data maps to RGBAF, which is what makes them read *linearly*.
#   3. TINTS the albedo with the palette role, which is the half a scan cannot do.
#
# ## 2 IS THE PART THAT IS EASY TO GET WRONG AND WAS
#
# A data map must not be gamma-decoded, and in Godot 4 an 8-bit image becomes an
# `*_SRGB` texture that IS decoded at sample time. Measured on this build:
#
#     Image.load(".../bitumen_n.png")            -> FORMAT_RGB8   (8-bit, sRGB)
#     img.convert(Image.FORMAT_RGBAF)            -> FORMAT_RGBAF  (float, linear)
#     pixel value through that convert           -> 0.54118 -> 0.54118, delta 0.00000
#
# Writing the maps as 16-bit PNG was the first attempt and it bought nothing: the files
# really were 16-bit on disk and `Image.load()` quantised them straight back to 8.
# The format has to be changed *here*, at texture creation, because there is no
# `.import` file to carry an sRGB flag and the kit has to work from an exported PCK.
#
# Albedo is deliberately NOT widened. A colour must stay sRGB.
#
# ## 3 IS WHY THE PALETTE STILL DECIDES EVERYTHING
#
# The scan supplies detail; `palette.gd` supplies hue. `standards.md` §4.1 - "saturated
# colour is a light source, not a surface" - is enforced by `artkit_check.gd` against
# `albedo_color`, and `albedo_color` is still the palette role. Multiplying a
# photograph by that role is the whole of the tinting: a Colorbond roof set is grey in
# the scan and arrives at the roof colour the palette asked for, with the scan's
# weathering, rib shading and rust reads intact underneath.

const PBR_DIR := "res://artkit/textures"
const PBR_MANIFEST := "res://artkit/textures/manifest.json"

## Which MatLib surface each set supersedes.
##
## `World/mat_lib.gd` is not this kit's file and is not edited by it. These names are
## the contract instead: each set replaces one named MatLib ramp, and a consumer that
## wants a ramp fallback has a one-line answer for which. `pbr_check.gd` asserts every
## `matlib` entry still names a factory that exists on MatLib, so a rename there fails
## a check here instead of silently making this table a lie.
const PBR_SETS: Dictionary = {
	"weatherboard": {
		"matlib": "wall",
		"replaces": "MatLib.wall()'s albedo speckle + normal ramp",
		"surface": "painted horizontal timber boarding - the cladding on the "
			+ "most-seen building in the game",
	},
	"corrugated_roof": {
		"matlib": "corrugated",
		"replaces": "MatLib.corrugated()'s UV-stripe corrugation",
		"surface": "Colorbond is corrugated steel; the scan supplies real ribs that "
			+ "catch a light along their length instead of a stripe in UV",
	},
	"paling_fence": {
		"matlib": "wall",
		"replaces": "the `timber` ramp's generic plank noise",
		"surface": "sawn vertical boards - a paling fence, not a plywood sheet",
	},
	"concrete_kerb": {
		"matlib": "concrete",
		"replaces": "MatLib.concrete()'s normal ramp",
		"surface": "a cast kerb pour; the red return is a palette tint of THIS set, "
			+ "not a second download",
	},
	"bitumen": {
		"matlib": "dry_asphalt",
		"replaces": "MatLib.dry_asphalt() on verges and shoulders",
		"surface": "bitumen and asphalt are the same binder; the WET hero surfaces "
			+ "are deliberately untouched - night tuning belongs to the night pass",
	},
	"grass_verge": {
		"matlib": "ground",
		"replaces": "MatLib.ground()'s grass albedo ramp",
		"surface": "the nature strip behind the kerb",
	},
}

static var _pbr_cache: Dictionary = {}
static var _pbr_manifest: Variant = null
static var _pbr_means: Dictionary = {}
static var _pbr_formats: Dictionary = {}


## The parsed ingest manifest, or {} if it is missing or malformed. Never fatal: a kit
## with no textures on disk still builds every surface from its ramp, which is the
## behaviour that made this change safe to land at all.
static func pbr_manifest() -> Dictionary:
	if _pbr_manifest == null:
		var parsed: Variant = null
		if ResourceLoader.exists(PBR_MANIFEST):
			var res := ResourceLoader.load(PBR_MANIFEST)
			if res is JSON:
				parsed = (res as JSON).data
		if not (parsed is Dictionary) and FileAccess.file_exists(PBR_MANIFEST):
			parsed = JSON.parse_string(FileAccess.get_file_as_string(PBR_MANIFEST))
		_pbr_manifest = parsed if parsed is Dictionary else {}
	return _pbr_manifest if _pbr_manifest is Dictionary else {}


## The set names on disk, sorted, so a consumer or a check can enumerate them.
static func pbr_sets() -> PackedStringArray:
	var out := PackedStringArray()
	for k in (pbr_manifest().get("sets", {}) as Dictionary).keys():
		out.append(String(k))
	out.sort()
	return out


## One map of one set as a GPU texture, built once per process.
##
## The cache key is `set/kind`, so `pbr_tex("bitumen", "c")` returns the *same object*
## for the life of the process - which is the memoisation rule applied to textures
## rather than to materials, and is the same requirement for the same reason.
##
## `kind` is "c" (albedo), "r" (roughness) or "n" (normal). "r" and "n" are widened to
## RGBAF; "c" is left sRGB. Returns null if the file is missing, and says which, because
## a null albedo texture on a wall is a wall in the palette colour with no detail and
## nothing anywhere reports it.
static func pbr_tex(setname: String, kind: String) -> Texture2D:
	var key := setname + "/" + kind
	if _pbr_cache.has(key):
		return _pbr_cache[key]
	var sets: Dictionary = pbr_manifest().get("sets", {})
	if not sets.has(setname):
		push_warning("ArtKitMaterials: unknown PBR set '%s'" % setname)
		_pbr_cache[key] = null
		return null
	var spec: Dictionary = sets[setname].get("maps", {})
	if not spec.has(kind):
		push_warning("ArtKitMaterials: set '%s' has no '%s' map" % [setname, kind])
		_pbr_cache[key] = null
		return null
	var rel := String(spec[kind].get("file", ""))
	var path := "res://" + rel
	var img := Image.new()
	if img.load(path) != OK:
		push_warning("ArtKitMaterials: cannot load %s" % path)
		_pbr_cache[key] = null
		return null
	if kind == "c":
		# A colour stays sRGB. Widening this one would desaturate the scan.
		if img.get_format() in [Image.FORMAT_L8, Image.FORMAT_LA8]:
			img.convert(Image.FORMAT_RGB8)
	elif img.get_format() != Image.FORMAT_RGBAF:
		# The data-map contract. See the header comment: without this the sampler
		# applies an sRGB decode to a roughness value and a normal direction.
		img.convert(Image.FORMAT_RGBAF)
	var tex := ImageTexture.create_from_image(img)
	_pbr_cache[key] = tex
	_pbr_means[key] = _mean_of(img)
	# Recorded rather than re-derived, so `pbr_format()` can report what the sampler
	# will get without holding a second copy of every image alive.
	_pbr_formats[key] = "%d" % img.get_format()
	return tex


## Mean of a loaded map, 0..1, cached. Used by `effective_roughness_of()` and reported
## by `pbr_check.gd`; it is the number that says what the shader is actually averaging.
static func pbr_mean(setname: String, kind: String) -> float:
	pbr_tex(setname, kind)
	return float(_pbr_means.get(setname + "/" + kind, 0.0))


## The image format a map ended up as, as a string, so a check can assert the colour
## space rather than infer it. "" if the map is not loaded.
static func pbr_format(setname: String, kind: String) -> String:
	var key := setname + "/" + kind
	pbr_tex(setname, kind)
	return String(_pbr_formats.get(key, ""))


static func _mean_of(img: Image) -> float:
	# 64x64 stride. An exact mean over 512x512x4 is 1M pixel reads per map per
	# process start, and the number is only used for reporting.
	var step := maxi(img.get_width() / 64, 1)
	var total := 0.0
	var n := 0
	var y := 0
	while y < img.get_height():
		var x := 0
		while x < img.get_width():
			total += img.get_pixel(x, y).get_luminance()
			n += 1
			x += step
		y += step
	return total / maxf(float(n), 1.0)


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


# ------------------------------------------------------------------- banding

## ## Boarded, ribbed and paled surfaces
##
## A flat albedo is why a building reads as a box. Timber weatherboard is horizontal
## boards with a shadow line under each lip; a paling fence is the same idea turned
## 90 degrees; Colorbond is a sawtooth. None of that is a colour - it is a *profile*,
## and a profile is a one-dimensional ramp, which Godot already draws. So these are
## `GradientTexture2D`s generated in-engine: no texture to source, no licence to hold.
## They are honest procedural work, not a stand-in for an asset nobody made.
##
## Each period gets its own small deterministic brightness offset, because the most
## recognisable thing about real weatherboard is that no two boards weather the same
## way. A uniform ramp reads as striped wallpaper, which is worse than the flat colour
## it replaced. The offset is centred on zero so the *mean* is untouched and only the
## spread moves - brightening every board by a positive jitter turns a cladding
## material into a lighter one by accident.
static var _band_cache: Dictionary = {}

const BOARD_PROFILE := [
	[0.00, 0.30], [0.06, 0.78], [0.18, 1.00], [0.74, 0.94], [0.90, 0.52], [1.00, 0.30],
]
const PALING_PROFILE := [
	[0.00, 0.22], [0.10, 0.86], [0.62, 1.00], [0.80, 0.44], [1.00, 0.22],
]
const RIB_PROFILE := [
	[0.00, 0.34], [0.14, 0.62], [0.42, 1.00], [0.58, 0.96], [0.86, 0.50], [1.00, 0.34],
]


## A repeating banded ramp. `vertical` runs the bands down U instead of along V,
## which is the whole difference between a paling fence and a weatherboard wall.
static func bands_tex(periods: int, profile: Array, warm: float, vertical: bool,
		seed_value: int, jitter: float = 0.10) -> GradientTexture2D:
	var key := "%d|%s|%.3f|%s|%d|%.3f" % [periods, str(profile), warm,
			str(vertical), seed_value, jitter]
	if _band_cache.has(key):
		return _band_cache[key]
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var span := 1.0 / float(maxi(periods, 1))
	for i in maxi(periods, 1):
		var base := float(i) * span
		var off := rng.randf_range(-jitter, jitter)
		for pair in profile:
			var v: float = clampf(float(pair[1]) + off, 0.0, 1.0)
			offs.append(base + float(pair[0]) * span)
			# `warm` biases red up and blue down. The palette owns base albedo; a
			# shading ramp is material data, exactly as `_palm_ring_tex` already is
			# with its `Color(v, v, v * 0.92)`.
			cols.append(Color(v * (1.0 + warm * 0.10), v, v * (1.0 - warm * 0.08)))
	g.offsets = offs
	g.colors = cols
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 8 if vertical else 128
	tex.height = 128 if vertical else 8
	if vertical:
		tex.fill_from = Vector2(0.0, 0.0)
		tex.fill_to = Vector2(1.0, 0.0)
	else:
		tex.fill_from = Vector2(0.0, 0.0)
		tex.fill_to = Vector2(0.0, 1.0)
	_band_cache[key] = tex
	return tex


# ------------------------------------------------------------------- the spec

## key -> build recipe. Written as data so the check can read the *intent* of
## each material - its roughness, whether it emits, which palette role it uses -
## without instantiating anything, and assert the library matches that intent.
## Emission energy at or above which a material counts as a light source for the
## albedo rule below, and as a bloom tier for `standards.md`. 0.5 sits in a real
## gap: the loudest faint self-lit surface is foliage at 0.05 and the quietest
## source is `interior_warm` at 0.55. The retroreflective family - lane paint,
## kerb paint, plate - sits below this line and is deliberately not a source; see
## `retro` in `_build`.
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
}
#
# There is deliberately no 0.09 tier. It used to hold `paint_white`,
# `paint_yellow` and `plate` - the retroreflective family - and its whole purpose
# was to let a lane marking and a licence plate sit on the bloom budget. That was
# the same category error as their emission, one layer over: a bloom tier is a
# declaration that a material is a light source, and it is what a consumer reads to
# decide how far it may scale a lens. A retroreflector has no business in the
# table, so removing the emission removed the row. `interior_warm` at 0.55 is now
# the quietest source in the library and foliage at 0.05 the loudest non-source.


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
	# Bitumen. The WET hero surfaces keep their ramp deliberately: they are the night
	# pass' tuning surface and `World/mat_lib.gd` documents a measured roughness band
	# for them, so swapping them here would be a night change made by a day brief.
	"surface_asphalt_dry": {"role": "asphalt_dry", "rough": 1.00, "noise_seed": 15, "pbr": "bitumen", "normal": 0.50, "uv": 0.45},

	# ---- markings. Retroreflective, NOT emissive.
	# ----
	# ---- These three were `rough: 0.22, emit: 0.09` - a faintly self-lit
	# ---- mirror - and that is a category error, not a tuning miss. Retroreflection
	# ---- is light returned *from* a source, near the direction it arrived from.
	# ---- Emission is light the surface makes itself, from nowhere, in every
	# ---- direction at once. The two read identically on a lit dash and
	# ---- oppositely everywhere else: an emissive line is exactly as visible on a
	# ---- stretch with no lamp as under one, which is the tell that it is a decal.
	# ---- `World/mat_lib.gd` reached the same conclusion independently and
	# ---- `artkit/props.gd` already documents it for the sign plates ("a sign
	# ---- that glows is a lie about the world"), so the kit contradicting its
	# ---- own neighbours was a real inconsistency, not a house style.
	# ----
	# ---- Roughness is the half that actually does the work here. 0.22 is a
	# ---- near-mirror: a horizontal dash reflects the sky and the lamp heads down
	# ---- its own length and reads as a strip of chrome. Thermoplastic measures
	# ---- about 0.55-0.62, and matte is what returns the lamp diffusely - which is
	# ---- the whole mechanism. So the paint is now matte and carries no emission
	# ---- at all; a dash brightens as the car comes under a lamp and goes dark
	# ---- between lamps, which is the behaviour that makes a street readable at
	# ---- speed.
	# ----
	# ---- `retro` is what replaces the emission: it is the flag that says "this
	# ---- surface returns light toward the viewer", and it drives the specular
	# ---- below. It is not a light source and never enters a bloom tier.
	"paint_white": {"role": "paint_white", "rough": 0.58, "retro": 0.52, "spec": 0.34, "wear": 0.13},
	"paint_yellow": {"role": "paint_yellow", "rough": 0.60, "retro": 0.52, "spec": 0.34, "wear": 0.13},
	# The red return keeps the retro/spec it gained above and takes t181's concrete
	# scan underneath it, because the whole point of that scan is that the red return
	# is the *same pour of concrete wearing council paint* rather than a second
	# material. `rough` is t181's 0.89, not the 0.52 this key carried before the set
	# existed: with `pbr` set, `rough` is a multiplier on the map's mean (0.5142), so
	# 0.52 would have meant an effective 0.267 - a near-mirror - while 0.89 lands at
	# 0.458, just under `concrete_a`'s 0.820. Painted, and still smoother than bare.
	"kerb_paint": {"role": "kerb_paint", "rough": 0.89, "retro": 0.40, "spec": 0.30, "pbr": "concrete_kerb", "normal": 0.40, "uv": 0.4},

	# ---- concrete. Three values because a kerb, a footpath and a gutter run
	# ---- side by side and are never the same pour.
	"concrete_a": {"role": "concrete_a", "rough": 1.59, "pbr": "concrete_kerb", "normal": 0.40, "uv": 0.4},
	"concrete_b": {"role": "concrete_b", "rough": 1.52, "pbr": "concrete_kerb", "normal": 0.40, "uv": 0.4},
	"concrete_c": {"role": "concrete_c", "rough": 1.40, "pbr": "concrete_kerb", "normal": 0.40, "uv": 0.4},

	# ---- corrugated iron. Roughness is the whole variation here: the same
	# ---- albedo at 0.28 and 0.55 catches a sodium lamp completely differently,
	# ---- and a roof that is uniformly 0.42 across 2198 buildings is a roof.
	"surface_roof_iron_a": {"role": "roof_iron_a", "rough": 0.707, "metal": 0.42, "corrugate": true, "pbr": "corrugated_roof", "normal": 0.45, "uv": 0.35},
	"surface_roof_iron_b": {"role": "roof_iron_b", "rough": 0.858, "metal": 0.38, "corrugate": true, "pbr": "corrugated_roof", "normal": 0.45, "uv": 0.35},
	"surface_roof_iron_c": {"role": "roof_iron_c", "rough": 1.388, "metal": 0.18, "corrugate": true, "pbr": "corrugated_roof", "normal": 0.45, "uv": 0.35},
	"surface_roof_iron_d": {"role": "roof_iron_d", "rough": 1.009, "metal": 0.30, "corrugate": true, "pbr": "corrugated_roof", "normal": 0.45, "uv": 0.35},
	"surface_roof_iron_e": {"role": "roof_iron_e", "rough": 1.262, "metal": 0.10, "corrugate": true, "pbr": "corrugated_roof", "normal": 0.45, "uv": 0.35},

	# ---- rendered walls. Six values, and the roughness spread across them is
	# ---- what stops a street of them looking like six copies of one house.
	# `board` puts weatherboard on all six: painted fibre-cement sheet is what a
	# Queensland house actually is, so boarding belongs to this family rather than to
	# a new one. A new family would need palette roles, and `variants("render_wall", i)`
	# is the documented entry point for these.
	#
	# The `board: "h"` ramp that used to carry that boarding is gone: t181 replaced the
	# fake with the weatherboard scan, and a procedural lap line drawn under a real
	# photo of painted boarding is two lap lines. The six `rough` scalars are re-derived
	# multipliers on the scan's mean (0.5726), so they hold their spread while
	# `effective_roughness_of()` reports what the shader sees.
	"surface_render_wall_a": {"role": "render_wall_a", "rough": 0.86, "pbr": "weatherboard", "normal": 0.55, "uv": 0.5},
	"surface_render_wall_b": {"role": "render_wall_b", "rough": 1.397, "pbr": "weatherboard", "normal": 0.55, "uv": 0.5},
	"surface_render_wall_c": {"role": "render_wall_c", "rough": 1.572, "pbr": "weatherboard", "normal": 0.55, "uv": 0.5},
	"surface_render_wall_d": {"role": "render_wall_d", "rough": 1.292, "pbr": "weatherboard", "normal": 0.55, "uv": 0.5},
	"surface_render_wall_e": {"role": "render_wall_e", "rough": 1.537, "pbr": "weatherboard", "normal": 0.55, "uv": 0.5},
	"surface_render_wall_f": {"role": "render_wall_f", "rough": 1.188, "pbr": "weatherboard", "normal": 0.55, "uv": 0.5},
	"brick": {"role": "brick", "rough": 0.92, "speckle": [0.76, 1.0], "normal": 0.34, "uv": 0.18},
	"industrial_metal": {"role": "industrial_metal", "rough": 0.46, "metal": 0.55},

	# ---- paling fence. Three values because a fence line is the first thing a
	# ---- viewer reads about a boundary, and one paling material makes a whole
	# ---- street the same fence. 10 palings per 1.6 m tile is a 160 mm
	# ---- board-and-gap pitch, which is what a paling fence measures once the gap
	# ---- is counted. Warm: the reference fence is a red-brown, and under the
	# ---- sodium in this scene a warm albedo is what keeps it from going grey.
	"paling_a": {"role": "timber", "rough": 0.90, "board": "v", "paling_seed": 5501, "paling_jitter": 0.16},
	"paling_b": {"role": "timber", "rough": 0.84, "board": "v", "paling_seed": 5502, "paling_jitter": 0.20},
	"paling_c": {"role": "timber", "rough": 0.94, "board": "v", "paling_seed": 5503, "paling_jitter": 0.13},

	# ---- vegetation. Two-sided and a touch self-lit: a streetlight behind a
	# ---- frond should bleed a little through it. Emission at 0.05 is well
	# ---- under the threshold where foliage starts looking like a light box.
	"surface_foliage_a": {"role": "foliage_a", "rough": 0.88, "leaf": true, "transmit": 0.05},
	"surface_foliage_b": {"role": "foliage_b", "rough": 0.84, "leaf": true, "transmit": 0.055},
	"surface_foliage_c": {"role": "foliage_c", "rough": 0.94, "leaf": true, "transmit": 0.03},
	"surface_foliage_d": {"role": "foliage_d", "rough": 0.90, "leaf": true, "transmit": 0.04},
	# `grass` is `bush_scrub`'s material, so it sits on the same verge `MatLib.ground()`
	# draws. Lifted with it, for the same measured reason and by the same amount: at
	# the palette's #17220f this is 24/255, below the wet tarmac it borders at 28/255,
	# so a verge planted with these read as a hole rather than a bank. Two greens that
	# do not match would be worse than either value.
	#
	# That `value` lift survives t181. `value` multiplies `albedo_color` - the palette
	# role - and `_attach_pbr()` deliberately leaves the role in `albedo_color` to be
	# multiplied by the scan, so the lift is orthogonal to where the detail comes from.
	# `rough` is now t181's 3.64 against the grass scan's 0.2611 mean, which lands on
	# effective 0.95 - the same number the ramp spec carried, by construction.
	"grass": {"role": "grass", "rough": 3.64, "leaf": true, "transmit": 0.02, "pbr": "grass_verge", "normal": 0.70, "uv": 1.6, "value": [1.275, 1.763, 1.395]},
	"dirt": {"role": "dirt", "rough": 0.97, "speckle": [0.68, 1.0], "normal": 0.55, "uv": 0.3},

	# ---- hard goods.
	"bark": {"role": "bark", "rough": 0.93, "speckle": [0.72, 1.0], "normal": 0.5, "uv": 0.4},
	"timber": {"role": "timber", "rough": 1.52, "pbr": "paling_fence", "normal": 0.60, "uv": 0.7},
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
	# The lit face of a shopfront sign fascia - cool white, so the mercury role.
	# It is NOT `lamp_lens_cool` at a lower setting: that is the luminaire lens
	# role, whose 5.0 is tuned for a small intense source, and a fascia is a large
	# flat face that covers several square metres. Emission energy times area is
	# what a street actually receives, so moving the same 5.0 onto a 4.2 x 0.95 m
	# panel raised the whole strip's clipping instead of lowering it (measured:
	# mean 0.167 -> 0.182, clipped 0.057 -> 0.061 across the three poses).
	#
	# 2.2 is derived, not chosen. The old bars were 0.52 x 4.6 m (2.39 m2) at
	# 3.0-3.4 for twelve shops in sixteen and 6.0 for four, averaging 9.63 of
	# energy-times-area per shop over the sixteen. Holding the three neon accents
	# at their existing energies, 2.2 on the 3.99 m2 fascia puts the same total
	# back into the street - so the shape can change without the exposure moving.
	"sign_face_lit": {"role": "mercury", "rough": 0.22, "emit": 2.2, "emit_role": "mercury"},
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
	# A plate is the purest retroreflector in the library and it was authored the
	# same wrong way as the road paint: `emit: 0.09`. A plate that glows is a
	# plate you can see from directly above with every light off, which is not a
	# property plates have. It is `retro` at a high value and matte - sheeting is
	# matte, and the return toward the viewer is the entire point.
	"plate": {"role": "plate", "rough": 0.44, "retro": 0.62, "spec": 0.38},
	"contact_shadow": {"role": "night_base", "unshaded_mul": true, "core": 0.18},

	"cbd_glass": {"role": "cbd_glass", "rough": 0.42, "metal": 0.2},
	"cbd_window": {"role": "cbd_window", "rough": 0.3, "emit": 1.1, "emit_role": "cbd_window"},
	"tail_light": {"role": "tail_light", "rough": 0.2, "emit": 4.0, "emit_role": "tail_light"},
	"headlight": {"role": "headlight", "rough": 0.2, "emit": 6.0, "emit_role": "headlight"},
}


static func _build(key: String) -> StandardMaterial3D:
	if not _SPECS.has(key):
		return null
	return build_spec(_SPECS[key])


## Build a material from a spec dictionary, uncached.
##
## Public because `artkit/pbr_shot.gd --ramp` needs it: the BEFORE frame of the
## before/after pair is the same spec with its `pbr` field erased, rebuilt from scratch,
## so the two frames differ only in whether the scan was attached. Mutating `_SPECS` to
## get that would be the wrong trade - it is a shared const table and a cache that is
## meant to hold one object per key for the life of the process.
##
## Deliberately NOT cached: a caller that wants a library material wants `get_()`, and a
## caller that wants a mutated one wants a fresh object.
static func build_spec(spec: Dictionary) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = ArtKitPalette.color(String(spec.get("role", "")))
	if spec.has("value"):
		# An explicit per-channel multiplier on a palette role. Used only where the
		# palette's own value is measurably wrong for this scene - see `grass`.
		var v: Array = spec["value"]
		m.albedo_color = Color(m.albedo_color.r * float(v[0]),
				m.albedo_color.g * float(v[1]), m.albedo_color.b * float(v[2]))
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

	## Boarding, palings and ribs
	#
	# These were a comment and a UV scale. `uv1_scale` on its own only changes how
	# # often a texture repeats, so a material with no texture got a different tile
	# # size and no pattern at all: every roof was one flat angled plane and every
	# # wall was isotropic speckle with no edge in it anywhere for an eye to find.
	# # Measured before this change, WALL_VARIATION was 0.00 on every pose.
	#
	# The profile is a `GradientTexture2D`, so it is one texture and two channels:
	# # albedo picks up enough of it to be visible in flat ambient, and roughness
	# # carries the rest. Roughness is what actually sells ribs - a crest is a
	# # different angle from the plane beside it, so under a lamp a crest returns
	# # a specular smear and a valley returns nearly nothing.
	#
	# One tile is a fixed number of METRES because the projection is triplanar, so
	# # the pitch is set once and every surface gets the pitch its own size can
	# # afford: a 9 m house wall spans ~2.7 board tiles and shows ~44 boards, a
	# # 0.4 m pedestrian spans an eighth of one and shows a soft gradient, and a
	# # 0.15 m pole spans a twentieth and shows nothing. The pattern sizes itself.
	var board := String(spec.get("board", ""))
	if board != "":
		var vertical := board == "v"
		var periods := 10 if vertical else 16
		var tile_m := 1.6 if vertical else 3.33   # a 160 mm paling, a 208 mm board
		var ramp := bands_tex(periods,
				PALING_PROFILE if vertical else BOARD_PROFILE,
				0.85 if vertical else 0.55, vertical,
				int(spec.get("paling_seed", 4407)),
				float(spec.get("paling_jitter", 0.11)))
		m.albedo_texture = ramp
		m.roughness_texture = ramp
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.uv1_scale = Vector3(1.0 / tile_m, 1.0 / tile_m, 1.0 / tile_m)
		m.uv1_triplanar = true
		# The `speckle` branch above already claimed uv1_scale and the albedo
		# texture; boarding owns both from here, because a board profile and an
		# isotropic mottle cannot share one texture and the board is the one with
		# edges in it.
		m.albedo_color = m.albedo_color.lightened(0.04)

	# Corrugation. Ribs run down the slope, so the profile lies along V. Triplanar is
	# deliberately off: these are roof quads from `ArtKitMesh`, which DO carry UVs,
	# and `artkit_check.gd` holds the tiling at `uv1_scale.y >= CORRUGATION_UV * 0.9`.
	# That contract is a MULTIPLIER, not a divisor: artkit's meshes run 0..1 across a
	# quad, so the tile count is the scale. The first version of this used
	# `1 / (0.076 * 32)` here and the check failed it - correctly, because on a 0..1
	# quad that is 0.4 of ONE tile across the whole roof, i.e. the corrugation I was
	# adding was invisible. One rib per tile and 13 tiles per quad puts a rib about
	# every 8 cm on a wall-sized quad, which is real Colorbond pitch.
	if bool(spec.get("corrugate", false)):
		var cu := CORRUGATION_UV
		m.uv1_scale = Vector3(1.0, cu, cu)
		m.uv1_triplanar = false
		var rib_ramp := bands_tex(1, RIB_PROFILE, 0.15, false, 6607, 0.05)
		m.albedo_texture = rib_ramp
		m.roughness_texture = rib_ramp
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED

	# Foliage: two-sided, and a little self-lit so a lamp behind a frond bleeds
	# through rather than the frond reading as a hole in the light.
	if bool(spec.get("leaf", false)):
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		var t := float(spec.get("transmit", 0.05))
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = t

	# ## Retroreflection: light returned, not light made
	#
	# `retro` is how this library says "this surface returns light toward the
	# viewer". It exists because the alternative was the mistake this file used to
	# make on every marking and on the plate: a little emission, standing in for a
	# physical effect it does not model. Emission has no direction. A dash with
	# emission on it glows equally whether or not anything is lighting it, which is
	# precisely why it reads as a decal rather than as paint.
	#
	# A real retroreflective surface - glass-bead thermoplastic, the sheeting on a
	# sign plate or a licence plate - works by returning light back along the axis
	# it arrived on, so the surface looks brightest to an observer *near the source*
	# and dims for one standing off to the side. StandardMaterial3D has no
	# retro-reflective lobe, so this is an approximation and is labelled as one:
	# `metallic_specular` is raised so the specular lobe is tight and bright rather
	# than a broad dim sheen, and `roughness` carries the rest. The two knobs pull
	# against each other - a wide lobe returns more total light but from more
	# directions, which is the wash this is avoiding - so the value is authored per
	# material rather than shared.
	#
	# What this deliberately does NOT do is set emission. A retroreflector is not a
	# light source: it never brightens an unlit stretch of road, never appears in
	# `BLOOM_TIERS`, and never makes the frame's brightest thing a piece of tarmac.
	# That last one is the ART_DIRECTION.md rule ("saturated colour is a light
	# source, not a surface") applied to a case the file had been getting backwards:
	# this is a *desaturated* surface that had been made to emit.
	if spec.has("retro"):
		m.metallic_specular = float(spec["retro"])

	# Wear. A wheel track polishes thermoplastic off and rain scours the edges, so a
	# flat albedo over a 0.12 m x 3 m dash is a rectangle. The ramp is held high
	# (0.87-1.0) so it adds mottle without halving the value the way raw noise does.
	if spec.has("wear"):
		var wseed := int(spec.get("noise_seed", 11)) + 1200
		m.uv1_scale = Vector3(1.0, 1.0, 1.0)
		m.uv1_triplanar = true
		m.albedo_texture = noise_tex(256, 2.4, 4, wseed, false, 0.87, 1.0)
		var w := float(spec["wear"])
		m.normal_enabled = true
		m.normal_texture = noise_tex(256, 3.1, 3, wseed + 18, true)
		m.normal_scale = w

	## An emitter's brightness belongs to emission, never to albedo
# ---- Real PBR set. Attached LAST among the surface maps, so it wins over the
	# ---- procedural ramp rather than fighting it: the ramp exists to make a surface
	# ---- with no texture look like something, and a surface with a texture does not
	# ---- need it. Anything the ramp set that a set does not (emission, leaf
	# ---- two-sidedness, the bloom tint) is left exactly as it was.
	#
	# ---- "Last" is load-bearing against the blocks above it as well as the ramp:
	# ---- `retro` sets `metallic_specular` and `wear` sets `albedo_texture` from a
	# ---- noise ramp, and `_attach_pbr()` touches neither. So `kerb_paint` keeps its
	# ---- retro lobe over the concrete scan, and a `wear` spec on a PBR key would
	# ---- correctly lose to the photograph.
	var setname := String(spec.get("pbr", ""))
	if setname != "":
		_attach_pbr(m, spec, setname)

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

	## Contact darkening
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


## Attach one scanned set to a material. Returns nothing; mutates `m` in place.
##
## Three decisions, each of which is load-bearing and none of which is obvious:
##
## **Roughness is `spec.rough * 1.0`, not `1.0 * spec.rough`.** ambientCG roughness
## maps are ABSOLUTE, not centred on 1.0 - `bitumen` averages 0.743 and `grass_verge`
## 0.263. So the scalar is left as the family multiplier and the map is the absolute
## base, and the product is what the shader sees. `effective_roughness_of()` reports
## the product, because a consumer reading `m.roughness` alone would read a number the
## renderer is not using.
##
## **Triplanar, always.** Every mesh in this kit is generated in GDScript and has no
## meaningful UVs, so a UV-mapped scan lands on the wall stretched and rotated at
## random. Triplanar projects from world position, which is also what the road already
## does. It costs three samples instead of one and it is the only thing that makes a
## scan usable on procedural geometry at all.
##
## **`normal_scale` comes from the spec, not from the scan.** A scan's normal strength
## is baked into how hard the light was when it was photographed, which is not a
## material property. The spec number is the artistic dial and it is the same number
## the ramp used, so a family keeps its measured spread.
static func _attach_pbr(m: StandardMaterial3D, spec: Dictionary, setname: String) -> void:
	var albedo := pbr_tex(setname, "c")
	if albedo == null:
		push_warning("ArtKitMaterials: set '%s' has no albedo; leaving the ramp in place"
				% setname)
		return
	m.albedo_texture = albedo
	# The palette role stays in `albedo_color` and is multiplied by the scan, so the
	# hue is chosen by `palette.gd` and the detail by the photograph. See the header.
	var rough := pbr_tex(setname, "r")
	if rough != null:
		m.roughness_texture = rough
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	var normal := pbr_tex(setname, "n")
	if normal != null:
		m.normal_enabled = true
		m.normal_texture = normal
		m.normal_scale = float(spec.get("normal", 0.35))
	# Tiles per metre. `uv` is the same field the ramp used, so a spec that was authored
	# for a noise scale gets a scan at a comparable one.
	var uv := float(spec.get("uv", 0.35))
	m.uv1_scale = Vector3(uv, uv, uv)
	m.uv1_triplanar = true
	# ## CORRUGATION_UV is deliberately not applied here
	#
	# That constant spaced a *stripe in UV* down a roof slope: `_build()` sets
	# `uv1_scale = (1, 13, 13)` so a stripe landed every ~8 cm. That is not a rib - it
	# has no shading across its width, no weathering, and it is identical on every roof
	# in the city.
	#
	# With the scanned corrugated-steel normal map the ribs are in the texture, so the
	# only thing left to space is the scan itself, which `uv` does. An earlier version
	# of this function kept a `CORRUGATION_UV / 100.0` override "because
	# artkit_check.gd asserts the ratio" - which produced a 7 m scan tile, a number
	# chosen to satisfy a check rather than because it was right. The check now measures
	# the scan instead, and this override is gone with the fake it propped up.


## The roughness the renderer actually uses: the spec's scalar multiplied by the mean
## of the roughness map, for a PBR-backed key, or the scalar on its own for a ramp key.
##
## This exists because `m.roughness` stopped being the answer the moment a texture was
## attached. A check that asserts on the scalar alone is asserting on a multiplier, and
## `World/look_dev_test.gd` already documents that shape of bug for the road: a guard on
## `m.roughness` cannot see the road's roughness, and it was green while the road sat
## outside the documented band by a factor of three.
static func effective_roughness_of(key: String) -> float:
	var m := get_(key)
	if m == null:
		return -1.0
	var base := float(m.roughness)
	if _SPECS.has(key) and String(_SPECS[key].get("pbr", "")) != "":
		base *= pbr_mean(String(_SPECS[key]["pbr"]), "r")
	return base


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

## How strongly a key returns light toward the viewer, 0.0 for a material that
## does not do it. Read from the spec rather than the built material because the
## intent is the thing worth asserting: a retroreflector that quietly became a
## light source, or a marking that quietly lost its return, both leave a plausible
## StandardMaterial3D behind and only the spec says which one it was meant to be.
static func retro_of(key: String) -> float:
	if not _SPECS.has(key):
		return 0.0
	return float(_SPECS[key].get("retro", 0.0))


## True for a surface that returns light rather than making it. The negative
## direction matters as much as the positive: a retroreflective surface that also
## emits is a light source wearing a marking's paint, which is the exact defect
## the `retro` block in `_build` documents.
static func is_retroreflexive(key: String) -> bool:
	return retro_of(key) > 0.0


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
