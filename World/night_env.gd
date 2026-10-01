class_name NightEnv
extends WorldEnvironment
## The night. This is the project's entire visual identity, so most of the
## settings here are deliberate rather than defaults.
##
## The look is: a hot, humid, over-cast tropical night. There is no moon worth
## speaking of - just enough cool fill to keep the shadows from going pure black
## - and every real light source is warm sodium. Dense humid fog, strong glow on
## the lamps, and a sky that reflects just enough to make the wet road read.

@export var rain_intensity := 0.35:
	set(v):
		rain_intensity = v
		_apply_rain()

var _sky_mat: ProceduralSkyMaterial
var _env: Environment


func _ready() -> void:
	_env = Environment.new()

	# --- sky ---------------------------------------------------------------
	# Not black, and not orange. A humid coastal city at 1am has a dim *cool*
	# glow on the underside of the cloud from the city's own light bouncing off
	# it, and that is the only thing lighting the sky. See ART_DIRECTION.md: the
	# first pass made this warm and bright, which turned every frame into a
	# single-hue orange wash with nothing to read a silhouette against.
	_sky_mat = ProceduralSkyMaterial.new()
	_sky_mat.sky_top_color = Color(0.010, 0.014, 0.028)
	_sky_mat.sky_horizon_color = Color(0.085, 0.105, 0.155)
	_sky_mat.ground_bottom_color = Color(0.006, 0.007, 0.010)
	_sky_mat.ground_horizon_color = Color(0.055, 0.062, 0.080)
	_sky_mat.sun_angle_max = 0.0
	_sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky

	# --- ambient ----------------------------------------------------------
	# Low and cool, and deliberately NOT sourced from the sky. Sourcing it from
	# the sky sounds more physical, but this sky is nearly black by design, so
	# the ambient fill came out at ~nothing and every unlit surface - the whole
	# near field of the road - rendered as pure black no matter how bright the
	# lamps were. An explicit colour is the only version of "cool night fill"
	# that is actually settable.
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_sky_contribution = 0.0
	_env.ambient_light_energy = Look.AMBIENT_ENERGY
	_env.ambient_light_color = Color(0.34, 0.42, 0.62)

	# --- fog --------------------------------------------------------------
	# Depth fog, cool and thin. Its job is depth cueing between the streetlights,
	# not lighting the scene - `fog_light_color` is nearly black on purpose.
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.030, 0.036, 0.052)
	_env.fog_light_energy = 1.0
	_env.fog_sun_scatter = 0.0
	_env.fog_density = 0.0
	_env.fog_depth_begin = 40.0
	_env.fog_depth_end = 620.0
	_env.fog_depth_curve = 1.7
	_env.fog_sky_affect = 0.15

	# --- glow -------------------------------------------------------------
	# Sodium lamps and neon should bleed. Without this a night scene looks like
	# a day scene with the brightness turned down.
	_env.glow_enabled = true
	_env.glow_intensity = Look.GLOW_INTENSITY
	_env.glow_strength = 1.0
	_env.glow_bloom = 0.08
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	_env.glow_hdr_threshold = Look.GLOW_THRESHOLD
	_env.glow_hdr_scale = 2.0

	# --- reflections / SSR ------------------------------------------------
	# Wet roads live or die on this. Screen-space reflections pick up the
	# streetlights and neon and smear them down the tarmac.
	_env.ssr_enabled = true
	_env.ssr_max_steps = 48
	_env.ssr_fade_in = 0.15
	_env.ssr_fade_out = 8.0
	_env.ssr_depth_tolerance = 0.30

	# --- contact detail ----------------------------------------------------
	_env.ssao_enabled = true
	_env.ssao_radius = 1.4
	_env.ssao_intensity = 1.6
	_env.ssao_power = 1.5
	_env.ssao_detail = 0.6

	_env.adjustment_enabled = true
	_env.adjustment_brightness = 1.03
	_env.adjustment_contrast = Look.ADJUSTMENT_CONTRAST
	_env.adjustment_saturation = 1.12

	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 1.45
	_env.tonemap_white = 1.2

	# --- volumetrics --------------------------------------------------------
	# What makes a headlight beam visible in humid air. Thin and nearly
	# unlit: the fog is here to catch the beams, not to glow on its own. A
	# dense emissive volume is what turned the first pass into orange soup.
	_env.volumetric_fog_enabled = true
	_env.volumetric_fog_density = 0.012
	_env.volumetric_fog_albedo = Color(0.58, 0.62, 0.72)
	_env.volumetric_fog_emission = Color(0.030, 0.034, 0.048)
	_env.volumetric_fog_emission_energy = 0.5
	_env.volumetric_fog_gi_inject = 0.0
	_env.volumetric_fog_anisotropy = 0.20
	_env.volumetric_fog_length = 70.0
	_env.volumetric_fog_detail_spread = 2.0
	_env.volumetric_fog_ambient_inject = 0.0

	environment = _env
	_apply_rain()


## Rain: heavier rain means you see less far, a darker sky, and *thicker
## volumetrics* - which is the good part, because a headlight beam in heavy rain
## is the single most convincing thing a night street can do.
func _apply_rain() -> void:
	if _env == null:
		return
	var r: float = clampf(rain_intensity, 0.0, 1.0)
	_env.fog_density = 0.0
	_env.fog_depth_end = lerpf(620.0, 260.0, r)
	_env.fog_depth_begin = lerpf(40.0, 10.0, r)
	_env.volumetric_fog_density = lerpf(0.012, 0.030, r)
	_env.glow_intensity = Look.GLOW_INTENSITY * lerpf(1.0, 1.2, r)
	_sky_mat.sky_horizon_color = Color(0.085, 0.105, 0.155).lerp(Color(0.040, 0.050, 0.070), r)


## Cycles through the four weather states the brief asks for.
func set_weather(name: String) -> void:
	match name:
		"clear": rain_intensity = 0.0
		"rain": rain_intensity = 0.35
		"heavy": rain_intensity = 0.7
		"storm": rain_intensity = 1.0
