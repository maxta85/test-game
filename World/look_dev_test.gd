extends SceneTree
## The look-dev assertions. Run it:
##
##     ./test.sh                                   # no - these do not live in Tests/
##     godot --headless --path . --fixed-fps 60 \
##           --script res://World/look_dev_test.gd -- [--lookdev <dir>]
##
## Why they are here and not in `Tests/`: the map agent owns `World/**` and
## nothing else, and `Tests/run_tests.gd` discovers `res://Tests/test_*.gd`. So
## this is a suite that lives in the path it tests and runs by explicit path. It
## uses the same `Tests/harness.gd` assertions, so a failure reads and counts
## exactly like one from `./test.sh` - it is not a second opinion with a second
## dialect. `./test.sh` does not run it and that is stated in the report rather
## than papered over.
##
## Two halves, and they are different kinds of thing:
##
##   1. **Code properties**, run headless, always. The kerb section, the
##      transverse budget that keeps the drain out from under the kerb, the
##      material families, and the winding convention every road-edge surface is
##      culled by. All of these are things the before build got wrong and all of
##      them were invisible to 1354 green assertions.
##   2. **Image thresholds**, from `LookDev`, run only when `--lookdev <dir>`
##      points at a directory `World/look_dev_capture.gd` wrote. Those are the
##      ones a human has to choose to run, because they need a GPU; when they are
##      skipped this says so loudly instead of counting as a pass.

const LOOKDEV_FLAG := "--lookdev"


func _initialize() -> void:
	var t := TestHarness.new()
	await t.attach(self)
	t.begin_suite("lookdev")

	_geometry(t)
	_winding(t)
	_materials(t)
	_measure_code(t)

	var frames := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if String(args[i]) == LOOKDEV_FLAG and i + 1 < args.size():
			frames = String(args[i + 1])
	if frames != "":
		_image_gate(t, frames)
	else:
		print("")
		print("  ** image thresholds SKIPPED - no --lookdev <dir> given **")
		print("     render them with:")
		print("       godot --path . --rendering-driver vulkan --resolution 1280x720 \\")
		print("             --script res://World/look_dev_capture.gd -- --out <dir> --tag <name>")
		print("     and re-run this with -- --lookdev <dir>. A skip is not a pass:")
		print("     the geometry half below is necessary and not sufficient.")

	t.end_suite()
	quit(t.summary())


# ----------------------------------------------------------------------- geometry
## The kerb section, and the budget that keeps five surfaces out of each other's
## way.
##
## Every number here is a real dimension with a reason, and each one is a
## regression guard with a named failure it prevents. `KERB_TOP_W` is the big
## one: 1.0 m is not a kerb, it is a plinth, and it is what 1278 streetlights
## were pointing at.
func _geometry(t: TestHarness) -> void:
	t.between(LookDev.KERB_TOP_W, 0.15, 0.45,
		"the kerb top is a kerb, not a plinth (%.2f m)" % LookDev.KERB_TOP_W)
	t.between(LookDev.CHANNEL_W, 0.30, 0.60,
		"the channel is a gutter, not a second footpath (%.2f m)" % LookDev.CHANNEL_W)
	t.between(LookDev.CHANNEL_DEPTH, 0.015, 0.060,
		"the channel dish is deep enough to read and shallow enough not to trap a wheel (%.3f m)"
			% LookDev.CHANNEL_DEPTH)
	t.gt(LookDev.KERB_CHAMFER, 0.0,
		"the kerb edge is chamfered, so it has an edge that catches a lamp (%.3f m)"
			% LookDev.KERB_CHAMFER)
	t.near(LookDev.KERB_HEIGHT, WorldBuilder.KERB_HEIGHT, 0.0001,
		"LookDev and WorldBuilder agree on the kerb height")
	t.near(LookDev.FOOTPATH_W, WorldBuilder.FOOTPATH_WIDTH, 0.0001,
		"LookDev and WorldBuilder agree on the footpath width")

	# The transverse budget. Sections must abut, not overlap: the old build had a
	# 1.6 m drain trench at carriageway + 0.15, which is to say underneath its own
	# kerb, and the visible symptom was a row of unexplained dark slots along
	# every street.
	var kerb_start := LookDev.CHANNEL_W
	var kerb_end := kerb_start + LookDev.KERB_TOP_W
	var walk_end := kerb_end + LookDev.FOOTPATH_W
	t.near(kerb_start, LookDev.CHANNEL_W, 0.0001,
		"the kerb starts where the channel ends (%.2f m)" % kerb_start)
	t.near(LookDev.back_of_footpath_to_drain_centre(), walk_end + 0.95, 0.0001,
		"the drain is measured from the back of the footpath (%.2f m from the edge)"
			% LookDev.back_of_footpath_to_drain_centre())
	t.gt(LookDev.back_of_footpath_to_drain_centre() - LookDev.DRAIN_W * 0.5, walk_end,
		"and the drain does not start under the footpath (%.2f m vs %.2f m)" % [
			LookDev.back_of_footpath_to_drain_centre() - LookDev.DRAIN_W * 0.5, walk_end])

	# Paint sits on the tarmac, not 12 mm proud of it and not below it.
	t.gt(LookDev.PAINT_Y, LookDev.TARMAC_Y,
		"paint is above the carriageway (%.3f > %.3f)" % [LookDev.PAINT_Y, LookDev.TARMAC_Y])
	t.gt(LookDev.PAINT_Y, LookDev.JUNCTION_Y,
		"and above the junction patch it crosses (%.3f > %.3f)" % [LookDev.PAINT_Y,
			LookDev.JUNCTION_Y])
	t.between(LookDev.PAINT_Y - LookDev.JUNCTION_Y, 0.001, 0.010,
		"by a film's worth, not a slab's (%.3f m)" % (LookDev.PAINT_Y - LookDev.JUNCTION_Y))
	t.between(LookDev.LINE_W, 0.10, 0.15,
		"a lane line is 100-150 mm wide (%.3f m)" % LookDev.LINE_W)


## Winding. Godot culls by winding, not by the normal attribute, so a surface can
## carry a perfect upward normal and still be invisible from a car.
##
## The reference is `_road_quad`: right-hand-rule normal **into** the surface, i.e.
## -Y for a horizontal road surface. It is the reference because the carriageway
## is the one surface in this project that is demonstrably drawn in every
## shipping screenshot; `_quad` and `_road_quad` both say so in as many words,
## and `_junction_fan` - written later, in the same file - disagrees.
func _winding(t: TestHarness) -> void:
	var paint := LookDev.winding_normal(LookDev.paint_quad())
	t.ok(paint.y < -0.99,
		"lane paint is wound to face up like the carriageway is (RH y=%.3f)" % paint.y)
	var channel := LookDev.winding_normal(LookDev.channel_mesh())
	t.ok(channel.y < -0.99,
		"and so is the channel floor (RH y=%.3f)" % channel.y)
	var kerb_top := LookDev.winding_normal(LookDev.kerb_top_mesh())
	t.ok(kerb_top.y < -0.30,
		"and the kerb top, whose back face tips it sideways but not far (RH y=%.3f)"
			% kerb_top.y)
	var kerb_face := LookDev.winding_normal(LookDev.kerb_face_mesh())
	t.ok(kerb_face.y > -0.99 and kerb_face.x > 0.9,
		"the kerb face is a vertical surface wound into the kerb, not out of it (RH=%s)"
			% _v3(kerb_face))

	# The junction patch, built the way `_intersections` builds it.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	WorldBuilder._junction_fan(st, Vector2.ZERO, 6.0, false)
	var fan := LookDev.winding_normal(st.commit())
	t.ok(fan.y < -0.99,
		"the junction patch is wound like the carriageway it is a part of (RH y=%.3f)" % fan.y)

	# And the give-way triangles: a road-edge marker, and the one surface in this
	# set whose winding was written by copying rather than by deriving.
	var tri := LookDev.winding_normal(WorldBuilder._tri_marker_mesh())
	t.ok(tri.y < -0.99,
		"give-way triangles face up (RH y=%.3f)" % tri.y)


# --------------------------------------------------------------------- materials
## MATERIAL VARIATION, one of the seven rubric points in
## `docs/decisions/0001-art-director.md`, and the point the document itself
## explains with "a library of N identical materials looks like a library and
## behaves like a bug".
##
## Built from the real builder rather than from a list of functions, so it fails
## if a material is defined and never instanced - which is what "defined and
## unused" looks like from here.
func _materials(t: TestHarness) -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var w := WorldBuilder.new()
	w.graph = g
	# Only the road edge. The full `build` also generates 2198 OSM buildings and
	# 1618 palms and takes half a minute for geometry this assertion never reads.
	w._kerbs_and_footpaths()
	w._lane_markings()
	w._junction_control()

	var fams := {}
	var tris := 0
	for batch in ["kerbs", "channels", "footpaths", "markings", "giveway"]:
		if not w._batches.has(batch):
			t.ok(false, "batch '%s' was never filled" % batch)
			continue
		for key in (w._batches[batch]["meshes"] as Dictionary):
			fams[String(key)] = true
			tris += int((w._batches[batch]["meshes"][key]["list"] as Array).size())
	t.gt(fams.size(), LookDev.MIN_SURFACE_FAMILIES - 1,
		"the road edge is drawn from at least %d distinct material families (%d: %s)" % [
			LookDev.MIN_SURFACE_FAMILIES, fams.size(), ", ".join(PackedStringArray(fams.keys()))])

	for need in ["kerb_top", "kerb_face", "channel", "footpath", "paint_white", "paint_yellow"]:
		t.ok(fams.has(need), "road edge has its own material for %s" % need)

	t.gt(tris, 1000, "and the road edge actually put geometry down (%d instances)" % tris)

	# The kerb is not painted in the same material as the footpath any more. This
	# is the single assertion that would have failed on the before build, where
	# `kerbs`, `footpaths` and `drainage` were all one key called "concrete".
	t.ok(not _shares_material(w, "kerbs", "footpaths"),
		"the kerb and the footpath are not the same material")
	t.ok(not _shares_material(w, "kerbs", "channels"),
		"and the kerb and the channel are not the same material either")

	# Roughness is what separates these at night: a sodium lamp at a grazing angle
	# gives a wet surface a long specular smear and a dry one almost nothing.
	var wet := LookDev.channel_mat()
	var dry := LookDev.footpath_mat()
	t.ok(wet.roughness < dry.roughness - 0.3,
		"the wet channel is markedly glossier than the dry footpath (%.2f vs %.2f)"
			% [wet.roughness, dry.roughness])
	t.ok(LookDev.kerb_face_mat().albedo_color.get_luminance()
			< LookDev.kerb_top_mat().albedo_color.get_luminance(),
		"the kerb face is darker than its own top, which is why the edge reads")

	# Asphalt. The measured failure was not "too orange", it was "not asphalt": a
	# base roughness of 0.14 modulated by a *raw* four-octave noise texture put
	# mirror-sharp and chalk pixels next to each other, and under a sodium lamp at
	# a grazing angle that is 55% of the lit road band reading orange-cast with
	# its 95th percentile at 249/255. What makes a wet road read as a wet road is
	# a highlight that smears, so the roughness has to stay inside a band.
	var tar := MatLib.wet_asphalt()
	t.between(tar.roughness, 0.20, 0.40,
		"the tarmac is wet, not polished (roughness %.2f)" % tar.roughness)
	t.ok(tar.roughness_texture is NoiseTexture2D
			and (tar.roughness_texture as NoiseTexture2D).color_ramp != null,
		"and its roughness noise is banded by a ramp, not fed raw across 0-1")
	t.between(tar.metallic_specular, 0.30, 0.70,
		"a lamp is a smear on it, not a blown highlight (specular %.2f)"
			% tar.metallic_specular)
	t.between(tar.normal_scale, 0.05, 0.20,
		"the aggregate is tooth, not glitter (normal scale %.2f)" % tar.normal_scale)
	# And it must still be darker than the kerb it runs up to, or the kerb has
	# nothing to read against.
	t.ok(tar.albedo_color.get_luminance() < LookDev.kerb_top_mat().albedo_color.get_luminance(),
		"tarmac is darker than the kerb top, which is what makes the kerb read")

	# Paint does not light itself. An emissive marking goes through the additive
	# glow and becomes a small lamp of its own, which is what the before frame's
	# markings did.
	var white := MatLib.paint_white()
	t.ok(not white.emission_enabled, "road paint is not self-lit")
	t.between(white.roughness, 0.35, 0.85,
		"and it is matte thermoplastic, not a mirror (roughness %.2f)" % white.roughness)
	t.ok(MatLib.paint_yellow().albedo_color.get_luminance()
			< white.albedo_color.get_luminance(),
		"yellow is not brighter than white, which is how a centre line ends up louder"
			+ " than the edge lines")


func _shares_material(w: WorldBuilder, a: String, b: String) -> bool:
	if not w._batches.has(a) or not w._batches.has(b):
		return true
	var ka: Dictionary = w._batches[a]["meshes"]
	var kb: Dictionary = w._batches[b]["meshes"]
	for k in ka:
		if kb.has(k):
			return true
	return false


# ------------------------------------------------------------- the instrument
## The measurement code, measured against frames whose answers are known.
##
## Without this, `LookMeasure.measure_image` is an instrument nobody has calibrated,
## and every threshold in the file is a threshold on an uncalibrated instrument.
## Three synthetic frames with hand-computable answers, built in-process.
func _measure_code(t: TestHarness) -> void:
	# 4x2: two mid greys, two whites.
	var img := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	var greys := [64, 64, 255, 255]
	for y in 2:
		for x in 4:
			var v: int = greys[x]
			img.set_pixel(x, y, Color(v / 255.0, v / 255.0, v / 255.0, 1.0))
	var m := LookMeasure.measure_image(img)
	t.ok(bool(m["ok"]), "the measurer accepts a real image")
	# luma of 64 is 64.0, of 255 is 255.0 (grey has equal channels, so the
	# Rec.709 weights sum to 1 and the mean is the mean).
	t.near(float(m["mean"]), (64.0 * 4 + 255.0 * 4) / 8.0, 0.6,
		"and returns the right mean luma (%.2f)" % float(m["mean"]))
	t.near(float(m["clipped"]), 0.5, 0.001,
		"and the right clipped share (%.3f)" % float(m["clipped"]))
	t.near(float(m["dark"]), 0.0, 0.001,
		"and no dark share for a frame that has none (%.3f)" % float(m["dark"]))
	t.near(float(m["orange"]), 0.0, 0.001,
		"and no orange cast in a grey frame (%.3f)" % float(m["orange"]))

	# 2x1: one fully saturated orange, one fully saturated blue.
	var hue := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	hue.set_pixel(0, 0, Color(1.0, 0.5, 0.0))
	hue.set_pixel(1, 0, Color(0.0, 0.5, 1.0))
	var h := LookMeasure.measure_image(hue)
	t.near(float(h["orange"]), 0.5, 0.001,
		"orange is measured as a colour cast, and blue is not (%.3f)" % float(h["orange"]))

	# A band is a region of the same image, not a different image. And "detail" has
	# to be zero on a flat region, not merely small: an instrument that reports
	# contrast in a uniform white rectangle is reporting its own noise, and every
	# `detail` threshold downstream would be a threshold on that noise.
	var band := LookMeasure.measure_band(img, 0.5, 0.0, 1.0, 1.0)
	t.ok(bool(band["ok"]), "a band measures")
	t.near(float(band["mean"]), 255.0, 0.6,
		"and it measures the right half, which is all white (%.2f)" % float(band["mean"]))
	t.near(float(band["detail"]), 0.0, 0.0001,
		"and calls a flat region flat (detail %.4f)" % float(band["detail"]))

	# The same instrument on the same kind of image with a step in it. A checker
	# step of 96 levels in a 6x6 patch, read over the whole patch.
	var stepped := Image.create(6, 6, false, Image.FORMAT_RGBA8)
	for y in 6:
		for x in 6:
			var v := 24.0 if (x + y) % 2 == 0 else 200.0
			stepped.set_pixel(x, y, Color(v / 255.0, v / 255.0, v / 255.0, 1.0))
	var sb := LookMeasure.measure_band(stepped, 0.0, 0.0, 1.0, 1.0)
	t.gt(float(sb["detail"]), 20.0,
		"and sees a checkerboard, which is what a kerb edge or a line of paint is (detail %.2f)"
			% float(sb["detail"]))
	t.near(float(sb["mean"]), 112.0, 3.0,
		"and a checkerboard has the mean of its two values (%.2f)" % float(sb["mean"]))


# ------------------------------------------------------------------- image gate
## The four rubric points that can only be settled by looking at a rendered frame.
func _image_gate(t: TestHarness, dir: String) -> void:
	var path := _find_report(dir)
	if path == "":
		t.ok(false, "look-dev frames: no *-lookdev.json in %s - run World/look_dev_capture.gd"
			% dir)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY or not data.has("poses"):
		t.ok(false, "look-dev frames: %s is not a capture report" % path)
		return
	var poses: Array = data["poses"]
	t.gt(poses.size(), 0, "look-dev frames: the capture measured %d poses" % poses.size())
	var bad := LookMeasure.failures(LookMeasure.checks(poses))
	for c in bad:
		t.ok(false, "[%s] %s: %s is %.4f, limit %.4f" % [c["rubric"], c["name"],
			c["got_label"], float(c["got"]), float(c["limit"])])
	t.eq(bad.size(), 0, "every look-dev rubric point passes on %d rendered poses"
		% poses.size())
	for p in poses:
		print("    %-10s %s" % [String(p["name"]),
			", ".join(_summary(String(p["name"]), p["report"]))])


## The capture writes `<tag>-lookdev.json`, and `--tag` is its own argument, so
## accepting the bare name means every caller has to repeat the tag twice. Take
## either.
func _find_report(dir: String) -> String:
	if FileAccess.file_exists("%s/lookdev.json" % dir):
		return "%s/lookdev.json" % dir
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	for f in d.get_files():
		if f.ends_with("-lookdev.json"):
			return "%s/%s" % [dir, f]
	return ""


## One line per pose with the numbers that decided it, so a green run still says
## what it measured. A threshold test that passes silently is a threshold that
## was never checked.
func _summary(pose: String, r: Dictionary) -> Array:
	var out := []
	for k in ["mean", "clipped", "dark", "orange", "detail"]:
		if r.has(k):
			out.append("%s=%.3f" % [k, float(r[k])])
	if pose == "street" and r.has("road"):
		var road: Dictionary = r["road"]
		for k in ["mean", "clipped", "orange", "p95", "detail"]:
			if road.has(k):
				out.append("road_%s=%.3f" % [k, float(road[k])])
	return out


## Godot 4.3's `Vector3.round()` takes no precision argument, and a failure
## message full of `Vector3(0, -1, 0)` is fine, so this exists only to keep the
## long decimals out.
func _v3(v: Vector3) -> String:
	return "%.2f, %.2f, %.2f" % [v.x, v.y, v.z]