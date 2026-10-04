class_name NightPass
extends Node3D
## THE NIGHT LAYER. One file, installed once, that owns every decision about how
## light behaves in this world at night: the optical distribution of each luminaire,
## where the reflection probe lives, and whether dynamic global illumination is
## allowed to touch the frame.
##
## It exists because the night was assembled from three unrelated places - the lamp
## loop in `world_builder.gd`, the grade in `night_env.gd`, and a reflection probe
## in `Game/main.gd` that is never moved again after it is created - and each of
## them was tuned against the other two's *defaults* rather than against each other.
## Nothing in the tree could answer "what does a lamp actually emit", so every
## question about the night had to be answered by re-rendering.
##
## ## WHAT IT DOES NOT DO
##
## It does not touch a mesh, a material, an albedo or a texture. Every asset in this
## world was day-verified by t181 (PBR surfaces) and t182 (kit GLBs) and is correct
## as it stands; the defect this fixes is that correct *day* content was being lit
## by an undefined night. `NightEnv` still owns the grade - this file never sets
## `tonemap_*`, `adjustment_*`, `ambient_*`, `fog_*`, `glow_*` or `ssr_*`, because
## those numbers were each swept and documented in `World/look.gd` and re-deciding
## them here would lose the argument that produced them.
##
## ## THE THREE THINGS, AND WHY EACH ONE IS A SEPARATE DECISION
##
## **1. Per-lamp optics.** `world_builder.gd` emitted every one of the 1,662 street
## standards as an `OmniLight3D` hanging under the luminaire head. An omni radiates
## into the full sphere: roughly half its flux goes UP past the shade into a sky
## that `night_env.gd` is trying to keep at `#0a0d16`, and its footprint on the
## tarmac is a symmetric disc rather than the forward-throwing distribution of a
## real cobra luminaire. That is why `Look.STREETLIGHT_ENERGY` had to be pushed
## down to 10.0 from 45.0 to stop the arterial clipping - the energy number was
## carrying the waste, not the light. A cone aimed at the tarmac spends the same
## flux where it is wanted. The aim is not a magic number: each spot is pointed at
## the point `RoadGraph.nearest_road()` reports for its own position, so a standard
## on a 26 m residential street and one on a 12 m lane both light their own road.
##
## **2. The probe follows the viewpoint.** `Game/main.gd` creates one
## `ReflectionProbe` ("the reflection probe follows the player", per
## `ART_DIRECTION.md`), sets `UPDATE_ALWAYS`, and then never touches it again: it
## stays at the map origin for the whole session. A wet road is a near-mirror
## (`MatLib.wet_asphalt`, roughness 0.10-0.18) and a mirror with nothing in it
## renders black, so the single most important surface in the game reflects a
## cubemap of empty origin for 50,000 m of city. This layer finds the probe that
## already exists rather than adding a second one, and drives it to the live camera
## every frame.
##
## **3. SDFGI, measured, and shipped OFF.** The four cascades are still configured
## from the near-field exclusion outward, because the configuration is correct and
## the engine honours it - but `SDFGI_ENERGY` ships at 0.0. Measured over 6 poses x
## 5 configurations, enabling SDFGI made the road darker on every single pose and
## brighter on none, so whatever the near-field exclusion protects, it is not a
## usable horizon glow. The numbers, including the `read_sky` hypothesis that the
## measurement refuted, are in the `SDFGI_ENERGY` comment and in
## `/tmp/reports/t185-night-pass.md`.
##
## ## OPTIONS ARE RUNTIME-SWEEPABLE, WHICH IS THE POINT
##
## `apply()` is idempotent and takes the same options dictionary the shipped
## defaults are built from, so `World/look_dev_capture.gd --night=...` can render
## the *same world build* under several configurations and get a same-camera
## comparison out of it. The shipped constants are the winning row of that sweep,
## not a preference - and the winning row is reproducible by anyone who re-runs it.

const NODE_NAME := "NightPass"

## Cone width, and it is NARROWER than it looks like it should be - which the
## sweep proved the expensive way. A standard's head hangs 1.2 m outside the kerb
## at 7.05 m, so the carriageway is ~6.5 m away laterally; a ground pool of radius
## `r` needs a half angle of `atan(7.05 / r)`, so 96 deg (half 48) is not a tight
## pool at all - it is a 300 m wash whose bright centre is the 0.25 m of ground
## directly under the head, with everything else on grazing rays that `spot_range`
## and `spot_attenuation` eat before it lands.
##
##     cone  aim_t  tilt   pool radius   kerb road luma   street detail
##     96    0.62   40.0   7.7 m         81.67 (-6.8%)   1.66 (-14%)
##     65    0.45   ~67    10.9 m        see the sweep
##
## i.e. the first attempt made the road DARKER and the frame LESS detailed, which
## is the "wide dim wash" `ART_DIRECTION.md` forbids, produced by narrowing the
## light rather than by raising it. 65 deg at a steep axis concentrates the same
## flux into the 11 m the carriageway actually occupies.
const SPOT_CONE_DEG := 65.0

## Cone edge softness. 1.0 is a smooth cosine falloff to the cone edge, 0.0 is a
## hard edge. A real cobra luminaire has a hard horizontal cutoff - the reason it
## exists is to stop light going into a first-floor window - so this is kept near
## the middle: soft enough not to draw a visible cone rim on the road, sharp enough
## that the rim does not read as a circle of light.
const SPOT_ANGLE_ATTEN := 0.6

## How far off its own centreline a standard can be and still aim at the road
## instead of straight down. The builder places it `width / 2 + 1.2 m` out and then
## slides it along the street by up to 13 m to clear a junction box - along, never
## across - so the widest real value is a 14 m lane plus 1.2 m of offset.
const MAX_AIM_LATERAL_M := 14.0

## Floor on how far below the horizon the cone axis points, so no standard can rake
## a beam along the street. Expressed as a maximum aim distance so the census tilt
## spread stays a spread: a floor that silently clamps all 1,662 standards is a
## constant wearing a floor's name. See the SDFGI read-back discipline.
const MIN_TILT_DEG := 50.0

## And the matching ceiling on how far out the axis may point, so a head cannot be
## aimed at the far kerb of a very wide road. 12 m puts the axis at 30 deg on a
## 7.05 m head, which is as shallow as a luminaire gets before it is a floodlight.
const MAX_AIM_FLAT_M := 12.0

## Cone axis aim, as a fraction of the way from the luminaire to the tarmac point
## below it. 1.0 aims AT the road centreline - a shallow axis, `atan(7.05 / 6.5) =
## 47 deg`, which throws the pool out past the far kerb. Less than 1.0 aims closer
## in, which steepens the axis and centres the pool on the carriageway: at 0.45 the
## axis is about 67 deg down and the pool is a circle ~11 m across sitting on the
## road instead of spilling onto the footpaths and the far side.
const AIM_T := 0.45

## Probe lift above the camera. A cubemap taken at eye height sees mostly road and
## almost no sky or lamp head, so the wet surface reflects a frame of tarmac. 6 m
## puts the probe above the pool it is reflecting and gives it both the lamps and
## the horizon.
const PROBE_LIFT_M := 6.0

## --------------------------------------------------------------------------
## SDFGI
## --------------------------------------------------------------------------
##
## ONE knob, not three, and that is a measurement rather than a preference. In
## Godot 4.3 the three SDFGI span properties recompute each other on every setter:
## `cascade0 = 64 * min_cell_size`, `max_distance = cascade0 * 2^cascades`, and
## whichever of the three you touch last is the one that wins. Measured on a fresh
## `Environment`, in this order:
##
##     set c0=120, max=420, cascades=4, cell=1.0   -> c0 64.00  max 1024.00
##     then set c0=120                             -> c0 120.00 max 1920.00
##     then set cell=1.0                           -> c0 64.00  max 1024.00
##     fresh: cell=1.0, casc=4, c0=120, max=420    -> c0 26.25  max  420.00
##
## So a version of this file that set all three and trusted its own values was
## rendering a 64 m near-field exclusion while believing it had asked for 120 m -
## 56 m of global illumination sitting exactly on the silhouette. The layer
## therefore states the number it actually cares about, THE NEAR-FIELD EXCLUSION,
## derives the cell size from it, and prints the span the engine reports back.
##
## The exclusion is what keeps this on the right side of `ART_DIRECTION.md`. The
## document asks for a "city glow ... low on the horizon only, behind the skyline"
## and for an ambient "low enough that an unlit kerb is nearly black"; those are
## in direct conflict if global illumination runs from the camera outwards, because
## 1,662 shadowless sodium lamps bouncing off 2,198 building footprints is a large,
## warm, spatially-uniform fill - the "hot orange tropical night" the art direction
## is explicitly a reversal of.

## Distance from the camera at which the first SDFGI cascade starts. Everything
## closer - kerb, car, the first two lamp pools, the shopfront being driven at -
## carries no global illumination at all and is lit by lamps and nothing else.
const SDFGI_NEAR_FIELD_M := 120.0

## Cell size is what the engine actually stores; `64 * cell` is the first
## cascade's distance, so this is `SDFGI_NEAR_FIELD_M / 64` and is never set
## independently. Stated as the derivation it is, so the two cannot drift.
const SDFGI_CELL_FROM_NEAR := 64.0

## Four cascades is Godot's own default and is left alone: the outermost cascade
## starts at `120 * 8 = 960 m`, past `night_env.gd`'s `fog_depth_end` of 620 m, so
## it is entirely fogged and contributes nothing visible either way.
const SDFGI_CASCADES := 4

## Energy multiplier. SHIPPED OFF, at 0.0, and that is the measured decision
## rather than the documented one - `World/look_dev_capture.gd` already said "the
## decision to ship it OFF is a measurement in this file", while this constant
## said 1.0. Measured 2026-10-04 (t185), one world build, 6 poses x 5
## configurations, Forward+ on an RTX 3060, road band:
##
##     pose       SDFGI off   sdfgi_far   sdfgi_nosky   sdfgi delta
##     kerb         100.02       96.83         96.0        -3.2
##     street        17.22       14.83        14.8        -2.4
##     junction      14.97       12.27        12.25       -2.7
##     walk1          8.25        6.18         6.15       -2.1
##     walk2          2.26        1.28         1.25       -1.0
##     walk3          2.14        1.17         1.15       -1.0
##
## Every configuration that switched SDFGI on made the road DARKER, and none made
## anything brighter anywhere - so on this map it is a subtractive term, not the
## "city glow low on the horizon" this layer exists to provide. The `nosky` column
## exists because the obvious hypothesis was wrong: it is NOT
## `sdfgi_read_sky_light` importing `#0a0d16`. Turning the sky read off changes
## every number by 0.03 or less (walk2 1.28 -> 1.25). What is left is
## `sdfgi_use_occlusion` shadowing 1,662 lamp pools inside a 2,198-building street
## canyon, with `sdfgi_bounce_feedback = 0.0` meaning no lamp replaces what it
## took away.
##
## So the near-field exclusion was never the thing keeping this off the right side
## of `ART_DIRECTION.md`. The exclusion is real and does what it says - the engine
## reports back 120.0 m for a declared 120.0 m, span 120-1920 m, past
## `night_env.gd`'s 620 m fog end - but it protects a contribution that is negative
## everywhere it lands. Set this above 0.0 to measure it again; the sweep variants
## `c65_probe_sdfgi_far` and `c65_probe_sdfgi_nosky` are still in the harness for
## exactly that.
const SDFGI_ENERGY := 0.0

## Read the sky into the cascades. This sky is near-black by design
## (`night_env.gd`), so this contributes almost nothing - but leaving it off makes
## the result depend on whether the sky changes later, which is exactly the kind of
## hidden coupling this file exists to end.
const SDFGI_READ_SKY := true

## Occlusion. `sdfgi_use_occlusion` darkens cascade cells behind geometry, and in a
## street canyon of 2,198 buildings that is the difference between "the far end of
## the street has a glow behind it" and "the far end of the street is grey".
const SDFGI_USE_OCCLUSION := true

## How much of each lamp's own bounce is fed back. 0.0 is the honest setting:
## letting a shadowless 1,662-lamp rig feed itself back is how a night frame turns
## into one flat orange mass, and it is the same failure as raising
## `AMBIENT_ENERGY`, which `World/look.gd` already measured at under 3% on every
## metric for the cost of flattening the image.
const SDFGI_BOUNCE_FEEDBACK := 0.0

## Options the game runs with. `apply()` merges anything over the top of this, so
## a sweep can change one key and leave the rest at the shipped values.
static func shipped() -> Dictionary:
	return {
		"optics": true,
		"spot_cone": SPOT_CONE_DEG,
		"spot_aim_t": AIM_T,
		"probe_follow": true,
		"sdfgi_energy": SDFGI_ENERGY,
		"sdfgi_near": SDFGI_NEAR_FIELD_M,
		"sdfgi_cascades": SDFGI_CASCADES,
		"sdfgi_read_sky": SDFGI_READ_SKY,
		"sdfgi_occlusion": SDFGI_USE_OCCLUSION,
		"sdfgi_bounce": SDFGI_BOUNCE_FEEDBACK,
		"probe_lift": PROBE_LIFT_M,
	}


## Pre-install configuration, so a capture harness can boot the real game with the
## night pass switched OFF (to measure the before) or switched on with sweep values.
## Read once by `install()`; a `{}` means "shipped defaults, enabled".
static var pending: Dictionary = {}


## Install on a freshly built world. Returns null when `pending["enabled"]` is
## false, which is how the before-picture is taken: the tree is then byte-for-byte
## the tree `integration` ships.
static func install(world: Node3D) -> NightPass:
	var want: Dictionary = pending.duplicate(true)
	var enabled := bool(want.get("enabled", true))
	want.erase("enabled")
	if not enabled:
		return null
	var existing := world.get_node_or_null(NodePath(NODE_NAME)) as NightPass
	if existing != null:
		existing.apply(want)
		return existing
	var np := NightPass.new()
	np.name = NODE_NAME
	# The layer keeps working while the tree is paused. The main menu pauses the
	# game and the camera sits still under it, but a reflection probe that stops
	# being placed the moment a menu opens is a probe that is in the wrong place
	# for the first frame after it closes.
	np.process_mode = Node.PROCESS_MODE_ALWAYS
	world.add_child(np)
	np.apply(want)
	return np


## Re-apply every option. Idempotent: calling it twice with the same dictionary
## converts nothing twice and sets the same environment values.
func apply(o: Dictionary) -> void:
	var opts := shipped()
	for k in o.keys():
		opts[k] = o[k]
	opts_applied = opts
	if bool(opts["optics"]):
		_optics(get_parent() as Node3D)
	_configure_probe()
	_configure_sdfgi()
	set_process(bool(opts["probe_follow"]))


## What the night is currently made of, read back off the live tree.
##
## Static, and taking the root to walk, because the most important thing it has to
## answer is "what does this look like with the layer NOT installed" - the before
## picture - and there is no layer instance in the tree at that moment to ask.
## Every number is counted rather than remembered, so a lamp the layer failed to
## convert shows up as an omni rather than as a claim that it converted.
static func census_of(root: Node) -> Dictionary:
	var standards := 0
	var standards_spot := 0
	var junction := 0
	var standard_omni := 0
	var other_omni := 0
	var spots := 0
	var energy := 0.0
	var tilt_min := 181.0
	var tilt_max := -1.0
	var cones := PackedFloat32Array()
	# How many standards are running on the `MIN_TILT_DEG` floor rather than on
	# `lateral * AIM_T`. At the shipped `AIM_T` this is every standard on this map,
	# which the tilt spread shows but cannot explain.
	var aim_floor_bound := 0
	for l_v in _walk(root):
		var l := l_v as Node
		if not (l is Light3D):
			continue
		var role := String(l.get_meta("night_role", ""))
		var light := l as Light3D
		if role == "street":
			standards += 1
			energy += light.light_energy
			if l is SpotLight3D:
				standards_spot += 1
				var s := l as SpotLight3D
				cones.append(s.spot_angle)
				if bool(s.get_meta("night_aim_floor", false)):
					aim_floor_bound += 1
				var axis := -s.global_transform.basis.z
				var t := rad_to_deg(acos(clampf(axis.normalized().y, -1.0, 1.0)))
				tilt_min = minf(tilt_min, t)
				tilt_max = maxf(tilt_max, t)
			else:
				standard_omni += 1
		elif role == "junction":
			junction += 1
		elif l is SpotLight3D:
			spots += 1
		elif l is OmniLight3D:
			other_omni += 1
	var probe := _find_probe(root)
	var env := _find_env(root)
	var inst := _find_pass(root)
	var out := {
		"standards": standards,
		"standards_spot": standards_spot,
		"junction": junction,
		"spots": spots,
		"standard_omni": standard_omni,
		"other_omni": other_omni,
		"standard_energy_sum": energy,
		"cone_min": _min(cones),
		"cone_max": _max(cones),
		# -1 when there is nothing to report: a min seeded at 90 that no tilt ever
		# beats reads as "every standard points sideways" when the honest answer is
		# "there are no spots", which is the difference between a defect and an
		# absent measurement.
		"tilt_min": tilt_min if standards_spot > 0 else -1.0,
		"tilt_max": tilt_max if standards_spot > 0 else -1.0,
		"aim_floor_bound": aim_floor_bound,
	}
	if probe != null:
		out["probe_pos"] = probe.global_position
		out["probe_intensity"] = probe.intensity
		out["probe_follow"] = inst != null and inst.is_processing()
	else:
		out["probe_pos"] = null
		out["probe_follow"] = false
	if env != null:
		out["sdfgi"] = env.environment.sdfgi_enabled
		out["sdfgi_energy"] = env.environment.sdfgi_energy
		out["sdfgi_cascade0"] = env.environment.sdfgi_cascade0_distance
		out["sdfgi_max"] = env.environment.sdfgi_max_distance
		out["ambient"] = env.environment.ambient_light_energy
		out["exposure"] = env.environment.tonemap_exposure
	return out


func census() -> Dictionary:
	return census_of(_tree_root())


## The layer instance in this tree, if one is installed.
static func _find_pass(root: Node) -> NightPass:
	for n_v in _walk(root):
		var n := n_v as Node
		if n is NightPass:
			return n as NightPass
	return null


## How much light is actually standing near a point. A total of "1,662
## streetlights" cannot be judged from: the question for a frame is how many are
## inside their own 30 m range of THIS camera, and how much flux that is.
static func budget_near(root: Node, eye: Vector3) -> Dictionary:
	var within := 0
	var flux := 0.0
	var nearest := INF
	var above := 0
	for l_v in _walk(root):
		var l := l_v as Node
		if not (l is Light3D):
			continue
		var light := l as Light3D
		var d := eye.distance_to(l.global_position)
		nearest = minf(nearest, d)
		if l.get_meta("night_role", "") == "street" and d <= Look.STREETLIGHT_RANGE:
			within += 1
			flux += light.light_energy
			if l.global_position.y > eye.y:
				above += 1
	return {"standards_in_range": within, "flux": flux, "nearest": nearest, "above_eye": above}


# ----------------------------------------------------------------- per-lamp optics
## Point every street standard at the road it stands over.
##
## The conversion replaces the node rather than reconfiguring it, because an
## `OmniLight3D` has no cone: there is no property to set. The replacement is
## inserted at the same child index so the tree order - and therefore the draw
## order - is unchanged.
func _optics(world: Node3D) -> void:
	if world == null:
		return
	var g: RoadGraph = world.get("graph")
	var converted := 0
	var aimed := 0
	for parent_v in _walk(world):
		var parent := parent_v as Node
		if parent == null:
			continue
		var kids := parent.get_children()
		for i in kids.size():
			var l := kids[i] as Node
			if String(l.get_meta("night_role", "")) != "street":
				continue
			var spot: SpotLight3D = null
			if l is OmniLight3D:
				spot = _aim_at_tarmac(l, g)
				if spot == null:
					continue
				_spot_cone_from(spot, float(opts_applied.get("spot_cone", SPOT_CONE_DEG)),
					float(opts_applied.get("spot_aim_t", AIM_T)))
				parent.add_child(spot)
				# The local transform was copied from the omni; re-assert the global
				# position now the node is in the tree, so the aim below cannot be
				# computed against a placement the parent silently scaled.
				spot.global_position = l.global_position
				parent.move_child(spot, i)
				l.queue_free()
				converted += 1
			elif l is SpotLight3D:
				spot = l as SpotLight3D
				_spot_cone_from(spot, float(opts_applied.get("spot_cone", SPOT_CONE_DEG)),
					float(opts_applied.get("spot_aim_t", AIM_T)))
			if spot != null:
				aimed += 1
	if converted > 0:
		_apply_aims()
		print("[NightPass] optics: %d standard(s) converted to spots, %d aimed, cone %.0f deg aim_t %.2f" % [
			converted, aimed, float(opts_applied.get("spot_cone", SPOT_CONE_DEG)),
			float(opts_applied.get("spot_aim_t", AIM_T))])
	elif aimed > 0:
		print("[NightPass] optics: re-aimed %d existing spot(s), cone %.0f deg aim_t %.2f" % [
			aimed, float(opts_applied.get("spot_cone", SPOT_CONE_DEG)),
			float(opts_applied.get("spot_aim_t", AIM_T))])


## The two bounds that keep a cone axis looking like a luminaire and not like a
## floodlight, as ONE function, because the two code paths that need them were
## applying them differently and that difference was measurable.
##
## `drop` is how far the head is above the tarmac and `flat` is how far out the axis
## may point horizontally, so the axis tilt is `atan(drop / flat)`. The floor keeps
## the axis at least `MIN_TILT_DEG` below the horizon; the ceiling keeps it from
## becoming a raking beam down the street.
##
## Why it has to be shared - measured, 2026-10-04, t185: the first-aim path applied
## both bounds and the sweep path applied NEITHER, so re-aiming with `aim_t = 1.0`
## produced a `flat` of 13.07 m against a documented `MAX_AIM_FLAT_M` of 12, i.e.
## the sweep could push every one of 1,662 standards past the ceiling the constant
## exists to enforce, and only on the second `apply()`. The census showed it as
## `tilt 118` where the first aim had said `tilt 140`.
func _bound_flat(drop: float, flat: float) -> float:
	if drop <= 0.0:
		return MAX_AIM_FLAT_M
	return clampf(flat, drop / tan(deg_to_rad(MIN_TILT_DEG)), MAX_AIM_FLAT_M)


## Where this head's axis points, on the tarmac.
##
## `flat` is the HORIZONTAL distance from the head's own vertical to the aim
## point, which is the only parameterisation of "how far out does it throw" that
## actually changes the axis. The first version lerped the aim point along the
## segment from the head to the road - and a point on that segment gives the SAME
## direction no matter where on it you sit, so `AIM_T` was a no-op by
## construction. It measured as one: the `aim_t 0.45` and `aim_t 1.00` sweep rows
## came back identical in every metric of every pose, including the md5.
##
## The road side comes from the data (`RoadGraph.nearest_road` on this head), and
## the aim distance is that road's own half-width plus offset, scaled by `AIM_T`.
##
## Two bounds, and both of them exist because the unclamped version was measured
## being wrong:
##
## * **Lateral.** `nearest_road` searches every edge in the map, so a standard
##   standing in a back yard or on a service lane projects onto something a long
##   way off, and an aim point 200 m away horizontally turns the cone into a
##   horizontal beam that lights the sky and not the road. A standard is never
##   more than `width / 2 + 1.2 m` from its own centreline plus a couple of metres
##   of slide, so past `MAX_AIM_LATERAL_M` the road under this head is not this
##   head's road and the honest aim is straight down.
## * **Tilt.** A cobra head 7 m up does not throw a grazing beam, and an aim point
##   20 m down the street would ask for 19 degrees of tilt - a beam that misses the
##   pool it is supposed to make and rakes the far kerb instead. `MIN_TILT_DEG` is
##   the floor on how far down the cone axis points, and `MAX_AIM_FLAT_M` the
##   matching ceiling so a head cannot be aimed at the far kerb of a wide road.
##
## ## WHAT ACTUALLY SHIPS, MEASURED
##
## At the shipped `AIM_T = 0.45` the tilt floor wins for EVERY standard on this
## map. The census tilt spread across all 1,662 of them is 0.0005 degrees
## (139.99978-140.00023, i.e. the floor to five significant figures), so the shipped
## axis is `MIN_TILT_DEG` and not `lateral * AIM_T`. That is a defensible aim - a
## head ~7.05 m up at a 50 deg axis throws its pool about 5.8 m out, which is on
## the carriageway and not on the footpath - but it means `AIM_T` is inert on the
## first `apply()` at 0.45 and only becomes live once `lateral * aim_t` clears
## `drop / tan(50 deg)`, i.e. above roughly `aim_t = 0.8` on a 7.2 m lateral. The
## census reports `aim_floor_bound` so this stays visible instead of being a
## comment that quietly stops being true.
##
## This function is the ONLY place an aim point is derived. An earlier version kept
## a second, near-identical copy (`_tarmac_aim`) that used the raw projection
## distance where this one uses `lateral * aim_t`, and applied the tilt floor
## under a different guard. Nothing called it, so it was not a variant - it was a
## second, disagreeing answer to the same question sitting one screen away, which
## is exactly how the next reader ends up editing the wrong one.
func _axis_target(pos: Vector3, g: RoadGraph) -> Vector3:
	var drop := pos.y - LookDev.TARMAC_Y
	if g == null:
		return Vector3(pos.x, LookDev.TARMAC_Y, pos.z)
	var nr := g.nearest_road(pos)
	var lateral := float(nr.get("lateral", 9999.0))
	var road: Vector3 = nr.get("point", pos)
	if lateral > MAX_AIM_LATERAL_M or lateral < 0.01:
		# No road of its own within reach: straight down. Not a corner case - it is
		# every head whose nearest edge is a service lane behind it.
		return Vector3(pos.x, LookDev.TARMAC_Y, pos.z)
	var to_road := Vector2(road.x - pos.x, road.z - pos.z).normalized()
	var aim_t := float(opts_applied.get("spot_aim_t", AIM_T))
	# `lateral` is the distance from the head to its own centreline, which is what
	# `aim_t = 1.0` means: aim AT the centreline.
	var raw := lateral * aim_t
	var flat := _bound_flat(drop, raw)
	# Recorded so the census can say how many standards are running on the floor
	# rather than on the aim formula, instead of leaving it to be inferred from a
	# tilt spread that looks like a rounding error.
	_last_aim_floor_bound = raw < flat
	return Vector3(pos.x + to_road.x * flat, LookDev.TARMAC_Y, pos.z + to_road.y * flat)


## A spot with the omni's own optics values, pointed at the tarmac below the head.
func _aim_at_tarmac(src: OmniLight3D, g: RoadGraph) -> SpotLight3D:
	var spot := SpotLight3D.new()
	spot.name = String(src.name) if String(src.name) != "" else "Standard"
	spot.transform = src.transform
	spot.light_color = src.light_color
	spot.light_energy = src.light_energy
	spot.light_specular = src.light_specular
	spot.light_volumetric_fog_energy = src.light_volumetric_fog_energy
	spot.shadow_enabled = false
	spot.spot_range = src.omni_range
	spot.spot_attenuation = src.omni_attenuation
	spot.spot_angle = float(opts_applied.get("spot_cone", SPOT_CONE_DEG))
	spot.spot_angle_attenuation = SPOT_ANGLE_ATTEN
	spot.set_meta("night_role", "street")
	spot.set_meta("night_optics", true)
	spot.set_meta("night_aim_floor", _last_aim_floor_bound)
	# The aim is recorded here and applied by `_apply_aims()` once the node is
	# parented, because `look_at` is a global operation and this node is still
	# unparented. If there is no road under the head the aim comes back null and
	# the spot keeps its placement rotation, which is straight down.
	# `global_position` on an unparented node returns the ORIGIN, not its own
	# position and not an error, so a world built outside the tree would aim every
	# standard at the same point on the map. Fall back to the local transform and
	# let the aim be wrong in a way that is visible in the census tilt.
	var from := src.global_position if src.is_inside_tree() else src.position
	spot.set_meta("night_aim_pos", _axis_target(from, g))
	_pending_aim[spot.get_instance_id()] = spot.get_meta("night_aim_pos")
	return spot


## Cone and aim for one standard that is already a `SpotLight3D`. Split out so a
## sweep can re-aim every standard WITHOUT reconverting any of them: an omni cannot
## be un-converted, but a spot's cone and axis are two properties, which is what makes
## the optics sweep cumulative-safe and free.
##
## The aim half is IN-TREE ONLY, and that guard is load-bearing. `_optics` calls
## this on a freshly built spot it has not parented yet, and on an unparented node
## `global_position` reads the ORIGIN and `look_at` refuses to run at all - the
## engine logs `Node not inside tree. Use look_at_from_position() instead.` and
## returns without rotating anything. Measured: that path produced ~1,600 such
## errors per boot, one per converted standard, and silently aimed every one of
## them at the map origin. The conversion still ended up correct only because
## `_apply_aims()` re-aims after insertion - so the guard below is not tidiness,
## it is the difference between one aim and two aims that disagree.
func _spot_cone_from(spot: SpotLight3D, cone_deg: float, aim_t: float) -> void:
	spot.spot_angle = cone_deg
	spot.spot_angle_attenuation = SPOT_ANGLE_ATTEN
	if not spot.has_meta("night_aim_pos") or not spot.is_inside_tree():
		# Cone properties are valid off-tree; the axis is not. `_apply_aims()` owns
		# the aim for anything this function has not already placed in a tree.
		return
	var from: Vector3 = spot.global_position
	var road: Vector3 = spot.get_meta("night_aim_pos")
	# `aim_t` re-derives the distance along the SAME bearing the first aim used,
	# so a sweep changes the angle and not which side of the road it lights.
	var bearing := Vector2(road.x - from.x, road.z - from.z)
	if bearing.length() > 0.01:
		bearing = bearing.normalized()
	var drop := from.y - LookDev.TARMAC_Y
	var raw := (Vector2(road.x - from.x, road.z - from.z)).length() * (aim_t / AIM_T)
	# The SAME bounds the first aim used. This used to rescale the already-clamped
	# distance with no bounds at all, which is how a sweep could put every one of
	# 1,662 standards past `MAX_AIM_FLAT_M` - see `_bound_flat`.
	var flat := _bound_flat(drop, raw)
	spot.set_meta("night_aim_floor", raw < flat)
	var aim := Vector3(from.x + bearing.x * flat, LookDev.TARMAC_Y, from.z + bearing.y * flat)
	var d := aim - from
	if d.length() > 0.25:
		if absf(d.normalized().dot(Vector3.UP)) > 0.999:
			spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		else:
			spot.look_at(aim, Vector3.UP)


## Aim points keyed by spot instance id, applied after insertion.
var _pending_aim: Dictionary = {}

## Whether the standard most recently aimed by `_axis_target` had its aim distance
## raised to the tilt floor. A one-shot flag read immediately by `_aim_at_tarmac`,
## which is the only caller that wants it.
var _last_aim_floor_bound: bool = false


## Point the freshly created spots at their own tarmac. Called by `_optics` once
## every replacement is in the tree.
func _apply_aims() -> void:
	for id in _pending_aim.keys():
		var spot := instance_from_id(int(id)) as SpotLight3D
		var aim: Vector3 = _pending_aim[id]
		_pending_aim.erase(id)
		if spot == null or not is_instance_valid(spot):
			continue
		var d := aim - spot.global_position
		if d.length() < 0.25:
			continue
		if absf(d.normalized().dot(Vector3.UP)) > 0.999:
			# `look_at` cannot build a basis for a direction parallel to `up`, and
			# a standard whose aim resolved to straight below itself is exactly
			# that case. It is not a corner case either: any head the layer judged
			# to have no road of its own falls here, and the first version simply
			# skipped those - leaving them as 96-degree cones firing HORIZONTALLY
			# along the street, which is the exact opposite of a cobra luminaire.
			spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
			continue
		spot.look_at(aim, Vector3.UP)


# ------------------------------------------------------------------------- probe
## The one `ReflectionProbe` `Game/main.gd` built, cached so `_process` is not a
## full recursive walk of a ~1,662-luminaire world sixty times a second.
var _probe: ReflectionProbe = null


## Take over the probe that already exists.
##
## `Game/main.gd` builds exactly one and adds it to the scene root, so this finds
## it rather than making a second one. A second probe would double the per-frame
## reflection cost to render the same empty origin from two places.
func _configure_probe() -> void:
	_probe = _find_probe(_tree_root())
	if _probe == null:
		return
	_probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	_probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED


## Drive the probe to the live camera, lifted.
##
## The probe handle is cached rather than re-found every frame: `_find_probe` is a
## full recursive walk of the world, and this world holds ~1,662 luminaires plus
## the OSM batches, so a per-frame walk is tens of thousands of node visits per
## second spent re-discovering a node that `Game/main.gd` created once. The
## instance is re-resolved only if it has actually gone away, which is the one
## case where the cached handle would be stale.
func _process(_delta: float) -> void:
	if not bool(opts_applied.get("probe_follow", true)):
		return
	if _probe == null or not is_instance_valid(_probe):
		_probe = _find_probe(_tree_root())
		if _probe == null:
			return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_probe.global_position = cam.global_position + Vector3.UP * float(
		opts_applied.get("probe_lift", PROBE_LIFT_M))


# ------------------------------------------------------------------------- SDFGI
## Configure the cascades on the environment `NightEnv` already owns.
##
## `NightEnv` stays the single owner of the grade; this only fills in the
## global-illumination block, which is the one part of a Forward+ night that no
## amount of lamp tuning can reach.
func _configure_sdfgi() -> void:
	var env := _find_env(_tree_root())
	if env == null:
		return
	var e := env.environment
	var on := float(opts_applied.get("sdfgi_energy", 0.0)) > 0.0
	e.sdfgi_enabled = on
	if not on:
		return
	var near_field := float(opts_applied.get("sdfgi_near", SDFGI_NEAR_FIELD_M))
	e.sdfgi_energy = float(opts_applied["sdfgi_energy"])
	e.sdfgi_cascades = int(opts_applied.get("sdfgi_cascades", SDFGI_CASCADES))
	# The cell size is what carries the exclusion; the two distance properties are
	# derived from it by the engine and are only read back here. See the table in
	# the SDFGI section above for why they are not set directly.
	e.sdfgi_min_cell_size = maxf(near_field / SDFGI_CELL_FROM_NEAR, 0.1)
	e.sdfgi_read_sky_light = bool(opts_applied.get("sdfgi_read_sky", SDFGI_READ_SKY))
	e.sdfgi_use_occlusion = bool(opts_applied.get("sdfgi_occlusion", SDFGI_USE_OCCLUSION))
	e.sdfgi_bounce_feedback = float(opts_applied.get("sdfgi_bounce", SDFGI_BOUNCE_FEEDBACK))
	# Read the span back and compare it against the NUMBER THIS FILE ASKED FOR, not
	# against a value sampled after the last setter. `sdfgi_cascade0_distance` is
	# derived by the engine from the cell size, so reading it here and comparing it
	# to itself is the check that can never fail - which is why the derived span is
	# printed as the primary number and the declared near-field is the assertion.
	var got_near := e.sdfgi_cascade0_distance
	var got_max := e.sdfgi_max_distance
	print("[NightPass] sdfgi: energy=%.2f cascades=%d cell=%.3f -> asked exclusion %.1f m, engine reports %.1f m, span %.1f-%.1f m, bounce=%.2f occlusion=%s sky=%s" % [
		e.sdfgi_energy, e.sdfgi_cascades, e.sdfgi_min_cell_size,
		near_field, got_near, got_near, got_max,
		e.sdfgi_bounce_feedback, str(e.sdfgi_use_occlusion), str(e.sdfgi_read_sky_light)])
	# 0.5 m of slack: the engine's own rounding of `64 * cell` lands well inside it.
	if absf(got_near - near_field) > 0.5:
		push_warning("[NightPass] asked for a %.1f m near-field exclusion and the engine reports %.1f m - "
			% [near_field, got_near]
			+ "the span is being derived by a property this file no longer sets")
	if got_max <= got_near:
		push_warning("[NightPass] the SDFGI span is degenerate (max %.1f m is not past near %.1f m)"
			% [got_max, got_near])


# ----------------------------------------------------------------------- helpers
var opts_applied: Dictionary = {}


static func _walk(from: Node) -> Array:
	var out: Array = [from]
	var stack: Array = [from]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out


func _tree_root() -> Node:
	var t := get_tree()
	if t != null and t.root != null:
		return t.root
	return get_parent() if get_parent() != null else self


static func _find_probe(root: Node) -> ReflectionProbe:
	for n_v in _walk(root):
		var n := n_v as Node
		if n is ReflectionProbe:
			return n as ReflectionProbe
	return null


static func _find_env(root: Node) -> WorldEnvironment:
	for n_v in _walk(root):
		var n := n_v as Node
		if n is WorldEnvironment:
			return n as WorldEnvironment
	return null


static func _min(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var m := a[0]
	for v in a:
		m = minf(m, v)
	return m


static func _max(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var m := a[0]
	for v in a:
		m = maxf(m, v)
	return m











