class_name DayEnv
extends WorldEnvironment
## The day. This is the default environment from t191 onwards.
##
## WHY A NEW FILE AND NOT A MODE ON `NightEnv`
##
## `night_env.gd` is not a theme with a daytime preset - every one of its numbers is
## the answer to a question only a night has. Its ambient is an explicit cool
## colour because the sky it pairs with is nearly black and a sky-sourced ambient
## measured at nothing (`night_env.gd:41-51`); its glow, its SSR and its volumetric
## fog exist to make a sodium lamp and a wet headlight beam read, and in daylight
## they are three effects that each *cost* legibility (a bright sky blooms, a mirror
## road at noon is glare, a lit volume in a lit sky is nothing). Flipping those from
## a `time_of_day` branch would mean every night number in `night_env.gd` now depends
## on an `if`, and the next person to sweep one cannot tell which branch they are in.
##
## So the night keeps its file, untouched, and this one is the day - stated
## positively, the way the night was. `NightPass`, `Look` and `night_env.gd` are all
## preserved verbatim for the night phase that follows; `switch_to_night()` below
## puts one back without a merge.
##
## WHAT IS DELIBERATELY NOT HERE
##
## No streetlight energy, no `Look` constant, no window emissive and no tonemap
## mode has been touched. `Look` is byte-identical to the promoted commit. The
## daylight exposure is this file's own constant and it is reported separately in
## t191 - see TONEMAP_EXPOSURE for what was measured and why the night value is not
## simply reused.

## Daylight sun. Neutral-warm, not white and not orange: a tropical morning sun
## through high cloud is around 5600 K, which is very slightly warm, and pushing it
## warmer is how a daylight scene ends up looking like the night one through a
## brighter grade.
const SUN_COLOUR := Color(1.0, 0.96, 0.90)

## Sun strength. A `DirectionalLight3D` with no falloff is the dominant light in the
## whole world (the same fact `Look.MOON` documents at night), so this is the
## single number that decides whether the day reads as day. 3.0 with an ACES curve
## sits bright without flattening - measured on the `street-level` pose, see the
## t191 report.
const SUN_ENERGY := 3.0

## Where the sun is. Mid-morning, high enough that the carriageway is lit rather
## than raked, and off-axis so every palm trunk and every facade pier casts a
## shadow across the footpath instead of straight down it - a vertical shadow at
## noon is a shadow that is not visible in a frame from a car.
const SUN_ROTATION_DEG := Vector3(-48.0, -58.0, 0.0)

## Ambient. Sourced from the sky this time, which is the whole point of a day: the
## sky is bright and blue, so the fill under a carport is blue and comes from
## where it actually comes from. `night_env.gd` had to name a colour because its
## sky is nearly black; naming one here would throw away the only piece of
## ambient that is physically grounded.
const AMBIENT_ENERGY := 1.0

## Haze. Tropical and thin, and its only job is aerial perspective down a 1.4 km
## straight - without it every distant building is the same contrast as the one in
## front of the camera and the street reads as a flat backdrop. `fog_light_color`
## is the sky's own horizon colour, so the far end of the road dissolves into the
## sky rather than into a grey card.
const HAZE_COLOUR := Color(0.62, 0.71, 0.82)

## How far the haze reaches. Long, because this is a length-of-street cue and not a
## mood: the whole point is that the far end fades.
const HAZE_BEGIN_M := 120.0
const HAZE_END_M := 1400.0

## Daylight exposure. See the note above - this is a value for this environment and
## it is the one judgement in this file that is not a physical fact.
##
## The night runs `tonemap_exposure = 1.45` (`night_env.gd:117`) against an
## environment whose brightest surface is a 0.85-emissive lamp lens and whose sky
## measures ~2/255. Reusing 1.45 here was measured, not assumed: on the
## `street-level` pose with the sun above it clips the frame, because the scene's
## linear values are an order of magnitude higher and ACES has nowhere to put them.
## Changing the *night's* 1.45 was out of scope, so this is a separate constant in
## a separate file. Both numbers are reported in t191 so the choice is visible.
const TONEMAP_EXPOSURE := 0.62

## The saved night environment, for the phase that comes after this one.
##
## This is the whole of "preserve the night": `NightEnv` still exists, still builds
## itself in `_ready`, and is still unit-tested by `Tests/test_fix_only.gd`. Nothing
## here edits it. A caller that wants the night asks for it, and gets the shipped
## night rather than a re-derivation of it.
func switch_to_night() -> WorldEnvironment:
	var night := NightEnv.new()
	night.name = "NightEnvironment"
	add_child(night)
	night.owner = null
	return night


func _ready() -> void:
	var env := Environment.new()

	# --- sky ---------------------------------------------------------------
	# A high, bright, slightly hazy tropical sky. `sun_angle_max` is widened from
	# the night's 0.0 because a daylight sun is a visible object and a 0.0 disc is
	# a white dot - which, in a frame with a 62 deg vertical FOV pointed down a
	# street, is a lens flare rather than a sun.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.29, 0.48, 0.78)
	sky_mat.sky_horizon_color = Color(0.71, 0.80, 0.88)
	sky_mat.sky_curve = 0.18
	sky_mat.ground_bottom_color = Color(0.32, 0.34, 0.33)
	sky_mat.ground_horizon_color = Color(0.66, 0.72, 0.78)
	sky_mat.sun_angle_max = 12.0
	sky_mat.sun_curve = 0.12
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# --- ambient ----------------------------------------------------------
	# From the sky. See AMBIENT_ENERGY above.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = AMBIENT_ENERGY

	# --- haze --------------------------------------------------------------
	env.fog_enabled = true
	env.fog_light_color = HAZE_COLOUR
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.25
	env.fog_density = 0.0
	env.fog_depth_begin = HAZE_BEGIN_M
	env.fog_depth_end = HAZE_END_M
	env.fog_depth_curve = 1.1
	# Low, and for the opposite reason to the night's 0.15: in daylight the haze is
	# aerial perspective, so washing it into the sky is correct rather than a way of
	# hiding a dark frame.
	env.fog_sky_affect = 0.45

	# --- glow: OFF ---------------------------------------------------------
	# A night effect. With a daylight sky nearly every pixel in a street frame is
	# above a glow threshold, so the halo is not around the bright things - it is
	# over everything, which costs contrast exactly where the day needs it. The
	# night keeps its 0.55 (`Look.GLOW_INTENSITY`, untouched).
	env.glow_enabled = false

	# --- SSR: OFF ----------------------------------------------------------
	# `night_env.gd:80-84` says what SSR is for: streetlights and neon smeared down
	# wet tarmac. A dry daylight road reflecting a bright sky through it is a glare
	# source pointed at the driver's eyes, and Godot's SSR has no roughness-aware
	# sky rejection here. Left off rather than "tuned down".
	env.ssr_enabled = false

	# --- volumetrics: OFF --------------------------------------------------
	# Same reasoning. `night_env.gd:120-124` is explicit that the volume is there
	# to catch a headlight beam. There is no beam to catch at 10am.
	env.volumetric_fog_enabled = false

	# --- contact detail ----------------------------------------------------
	# Kept: the thing SSAO does in daylight is put the kerb, the road camber and
	# the building bases on the ground, and it is not a night effect. Radius is
	# tighter than the night's 1.4 because a 1.4 m radius in full daylight is a
	# grey halo around every bollard.
	env.ssao_enabled = true
	env.ssao_radius = 0.8
	env.ssao_intensity = 1.2
	env.ssao_power = 1.6
	env.ssao_detail = 0.4

	# --- grade -------------------------------------------------------------
	# `Look.ADJUSTMENT_CONTRAST` is read, not restated, so the two environments
	# cannot drift apart on the one number that was swept against a clipped black
	# floor (`look.gd:203-211`). Brightness and saturation are the day's own.
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = Look.ADJUSTMENT_CONTRAST
	env.adjustment_saturation = 1.06

	# Tonemap mode unchanged from the night: ACES, because changing the curve is
	# exactly the "rework the tonemap" this task rules out. Exposure is the daylight
	# constant above, argued there.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = TONEMAP_EXPOSURE
	env.tonemap_white = 1.2

	environment = env


## The sun this environment expects, so the light and the sky cannot disagree.
## `Game/main.gd` builds its `DirectionalLight3D` from here rather than from its
## own constants, which is what stops a future sun/sky mismatch.
static func sun_transform() -> Transform3D:
	return Transform3D(Basis.from_euler(
		Vector3(deg_to_rad(SUN_ROTATION_DEG.x), deg_to_rad(SUN_ROTATION_DEG.y),
			deg_to_rad(SUN_ROTATION_DEG.z))), Vector3.ZERO)