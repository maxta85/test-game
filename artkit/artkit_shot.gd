extends SceneTree
## artkit_shot.gd - a contact sheet of the kit's props, lit the way the game lights
## them at night, from one fixed camera.
##
##     godot --path . --rendering-driver opengl3 --audio-driver Dummy \
##         --resolution 1600x900 --script res://artkit/artkit_shot.gd -- \
##         --out /tmp/shot.png [--props palm_coco,palm_alexandrine] [--closeup]
##
## ## Why this exists
##
## ART_DIRECTION.md §"How to check your work" says render it and *look at it*, and
## the honest failure this guards against is judging a foliage change from a
## street preset where the trees are 90 m away and three pixels tall. A prop sheet
## is the only way to see what the geometry actually does.
##
## It is also the comparison instrument: the camera, the lights and the exposure
## are all constants below, so two commits render two PNGs that differ only by
## what changed in artkit/. That is the whole point of `--shot`'s fixed presets
## applied to the kit itself.
##
## Writes only to the `--out` path. Touches nothing else in the repo.

const OUT_DEFAULT := "/tmp/artkit_shot.png"

## The framing is a constant on purpose. If it moved, two shots would differ for
## a reason that has nothing to do with the change being judged.
const CAM_POS := Vector3(0.0, 7.0, 27.0)
const CAM_LOOK := Vector3(0.0, 7.5, 0.0)
const CAM_FOV := 42.0

## Spacing along X between props on the sheet, in metres.
const PITCH := 9.0

## Close-up framing: eye level with a single crown, which is where "flat quad"
## and "arched frond" stop being arguable. Aimed at the middle of a coco palm's
## crown (trunk 9.5-13 m, crown above that) rather than at the base, because the
## defect being judged lives in the crown and a shot that crops it proves nothing.
const CLOSE_POS := Vector3(8.2, 12.0, 9.0)
const CLOSE_LOOK := Vector3(0.0, 11.6, 0.0)
const CLOSE_FOV := 40.0

const DEFAULT_PROPS := ["palm_coco", "palm_alexandrine", "palm_areca", "palm_fan"]

var _out := OUT_DEFAULT
var _props: Array[String] = []
var _closeup := false
var _variant := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				_out = String(args[i + 1])
				i += 2
			"--props":
				for p in String(args[i + 1]).split(",", false):
					_props.append(p.strip_edges())
				i += 2
			"--variant":
				_variant = int(String(args[i + 1]))
				i += 2
			"--closeup":
				_closeup = true
				i += 1
			_:
				i += 1
	if _props.is_empty():
		_props.assign(DEFAULT_PROPS)

	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 900)
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	vp.own_world_3d = true
	# Without this the viewport renders once and then never again, and the
	# readback is a black frame that still saves as a valid PNG.
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	_build_environment(vp)
	_build_lights(vp)
	_build_props(vp)

	var cam := Camera3D.new()
	cam.fov = CLOSE_FOV if _closeup else CAM_FOV
	# look_at() refuses to run before the node is in the tree, and this script
	# builds its scene from _initialize(), which is early. The _from_position
	# form has no such precondition.
	cam.look_at_from_position(CLOSE_POS if _closeup else CAM_POS,
			CLOSE_LOOK if _closeup else CAM_LOOK, Vector3.UP)
	vp.add_child(cam)
	cam.make_current()

	_shoot.call_deferred(vp)


func _shoot(vp: SubViewport) -> void:
	# A few real frames so shadows, transmission and the sky have all been
	# rasterised before the readback. Four is enough and keeps the shot fast on
	# a software rasteriser.
	for _n in 4:
		await process_frame
	var img := vp.get_texture().get_image()
	img.save_png(_out)
	# A black PNG is a valid PNG, and "the render is dark" and "the render never
	# happened" look identical in a diff. So report the mean luminance and how
	# much of the frame is non-black, and fail loudly if it is all black.
	var lit := 0
	var total := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			total += 1
			if _luma(img.get_pixel(x, y)) > 0.004:
				lit += 1
	print("[artkit_shot] wrote %s (%dx%d) props=%s closeup=%s"
			% [_out, img.get_width(), img.get_height(), str(_props), _closeup])
	print("[artkit_shot] frame luminance: %.4f  non-black samples: %d/%d"
			% [_mean_luma(img), lit, total])
	if lit == 0:
		push_error("artkit_shot: frame is entirely black - the shot is not evidence of anything")
	quit(0 if lit > 0 else 1)


## Rec.709 luma, spelled out rather than calling Color.get_luma(): this build does
## not have it, and a helper that fails to parse would take the whole shot with
## it.
func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _mean_luma(img: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			sum += _luma(img.get_pixel(x, y))
			n += 1
	return sum / maxf(float(n), 1.0)


## Night, built from the palette rather than typed in as RGB: the sheet is only
## useful as evidence if it is lit by the same vocabulary the game uses.
func _build_environment(vp: SubViewport) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = ArtKitPalette.color("night_base")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ArtKitPalette.color("city_glow")
	# Deliberately low. ART_DIRECTION.md: "ambient energy low enough that an
	# unlit kerb is nearly black" - a contact sheet with generous ambient would
	# hide exactly the silhouette problem this shot exists to show.
	env.ambient_light_energy = 0.16
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)


## One sodium key, one cool mercury fill, exactly the warm/cool pair
## ART_DIRECTION.md calls the thing that sells a street. Key is off to one side
## so the fronds are *rimmed* rather than flatly lit - a canopy lit from its own
## centroid is how geometry hides itself.
func _build_lights(vp: SubViewport) -> void:
	var key := DirectionalLight3D.new()
	key.light_color = ArtKitPalette.color("sodium")
	key.light_energy = 2.6
	key.shadow_enabled = true
	key.rotation_degrees = Vector3(-34.0, -128.0, 0.0)
	vp.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_color = ArtKitPalette.color("mercury")
	fill.light_energy = 0.55
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-12.0, 62.0, 0.0)
	vp.add_child(fill)


## One instance of each named prop, variant as requested, evenly spaced. Ground
## plane at y=0 so the props are standing on something and not floating, which is
## half of what "toy prop" means.
func _build_props(vp: SubViewport) -> void:
	var ground := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	gm.size = Vector2(PITCH * (_props.size() + 2), PITCH * (_props.size() + 2))
	ground.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.035, 0.042, 0.058)
	gmat.roughness = 0.35
	gmat.metallic = 0.6
	ground.material_override = gmat
	vp.add_child(ground)

	for n in _props.size():
		var name := _props[n]
		var holder := Node3D.new()
		holder.position = Vector3((float(n) - float(_props.size() - 1) * 0.5) * PITCH, 0.0, 0.0)
		vp.add_child(holder)
		for part in ArtKitProps.variant(name, _variant):
			var mi := MeshInstance3D.new()
			mi.mesh = part.mesh
			mi.material_override = ArtKitMaterials.get_(part.mat)
			holder.add_child(mi)
		print("[artkit_shot] %s v%d: %d parts" % [name, _variant, ArtKitProps.variant(name, _variant).size()])