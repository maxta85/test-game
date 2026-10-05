extends SceneTree
## What the artkit surfaces looked like BEFORE any licensed capture was applied.
##
##     godot --path . --rendering-driver vulkan --audio-driver Dummy \
##       --resolution 1600x900 --script res://artkit/tex_probe_baseline.gd -- \
##       --out /tmp/tex_before.png
##
## ## Why a separate file rather than a flag
##
## `tex_probe.gd` reads `ArtKitMaterials.TEX_UV` to scale each panel. Rendering
## the *before* state means running against a `materials.gd` that has no
## `TEXTURED` or `TEX_UV` at all - the state at commit `160eb9b` - and a probe
## that references a member the baseline does not have will not compile against
## it. The obvious fixes are all worse than a second script:
##
##   * swap `materials.gd` on disk around each render - that is mutating a shared
##     file to produce evidence, and two runs a minute apart in the same
##     worktree is a corruption waiting to happen;
##   * add a `--baseline` flag to `tex_probe.gd` and make every `TEX_UV` lookup
##     defensive - that pushes baseline-specific shape into the live probe and
##     makes the "after" measurement depend on a branch nobody exercises.
##
## So the baseline is a small, honest, self-contained script: the same scene
## graph, the same lighting, the same camera, the same measurement - with the
## panel scale taken from the *spec's* `uv` the way the pre-t194 code did. Two
## scripts with one shared measurement convention is a smaller thing to keep
## correct than one script that has to describe both worlds.
##
## The numbers from this and from `tex_probe.gd` are directly comparable: same
## camera, same light, same threshold, same `_measure`.

const PANELS := [
	{"key": "surface_asphalt_wet_a", "label": "asphalt_wet_a"},
	{"key": "concrete_a", "label": "concrete_a"},
	{"key": "bark", "label": "bark"},
	{"key": "brick", "label": "brick"},
	{"key": "surface_render_wall_a", "label": "render_wall_a"},
	{"key": "grass", "label": "grass"},
]

const LIGHT_ENERGY := 3.4
const AMBIENT := 0.85
const PANEL_M := 1.1
const PANEL_TILES := 2.0

static var _cursor: Array = []
static var _total_w := 0.0
static var _panels: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/tex_before.png"
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out": out = String(args[i + 1]); i += 2
			_: i += 1

	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 900)
	vp.transparent_bg = false
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	_build_environment(vp)
	_build_lights(vp)
	_build_panels(vp)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = _total_w * 1.04
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.look_at_from_position(Vector3(0.0, 3.0, 12.0), Vector3(0.0, 3.0, 0.0),
			Vector3.UP)
	vp.add_child(cam)
	cam.make_current()

	await process_frame
	if vp.get_camera_3d() != cam:
		push_error("[tex_base] FATAL viewport is not using this camera")
		quit(2)
		return

	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw

	var img := vp.get_texture().get_image()
	if img == null or img.get_used_rect().size == Vector2i.ZERO:
		push_error("[tex_base] FATAL readback produced nothing")
		quit(3)
		return
	if img.save_png(out) != OK:
		push_error("[tex_base] FATAL save failed")
		quit(4)
		return
	print("[tex_base] wrote %s" % out)
	for n in PANELS.size():
		var rect := _rect_for(vp.get_camera_3d() as Camera3D, n, img)
		if rect.size.x < 8 or rect.size.y < 8:
			print("[tex_base] %-22s PANEL OFFSCREEN - not measured"
					% String(PANELS[n]["key"]))
			continue
		_measure(String(PANELS[n]["key"]), img.get_region(rect))
	quit(0)


func _rect_for(cam: Camera3D, n: int, img: Image) -> Rect2i:
	var node := _panels[n] as MeshInstance3D
	if node == null:
		return Rect2i()
	var centre := node.global_position
	var half := PANEL_M * 0.5 * 0.86
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	for off in [Vector3(-half, half, 0.0), Vector3(half, half, 0.0),
			Vector3(-half, -half, 0.0), Vector3(half, -half, 0.0)]:
		var p := cam.unproject_position(centre + off)
		xs.append(p.x)
		ys.append(p.y)
	var x0 := clampi(int(minf(xs[0], minf(xs[1], minf(xs[2], xs[3])))), 0, img.get_width())
	var x1 := clampi(int(maxf(xs[0], maxf(xs[1], maxf(xs[2], xs[3])))), 0, img.get_width())
	var y0 := clampi(int(minf(ys[0], minf(ys[1], minf(ys[2], ys[3])))), 0, img.get_height())
	var y1 := clampi(int(maxf(ys[0], maxf(ys[1], maxf(ys[2], ys[3])))), 0, img.get_height())
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


func _build_panels(vp: SubViewport) -> void:
	_cursor = []
	_panels = []
	var acc := 0.0
	for n in PANELS.size():
		_cursor.append(acc)
		acc += PANEL_M
	_total_w = acc
	for n in PANELS.size():
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(PANEL_M, PANEL_M)
		mi.mesh = qm
		mi.position = Vector3(_cursor[n] + PANEL_M * 0.5 - _total_w * 0.5, 3.0, 0.0)
		var key := String(PANELS[n]["key"])
		var mat := ArtKitMaterials.get_(key)
		if mat == null:
			continue
		# The baseline's scale convention: `1 / spec.uv`, which is what the
		# pre-t194 material used directly. Shown here so the panel is not a
		# magnifying glass on its own texture.
		var spec_uv := float(ArtKitMaterials._SPECS[key].get("uv", 0.1))
		var shown := mat.duplicate() as StandardMaterial3D
		var tiles := float(PANEL_M) / maxf(spec_uv, 0.001)
		shown.uv1_scale = Vector3(tiles, tiles, tiles)
		shown.uv1_triplanar = false
		mi.material_override = shown
		vp.add_child(mi)
		_panels.append(mi)


func _build_environment(vp: SubViewport) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = AMBIENT
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


## Same convention and threshold as `tex_probe.gd`, so the two runs compare.
func _measure(key: String, img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		print("[tex_base] %-22s EMPTY PANEL" % key)
		return
	var lumas := PackedFloat32Array()
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			lumas.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
	lumas.sort()
	var n := lumas.size()
	var mean := 0.0
	for v in lumas:
		mean += v
	mean /= float(n)
	var p05: float = lumas[int(n * 0.05)]
	var p95: float = lumas[int(n * 0.95)]
	var spread := p95 - p05
	print("[tex_base] %-22s mean=%.4f p05=%.4f p95=%.4f spread=%.4f %s"
			% [key, mean, p05, p95, spread,
			"STRUCTURED" if spread > 0.01 else "FLAT"])