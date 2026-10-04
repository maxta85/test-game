extends SceneTree
## pbr_shot.gd - a measured before/after board for the scanned PBR sets, under a
## DAY overcast sky, from one fixed camera per set.
##
##     DISPLAY=:99 godot --path . --rendering-driver opengl3 --audio-driver Dummy \
##         --resolution 1280x720 --script res://artkit/pbr_shot.gd -- \
##         --out /tmp/t181 --tag after [--night] [--measure]
##
## ## Why a separate harness and not `artkit_shot.gd`
##
## `artkit_shot.gd` renders *props* on a contact sheet at night. This one renders the
## six **surfaces** of the residential palette as a board of flat panels, in daylight,
## because the thing being judged is a material and the things that make a material
## wrong are all lighting-independent-or-wrong:
##
##   - a scan that is tiling obviously is invisible at night and obvious at noon;
##   - a scan whose roughness was gamma-decoded is either chalk or a mirror, and which
##     one it is depends entirely on the key light;
##   - a palette tint that is correct at night under a sodium lamp can be wrong under
##     a neutral 6500 K sky, because at night the illuminant supplies the hue and by day
##     the albedo does.
##
## So day is the honest test and night is a content check, not the other way round.
## Night is captured here too (`--night`), once per pose, and it is captured for
## *content* - is the panel the right material and does it read - and deliberately NOT
## for exposure. The night pass owns all night tuning; a number from here would be
## measured on this box's software renderer and would not survive contact with it.
##
## ## The five disciplines, and what each one is defending against
##
## **1. `asked-vs-got`.** Every pose prints the camera transform it asked for and the
## one it got. `World/look_dev_capture.gd` does this and the reason is recorded there:
## taking "the first Camera3D in the tree" returned six byte-identical frames, because a
## rig camera re-asserts its own transform every frame unless tracking is cleared.
## The failure mode is identical to "the change had no effect" - you get a plausible
## image of the wrong thing.
##
## **2. Delete the target PNG before rendering, and require a fresh one.** A render that
## silently no-ops exits 0 and leaves the previous run's file in place, which is then
## measured and reported as this run's evidence. This bit a sweep on this repo: four
## "different" exposure results that were one stale PNG read four times.
##
## **3. md5 the PNG after writing.** Proves the six poses are six different images. If
## two md5s match, the poses are not independent and every per-pose number below is
## the same number twice.
##
## **4. Unprojected pixel samples.** Reading a PNG's global mean says the frame is not
## black; it does not say the kerb is where the kerb was asked to be. Each pose names
## the world point it expects to see and the script unprojects it and reports the colour
## actually there, so "the panel is showing its scan" is a pixel value and not an
## impression.
##
## **5. Day, then night, and never a blend.** `--night` is a separate process and a
## separate tag. A single run that interpolated between the two would produce a frame
## nobody asked for.

const OUT_DEFAULT := "/tmp/artkit_pbr"
const RES := Vector2i(1280, 720)

## Luma at or above this counts as clipped, and so does at or below CLIP_LOW. Both
## ends, because the failure being hunted is a material that is either chalk (all the
## detail crushed) or a mirror (one blown specular), and a one-sided clip count reads
## both as "fine".
const CLIP_HIGH := 250.0
const CLIP_LOW := 5.0

## One panel per set. `size` is metres, and it matters: a scan tiled at a plausible
## real-world rate on a 4 m panel looks like a material, and on a 40 m panel it looks
## like a poster of a material. These are all street-scale.
const PANELS := [
	{"set": "weatherboard", "label": "weatherboard (house cladding)", "size": Vector2(4.2, 2.6), "key": "surface_render_wall_a"},
	{"set": "corrugated_roof", "label": "corrugated_roof (Colorbond)", "size": Vector2(4.2, 2.6), "key": "surface_roof_iron_a"},
	{"set": "paling_fence", "label": "paling_fence (sawn boards)", "size": Vector2(3.6, 1.8), "key": "timber"},
	{"set": "concrete_kerb", "label": "concrete_kerb + red return", "size": Vector2(3.6, 1.8), "key": "concrete_a"},
	{"set": "bitumen", "label": "bitumen (verge / shoulder)", "size": Vector2(4.2, 2.6), "key": "surface_asphalt_dry"},
	{"set": "grass_verge", "label": "grass_verge (nature strip)", "size": Vector2(3.6, 1.8), "key": "grass"},
]
const PANEL_PITCH := 4.6          ## metres between panel centres along X
const PANEL_Z := -1.0             ## the board's plane; the camera is on +Z looking -Z


## An explicit pinhole projection of a world point to viewport pixels.
##
## `Camera3D.unproject_position()` disagreed with the rendered frame by a constant ~86 px
## vertically on this build: it placed the panels at y 411-484 while the image has them
## at y~330-385, which is the ground. Every per-panel number therefore sampled the
## ground plane behind the board, and six ground measurements agree with each other to
## within 2/255 - the most confident wrong answer this file could produce.
##
## The camera is dead level and looking down -Z, so the projection is three lines and
## there is nothing to get wrong:
##
##     depth  d  = cz - P.z
##     ndc.y     = (P.y - cy) / (d * tan(vfov/2))
##     ndc.x     = (P.x - cx) / (d * tan(vfov/2) * aspect)
##     px.x      = W/2 + ndc.x * W/2
##     px.y      = H/2 - ndc.y * H/2
##
## `_measure_panel` reports BOTH this and `unproject_position()` and prints the delta,
## so the disagreement stays visible instead of being papered over.
static func project(cam: Camera3D, p: Vector3, w: int, h: int) -> Vector2:
	# `cam.position`, NOT `cam.global_position`. Global transforms are propagated on the
	# frame, and the standoff fit loop calls this many times without awaiting one - so
	# global_position was still (0,0,0) and the fit measured the board from 1 m away
	# instead of 25 m, reported a 9208 px span, and ran the camera out to the 220 m
	# clamp. `position` is a local property and is correct immediately, and the parent
	# sits at the origin so local == global here.
	var c := cam.position
	var d := c.z - p.z
	if absf(d) < 1e-4:
		return Vector2(-99999.0, -99999.0)
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	var ndc_y := (p.y - c.y) / (d * tv)
	var ndc_x := (p.x - c.x) / (d * tv * (float(w) / float(h)))
	return Vector2(float(w) * 0.5 + ndc_x * float(w) * 0.5,
			float(h) * 0.5 - ndc_y * float(h) * 0.5)


## Widest half-width across the board, so the standoff can be derived from the panels
## instead of from a constant that has to be kept in step with them by hand.
static func max_panel_half_w() -> float:
	var m := 0.0
	for spec in PANELS:
		m = maxf(m, float((spec["size"] as Vector2).x) * 0.5)
	return m


## ## The DAY sky, and why it is uniform
##
## A uniform overcast sky is the standard first light for judging a material because it
## removes the two variables you cannot control: a hard key gives you a specular
## highlight whose shape depends on the light, and a clear sky gives you a gradient
## across the panel that reads as "the panel is lit unevenly" rather than as the
## panel's own value. `ART_DIRECTION.md` calls the hero surface out for being read under
## a raking lamp; the same reasoning applies to reading a scan at all.
##
## So: one DirectionalLight3D, no shadows (a shadow across a flat panel is not
## information), and a sky whose radiance is nearly the same in every direction.
static func day_env(night: bool) -> WorldEnvironment:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.72, 0.75, 0.79)
	sky_mat.sky_horizon_color = Color(0.78, 0.80, 0.83)
	# No ground bounce and no sun disc. Overcast means the whole dome is the light.
	sky_mat.ground_bottom_color = Color(0.30, 0.30, 0.31)
	sky_mat.ground_horizon_color = Color(0.62, 0.63, 0.65)
	sky_mat.sun_angle_max = 30.0
	sky_mat.sun_curve = 0.0
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	# No tonemap surprises: this board is read by eye and by number, and a filmic
	# curve moves both. Linear keeps a pixel value meaningful.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	# Exposure 3.4, and this is an INSTRUMENT decision, not a look decision.
	#
	# The palette's surface albedos live in a deliberately narrow dark band
	# (`standards.md` 4.1), so at exposure 1.0 the six panels measured means of
	# 18.7-41.8 out of 255 - physically defensible and useless as a judgement, because
	# two materials whose true means differ by 5/255 are indistinguishable once both
	# are sitting in the bottom eighth of the range. The game runs a filmic curve and a
	# graded exposure for exactly this reason; the board runs LINEAR so a pixel value
	# stays meaningful, which means it has to lift the range instead.
	#
	# Measured at 1.0: weatherboard 41.8, corrugated 29.2, paling 23.0, concrete 28.9,
	# bitumen 30.0, grass 18.7. The camera did not move to get better numbers; the
	# exposure moved, and both values are in the report.
	env.tonemap_exposure = 3.4
	# Nothing to grade. `adjustment_contrast` above 1.0 pivots at 0.5 in Godot and
	# silently crushes the bottom of the range to pure black - measured on this repo as
	# unlit tarmac at rgb(0,0,0), which reads as "unlit" rather than as "dark". A
	# material board is exactly where that mistake hides, because a black panel looks
	# like a dark material.
	env.adjustment_enabled = false
	if night:
		# Night CONTENT, not night grading. Palette sodium from `MatLib`, at the
		# intensity the game's own lamps run, and no exposure change at all.
		sky_mat.sky_top_color = Color(0.006, 0.008, 0.016)
		sky_mat.sky_horizon_color = Color(0.014, 0.016, 0.026)
		sky_mat.ground_bottom_color = Color(0.004, 0.004, 0.005)
		sky_mat.ground_horizon_color = Color(0.010, 0.011, 0.014)
		env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	we.name = "PBREnv"
	return we


static func key_light(night: bool) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = "Key"
	if night:
		# Sodium, from `MatLib.SODIUM`, because that is the illuminant the frame will
		# actually have. Energy is the game's own streetlight scale roughly, NOT tuned
		# here: the night pass owns exposure and anything I pick would be a number
		# measured on a software rasteriser.
		l.light_color = MatLib.SODIUM
		l.light_energy = 1.6
		l.rotation_degrees = Vector3(-38.0, 214.0, 0.0)
	else:
		# Overcast: a soft, near-white, high sun. Not 6500 K blue and not warm -
		# an overcast dome is the colour of the cloud, and a blue key on a material
		# board makes every grey surface read as a different material.
		l.light_color = Color(1.0, 0.99, 0.97)
		# 2.2, not the 0.85 this started at. The palette's surface albedos sit in a
		# deliberately narrow dark band (standards.md 4.1), so under a 0.78 sky at 0.85
		# the panels measured 0.05 luma against the sky's 0.78 - a 15:1 ratio, which is
		# not "a dark surface", it is an unreadable board. This lifts the key only; the
		# sky is untouched, so the frame's overall level is still the sky's decision.
		l.light_energy = 2.2
		l.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
	l.shadow_enabled = false
	l.light_specular = 1.0
	return l


## A flat panel in the XY plane at `x`, carrying one material key. Four vertices, two
## triangles, `nrm` along -Z so it faces the camera.
static func panel_mesh(w: float, h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := Vector3(0.0, 0.0, -1.0)
	var quad := [
		Vector3(-w * 0.5, -h * 0.5, 0.0), Vector3(w * 0.5, -h * 0.5, 0.0),
		Vector3(w * 0.5, h * 0.5, 0.0), Vector3(-w * 0.5, h * 0.5, 0.0),
	]
	# ## Winding, and the version that rendered nothing
	#
	# Stored normal (0,0,-1) points at the camera; the triangle winding has to point the
	# OTHER way. Godot draws a face only when its right-hand-rule winding normal points
	# away from the viewer, so a quad whose winding agrees with its own normal is
	# back-face culled - correct geometry, submitted every frame, drawn from nowhere.
	# `World/world_builder.gd` says this at length and this repo has now paid for it
	# three times.
	#
	# Emitting (0,1,2),(0,2,3) with this normal gives a winding normal of +Z, i.e. at
	# the camera, so all six panels were culled and every "measurement" was of the sky
	# behind them: six panels, six means of 77.9-79.9, six spreads of 2-8, and a
	# sky-coloured RGB at the centre of every one. It read as "six materials that
	# agree", which is the most confident wrong answer a material board can produce.
	#
	# Reversed to (0,2,1),(0,3,2). The `in_frame` and unprojected-rect assertions could
	# not have caught this - the panels WERE in frame, at the right pixels, and there
	# was simply nothing there. Only comparing the sampled values against what the sky
	# measures did.
	for tri in [[0, 2, 1], [0, 3, 2]]:
		for i in tri:
			st.set_normal(n)
			st.set_uv(Vector2(quad[i].x, quad[i].y) * 0.1 + Vector2(0.5, 0.5))
			st.add_vertex(quad[i])
	return st.commit()


var _out := OUT_DEFAULT
var _tag := "shot"
var _night := false
var _measure_only := false
var _ramp := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				_out = String(args[i + 1]); i += 2
			"--tag":
				_tag = String(args[i + 1]); i += 2
			"--night":
				_night = true; i += 1
			"--measure":
				_measure_only = true; i += 1
			"--ramp":
				# The BEFORE half of the pair. Same camera, same scene, same sky, and
				# the PBR field stripped from every spec, so the only difference between
				# the two frames is the material. That is the whole comparison.
				_ramp = true; i += 1
			_:
				i += 1
	DirAccess.make_dir_recursive_absolute(_out)
	if _measure_only:
		_measure_all()
		return
	_build_and_shoot()


# ------------------------------------------------------------------ the scene
##
## ONE camera for the whole board, not one per panel.
##
## The first version moved the camera to each panel in turn and measured it. It was
## fragile - four of its six frames came back byte-identical even with the camera
## transform verified correct - and it was *wrong* independently of that: six poses
## means six exposures, so two materials can differ because one is lighter and one
## because it was framed brighter. Comparing six materials through six exposures
## cannot answer "are these six materials different?".
##
## One frame, one exposure, one camera. Each panel's screen rectangle comes from
## unprojecting its own four corners, so the six numbers are all read out of the same
## photograph and a difference between two of them is a difference between the
## materials.
func _build_and_shoot() -> void:
	var root_node := Node3D.new()
	root_node.name = "Board"
	get_root().add_child(root_node)
	root_node.add_child(day_env(_night))
	root_node.add_child(key_light(_night))

	var cam := Camera3D.new()
	cam.name = "ShotCam"
	cam.near = 0.05
	cam.far = 200.0
	root_node.add_child(cam)

	# The viewport size is measured, not taken from `--resolution`. This matters: the
	# first version used the constant for the unprojections and the frame for the pixel
	# reads, and the two disagreed - the panels sit at y~330-385 in a 720 px frame while
	# the script sampled y 411-484, which is the GROUND. Every number it reported was a
	# measurement of the sky-lit ground plane behind the board, and every panel's mean
	# came out within 2/255 of every other panel's, which is what the sky reads and is
	# exactly what six identical wrong measurements look like.
	# THE ROOT VIEWPORT IS 100x100 BY DEFAULT IN A `--script` SceneTree RUN, and
	# `--resolution` does not change it. Measured: "viewport 100x100 (asked for
	# 1280x720)". So `Camera3D.unproject_position()` was returning coordinates in a
	# 100 px frame while every pixel read came out of a 1280x720 image, and the two were
	# being compared directly. Every sampled rectangle was wrong - the panels sit at
	# y~330-385 in the frame and the script sampled y 411-484, which is the ground
	# behind them - and the symptom was six panel means within 2/255 of each other,
	# because six wrong measurements of the same piece of ground agree with each other.
	#
	# Setting it explicitly is the fix. It is asserted immediately below rather than
	# trusted, because every other number in this file is derived from it.
	get_root().size = RES
	var vsize := get_root().size
	print("[PBR] viewport set to %dx%d" % [vsize.x, vsize.y])
	if vsize != RES:
		push_error("pbr_shot: the root viewport is %dx%d, not %dx%d; every unprojection "
				% [vsize.x, vsize.y, RES.x, RES.y]
				+ "in this run is in the wrong pixel space")

	var n := PANELS.size()
	var panels: Array = []
	var first_x := -INF
	var last_x := INF
	for i in n:
		var spec: Dictionary = PANELS[i]
		var size: Vector2 = spec["size"]
		var x := (float(i) - (float(n) - 1.0) * 0.5) * PANEL_PITCH
		var centre := Vector3(x, size.y * 0.5 + 1.4, PANEL_Z)
		var mi := MeshInstance3D.new()
		mi.name = "Panel_%s" % spec["set"]
		mi.mesh = panel_mesh(size.x, size.y)
		# `material_override` rather than a surface material: the kit's batching rule is
		# "take materials from the library, never construct one inline".
		mi.material_override = _material_for(String(spec["key"]))
		mi.position = centre
		root_node.add_child(mi)
		var hx := size.x * 0.5
		panels.append({
			"spec": spec, "centre": centre, "size": size,
			"corners": [
				centre + Vector3(-hx, -size.y * 0.5, 0.0),
				centre + Vector3(hx, -size.y * 0.5, 0.0),
				centre + Vector3(hx, size.y * 0.5, 0.0),
				centre + Vector3(-hx, size.y * 0.5, 0.0),
			]})
		first_x = minf(first_x, x - hx)
		last_x = maxf(last_x, x + hx)

	# ASKED: frame the whole board from `board_standoff` metres, dead on and level.
	# Constants, not computed from anything that can drift, so two runs differ only by
	# what changed in artkit/.
	var board_mid := Vector3(0.0, 2.6, PANEL_Z)
	# Standoff is derived from the board width and the horizontal FOV, with a margin, so
	# that changing the panel count or the pitch cannot quietly push the last panel out
	# of frame. It did: at 1280 px and 52 degrees the sixth panel projected to x=1479
	# and its numbers were about nothing. The script now reports `in_frame` per panel
	# and errors when it is false, but not framing itself is better.
	# The standoff is FITTED, not derived from a formula.
	#
	# Two attempts at a closed form both put the sixth panel outside the frame, and both
	# were wrong in ways that looked right: `Camera3D.fov` is vertical (so the
	# horizontal half-angle is `atan(tan(v/2) * aspect)`, not `fov * aspect`), and even
	# with that fixed the near panels and the far panels need different margins because
	# the projection is perspective. Measured failures: sixth panel's right edge at
	# x=1489, then at x=1318, in a 1280 px frame.
	#
	# So it is measured instead. `unproject_position()` needs no draw, so this loop is
	# free, and it cannot be wrong about the aspect ratio or about perspective.
	#
	# Two frame bugs were caught by this instrument rather than by eye, and both times
	# the per-panel numbers were about the background: the "numbers would be about
	# something else" error below is the reason they were not reported as results.
	var fov := 56.0
	var margin := 24.0                      ## px of board left at each edge
	var half_w := float(RES.x) * 0.5 - margin
	var half_h := float(RES.y) * 0.5 - margin
	# Closed form, and the assertion below is the thing that makes it safe.
	#
	# `Camera3D.fov` is VERTICAL. The horizontal half-angle is `atan(tan(v/2) * aspect)`,
	# so the half-width visible at distance d is `tan(v/2) * aspect * d`, and the
	# standoff that fits a board of half-width `hw` is `hw / (tan(v/2) * aspect)`.
	# That gave 15.83 m at 56 deg, which puts the outermost panel corner at the frame
	# edge and all six panels inside it.
	#
	# Three wrong versions came first and are recorded because each looked reasonable:
	#   - `tan(deg_to_rad(fov) * aspect * 0.5)` - not the horizontal half-angle of
	#     anything; put the sixth panel at x=1489 in a 1280 px frame;
	#   - `standoff *= worst / limit` - perspective is not proportional; 62 million
	#     metres, past the far plane, every corner on the same pixel;
	#   - driving the overflow down to `min(half_w, half_h)` - asks a 23 m wide, 2.6 m
	#     tall board to fill the frame vertically; needed 400 m and produced a
	#     postage stamp.
	#
	# The lesson is the one this whole file keeps rediscovering: a formula is fine, but
	# the assertion that the thing is actually in the frame is what turns a formula
	# from a guess into a contract. `in_frame` is reported per panel below and errors
	# when false, so a future change to the panel count, the pitch or the FOV cannot
	# quietly turn six measurements into six measurements of the background.
	var half_board := PANEL_PITCH * (float(n) - 1.0) * 0.5 + max_panel_half_w()
	# ONE measured correction, not a closed form and not a search loop.
	#
	# The closed form above predicted 15.11 m of half-width visible at this distance and
	# the frame behaved as though it were 20.4 m: the sixth panel's right edge landed at
	# x=1504 in a 1280 px frame. Rather than keep guessing at the projection (Godot's
	# `keep_aspect`, the window manager's aspect, and `unproject_position` all have
	# opinions), MEASURE it - stand off at a comfortable distance, see how many pixels
	# the board actually spans, and scale the distance by that ratio.
	#
	# One step, not a loop, on purpose. Two earlier loops are recorded in the comment
	# above because each was wrong in an instructive way: `standoff *= worst / limit`
	# ran away to 62 million metres (perspective is not proportional, and the camera
	# went past its own far plane), and driving `worst` down to `min(half_w, half_h)`
	# asked a 23 m wide, 2.6 m tall board to fill the frame vertically and needed 400 m.
	#
	# Perspective makes px-per-metre very nearly inversely proportional to distance, so
	# one scaling step lands within a few percent - and `in_frame` below is what proves
	# it, rather than the arithmetic being trusted.
	var standoff := 24.0
	var d0 := standoff
	var span_px := Vector2.ZERO
	for pass_i in 3:
		cam.fov = fov
		cam.position = board_mid + Vector3(0.0, 0.0, standoff)
		cam.look_at(board_mid, Vector3.UP)
		var px := 0.0
		var py := 0.0
		for p in panels:
			for c in p["corners"]:
				var u := project(cam, c, vsize.x, vsize.y)
				px = maxf(px, absf(u.x - float(vsize.x) * 0.5))
				py = maxf(py, absf(u.y - float(vsize.y) * 0.5))
		span_px = Vector2(px, py)
		var scale := maxf(px / half_w, py / half_h)
		if absf(scale - 1.0) < 0.01:
			break
		standoff = clampf(standoff * scale, 3.0, 220.0)
	print("[PBR] BOARD fit: %.3f m standoff (from %.1f), board spans %.0f x %.0f px "
			% [standoff, d0, span_px.x, span_px.y]
			+ "against a %.0f x %.0f px limit" % [half_w, half_h])
	var asked_pos := board_mid + Vector3(0.0, 0.0, standoff)
	cam.fov = fov
	cam.position = asked_pos
	cam.look_at(board_mid, Vector3.UP)
	cam.current = true
	print("[PBR] BOARD standoff %.3f m for a %.2f m half-board (fov %.0f, %dx%d)"
			% [standoff, half_board, fov, RES.x, RES.y])

	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	RenderingServer.force_draw()

	# DISCIPLINE 1: asked vs got, printed, with the numbers that decide whether the
	# frame is the one that was asked for.
	var got := cam.global_position
	var got_fwd := -cam.global_transform.basis.z
	var asked_fwd := (board_mid - asked_pos).normalized()
	var drift := got.distance_to(asked_pos)
	var aim_err := rad_to_deg(got_fwd.angle_to(asked_fwd))
	print("[PBR] BOARD asked pos=%s look=%s fov=%.1f standoff=%.2f span=[%.2f..%.2f]"
			% [_r3(asked_pos), _r3(board_mid), fov, standoff, first_x, last_x])
	print("[PBR] BOARD got   pos=%s fwd=%s fov=%.1f | pos drift %.4f m, aim error %.4f deg"
			% [_r3(got), _r3(got_fwd), cam.fov, drift, aim_err])
	print("[PBR] BOARD viewport camera == ShotCam: %s"
			% str(get_root().get_camera_3d() == cam))
	print("[PBR] BOARD asked-vs-got verdict: %s"
			% ("OK" if drift < 0.01 and aim_err < 0.05 else "CAMERA IS NOT WHAT WAS ASKED FOR"))

	var img := get_root().get_texture().get_image()
	if img == null:
		push_error("pbr_shot: no viewport image")
		quit(1)
		return

	# DISCIPLINE 2: delete first. A render that no-ops exits 0 and leaves the previous
	# run's file, which then gets measured and reported as this run's evidence.
	var board_path := "%s/%s-board.png" % [_out, _tag]
	if FileAccess.file_exists(ProjectSettings.globalize_path(board_path)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(board_path))
	img.save_png(ProjectSettings.globalize_path(board_path))
	if not FileAccess.file_exists(ProjectSettings.globalize_path(board_path)):
		push_error("pbr_shot: %s was not written - the render did not happen" % board_path)
		quit(1)
		return
	# DISCIPLINE 3: md5 on disk.
	var board_md5 := _md5_file(ProjectSettings.globalize_path(board_path))
	print("[PBR] BOARD wrote %s md5=%s %d B"
			% [board_path, board_md5.substr(0, 12),
			   FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(board_path)).size()])

	var results: Array = []
	for p in panels:
		results.append(_measure_panel(img, cam, p, board_path))

	_write_report(results, board_path, board_md5,
			{"asked_pos": _r3(asked_pos), "got_pos": _r3(got),
			 "asked_fwd": _r3(asked_fwd), "got_fwd": _r3(got_fwd),
			 "pos_drift_m": snappedf(drift, 0.0001),
			 "aim_error_deg": snappedf(aim_err, 0.0001),
			 "asked_fov": fov, "got_fov": cam.fov, "standoff_m": standoff})
	quit(0)


# ------------------------------------------------------------------- measuring
## Per-panel numbers, read from the ONE frame, inside that panel's own unprojected
## screen rectangle.
##
## The rectangle is asked for and got, and both are reported: the asked rectangle is
## the panel's four corners unprojected by the camera we set, and the got rectangle is
## the bounding box of the pixels actually sampled. When they disagree the panel is out
## of frame or clipped and the numbers below are about something else - which is the
## failure mode that makes a per-pose average meaningless, recorded in
## `World/facade_capture.gd`: one invisible street cancelling one blown street against
## an aggregate floor.
##
## A 2 px inset, because the outermost ring of a panel is its silhouette against the
## sky and antialiasing puts the two in the same pixels. Measuring the edge would put a
## sky-coloured pixel into every panel's mean and make six materials agree for a reason
## that has nothing to do with any of them.
func _measure_panel(img: Image, cam: Camera3D, panel: Dictionary, board: String) -> Dictionary:
	var spec: Dictionary = panel["spec"]
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	var ulo := Vector2(1e9, 1e9)
	var uhi := Vector2(-1e9, -1e9)
	for c in panel["corners"]:
		var u := project(cam, c, img.get_width(), img.get_height())
		lo = Vector2(minf(lo.x, u.x), minf(lo.y, u.y))
		hi = Vector2(maxf(hi.x, u.x), maxf(hi.y, u.y))
		# The engine's own answer, kept so the disagreement is on the record.
		var e := cam.unproject_position(c)
		ulo = Vector2(minf(ulo.x, e.x), minf(ulo.y, e.y))
		uhi = Vector2(maxf(uhi.x, e.x), maxf(uhi.y, e.y))
	var w := img.get_width()
	var h := img.get_height()
	var x0 := clampi(int(lo.x) + 2, 0, w - 1)
	var y0 := clampi(int(lo.y) + 2, 0, h - 1)
	var x1 := clampi(int(hi.x) - 2, 0, w - 1)
	var y1 := clampi(int(hi.y) - 2, 0, h - 1)
	var inside := x1 > x0 and y1 > y0
	if not inside:
		push_error("pbr_shot: %s projects outside the frame (%.0f,%.0f)-(%.0f,%.0f) in a "
				% [spec["set"], lo.x, lo.y, hi.x, hi.y]
				+ "%dx%d frame; its numbers would be about something else" % [w, h])

	var lums: Array[float] = []
	var centre_rgb := Color(0, 0, 0)
	if inside:
		var step := maxi(mini((x1 - x0) / 24, (y1 - y0) / 24), 1)
		var y := y0
		while y <= y1:
			var x := x0
			while x <= x1:
				lums.append(img.get_pixel(x, y).get_luminance())
				x += step
			y += step
		centre_rgb = img.get_pixel(int((x0 + x1) * 0.5), int((y0 + y1) * 0.5))
	lums.sort()
	var n := lums.size()
	var r := {"set": spec["set"], "label": spec["label"], "key": spec["key"],
		"board": board,
		"asked_rect": [int(lo.x), int(lo.y), int(hi.x), int(hi.y)],
		"engine_unproject_rect": [int(ulo.x), int(ulo.y), int(uhi.x), int(uhi.y)],
		"got_rect": [x0, y0, x1, y1], "in_frame": inside, "samples": n,
		"centre_rgb": Color(snappedf(centre_rgb.r, 0.0001),
				snappedf(centre_rgb.g, 0.0001),
				snappedf(centre_rgb.b, 0.0001))}
	if n == 0:
		r["mean"] = 0.0; r["p5"] = 0.0; r["p95"] = 0.0; r["spread"] = 0.0
		r["clip_hi"] = 0.0; r["clip_lo"] = 0.0
		return r
	var total := 0.0
	var hi_n := 0
	var lo_n := 0
	for v in lums:
		total += v
		if v >= CLIP_HIGH / 255.0:
			hi_n += 1
		if v <= CLIP_LOW / 255.0:
			lo_n += 1
	var p5 := lums[int(float(n) * 0.05)] * 255.0
	var p95 := lums[int(float(n) * 0.95)] * 255.0
	r["mean"] = snappedf(total / float(n) * 255.0, 0.01)
	r["p5"] = snappedf(p5, 0.01)
	r["p95"] = snappedf(p95, 0.01)
	r["spread"] = snappedf(p95 - p5, 0.01)
	r["clip_hi"] = snappedf(float(hi_n) / float(n), 0.000001)
	r["clip_lo"] = snappedf(float(lo_n) / float(n), 0.000001)

	print("[PBR] %-16s rect=%s engine_unproject=%s got=%s n=%d | mean=%.1f p5=%.1f p95=%.1f "
			% [spec["set"], str(r["asked_rect"]), str(r["engine_unproject_rect"]),
			   str(r["got_rect"]), n, r["mean"], r["p5"], r["p95"]])
	print("[PBR] %-16s spread=%.1f clip_hi=%.4f clip_lo=%.4f centre_rgb=%s"
			% [spec["set"], r["spread"], r["clip_hi"], r["clip_lo"],
			   str(r["centre_rgb"])])
	return r


## Re-read every PNG off disk and re-report. Separate from the render so a measurement
## can be repeated without re-rendering, which is how you tell a measurement problem
## from a render problem.
func _measure_all() -> void:
	var pts: Array = []
	for spec in PANELS:
		var path := "%s/%s-%s.png" % [_out, _tag, spec["set"]]
		if not FileAccess.file_exists(path):
			print("[PBR-MEASURE] MISSING %s" % path)
			continue
		var img := Image.new()
		if img.load(ProjectSettings.globalize_path(path)) != OK:
			print("[PBR-MEASURE] UNREADABLE %s" % path)
			continue
		print("[PBR-MEASURE] %-16s %s  md5=%s" % [spec["set"], path,
				_md5_file(ProjectSettings.globalize_path(path)).substr(0, 12)])
		pts.append({"set": spec["set"]})
	if pts.is_empty():
		push_error("pbr_shot: nothing to measure in %s for tag '%s'" % [_out, _tag])
		return
	print("PBR-MEASURE-OK: %d images" % pts.size())


func _write_report(results: Array, board: String, board_md5: String,
		camera: Dictionary) -> void:
	var f := FileAccess.open("%s/%s-report.json" % [_out, _tag], FileAccess.WRITE)
	if f == null:
		push_error("pbr_shot: cannot write the report into %s" % _out)
		return
	# Two frames being identical is still the failure mode worth asserting, even with
	# one board: a second run tagged differently would otherwise reuse the file.
	var means := {}
	var dupes: Array[String] = []
	for r in results:
		var k := "%.2f" % float(r.get("mean", 0.0))
		if means.has(k):
			dupes.append("%s == %s (identical mean)" % [r["set"], means[k]])
		means[k] = String(r["set"])
	f.store_string(JSON.stringify({
		"tag": _tag, "night": _night, "resolution": [RES.x, RES.y],
		"board_png": board, "board_md5": board_md5,
		"camera_asked_vs_got": camera,
		"clip_thresholds": {"high": CLIP_HIGH, "low": CLIP_LOW},
		"poses": results, "identical_means": dupes,
	}, "  "))
	f.close()
	print("[PBR] %d panels off ONE frame, report %s/%s-report.json"
			% [results.size(), _out, _tag])


## The material for a panel: the library's, or - under `--ramp` - the SAME spec rebuilt
## with its PBR field removed, which is exactly what the game had before t181.
##
## The rebuild goes through a private spec entry rather than by mutating `_SPECS`, so
## the library is untouched and the "before" frame cannot leak into the "after" one
## through the material cache. Both frames then come from one camera and one scene and
## differ only in whether the scan was attached.
func _material_for(key: String) -> StandardMaterial3D:
	if not _ramp:
		return ArtKitMaterials.get_(key)
	var stripped: Dictionary = ArtKitMaterials._SPECS[key].duplicate(true)
	stripped.erase("pbr")
	return ArtKitMaterials.build_spec(stripped)


## md5 of a file on disk. `FileAccess.get_md5()` and not hashing bytes read into a
## `PackedByteArray` - the latter has no `md5_text()` in Godot 4.3, and the fallback
## everybody reaches for (`var s := raw.get_string_from_utf8(); s.md5_text()`) hashes
## *text*, which mangles any byte above 0x7F and would happily report a collision
## between two different PNGs.
static func _md5_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_md5(path)


## A Vector3 rounded for printing. `Vector3.round()` takes no precision argument in
## Godot 4.3, so per-component `snappedf`.
static func _r3(v: Vector3) -> Vector3:
	return Vector3(snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001))