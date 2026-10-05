extends RefCounted
## t191 day pass: the daytime environment is the default, the night is preserved,
## and the verge screen keeps solid plants out of the carriageway.
##
## Three things are asserted here that nothing else in the suite can catch:
##
## 1. **The day is a day.** Not "an environment exists" - that is satisfied by a
##    black one. The sky is bright, the ambient comes from the sky rather than from a
##    named colour, and the three night-only optics (glow, SSR, volumetric fog) are
##    off. A daylight frame that still has sodium bloom and a mirror road is the night
##    with the brightness turned up, which is what the owner rejected.
##
## 2. **The night is preserved.** This is the half that a day-first change usually
##    loses. `NightEnv` is built and its own numbers are asserted here, so "we kept it
##    for later" is a fact with a number attached rather than a promise. If the night is
##    ever deleted or quietly regraded to match the day, this goes red.
##
## 3. **The verge screen works, and it works for the case it was written for.** A palm
##    shaft dropped in a lane is pushed out along the way out of the carriageway and
##    re-tested; a scrub bush in the same lane is left alone, because the world means
##    you drive through those. Both branches, measured, not asserted by construction.
##
## The reachability consequence of (1) lives in `Tests/test_0reachability.gd`: the
## shipped-environment witness moved from `night_env.gd` to `day_env.gd`, and
## `night_env.gd` moved to that file's NOT_SHIPPED list, where it fails the moment
## anybody wires it back.

func run(t: TestHarness) -> void:
	await _day_is_a_day(t)
	await _night_is_preserved(t)
	_the_switch_exists(t)
	await _verge_screen(t)


## A day, stated as properties of the Environment that was actually built.
func _day_is_a_day(t: TestHarness) -> void:
	var day := DayEnv.new()
	var day_root := t.new_root("DayPass")
	day_root.add_child(day)
	var env: Environment = day.environment
	if t.ok(env != null, "DayEnv builds an Environment"):
		_day_properties(t, env)
	await t.drop(day_root)


func _day_properties(t: TestHarness, env: Environment) -> void:
	t.eq(env.background_mode, Environment.BG_SKY, "the day has a sky, not a colour")

	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	if not t.ok(sky_mat != null, "and it is a procedural sky"):
		return

	# Luma, because "blue" and "bright" are separate claims and only one of them makes
	# a frame read as daytime.
	t.gt(_luma(sky_mat.sky_top_color), 0.30,
		"the sky's zenith is bright (luma %.3f)" % _luma(sky_mat.sky_top_color))
	t.gt(_luma(sky_mat.sky_horizon_color), 0.55,
		"and the horizon is brighter still (luma %.3f)" % _luma(sky_mat.sky_horizon_color))
	t.gt(sky_mat.sky_horizon_color.b, sky_mat.sky_horizon_color.r,
		"and the horizon is blue-dominant, i.e. daylight and not sodium")

	t.eq(env.ambient_light_source, Environment.AMBIENT_SOURCE_SKY,
		"ambient comes from the sky (the night cannot: its sky is black)")
	t.gt(env.ambient_light_energy, 0.5, "and there is enough of it to see under a carport")

	# The three that are night-only. Each has a named reason in day_env.gd.
	t.eq(env.glow_enabled, false, "glow is off - it is a night effect")
	t.eq(env.ssr_enabled, false, "SSR is off - a dry daylight road is a glare source")
	t.eq(env.volumetric_fog_enabled, false, "volumetrics are off - there is no beam to catch")
	t.eq(env.ssao_enabled, true, "SSAO stays on: it puts the kerb on the ground either way")

	t.eq(env.tonemap_mode, Environment.TONE_MAPPER_ACES, "tonemap mode is unchanged")
	t.near(env.tonemap_exposure, DayEnv.TONEMAP_EXPOSURE, 0.0001,
		"exposure is this environment's own daylight value")
	t.near(env.adjustment_contrast, Look.ADJUSTMENT_CONTRAST, 0.0001,
		"contrast is read from Look, so the two environments cannot drift apart")

	# Haze that reaches: a daylight street needs aerial perspective or every distant
	# building is the same contrast as the one in front of the camera.
	t.eq(env.fog_enabled, true, "daylight has haze")
	t.gt(env.fog_depth_end, 800.0, "and it reaches down a 1.4 km straight (%.0f m)"
		% env.fog_depth_end)

	# The sun is the same object the environment expects. If these can disagree, the
	# sky says one thing and the light says another and nobody finds out.
	t.ok(DayEnv.SUN_ENERGY > 1.0,
		"the sun is the dominant light in daylight (energy %.2f)" % DayEnv.SUN_ENERGY)
	t.gt(DayEnv.SUN_COLOUR.r, DayEnv.SUN_COLOUR.b,
		"and it is warm-white, not sodium-orange")
	t.ok(DayEnv.sun_transform().basis.determinant() > 0.0, "the sun transform is a rotation")


## The night, unchanged. Every number here is one `night_env.gd` already had.
func _night_is_preserved(t: TestHarness) -> void:
	var night := NightEnv.new()
	var night_root := t.new_root("NightPass")
	night_root.add_child(night)
	var env: Environment = night.environment
	if t.ok(env != null, "NightEnv still builds - the night was preserved, not deleted"):
		_night_properties(t, env)
	await t.drop(night_root)


func _night_properties(t: TestHarness, env: Environment) -> void:
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
	t.ok(sky_mat != null, "and it still has its sky")
	if sky_mat != null:
		t.lt(_luma(sky_mat.sky_top_color), 0.05,
			"the night sky is still nearly black (luma %.3f)"
			% _luma(sky_mat.sky_top_color))
	t.eq(env.ambient_light_source, Environment.AMBIENT_SOURCE_COLOR,
		"the night ambient is still the explicit colour it has to be")
	t.eq(env.glow_enabled, true, "the night keeps its glow")
	t.near(env.glow_intensity, Look.GLOW_INTENSITY, 0.0001,
		"at Look.GLOW_INTENSITY, untouched")
	t.eq(env.volumetric_fog_enabled, true, "the night keeps its volumetrics for the beams")
	t.eq(env.ssr_enabled, true, "and its SSR for the wet road")
	t.near(env.tonemap_exposure, 1.45, 0.0001,
		"the night's exposure is still 1.45 - the day pass did not retune it")
	t.near(env.adjustment_contrast, Look.ADJUSTMENT_CONTRAST, 0.0001,
		"and both environments read the one Look constant")


## The night is one flag away, and the flag is a constant someone can read.
func _the_switch_exists(t: TestHarness) -> void:
	var script: Script = load("res://Game/main.gd")
	if not t.ok(script != null, "the entry script loads"):
		return
	var consts := script.get_script_constant_map()
	t.ok(consts.has("NIGHT_MODE"), "Game/main.gd declares the switch as a constant")
	if consts.has("NIGHT_MODE"):
		t.eq(String(consts["NIGHT_MODE"]), "--night",
			"and it is --night, so the night is one documented argument away")
	# The default has to be readable from the source too, or "day is the default" is
	# only true of whichever branch someone happened to leave in place.
	var src := FileAccess.get_file_as_string("res://Game/main.gd")
	t.ok(src.find("DayEnv.new()") >= 0, "the entry point constructs DayEnv")
	t.ok(src.find("NightEnv.new()") >= 0 and src.find("_night_requested()") >= 0,
		"and reaches NightEnv only through _night_requested(), so the default cannot drift")


## The verge screen, on the real road graph, on both branches it has.
##
## Fast on purpose: a `WorldBuilder` is built with `graph` set and `build()` is never
## called, because the screen only needs the corridor index. The full world's verdict
## is `World/corridor_audit.gd`'s job and it runs on the GPU.
func _verge_screen(t: TestHarness) -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var roads := OSMBuildings.road_index(g)
	if not t.gt((roads["segs"] as Array).size(), 10, "the corridor index has segments"):
		return

	# The longest straight run of carriageway in the map, which is the easiest place
	# to say exactly where the kerb is.
	var best_a := Vector2.ZERO
	var best_b := Vector2.ZERO
	var best_hw := 1.0
	var best_len := 0.0
	for s in (roads["segs"] as Array):
		var a: Vector2 = s["a"]
		var b: Vector2 = s["b"]
		var l := a.distance_to(b)
		if l > best_len:
			best_len = l
			best_a = a
			best_b = b
			best_hw = float(s["hw"])
	if not t.gt(best_len, 50.0, "found a straight long enough to test against (%.1f m)" % best_len):
		return
	var mid := (best_a + best_b) * 0.5
	var side := Vector2(-(best_b - best_a).y, (best_b - best_a).x).normalized()
	var kerb := mid + side * best_hw

	var was := WorldBuilder.verge_screening
	WorldBuilder.verge_screening = true

	# A palm shaft standing 2 m INSIDE the carriageway edge: the defect t191 exists for.
	var b := WorldBuilder.new()
	b.graph = g
	var inside := kerb - side * 2.0
	var palm := {"kind": "palm", "pos": inside, "yaw": 0.0, "h": 9.0,
		"lean": 0.0, "droop": 0.5, "salt": 0,
		"size": Vector3(0.72, 9.0, 0.72), "centre": Vector3(0.0, 4.5, 0.0)}
	t.ok(_clear(b, roads, inside, palm) < 0.0,
		"CONTROL: a palm 2 m inside the kerb really does intrude before the screen")
	var res := b._screen_verge([palm])
	t.eq(int(res["moved"]), 1, "and the screen pushes it out rather than dropping it (%s)"
		% str(res["reasons"]))
	t.eq(int(res["dropped"]), 0, "without throwing it away")
	var kept: Array = res["kept"]
	if t.eq(kept.size(), 1, "one plant came out"):
		var now: Vector2 = kept[0]["pos"]
		t.ok(_clear(b, roads, now, kept[0]) >= 0.0,
			"and what came out is verified clear, not assumed clear (%.2f m)"
			% _clear(b, roads, now, kept[0]))

	# The other branch: a plant in the middle of the lane with no way out is dropped,
	# and the drop is reported with a reason rather than silently vanishing.
	var centre := mid
	var trapped := {"kind": "palm", "pos": centre, "yaw": 0.0, "h": 9.0,
		"lean": 0.0, "droop": 0.5, "salt": 1,
		"size": Vector3(0.72, 9.0, 0.72), "centre": Vector3(0.0, 4.5, 0.0)}
	var drop := b._screen_verge([trapped])
	t.ok(int(drop["dropped"]) + int(drop["moved"]) >= 1,
		"a palm on the centreline is dealt with")
	t.gt((drop["reasons"] as Array).size(), 0, "and says why (%s)" % str(drop["reasons"]))

	# The screen off must return the list untouched, or the before picture is a lie.
	WorldBuilder.verge_screening = false
	var off := b._screen_verge([palm])
	t.eq(int(off["moved"]) + int(off["dropped"]), 0, "screening off moves nothing")
	t.eq((off["kept"] as Array).size(), 1, "and returns the plant, still in the road")
	t.ok((b.get("_solid") as Dictionary).get("verge_screen", {}).get("on") == false,
		"and records that it was off, so an unscreened build cannot pass for a screened one")

	WorldBuilder.verge_screening = was
	b.free()


## The screen's own verdict on one candidate: worst corner gap minus the clearance.
func _clear(b: WorldBuilder, roads: Dictionary, p: Vector2, cand: Dictionary) -> float:
	return b._prop_clear(p, {"size": cand["size"], "centre": cand["centre"]},
		float(cand["yaw"]), 1.0, roads)


static func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b