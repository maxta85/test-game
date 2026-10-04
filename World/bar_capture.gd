extends SceneTree

## Before/after rig for t128: the tall thin saturated bars standing in the street.
##
## The defect is identified in `artkit/buildings.gd::_build_qld_shop`: the shop
## sign was a 0.52 m x 3.5-6.0 m emissive PANEL standing 1.04 m in front of the
## facade with nothing under it, in a colour rolled at random per building.
##
## Three things this rig is careful about, all learned the hard way:
##
##   - Poses come from `World/look_dev_capture.gd`'s OWN `_pose_spec`, so there is
##     no second copy of the pose maths to drift out of step with the reference
##     frames.
##   - `--tint` paints the sign surfaces flat magenta. A geometry-derived claim
##     cannot disagree with itself; a magenta control can. It is what proves the
##     bar is the sign and not something else at the same pixels.
##   - The metric is `neon_bars`, and it splits saturated pixels by HUE rather
##     than counting saturation alone. Every lamp in this world is a saturated
##     warm orange, so "count the saturated pixels" measures the streetlights.
##     `b > g` separates the neon accents from every warm source in the frame,
##     and `r > b` picks the warm bars out separately instead of hiding them.
##
## Usage (engine flags BEFORE the bare `--`):
##   godot --path . --rendering-driver vulkan --audio-driver Dummy \
##     --resolution 1280x720 --script res://World/bar_capture.gd -- \
##     --out /tmp/bars --tag after
##   ... --tint                      paint the sign surfaces flat magenta
##   ... --poses <file.json>         replay another run's cameras exactly
##   ... --measure                   re-measure existing PNGs, no render

const PROBE := "res://World/look_dev_capture.gd"
const POSES := ["walk3", "walk1", "street"]
const TINT := Color(1.0, 0.0, 1.0)
## Surfaces that make up the shop sign. `lamp_lens` is in this list because the
## broken roll used it as a sign colour - it is the brightest bar in the frame
## and that is why.
const SIGN_SURFACES := ["neon_cyan", "neon_magenta", "neon_red", "lamp_lens",
	"sign_face", "lamp_lens_cool", "sign_face_lit"]

const BAND_Y0 := 100
const BAND_Y1 := 400
const SAT := 0.22
const MIN_RUN := 40
const COOL_B := 0.05
const WARM_R := 0.16
## A saturated group counts as a BAR only if it is at least as tall as
## `THIN_RATIO` allows it to be wide. See `_bars`.
const THIN_RATIO := 0.6
## ...and the defect additionally CLIPPED: the measured bars were rgb(248,158,122)
## and rgb(255,121,194), i.e. at least one channel pinned at 255. Nothing else
## tall and thin in this city clips - the nearest miss is a palm trunk lit by
## sodium, which is a bar by proportion (9:1) and is NOT one by exposure. Both
## terms are needed; proportion alone counts trees, clipping alone counts the
## blown sodium cores of the lamp heads.
const CLIP := 0.985


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := "/tmp/bars"
	var tag := "frame"
	var settle := 10
	var tint := false
	var measure_only := false
	var poses_from := ""
	var only := ""
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out":
				out = String(args[i + 1]); i += 2
			"--tag":
				tag = String(args[i + 1]); i += 2
			"--settle":
				settle = int(args[i + 1]); i += 2
			"--only":
				only = String(args[i + 1]); i += 2
			"--poses":
				poses_from = String(args[i + 1]); i += 2
			"--tint":
				tint = true; i += 1
			"--measure":
				measure_only = true; i += 1
			_:
				i += 1
	DirAccess.make_dir_recursive_absolute(out)

	var rig = load(PROBE).new()
	var poses: Array = POSES.duplicate()
	if only != "":
		poses = [only]

	if measure_only:
		for pose in poses:
			var path := "%s/%s-%s.png" % [out, tag, pose]
			var img := Image.new()
			if img.load(path) != OK:
				push_error("[Bar] no frame at %s - render it first" % path)
				quit(1)
				return
			print("[Bar] %s  %s" % [pose, JSON.stringify(_measure(img))])
		quit(0)
		return

	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var street := OSMLayout.start_line()
	var at: Vector3 = street["pos"]
	var d: Vector2 = street["dir"]
	var fwd := Vector3(d.x, 0.0, d.y).normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x)

	print("[Bar] booting world (settle=%d frames)" % settle)
	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	for f in settle:
		await process_frame
	var flow: Node = rig.call("_menu_flow", main)
	if flow != null:
		flow.call("close")
	rig.call("_hide_ui", main)

	var cam: Camera3D = rig.call("_camera", main)
	if cam == null:
		push_error("[Bar] no Camera3D in the scene")
		quit(1)
		return
	for n in rig.call("_ancestry", cam):
		if "tracking" in n:
			n.set("tracking", false)
	cam.current = true
	Engine.time_scale = 0.0

	if tint:
		var n := _tint_signs(main)
		print("[Bar] tinted %d sign surface(s) flat magenta" % n)

	# Cameras: either replay another run's, or derive and record our own.
	var specs: Array = []
	if poses_from != "":
		var txt := FileAccess.get_file_as_string(poses_from)
		var parsed = JSON.parse_string(txt)
		if typeof(parsed) != TYPE_DICTIONARY:
			push_error("[Bar] cannot read poses from %s" % poses_from)
			quit(1)
			return
		for e in parsed["specs"]:
			if poses.has(String(e["name"])):
				specs.append(e)
		print("[Bar] replaying %d camera(s) from %s" % [specs.size(), poses_from])
	else:
		for pose in poses:
			var sp: Dictionary = rig.call("_pose_spec", String(pose), at, fwd, side, g)
			sp["name"] = String(pose)
			specs.append(sp)

	for sp in specs:
		cam.global_position = sp["at"]
		cam.look_at(sp["look"], Vector3.UP)
		cam.fov = float(sp["fov"])
		for f in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = get_root().get_texture().get_image()
		var path := "%s/%s-%s.png" % [out, tag, String(sp["name"])]
		# Delete first: a render that silently no-ops then leaves yesterday's
		# frame in place, and the measurement loop reads it as a new data point.
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		img.save_png(path)
		if not FileAccess.file_exists(path):
			push_error("[Bar] render produced no frame at %s" % path)
			quit(1)
			return
		# Print where the camera GOT to, not where it was asked to go.
		print("[Bar] %s  asked=%s got=%s current=%s fov=%.0f" % [
			String(sp["name"]), str(sp["at"].round()), str(cam.global_position.round()),
			str(cam.current), float(sp["fov"])])
		print("           %s" % JSON.stringify(_measure(img)))

	Engine.time_scale = 1.0
	var dump := {"specs": specs}
	FileAccess.open("%s/%s_poses.json" % [out, tag], FileAccess.WRITE).store_string(
		JSON.stringify(dump, "  "))
	quit(0)


## Flat magenta on every merged surface that makes up the shop sign. Returns how
## many were tinted, so a run that silently matched nothing cannot pass for a
## control.
func _tint_signs(main: Node) -> int:
	var flat := StandardMaterial3D.new()
	flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flat.albedo_color = TINT
	flat.emission_enabled = true
	flat.emission = TINT
	flat.emission_energy_multiplier = 1.0
	var n := 0
	for c in _all(main):
		var nm := String(c.name)
		for s in SIGN_SURFACES:
			if nm == s:
				c.set("material_override", flat)
				n += 1
				break
	return n


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out


func _measure(img: Image) -> Dictionary:
	var cool := _bars(img, true)
	var warm := _bars(img, false)
	var cool_c := _bars(img, true, true)
	var warm_c := _bars(img, false, true)
	var clipped := 0
	var dark := 0
	var total := 0
	var lsum := 0.0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			var mx: float = maxf(c.r, maxf(c.g, c.b))
			if mx >= CLIP:
				clipped += 1
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			lsum += l
			if l <= 0.02:
				dark += 1
			total += 1
	var d := {
		# The headline number: tall, thin, saturated AND clipping. That is the
		# defect's signature and it is the only figure here that separates the
		# defect from this city's legitimate saturated sources.
		"bars": cool_c["thin"] + warm_c["thin"],
		"bars_cool": cool_c["thin"],
		"bars_warm": warm_c["thin"],
		"bars_tallest": maxi(cool_c["tallest"], warm_c["tallest"]),		# Everything below is diagnostic context, not the verdict.
		"neon_groups": cool["count"],
		"neon_px": cool["px"],
		"neon_tallest": cool["tallest"],
		"warm_groups": warm["count"],
		"warm_tallest": warm["tallest"],
		"mean": snappedf(lsum / float(maxi(total, 1)), 0.0001),
		"clipped": snappedf(float(clipped) / float(maxi(total, 1)), 0.0001),
		"dark": snappedf(float(dark) / float(maxi(total, 1)), 0.0001),
	}
	return d


## Vertical runs of saturated pixels in the band, grouped into bars.
##
## `cool` selects the neon accents (`b` leads `g`); otherwise the warm sources
## (sodium lamps, the lit sign face) are picked out, so neither family hides
## inside the other's number.
##
## The count that matters is `thin`, NOT `count`. Splitting by hue is not enough
## on its own: this city's two legitimate saturated sources are the sodium lamp
## halo (a soft disc roughly as wide as it is tall) and the cool-white mercury
## shopfront (wide and short). Both are saturated, both are tall enough to clear
## `MIN_RUN`, and grouping by hue alone counts them as bars - which is how a
## metric built to count the defect came to sit still while the defect was
## removed. A BAR is defined by its proportion: a saturated group whose width is
## no more than `THIN_RATIO` of its height. The defect was 7:1 to 11.3:1 tall,
## the lamp halo is about 1:1 and the fascia 4.4:1 wide, so exactly one of the
## three can be a bar.
func _bars(img: Image, cool: bool, clip := false) -> Dictionary:
	var w := img.get_width()
	var cols: Array = []
	for x in range(w):
		var run := 0
		var best := 0
		for y in range(BAND_Y0, BAND_Y1):
			if _is(img.get_pixel(x, y), cool, clip):
				run += 1
				best = maxi(best, run)
			else:
				run = 0
		cols.append(best)
	var bars: Array = []
	var thin := 0
	var x := 0
	var px := 0
	var tallest := 0
	var tallest_thin := 0
	while x < w:
		if int(cols[x]) >= MIN_RUN:
			var x0 := x
			var peak := 0
			while x < w and int(cols[x]) >= MIN_RUN:
				peak = maxi(peak, int(cols[x]))
				px += int(cols[x])
				x += 1
			var width := x - x0
			bars.append({"x0": x0, "x1": x - 1, "tall": peak, "w": width})
			tallest = maxi(tallest, peak)
			if float(width) <= THIN_RATIO * float(peak):
				thin += 1
				tallest_thin = maxi(tallest_thin, peak)
		else:
			x += 1
	return {"count": bars.size(), "thin": thin, "px": px, "tallest": tallest_thin,
			"tallest_any": tallest, "bars": bars}


func _is(c: Color, cool: bool, clip: bool = false) -> bool:
	var mx: float = maxf(c.r, maxf(c.g, c.b))
	var mn: float = minf(c.r, minf(c.g, c.b))
	if mx <= SAT or (mx - mn) < SAT:
		return false
	if clip and mx < CLIP:
		return false
	if cool:
		return c.b - c.g > COOL_B
	return c.r - c.b > WARM_R
