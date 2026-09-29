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
	# Not black. A night sky in a humid coastal city is a dull orange-brown
	# glow on the underside of the cloud, and that is what lights the scene.
	_sky_mat = ProceduralSkyMaterial.new()
	_sky_mat.sky_top_color = Color(0.030, 0.038, 0.062)
	_sky_mat.sky_horizon_color = Color(0.42, 0.315, 0.245)
	_sky_mat.ground_bottom_color = Color(0.014, 0.013, 0.014)
	_sky_mat.ground_horizon_color = Color(0.20, 0.155, 0.125)
	_sky_mat.sun_angle_max = 0.0
	_sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky

	# --- ambient ----------------------------------------------------------
	# Warm, dim, and mostly from the horizon where the city glow is.
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_sky_contribution = 1.0
	_env.ambient_light_energy = 3.0
	_env.ambient_light_color = Color(0.62, 0.58, 0.62)

	# --- fog --------------------------------------------------------------
	# This is the single most important setting in the file. Dense, warm, and
	# depth-based so it thickens with distance rather than hazing the foreground.
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.075, 0.065, 0.070)
	_env.fog_light_energy = 1.0
	_env.fog_sun_scatter = 0.0
	_env.fog_density = 0.0
	_env.fog_depth_begin = 18.0
	_env.fog_depth_end = 420.0
	_env.fog_depth_curve = 1.4
	_env.fog_sky_affect = 0.4

	# --- glow -------------------------------------------------------------
	# Sodium lamps and neon should bleed. Without this a night scene looks like
	# a day scene with the brightness turned down.
	_env.glow_enabled = true
	_env.glow_intensity = 0.45
	_env.glow_strength = 1.05
	_env.glow_bloom = 0.06
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	_env.glow_hdr_threshold = 1.05
	_env.glow_hdr_scale = 2.0

	# --- reflections / SSR ------------------------------------------------
	# Wet roads live or die on this. Screen-space reflections pick up the
	# streetlights and neon and smear them down the tarmac.
	_env.ssr_enabled = true
	_env.ssr_max_steps = 32
	_env.ssr_fade_in = 0.2
	_env.ssr_fade_out = 6.0
	_env.ssr_depth_tolerance = 0.35

	# --- contact detail ----------------------------------------------------
	_env.ssao_enabled = true
	_env.ssao_radius = 1.4
	_env.ssao_intensity = 1.6
	_env.ssao_power = 1.5
	_env.ssao_detail = 0.6

	_env.adjustment_enabled = true
	_env.adjustment_brightness = 1.03
	_env.adjustment_contrast = 1.10
	_env.adjustment_saturation = 1.12

	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 1.30
	_env.tonemap_white = 1.2

	# --- volumetrics --------------------------------------------------------
	# This is the single most important setting in the whole file for the brief.
	# "Hot tropical night, humid air, dense atmospheric fog" is not a fog colour -
	# it is light *scattering through* the air. Without volumetrics the streetlights
	# are point specks on black tarmac; with them the air itself glows and you get
	# the light cones over the road that make a wet street look wet.
	_env.volumetric_fog_enabled = true
	_env.volumetric_fog_density = 0.030
	_env.volumetric_fog_albedo = Color(0.72, 0.66, 0.60)
	_env.volumetric_fog_emission = Color(0.10, 0.075, 0.055)
	_env.volumetric_fog_emission_energy = 1.4
	_env.volumetric_fog_gi_inject = 0.0
	_env.volumetric_fog_anisotropy = 0.35
	_env.volumetric_fog_length = 90.0
	_env.volumetric_fog_detail_spread = 2.0
	_env.volumetric_fog_ambient_inject = 0.35

	environment = _env
	_apply_rain()


## Rain: heavier rain means thicker fog (you cannot see as far), a darker sky,
## and more wetness. This is the "occasional downpour" the brief asks for.
func _apply_rain() -> void:
	if _env == null:
		return
	var r: float = clampf(rain_intensity, 0.0, 1.0)
	_env.fog_density = 0.0
	_env.fog_depth_end = lerpf(360.0, 150.0, r)
	_env.fog_depth_begin = lerpf(20.0, 6.0, r)
	_env.fog_light_color = Color(0.075, 0.065, 0.070).lerp(Color(0.055, 0.052, 0.058), r)
	_env.glow_intensity = lerpf(0.45, 0.58, r)
	_sky_mat.sky_horizon_color = Color(0.42, 0.315, 0.245).lerp(Color(0.17, 0.155, 0.165), r)


## Cycles through the four weather states the brief asks for.
func set_weather(name: String) -> void:
	match name:
		"clear": rain_intensity = 0.0
		"rain": rain_intensity = 0.35
		"heavy": rain_intensity = 0.7
		"storm": rain_intensity = 1.0
