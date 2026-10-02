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


## Ground beyond the kerb: tropical grass and bare earth.
static func ground() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.075, 0.105, 0.055)
	m.roughness = 0.95
	m.uv1_scale = Vector3(0.04, 0.04, 0.04)
	m.uv1_triplanar = true
	m.albedo_texture = noise_tex(256, 0.7, 4, 91)
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 1.2, 3, 103, true)
	m.normal_scale = 0.6
	return m


## Corrugated iron roofing - the defining Queensland surface.
static func corrugated(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.42
	m.metallic = 0.35
	m.metallic_specular = 0.6
	# Stripes in UV give the corrugation without a texture lookup.
	m.uv1_scale = Vector3(0.5, 0.5, 0.5)
	return m


## Painted / rendered house wall.
static func wall(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.85
	m.uv1_scale = Vector3(0.1, 0.1, 0.1)
	m.uv1_triplanar = true
	# Albedo speckle as well as a normal map. Flat albedo under a sodium lamp is
	# cardboard: one value across a whole wall, so the only thing giving the
	# surface any variation is the normal map, and a normal map alone reads as
	# relief on a sheet of card. Painted render is patchy - a roller leaves the
	# wall lighter where it was laid down and darker where the weather got it -
	# and that mottle is what stops the flat side of a building reading as a
	# rectangle of colour.
	#
	# Ramped like the tarmac's, for the same reason: fed raw, FastNoiseLite
	# averages ~0.5 and silently halves the tint, which reads as every wall being
	# grubby rather than mottled. 0.74-1.0 keeps the mottle and loses ~13%.
	m.albedo_texture = noise_tex(128, 1.6, 4, 907)
	var wall_ramp := Gradient.new()
	wall_ramp.set_color(0, Color(0.74, 0.74, 0.74))
	wall_ramp.set_color(1, Color(1.0, 1.0, 1.0))
	(m.albedo_texture as NoiseTexture2D).color_ramp = wall_ramp
	m.normal_enabled = true
	m.normal_texture = noise_tex(128, 2.5, 3, 131, true)
	m.normal_scale = 0.15
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
