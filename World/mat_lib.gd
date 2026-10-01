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
static func wet_asphalt(uv_scale: float = 0.06) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# Wet asphalt is a near-mirror, so almost all the light it returns is
	# specular reflection of the sky - and this sky is nearly black. Physically
	# honest is also unreadable here, so the diffuse albedo is lifted well past
	# real tarmac. It is the only thing keeping the road visible under a lamp.
	m.albedo_color = Color(0.105, 0.108, 0.122)
	# Wet tarmac is a mirror with a rough patch here and there. Roughness is
	# driven by a noise texture so the reflection breaks up instead of reading
	# as a uniform sheet of plastic.
	m.roughness = 0.14
	m.roughness_texture = noise_tex(256, 0.55, 4, 37)
	m.metallic = 0.0
	m.metallic_specular = 1.0
	m.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	m.uv1_triplanar = true
	# The aggregate noise *modulates* the albedo, it does not replace it. Fed
	# raw, FastNoiseLite averages ~0.5 and silently halves every value written
	# above, which is how the road stayed invisible no matter how bright the
	# lamps got. A ramp of 0.72-1.0 keeps the speckle and loses ~14%.
	m.albedo_texture = noise_tex(256, 0.9, 4, 11)
	var albedo_ramp := Gradient.new()
	albedo_ramp.set_color(0, Color(0.72, 0.72, 0.72))
	albedo_ramp.set_color(1, Color(1.0, 1.0, 1.0))
	var albedo_tex := m.albedo_texture as NoiseTexture2D
	albedo_tex.color_ramp = albedo_ramp
	m.normal_enabled = true
	m.normal_texture = noise_tex(256, 1.6, 5, 23, true)
	m.normal_scale = 0.28
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


## Painted road markings. Emissive so they still read under sodium light and in
## the rain, which is what stops a night road looking unlit.
static func road_paint(colour: Color, wet: bool = true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.18 if wet else 0.75
	m.metallic_specular = 1.0
	m.emission_enabled = true
	m.emission = colour
	m.emission_energy_multiplier = 0.10
	return m


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
	# under the same lamp takes it at 25 degrees - and a trunk at a "realistic"
	# 0.165 grey-brown came out as bright terracotta, the loudest thing in every
	# night frame. Halved and pulled toward neutral: under sodium that still
	# reads warm, but as a tree instead of a plastic pole.
	m.albedo_color = Color(0.0, 0.0, 1.0)
	m.roughness = 0.92
	m.uv1_scale = Vector3(0.35, 0.12, 0.35)
	m.uv1_triplanar = true
	# Fed raw, FastNoiseLite averages ~0.5 and silently halves the albedo written
	# above, so the speckle goes through a ramp that keeps the range it looks like
	# it has: 0.62-1.0 is visible fibre without dropping the trunk into the dark.
	m.albedo_texture = noise_tex(256, 2.2, 4, 53)
	var bark_ramp := Gradient.new()
	bark_ramp.set_color(0, Color(0.62, 0.62, 0.62))
	bark_ramp.set_color(1, Color(1.0, 1.0, 1.0))
	(m.albedo_texture as NoiseTexture2D).color_ramp = bark_ramp
	m.normal_enabled = true
	m.normal_texture = noise_tex(128, 3.2, 4, 59, true)
	m.normal_scale = 0.45
	return m


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
