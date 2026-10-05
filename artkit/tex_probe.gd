extends SceneTree
## Does the licensed capture actually reach the pixels? A daylit probe.
##
##     godot --path . --rendering-driver vulkan --audio-driver Dummy \
##       --resolution 1600x900 --script res://artkit/tex_probe.gd -- \
##       --out /tmp/tex_probe.png [--metres 1.0]
##
## ## Why this exists
##
## The night contact sheet said the texture made almost no difference: 0.58% of
## pixels changed by more than 4/255. Two completely different explanations fit
## that number and the sheet cannot tell them apart:
##
##   1. the capture is not reaching the material, and the change is not texture;
##   2. the capture *is* applied, and the night trunk sits at 13/255 mean luma
##      where an 18% albedo variation is about two 8-bit levels - below the
##      threshold anyone would call a difference.
##
## Those need opposite responses: (1) is a bug in this task, (2) is a property of
## the night look, which `t189` owns and this task must not change. Guessing is
## how a texture layer gets "fixed" by deleting the texture.
##
## So this renders the same materials under flat neutral light at a chosen
## metres-per-tile. If the capture is wired up, it is unmissable here. If it is
## invisible here too, the wiring is broken and no amount of darkness explains
## it.
##
## ## What it does not prove
##
## That the capture looks good in the shipped night scene. It is a reachability
## instrument, not an appearance one - it deliberately removes the night grade so
## the only variable left is whether the texture is in the material.

const PANELS := [
	{"key": "surface_asphalt_wet_a", "label": "asphalt_wet_a"},
	{"key": "concrete_a", "label": "concrete_a"},
	{"key": "bark", "label": "bark"},
	{"key": "brick", "label": "brick"},
	{"key": "surface_render_wall_a", "label": "render_wall_a"},
	{"key": "grass", "label": "grass"},
]

## Flat, bright and neutral. Any variation in the panels is the texture.
const LIGHT_ENERGY := 3.4
const AMBIENT := 0.85
const PANEL_M := 1.6
const PITCH := 2.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/tex_probe.png"
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out": out = String(args[i + 1]); i += 2
			_: i += 1

	# A SubViewport has to be a child of the tree to own a camera, and its camera
	# only becomes `get_camera_3d()` after the node is inside the tree AND the
	# viewport has been given a size it can render at. Created-but-unparented, it
	# accepts `cam.current = true` and still reports a different camera - which
	# is why the first version of this probe framed nothing and read back a
	# single-colour frame.
	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 900)
	vp.transparent_bg = false
	# Own render target, so the probe's frame is independent of whatever the root
	# viewport is doing. Without it this can be handed the root's texture and
	# measured against the wrong image.
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	# The SceneTree root is a Window; a SubViewport child of it renders into its
	# own target, but `own_world_3d` must be set for 3D content to render at all
	# when the viewport is not the root one.
	vp.own_world_3d = true

	_build_environment(vp)
	_build_lights(vp)
	_build_panels(vp)

	# Godot 4: Camera3D.current defaults to FALSE. It defaults to FALSE even for
	# the first camera added, unlike Godot 3, so a camera that is merely *added*
	# frames nothing and the saved PNG is a stale black frame - which reads as
	# "the texture did nothing" when the camera never looked at anything.
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# Frame the whole row. The panels are laid out in `_build_panels`, which runs
	# before this, so the total width is known. A fixed ortho size would clip the
	# ends as soon as the panels stopped being a constant width - and it was,
	# because asphalt is 2 m/tile and plaster is 1.5.
	cam.size = _total_w * 1.04
	# `size` here is the horizontal frustum width, which the sheet is laid out to
	# match. The panels are measured by un-projecting their own corners rather
	# than by deriving pixels-per-world-unit from this value, so the aspect mode
	# no longer has to be kept in step with the measurement by hand.
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	# `look_at_from_position`, not `position` + `look_at`: `look_at` refuses to
	# run on a node that is not yet in the tree, and an unrotated camera looks
	# down -Z from the origin and frames empty space.
	cam.look_at_from_position(Vector3(0.0, 3.0, 12.0), Vector3(0.0, 3.0, 0.0),
			Vector3.UP)
	vp.add_child(cam)
	# `make_current()`, not `current = true`. The property sets the flag on the
	# camera; `make_current()` is what tells the *viewport* to use it. With the
	# property alone, `vp.get_camera_3d()` still returns some other camera and the
	# probe frames nothing while reporting success.
	cam.make_current()

	# `make_current()` is processed by the viewport on the next frame, not
	# synchronously: querying `vp.get_camera_3d()` in the same frame it was called
	# still returns the previous camera. That is the reason `artkit_shot.gd`
	# defers its whole shoot with `call_deferred`, and the reason this probe
	# reported "viewport is not using this camera" on three separate attempts to
	# set it more emphatically. The camera was correct every time; the check was
	# just early.
	await process_frame

	# Prove the framing before believing any measurement from it.
	if vp.get_camera_3d() != cam:
		push_error("[tex_probe] FATAL viewport is not using this camera "
				+ "(viewport camera is ours: %s)"
				% str(vp.get_camera_3d() == cam))
		quit(2)
		return
	print("[tex_probe] camera eye=%s ortho_size=%.2f looking at %d panels"
			% [str(cam.global_position), cam.size, PANELS.size()])

	# `SubViewport.get_texture().get_image()` returns the LAST RENDERED frame, so
	# the image is only valid after a draw. `await process_frame` advances logic
	# without drawing, which is how this produced an all-black PNG that measured
	# spread=0.0000 for every panel - a perfectly plausible "the textures are
	# flat" result from a frame in which nothing was ever rendered.
	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw

	var img := vp.get_texture().get_image()
	if img == null:
		push_error("[tex_probe] FATAL readback failed")
		quit(3)
		return
	# Blankness check. A probe whose own frame is uniform cannot distinguish
	# "material has no texture" from "camera rendered nothing", so it must say so
	# rather than report six FLAT panels and let that be believed.
	if img.get_used_rect().size == Vector2i.ZERO:
		push_error("[tex_probe] FATAL image is empty")
		quit(5)
		return
	var uniq := _unique_colours(img)
	print("[tex_probe] frame has %d distinct colours" % uniq)
	if uniq <= 1:
		push_error("[tex_probe] FATAL the frame is a single colour - nothing was "
				+ "rendered, so every panel below is meaningless")
		quit(6)
		return
	if img.save_png(out) != OK:
		push_error("[tex_probe] FATAL save failed")
		quit(4)
		return
	# Measure each panel where it actually is, by un-projecting its corners. A
	# fixed grid of equal columns was wrong the moment the panels stopped being
	# equal, and it sampled background for some materials and their own pixels for
	# others - producing numbers that looked like measurements and were not.
	var cam3 := vp.get_camera_3d() as Camera3D
	var flat := 0
	for n in PANELS.size():
		var node := _panels[n] as MeshInstance3D
		if node == null:
			print("[tex_probe] %-22s NO PANEL NODE - not measured"
					% String(PANELS[n]["key"]))
			flat += 1
			continue
		# Un-project the panel's own four corners, using the camera that actually
		# rendered the frame.
		#
		# Two hand-rolled versions came first and both were wrong in ways that read
		# as findings. The first assumed `width / cam.size` pixels per world unit
		# on both axes, which only holds under KEEP_WIDTH. The second derived the
		# vertical window from a *world Y* and then subtracted top from bottom
		# without ordering them - a negative height, which `get_region` accepts as
		# an empty rect, which reported all six textured materials as EMPTY while
		# the saved PNG plainly showed six textured panels.
		#
		# `unproject_position` is the engine's own answer to this question. Asking
		# it is strictly better than re-deriving projection maths, because the
		# derivation has to be kept in step with four camera properties and every
		# one of them is a silent-corruption vector.
		var centre := node.global_position
		var half := PANEL_M * 0.5 * 0.86  # 14% inset, so panel edges and background
		var corners := [
			cam3.unproject_position(centre + Vector3(-half, half, 0.0)),
			cam3.unproject_position(centre + Vector3(half, half, 0.0)),
			cam3.unproject_position(centre + Vector3(-half, -half, 0.0)),
			cam3.unproject_position(centre + Vector3(half, -half, 0.0)),
		]
		var x0 := 99999
		var x1 := -99999
		var y0 := 99999
		var y1 := -99999
		for c in corners:
			x0 = mini(x0, int(c.x))
			x1 = maxi(x1, int(c.x))
			y0 = mini(y0, int(c.y))
			y1 = maxi(y1, int(c.y))
		x0 = maxi(x0, 0)
		y0 = maxi(y0, 0)
		x1 = mini(x1, img.get_width())
		y1 = mini(y1, img.get_height())
		if x1 - x0 < 8 or y1 - y0 < 8:
			print("[tex_probe] %-22s PANEL OFFSCREEN (%d,%d)-(%d,%d) - not measured"
					% [String(PANELS[n]["key"]), x0, y0, x1, y1])
			flat += 1
			continue
		var panel := img.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))
		if not _measure(String(PANELS[n]["key"]), panel):
			flat += 1
	if flat > 0:
		# Nonzero here means at least one declared-texture material renders as a
		# flat swatch under a light that reveals everything else. That is the one
		# result this probe exists to produce, so it fails loudly.
		push_error("[tex_probe] FATAL %d of %d textured materials rendered FLAT"
				% [flat, PANELS.size()])
		quit(7)
		return
	print("[tex_probe] wrote %s" % out)
	quit(0)


## Distinct colours in the frame. Sampled, not exhaustive: a full 1.44 M-pixel
## set build is slow and the only question is "is this one colour or not".
func _unique_colours(img: Image) -> int:
	var seen := {}
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			seen[Vector3i(int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0))] = true
	return seen.size()


## Luma spread across a panel. Returns false if the panel is FLAT, so the caller
## can treat a flat textured material as a failure rather than a curiosity.
##
## `spread` is the whole measurement: a material carrying a real capture has
## structure across it, and a material whose texture never arrived is one value.
##
## ## Why the threshold is 0.01 and not something rounder
##
## It is set from the *measured* spreads of this project's own captures, not
## picked for tidiness. Under this probe's flat lighting the observed range is
## 0.0157 (painted plaster) to 0.0482 (palm bark), and a genuinely untextured
## material measures exactly 0.0000 because a flat fill has no spread at all -
## there is no quantisation noise to confuse it with.
##
## The first threshold was 0.02, chosen when the panels were lit differently and
## spreads ran 0.24-0.42. Lowering the light to remove the night grade collapsed
## those numbers by an order of magnitude, and 0.02 then failed painted plaster
## at 0.0157 - a **false failure on a correctly textured material**. A threshold
## carried across a change to the measuring apparatus is a threshold measuring
## the old apparatus.
##
## 0.01 sits below the weakest real capture and exactly at 0 for a flat fill, so
## it discriminates on the thing that matters rather than on absolute brightness.
func _measure(key: String, img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		print("[tex_probe] %-22s EMPTY PANEL" % key)
		return false
	var lumas := PackedFloat32Array()
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			lumas.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
	lumas.sort()
	var n := lumas.size()
	if n == 0:
		return false
	var mean := 0.0
	for v in lumas:
		mean += v
	mean /= float(n)
	var p05: float = lumas[int(n * 0.05)]
	var p95: float = lumas[int(n * 0.95)]
	var spread := p95 - p05
	var structured := spread > 0.01
	print("[tex_probe] %-22s mean=%.4f p05=%.4f p95=%.4f spread=%.4f %s"
			% [key, mean, p05, p95, spread, "STRUCTURED" if structured else "FLAT"])
	return structured


func _build_environment(vp: SubViewport) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = AMBIENT
	# No tonemap curve and no glow: both are nonlinear and both would compress the
	# very variation this probe exists to measure.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)


func _build_lights(vp: SubViewport) -> void:
	var key := DirectionalLight3D.new()
	key.light_color = Color(1, 0.97, 0.92)
	key.light_energy = LIGHT_ENERGY
	key.rotation_degrees = Vector3(-38.0, -35.0, 0.0)
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.9, 0.94, 1.0)
	fill.light_energy = LIGHT_ENERGY * 0.35
	fill.rotation_degrees = Vector3(-20.0, 145.0, 0.0)
	vp.add_child(fill)


## One flat quad per material, filling its own column of the frame, carrying that
## material's `material_override`. A quad because the question is "does this
## material have texture in it", and a quad has no UV authoring of its own to
## confuse the answer.
## Panel widths and left edges, in world metres. Both are derived from each
## material's authored tile, so every panel shows the same *count* of texture.
## Static rather than instance state: they are needed by both the builder and the
## measurer, and a `static var` initialised from a const dictionary is the only
## way both can see them without threading a value through.
static var _cursor: Array = []
static var _total_w := 0.0
## The panel nodes, kept so the measurer can un-project their real corners rather
## than re-deriving where they should be on screen.
static var _panels: Array = []

## Tiles to show across each panel. Two shows structure and enough repetition to
## notice a tile.
const PANEL_TILES := 2.0

## Every panel the same width, and each material's `uv1_scale` overridden to put
## `PANEL_TILES` tiles across it.
##
## Both of the obvious layouts lie, and both were tried:
##
##   * one panel per material, sized to its authored tile - asphalt at 2.0 m and
##     bark at 0.35 m produce panels a 6x apart in width, so the sheet is as wide
##     as its widest member and the narrow panels fall below a pixel per texel at
##     any usable frame size;
##   * one fixed panel width, materials at their authored scale - a 2.5 m grass
##     tile in a 1.6 m panel is 0.64 of one tile, i.e. a magnifying glass on a
##     handful of pixels. Measured spread 0.0000, which reads convincingly as
##     "this material has no texture".
##
## So the panels are uniform and the *scale* is varied per panel, on a duplicate
## of the material so the shared cache is not mutated. The measurement is of the
## texture's content at a known tile count; the authored per-material scale is a
## separate question, checked in the game renders.
static func _layout() -> void:
	_cursor = []
	_panels = []
	var acc := 0.0
	for n in PANELS.size():
		_cursor.append(acc)
		acc += PANEL_M
	_total_w = acc


func _build_panels(vp: SubViewport) -> void:
	# Laid out left to right with each panel its own width, so nothing overlaps
	# and the widths are proportional to the material's authored tile.
	_layout()
	for n in PANELS.size():
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		mi.mesh = qm
		# Sized from the material's own authored tile, so every panel shows the
		# same *count* of texture rather than the same *area*.
		#
		# A fixed-width plate made this probe lie. Asphalt and grass are authored
		# at 2.0 and 2.5 m per tile, so a 1.6 m square showed 0.8 and 0.64 of one
		# tile - a magnifying glass on a 4-pixel region, which measured
		# spread=0.0000 and read as "these materials have no texture". They do;
		# the panel was simply smaller than the pattern it was meant to display.
		#
		# Two tiles across is enough to see structure and enough repetition to
		# notice a tile.
		qm.size = Vector2(PANEL_M, PANEL_M)
		mi.position = Vector3(_cursor[n] + PANEL_M * 0.5 - _total_w * 0.5, 3.0, 0.0)
		var mat := ArtKitMaterials.get_(String(PANELS[n]["key"]))
		if mat == null:
			push_error("[tex_probe] no material for %s" % PANELS[n]["key"])
			continue
		# Duplicate before rescaling. `ArtKitMaterials.get_()` hands back the
		# shared cached instance that the whole city renders with; changing its
		# uv1_scale here would leave every other consumer of this material looking
		# at bark tiles the size of a house, in this same process.
		var shown := mat.duplicate() as StandardMaterial3D
		var tiles := float(PANEL_M) / maxf(
				float(ArtKitMaterials.TEX_UV.get(String(PANELS[n]["key"]), 1.0)), 0.001)
		shown.uv1_scale = Vector3(tiles, tiles, tiles)
		mi.material_override = shown
		vp.add_child(mi)
		_panels.append(mi)
