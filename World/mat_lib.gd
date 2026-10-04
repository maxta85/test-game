class_name MatLib
extends RefCounted
## Procedural material library.
##
## Everything is generated in-engine from FastNoiseLite, so there are no texture
## downloads and no licensing questions. The whole look hangs off two ideas:
##   - the roads are WET, which means low roughness and a strong environment
##     reflection, and that single decision is most of the "night street" feel
##   - light sources are mostly warm sodium with a cool moon fill, which is what
##     makes a tropical night look tropical rather than generic

const SODIUM := Color(1.0, 0.63, 0.24)      ## orange-vapour street lighting
const MERCURY := Color(0.72, 0.85, 1.0)     ## cooler shop / flood lights
const MOON := Color(0.42, 0.56, 0.86)       ## the only real light source here
const NEON_PINK := Color(1.0, 0.24, 0.55)
const NEON_CYAN := Color(0.2, 0.95, 0.95)


## ## Banded profiles: the shape every real cladding surface has
##
## A flat albedo is the reason a building reads as a box. Timber weatherboard is
## horizontal boards with a shadow line under each lip; paling fencing is the same
## idea rotated 90 degrees; corrugated iron is a sawtooth. None of that is a colour,
## it is a *profile*, and a profile is a one-dimensional ramp - which Godot already
## draws. So these are `GradientTexture2D`s, generated in-engine, no asset to source
## and no licence to hold. They are honest procedural work, not a stand-in for a
## texture that was never made.
##
## `bands_tex` builds one ramp of `periods` repeats. `profile` is a list of
## `[offset_in_period, value]` pairs, so the shape of a board or a rib is written
## down rather than emergent. Each period is then given its own small deterministic
## brightness offset, because the single most recognisable thing about real
## weatherboard is that no two boards weather the same way - a uniform ramp reads as
## a striped wallpaper, which is worse than the flat colour it replaced.
##
## `warm` biases the ramp's red up and its blue down without touching the palette.
## The palette owns base albedo; a shading ramp is material data, the same way
## `_palm_ring_tex`'s `Color(v, v, v * 0.92)` already is.
static var _band_cache: Dictionary = {}


## A repeating banded ramp. `vertical` runs the bands down U instead of along V,
## which is the whole difference between a paling fence and a weatherboard wall.
static func bands_tex(periods: int, profile: Array, warm: float, vertical: bool,
		seed_v: int, jitter: float = 0.10) -> GradientTexture2D:
	var key := "%d|%s|%.3f|%s|%d|%.3f" % [periods, str(profile), warm,
			str(vertical), seed_v, jitter]
	if _band_cache.has(key):
		return _band_cache[key]
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var span := 1.0 / float(maxi(periods, 1))
	for i in maxi(periods, 1):
		var base := float(i) * span
		# Per-board offset, centred on zero, so the *mean* is unchanged and only
		# the spread moves. Brightening every board by a positive jitter is how a
		# cladding material turns into a lighter one by accident.
		var off := rng.randf_range(-jitter, jitter)
		for pair in profile:
			var p: float = float(pair[0])
			var v: float = float(pair[1]) + off
			v = clampf(v, 0.0, 1.0)
			offs.append(base + p * span)
			cols.append(Color(v * (1.0 + warm * 0.10), v, v * (1.0 - warm * 0.08)))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	g.offsets = offs
	g.colors = cols
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


## The weatherboard profile. Read it as one board, top to bottom: a hard dark line
## where the board above overhangs this one, the face coming up into the light, the
## face holding, then falling away into the next shadow.
const BOARD_PROFILE := [
	[0.00, 0.30], [0.06, 0.78], [0.18, 1.00], [0.74, 0.94], [0.90, 0.52], [1.00, 0.30],
]

## A paling fence: narrower boards, a wider dark gap, and more spread between them.
const PALING_PROFILE := [
	[0.00, 0.22], [0.10, 0.86], [0.62, 1.00], [0.80, 0.44], [1.00, 0.22],
]

## A corrugated rib: narrow crest, wide dark valley, and a hard shoulder. Ribs are
## much finer than boards and there are many more of them per tile.
const RIB_PROFILE := [
	[0.00, 0.34], [0.14, 0.62], [0.42, 1.00], [0.58, 0.96], [0.86, 0.50], [1.00, 0.34],
]


## Seamless procedural noise texture.
static func noise_tex(size: int, freq: float, octaves: int, seed_v: int,
		as_normal: bool = false) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = seed_v
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
	return tex


## Wet asphalt. The star of the show: low roughness, strong normal detail for
## the aggregate, and a slight sheen so sodium lights smear along it.
##
## `seed` exists because the tarmac is triplanar: the grain is sampled from world
## position, so every square metre of road shows the same 16.7 m tile of it and the
## repeat is a grid across the whole map. Per-mesh UV offsets cannot break that -
## the shader never reads them - so the only lever is a different material, and
## `seed` moves the noise without moving the mean: variants differ in grain, not
## in brightness, which is what stops the road looking blotchy instead of tiled.
static func wet_asphalt(uv_scale: float = 0.06, seed: int = 0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# Wet asphalt is a near-mirror, so almost all the light it returns is
	# specular reflection of the sky - and this sky is nearly black. Physically
	# honest is also unreadable here, so the diffuse albedo is lifted well past
	# real tarmac. It is the only thing keeping the road visible under a lamp.
	m.albedo_color = Color(0.105, 0.108, 0.122)
	# Wet tarmac is a mirror with a rough patch here and there. Roughness is
	# driven by a noise texture so the reflection breaks up instead of reading
	# as a uniform sheet of plastic.
	#
	# The base roughness was 0.14 with a *raw* roughness texture, i.e. four
	# octaves spread across the whole 0-1 range. A pixel that samples 0.02 is a
	# mirror, a pixel that samples 0.60 is chalk, and a road made of both, under
	# a sodium lamp at a grazing angle with a 0.28 normal map on top, is a field
	# of pin-sharp orange highlights. Measured on the `street` pose that was
	# 55% of the lit road band reading orange-cast with 4.6% of it clipped and
	# the 95th percentile at 249/255 - the road was glitter, not asphalt. So the
	# roughness now lives in a *band* a wet road can plausibly occupy, and the
	# ramp is the thing doing the work: the texture still breaks the reflection
	# up, but every sample in it is somewhere a wet surface can actually be.
	m.roughness = 0.26
	m.roughness_texture = noise_tex(256, 0.55, 4, 37 + seed * 7)
	var rough_ramp := Gradient.new()
	rough_ramp.set_color(0, Color(0.18, 0.18, 0.18))
	rough_ramp.set_color(1, Color(0.52, 0.52, 0.52))
	(m.roughness_texture as NoiseTexture2D).color_ramp = rough_ramp
	m.metallic = 0.0
	# Full specular on a surface this dark is what turns a lamp into a blown
	# highlight the size of a car bonnet. 0.62 keeps the sheen the material is
	# there for and stops it clipping.
	m.metallic_specular = 0.62
	m.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	m.uv1_triplanar = true
	# The aggregate noise *modulates* the albedo, it does not replace it. Fed
	# raw, FastNoiseLite averages ~0.5 and silently halves every value written
	# above, which is how the road stayed invisible no matter how bright the
	# lamps got. A ramp of 0.72-1.0 keeps the speckle and loses ~14%.
	m.albedo_texture = noise_tex(256, 0.9, 4, 11 + seed * 13)
	var albedo_ramp := Gradient.new()
	albedo_ramp.set_color(0, Color(0.72, 0.72, 0.72))
	albedo_ramp.set_color(1, Color(1.0, 1.0, 1.0))
	var albedo_tex := m.albedo_texture as NoiseTexture2D
	albedo_tex.color_ramp = albedo_ramp
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 1.6, 5, 23 + seed * 17, true)
	# 0.28 was enough aggregate to shatter a specular highlight into glitter. At
	# 0.16 the surface still has the fine tooth of tarmac and a lamp still smears
	# along it, but the highlight is a smear and not a starfield.
	m.normal_scale = 0.16
	# No flat emission. An emissive floor lifts the whole surface evenly and
	# kills the specular contrast that actually makes a road look wet.
	m.emission_enabled = false
	return m


## Dry-ish asphalt for shoulders and the industrial yard.
static func dry_asphalt() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.075, 0.075, 0.08)
	m.roughness = 0.72
	m.uv1_scale = Vector3(0.08, 0.08, 0.08)
	m.uv1_triplanar = true
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 1.8, 4, 51, true)
	m.normal_scale = 0.4
	return m


## Painted road markings.
##
## This used to be `roughness 0.18, metallic_specular 1.0, emission_enabled true,
## emission_energy_multiplier 0.10` - a self-lit mirror. Three separate mistakes
## stacked in five lines, and all three are visible in a street-level night frame:
##
##   - **Emissive.** 0.10 of self-illumination goes through the additive glow in
##     `night_env.gd`, so every dash in frame grows a sodium halo and the frame's
##     brightest thing stops being the light that is actually lighting it. Paint
##     is retroreflective, not luminous: it returns light *from the lamp*, and
##     that is a completely different thing - it means the markings brighten as
##     the car comes under a lamp and go dark between lamps, which is the
##     behaviour that makes a real street readable at speed.
##   - **Roughness 0.18 on a horizontal line.** The marker's own plane reflects
##     the sky and the lamp heads along its whole length, so a lane line read as
##     a strip of chrome. Markings are thermoplastic: matte, and the one thing
##     that makes them visible is how much light they return diffusely.
##   - **No texture.** A flat albedo over a 0.12 m x 3 m rectangle is a rectangle.
##
## Wear is the other half. Real paint is not uniform: the wheel tracks polish it
## off, rain scours the edges, and a line laid in 1998 is not a line laid last
## week. A tight ramp on a high-frequency noise gives the patchiness that stops a
## lane line reading as a decal, and it costs one texture lookup.
static func road_paint(colour: Color, wet: bool = true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	# Matte, with a little more sheen when the paint is fresh and wet. 0.62 is
	# what thermoplastic actually measures; the old 0.18 was a chrome finish.
	m.roughness = 0.55 if wet else 0.78
	m.metallic = 0.0
	m.metallic_specular = 0.32
	# Wear and scuff. Fed raw the noise averages 0.5 and halves the colour, so it
	# is ramped to 0.80-1.0: keeps the mottle, loses 10% of the value.
	m.uv1_scale = Vector3(1.0, 1.0, 1.0)
	m.uv1_triplanar = true
	m.albedo_texture = noise_tex(256, 2.4, 4, 313)
	var wear := Gradient.new()
	wear.set_color(0, Color(0.80, 0.80, 0.80))
	wear.set_color(1, Color(1.0, 1.0, 1.0))
	(m.albedo_texture as NoiseTexture2D).color_ramp = wear
	# A little relief so the paint is not a perfectly smooth film - a wheel track
	# is a millimetre of texture and at a grazing angle that is most of the read.
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 3.1, 3, 331, true)
	m.normal_scale = 0.12
	# No flat emission. See above: this is the line that made every marking in the
	# frame a small light source of its own.
	m.emission_enabled = false
	return m


## The two marking colours, as albedo rather than as "a colour passed in at the
## call site". White thermoplastic and yellow thermoplastic are not the same
## yellow: the yellow is a pigment in a white base, so it is darker, warmer and
## much less bright than the white, and treating them as the same material at
## different brightness is how a centre line ends up brighter than the edge lines
## it is supposed to be subordinate to.
static func paint_white() -> StandardMaterial3D:
	return road_paint(Color(0.70, 0.69, 0.66))


static func paint_yellow() -> StandardMaterial3D:
	return road_paint(Color(0.52, 0.36, 0.045))


## Concrete: kerbs, gutters, driveways, footpaths.
static func concrete(tint: Color = Color(0.26, 0.25, 0.235)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.80
	m.uv1_scale = Vector3(0.12, 0.12, 0.12)
	m.uv1_triplanar = true
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 2.2, 3, 71, true)
	m.normal_scale = 0.25
	return m


## Ground beyond the kerb: the grass verge, and bare earth further out.
##
## ## Two measured faults, both fixed here
##
## **It was fed raw noise.** Every other material in this file ramps its noise,
## because FastNoiseLite averages ~0.5 and a raw ramp-less texture silently halves
## whatever albedo it multiplies. `ground()` was the one that did not, so the verge
## was not the 0.095 it asked for - it was about half that. Ramped 0.62-1.16 it keeps
## the clumping and stops losing half the value.
##
## **It was darker than the road it sits beside.** At 0.095 luma the verge sat at
## 24/255 while the wet tarmac it borders is at 28/255, so the one surface in the
## reference that reads instantly was, in ours, a hole. The value is lifted to 0.198
## (51/255) which puts it clearly above the carriageway - a distinct band, not a void.
##
## The hue keeps the palette's `grass` ratio (#17220f) and its saturation is 0.65
## against the palette's 0.54, which is a small deliberate departure in the direction
## of the reference's saturated green. It is the only place in this library that
## brightens a surface role rather than darkening one, and the reason is measured
## rather than aesthetic: no light reaches the verge in this scene, so albedo is the
## only lever there is, and the alternative is a black band.
static func ground() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.115, 0.235, 0.082)
	m.roughness = 0.95
	# Clumps at roughly 1.2 m, not the 25 m the old 0.04 scale gave: at 25 m a
	# "texture" is one cycle across the entire suburb, which is a gradient, and a
	# gradient is what the verge already looked like.
	m.uv1_scale = Vector3(0.85, 0.85, 0.85)
	m.uv1_triplanar = true
	var clumps := noise_tex(256, 0.85, 4, 91)
	var ground_ramp := Gradient.new()
	ground_ramp.set_color(0, Color(0.62, 0.62, 0.62))
	ground_ramp.set_color(1, Color(1.16, 1.16, 1.16))
	clumps.color_ramp = ground_ramp
	m.albedo_texture = clumps
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 1.2, 3, 103, true)
	m.normal_scale = 0.6
	return m


## Corrugated iron roofing - the defining Queensland surface.
##
## ## The ribs were a comment, not an implementation
##
## This function used to set `uv1_scale` and call it a day. The comment said
## "stripes in UV give the corrugation without a texture lookup", and there was no
## stripe: `uv1_scale` alone changes how often a texture repeats, and this material
## had no texture. So every roof in the city was one flat angled plane at one
## roughness, which is exactly what the reference is not - Colorbond reads as a row of
## half-round ribs because each one catches the sky at its own angle.
##
## What actually makes ribbing read at street distance is not the albedo, it is the
## ROUGHNESS. A crest is a different angle from the plane either side of it, so under
## a lamp a crest returns a specular smear and a valley returns almost nothing. One
## ramp drives both channels: albedo picks up a little of it so the ribs are also
## visible in flat ambient, and roughness carries the rest. Rib pitch is 76 mm, the
## real Colorbond figure the artkit constant already quoted, and a tile holds 32 of
## them over 2.43 m.
static func corrugated(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.42
	m.metallic = 0.35
	m.metallic_specular = 0.6
	## Triplanar is not a stylistic choice here, it is the only thing that can work.
	## `osm_buildings.gd` has two `set_uv` calls in the whole file and neither is in
	## `_pitched()` or `_cap()`, so all 2198 roof meshes carry **no UVs at all** -
	## every vertex is (0,0). A texture on a mesh with no UVs samples one texel, so
	## the first version of this function set a uv1_scale and nothing appeared at
	## all: the scale was being applied to a UV that did not exist. Triplanar derives
	## its UVs from world position instead, which is why a roof mesh with no UV
	## channel can carry a rib pattern. Measured on the `street` pose, the flat-UV
	## version moved the roof pixels not at all.
	var rib_m := 0.076          # real Colorbond pitch
	var ribs := 32
	var tile := rib_m * float(ribs)
	m.uv1_scale = Vector3(1.0 / tile, 1.0 / tile, 1.0 / tile)
	m.uv1_triplanar = true
	var ramp := bands_tex(ribs, RIB_PROFILE, 0.15, false, 6607, 0.05)
	m.albedo_texture = ramp
	m.roughness_texture = ramp
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	return m


## Painted / rendered house wall - and, since this is the function the world
## actually calls for every wall it builds, the boarding lives here.
##
## ## Why the boarding is in `wall()` and not somewhere the caller chooses
##
## `Wall.tint` is reached from four places that are not all walls: the OSM building
## walls, a glass surround band, a light pole, a wire, a pedestrian and a parked car
## all come through this same function. Putting the boarding behind a flag would mean
## every one of those call sites had to opt in, and none of them can be edited from
## here - so the flag would never be passed and the walls would stay flat. That is the
## "graceful fallback nobody notices" failure: the code would look correct and the
## frame would not change.
##
## So the boarding is unconditional, and it is made safe by *scale* instead of by a
## flag. `uv1_triplanar` projects from world position, so one texture tile is a fixed
## number of metres everywhere and the pattern is automatically the right size on
## whatever it lands on:
##
## | surface | width | tile it spans | reads as |
## |---|---|---|---|
## | a two-storey house wall | 9 m | ~2.7 tiles | ~44 boards, unmistakable |
## | a pedestrian | 0.4 m | 0.12 of a tile | a soft gradient, no stripes |
## | a light pole | 0.15 m | 0.05 of a tile | flat |
##
## The board pitch is therefore set once, in metres, and every surface gets the pitch
## its own size can afford. Measured before/after in `/tmp/reports/materials.md`.
static func wall(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.85
	# One tile is 3.33 m of wall with 16 boards in it, so a board is 208 mm - a real
	# block-board reveal. `uv1_scale` is per-metre because the projection is triplanar.
	var tile := 3.33
	m.uv1_scale = Vector3(1.0 / tile, 1.0 / tile, 1.0 / tile)
	m.uv1_triplanar = true
	# The board profile IS the albedo variation now. The old flat mottle is what a
	# wall had before this task, and it was measured at WALL_VARIATION=0 on every
	# pose: isotropic speckle has no direction, so there is no edge anywhere in it for
	# an eye to find. Boarding has horizontal edges, which is the entire point.
	var boards := bands_tex(16, BOARD_PROFILE, 0.55, false, 4407, 0.11)
	m.albedo_texture = boards
	# The same ramp drives roughness. The shadow line under a board's lip is where
	# water sits and dirt collects, so it is the matt part of the wall and the face is
	# the part that has been washed by rain. One ramp, two channels - no second
	# texture, no extra fetch.
	m.roughness_texture = boards
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	# Grain stays on the normal map, where grain belongs. Feeding the same noise into
	# the albedo as well is what made the old wall read as grubby rather than boarded:
	# a low-frequency mottle over a wall hides the edges instead of sitting under them.
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 2.5, 3, 131, true)
	m.normal_scale = 0.15
	return m


## Weatherboard as its own entry point, for the geometry worker who can pass a tint
## per building. `wall()` is the same surface with the boarding baked in; this exists
## so a caller that knows it is drawing a house does not have to take the poles and
## the wires' material to get one.
static func weatherboard(tint: Color, board_h: float = 0.208) -> StandardMaterial3D:
	var m := wall(tint)
	var tile := board_h * 16.0
	m.uv1_scale = Vector3(1.0 / tile, 1.0 / tile, 1.0 / tile)
	return m


## Timber paling fence: vertical boards, a wider shadow gap and more spread between
## them than weatherboard has, because a paling is a 100 mm board with a 20 mm gap
## and nothing overlaps. Warm - the reference fence is a red-brown, and under the
## sodium in this scene a warm albedo is what keeps it from going grey.
static func paling(tint: Color = Color(0.20, 0.105, 0.075)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.90
	var tile := 1.6
	m.uv1_scale = Vector3(1.0 / tile, 1.0 / tile, 1.0 / tile)
	m.uv1_triplanar = true
	# 10 palings per 1.6 m tile = a 160 mm board-and-gap pitch, which is what a
	# paling fence actually measures once the gap is counted.
	m.albedo_texture = bands_tex(10, PALING_PROFILE, 0.85, true, 5501, 0.16)
	m.roughness_texture = m.albedo_texture
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.normal_enabled = true
	m.normal_texture = noise_tex(128, 3.0, 3, 149, true)
	m.normal_scale = 0.22
	return m


## Red-painted kerb return - the no-stopping treatment. Queensland paints these and
## almost nothing else, which is why it reads as an accent rather than as a kerb that
## happens to be red.
##
## ## A deliberate exception, stated so it can be overruled
##
## The palette's rule is that a surface role is never a saturated hue, because
## saturated colour is a light source. This is a saturated red on a surface. Two
## reasons it is here anyway: a no-stopping kerb *is* red in the world, and inventing
## a colour that does not exist would be a worse lie than breaking a convention. It is
## also the one material in the library with no palette role behind it, because the
## palette cannot be edited from this task - so if the lead would rather it were a
## named role, that is a one-line addition to `palette.gd` plus this spec dropping
## its explicit albedo.
##
## It is dark and slightly rough rather than bright and gloss: under this scene's
## sodium, which has almost no red in it, a vivid red albedo returns very little and
## the honest result at night is a deep maroon that separates from grey concrete by
## hue *and* by value. Measured, not assumed - see the report.
static func kerb_red() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.26, 0.045, 0.032)
	m.roughness = 0.58
	m.metallic_specular = 0.42
	m.uv1_scale = Vector3(0.5, 0.5, 0.5)
	m.uv1_triplanar = true
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 2.2, 3, 71, true)
	m.normal_scale = 0.25
	return m


## Coconut bark. Its own material rather than `wall()` because the trunks were
## the worst-looking thing in the frame and `wall()` is why: a 0.30 albedo with no
## albedo texture at all is three times the tarmac's 0.105, so under a sodium lamp
## a trunk returns more light than the road it is planted in and renders as a flat
## orange slab - 1621 of them, and the "everything is orange" complaint is mostly
## this. Bark is grey-brown, not orange: the sodium in the frame is supposed to be
## the lamp's, not the material's.
static func palm_bark() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# A palm trunk is vertical, so it takes the lamp square-on while the road
	# under the same lamp takes it at 25 degrees - and the old wall() albedo of
	# 0.30 returned more light than the tarmac it is planted in, so every trunk
	# rendered as a flat orange slab. Grey-brown and dark enough to lose to the
	# road: under sodium that still reads warm, but as a tree, not a terracotta pole.
	m.albedo_color = Color(0.13, 0.125, 0.112)
	m.roughness = 0.92
	# Triplanar is off deliberately. It projects the texture from world space in
	# three axes, which is the wrong basis for a cylinder - and WorldBuilder now
	# supplies trunk UVs where `u` runs once around the shaft and `v` is already
	# scaled by PALM_RING_BANDS, so the leaf-scar rings land as horizontal bands.
	# Triplanar would have thrown those away and smeared the rings diagonally.
	m.uv1_scale = Vector3.ONE
	m.albedo_texture = _palm_ring_tex()
	return m


## Leaf-scar rings for a palm shaft: a narrow dark band per scar, with the
## weathered panel above it.
##
## A GradientTexture2D rather than a per-pixel Image loop, because a vertical
## gradient is exactly this shape - a ramp along one axis - and Godot already
## draws one. The gradient only varies vertically, so it wraps seamlessly left
## to right, which matters because the trunk UVs tile once per side: any
## horizontal variation would show as a stripe down every seam.
static func _palm_ring_tex() -> GradientTexture2D:
	# Light smooth panel easing down into the dark scar, then a hard edge back
	# out. Offset 1.0 repeats the panel top so the last ring meets the first.
	# Set through `offsets`/`colors` rather than `set_offset`/`set_color`: those
	# only edit points the gradient already has, and a fresh Gradient has two.
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 0.80, 0.90, 0.97, 1.0])
	var cols := PackedColorArray()
	for v in [0.92, 0.80, 0.72, 0.30, 0.26, 0.92]:
		cols.append(Color(v, v, v * 0.92))
	g.colors = cols
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 8
	tex.height = 128
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	return tex


## Foliage. Two-sided and slightly translucent so streetlights bleed through.
static func foliage(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.88
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = 0.06
	return m


## A self-lit surface: window glass, sign, tail light, lamp.
static func emissive(colour: Color, energy: float = 1.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.25
	m.emission_enabled = true
	m.emission = colour
	m.emission_energy_multiplier = energy
	return m


## Glass for lit windows at night. Mostly dark, with a warm interior hint.
static func window_glass() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.02, 0.025, 0.03)
	m.roughness = 0.08
	m.metallic = 0.1
	m.metallic_specular = 1.0
	m.emission_enabled = true
	m.emission = Color(1.0, 0.72, 0.42)
	m.emission_energy_multiplier = 0.0   # per-instance override for lit windows
	return m


## Water: the drainage channels that never dry in the Wet Tropics.
static func water() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.012, 0.03, 0.035)
	m.roughness = 0.04
	m.metallic = 0.25
	m.metallic_specular = 1.0
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color.a = 0.86
	return m
