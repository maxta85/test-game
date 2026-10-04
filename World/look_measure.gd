class_name LookMeasure
extends RefCounted
## The instrument. Everything needed to turn a rendered PNG into numbers, and to
## hold those numbers to the thresholds in `docs/decisions/0001-art-director.md`.
##
## It is a separate file from `World/look_dev.gd` - which holds the geometry and
## the materials - for one concrete reason: **the before build has to be measured
## by the same code as the after build.** A before/after pair measured by two
## versions of the measurer is not a comparison, it is two numbers that happen to
## be printed in the same font. Keeping this file dependent on nothing but `Image`
## and its own constants means it can be dropped into a pristine checkout of the
## old `World/**` and still produce comparable output, which is exactly what the
## before capture does.
##
## So: if you are about to change a threshold, change it *here*, and re-measure
## the existing PNGs with
##
##     godot --headless --path . --script res://World/look_dev_capture.gd -- \
##           --out <dir> --tag before --measure
##
## rather than rendering 500 m of street again. The frames are the expensive part.

## The gate from the decision document: "the map agent must make one good 500 m
## stretch first", and "No agent is authorised to expand the world until the beauty
## shot is acceptable".
const COVERAGE_M := 500.0

## Resolution the captures are compared at. Fixed so a before/after pair is a
## like-for-like comparison and not a scaling artefact.
const CAPTURE_RES := Vector2i(1280, 720)

## Luma above which a pixel is "clipped", and below which it is "dark". Both are
## out of 255 and neither is a taste call: 250 is inside the last two 8-bit steps
## where the tonemap has no room left to roll off, and 8 is below where the frame
## has any tonal separation to measure.
const CLIP_LUMA := 250.0
const DARK_LUMA := 8.0

## How far red may lead blue before a pixel counts as orange-cast, out of 255.
const ORANGE_LEAD := 24.0

## And how bright it has to be to count as a *shape*. `ORANGE_LEAD` on its own is
## a measure of the illuminant - under this city's sodium street lighting almost
## every lamp-lit pixel passes it, and no material change can move that number.
## The decision document's failure mode is "Rendered, it reads as orange polygons
## in darkness": a *polygon* is a region with a shape, which means saturated
## orange that is bright enough to see against the dark. So the orange check
## counts pixels that are saturated orange AND lit above this level, and the
## unlit orange around them is not what the document is complaining about.
const ORANGE_BRIGHT_LUMA := 96.0


## ASPHALT. The document's failure mode, verbatim: "Rendered, it reads as orange
## polygons in darkness." Orange in the frame is the sodium lamp doing its job;
## orange as the *material's own colour* is the failure. Measured as the share of
## lit road-band pixels where red leads blue by more than 24/255.
##
## **What this number is, honestly.** It is a bound on the *illuminant*, not on
## the material. `ORANGE_LEAD` counts a pixel as orange-cast when red leads blue
## by 24/255, and `MatLib.SODIUM` - a documented load-bearing look decision, "warm
## sodium with a cool moon fill ... makes a tropical night look tropical" - puts
## red 194/255 ahead of blue. So under this city's own street lighting essentially
## every lamp-lit road pixel counts as orange, and no material change can move
## this number. It is kept at 0.80 as the ceiling that would catch a surface
## tinted orange *on top of* sodium light, and it is **not** evidence that the
## before and after builds differ: they measure 0.52-0.75 before and 0.54-0.75
## after, which is the same. The rubric's headline failure, "orange polygons in
## darkness", is caught by the two checks below this one - a road you cannot see
## is the same defect as a road you see only as colour - and by
## `MAX_FRAME_CLIPPED`, which catches the orange pool blown to white.
##
## It was 0.62, then briefly 0.45. 0.45 was wrong for the reason above: it is a
## threshold no sodium-lit street in this city can meet, so it would have failed
## the build permanently and taught whoever reads the report to ignore it.
const MAX_ROAD_ORANGE := 0.80

## The ceiling that is actually asserted: saturated orange *bright enough to read
## as a shape*. Set from both builds: the before street band measures 0.13, the
## after one 0.16, and the four mid-block poses 0.00 to 0.03 - the metric
## separates a blown orange pool from a sodium-lit road, which `MAX_ROAD_ORANGE`
## above cannot do at all.
const MAX_ROAD_ORANGE_BRIGHT := 0.25

## A markings band only gets asserted when its p95/p50 is at least this, i.e.
## when it actually straddles something bright. A band of plain tarmac measures
## 1.4-1.6; one with a lane line through it measures 3.7-6.1.
const MARKING_BAND_SPREAD := 2.0

## ASPHALT, second half: a road you cannot see is not lit, it is absent. The floor
## is deliberately low, because `Look.ADJUSTMENT_CONTRAST` was swept down to 1.00
## precisely to stop the bottom stop of the range clamping away (see `look.gd`)
## and pushing this up would undo that for a different reason. It is set from the
## *worst* pose measured, not the average: the after build's darkest road band is
## junction at 9.83 mean with 68% of it below the dark threshold, and walk3 on the
## before build is 2.65 with 100% of it black. 6.0 rejects the black one and
## accepts the dark one, which is the intended split.
const MIN_ROAD_LUMA := 6.0

## ASPHALT, third: the share of a road band that may be below the dark threshold.
## `walk3` on the before build measures 1.000 - a road that is not unlit, it is
## absent, at 90 m along the same stretch the other five poses say is fine. The
## after build's worst is 0.68. A quarter of the road being black is the defect;
## two thirds of it is the report's headline.
const MAX_ROAD_DARK := 0.75

## ASPHALT, fourth - and this is the one that decides whether any of the others
## were measured on a street at all: the mean absolute horizontal gradient in the
## road band, i.e. `detail` (see `_detail`). Every other threshold in this file is
## a statement about a road, and a wall, a field or the inside of a hillside all
## satisfy them. A uniformly lit surface has no horizontal structure to measure,
## so `detail` collapses toward zero and everything else reads as a healthy dim
## orange road.
##
## Measured 2026-10-03 on tag vf-before, same camera, six poses: `street` 4.69,
## `junction` 4.93, `kerb` 2.62, `walk1` 2.26 - and `walk2` 0.044 and `walk3`
## 0.79, which are a building wall and bare terrain. Both of those poses reported
## 90 m of covered carriageway and passed the luma, dark, clip and orange checks,
## so the 500 m coverage gate was cleared by frames with no street in them. 1.00
## rejects both of those and keeps all four that are on tarmac; the margin over
## `walk3` is deliberately thin, because a pose that is nearly this bad should
## fail rather than be tolerated.
const MIN_ROAD_DETAIL := 1.00

## LIGHTING. A night frame whose near field clips is a frame with no night in it.
## The before frame loses its whole right-hand third to white, so this is the
## threshold that has to move and it is the one that could redden a release.
const MAX_FRAME_CLIPPED := 0.035

## ATMOSPHERE / LIGHTING, the other side of the same knob: a frame with no floor is
## just as wrong as one with no ceiling. `look.gd` measured the unlit road at
## literally rgb(0,0,0) before the contrast fix.
const MAX_FRAME_DARK := 0.86

## MARKINGS. Paint has to read as the brightest thing on the road without being
## the brightest thing in the frame. Measured as the 95th percentile of the
## markings band against the road-band mean, because a band that clips the centre
## line only for part of its width is exactly the normal case and a mean would
## quietly wash it out. `p95` of a strip through the line is the paint; `p50` of
## the same strip is the tarmac either side of it, which is why both exist.
##
## The before build clears this on two poses and fails it on two: walk3's paint
## band measures p95 = 4 against a road mean of 2.65, which is a ratio of 1.5 and
## a centre line you cannot see. That is the whole argument for checking it per
## pose - the ratio is a ratio either way, but only one of the two ratios means
## anything.
const MIN_PAINT_OVER_ROAD := 1.30
##
## The point of this function is that every one of these numbers can be measured
## from a PNG on disk by anyone, with no engine and no scene, so the thresholds
## above are checkable against a shipped screenshot rather than only against a
## test run. `measure_image` takes an `Image`; `measure_png` takes a path and does
## the loading.
static func measure_png(path: String) -> Dictionary:
	var img := Image.new()
	if img.load(path) != OK:
		return {"ok": false, "error": "cannot load %s" % path}
	return measure_image(img)


static func measure_image(img: Image) -> Dictionary:
	var fmt := img.get_format()
	var px := img.get_width()
	var py := img.get_height()
	var total := px * py
	if total == 0:
		return {"ok": false, "error": "empty image"}
	var stride := 4 if fmt == Image.FORMAT_RGBA8 else (3 if fmt == Image.FORMAT_RGB8 else 0)
	var data := PackedByteArray()
	if stride > 0:
		data = img.get_data()
		if data.size() < total * stride:
			stride = 0
	if stride == 0:
		return _measure_by_pixel(img, px, py, total)
	var sum := 0.0
	var lit := 0
	var clipped := 0
	var dark := 0
	var orange := 0
	var orange_bright := 0
	var hist := PackedInt32Array()
	hist.resize(256)
	for i in total:
		var o := i * stride
		var r := float(data[o])
		var g := float(data[o + 1])
		var b := float(data[o + 2])
		var l := 0.2126 * r + 0.7152 * g + 0.0722 * b
		sum += l
		hist[int(clampf(l, 0.0, 255.0))] += 1
		if l >= CLIP_LUMA:
			clipped += 1
		if l <= DARK_LUMA:
			dark += 1
		if l > DARK_LUMA:
			lit += 1
			if r - b > ORANGE_LEAD:
				orange += 1
				if l >= ORANGE_BRIGHT_LUMA:
					orange_bright += 1
	var litf := maxf(float(lit), 1.0)
	return {
		"ok": true,
		"mean": sum / float(total),
		"clipped": float(clipped) / float(total),
		"dark": float(dark) / float(total),
		"orange": float(orange) / litf,
		"orange_bright": float(orange_bright) / litf,
		"p50": _percentile(hist, total, 0.50),
		"p95": _percentile(hist, total, 0.95),
		"p99": _percentile(hist, total, 0.99),
	}


## Same statistics over a rectangle of the frame, in normalised coordinates.
##
## Bands exist because "the frame" is not a thing you can hold to a standard: a
## street frame is 60% sky and the sky is *supposed* to be black. A road-band mean
## answers "can you see the road you are driving on", which is the question the
## rubric point "asphalt" actually asks.
static func measure_band(img: Image, x0: float, y0: float, x1: float, y1: float) -> Dictionary:
	var sub := img.get_region(Rect2i(
		int(x0 * img.get_width()), int(y0 * img.get_height()),
		maxi(1, int((x1 - x0) * img.get_width())), maxi(1, int((y1 - y0) * img.get_height()))))
	if sub == null or sub.get_width() < 2 or sub.get_height() < 2:
		return {"ok": false, "error": "band too small"}
	var m := measure_image(sub)
	# Local contrast: mean absolute horizontal gradient. A flat road and a road
	# with aggregate, kerb edges and markings in it differ far more here than they
	# do in mean luma, and "local contrast in those panels" is already the metric
	# `night_env.gd` swept the tonemap with.
	m["detail"] = _detail(sub)
	return m


static func _detail(img: Image) -> float:
	var px := img.get_width()
	var py := img.get_height()
	var fmt := img.get_format()
	var stride := 4 if fmt == Image.FORMAT_RGBA8 else 3
	var data := img.get_data()
	if stride == 0 or data.size() < px * py * stride:
		return 0.0
	var acc := 0.0
	var n := 0
	for y in py:
		var row := y * px * stride
		for x in px - 1:
			var o := row + x * stride
			var a := 0.2126 * float(data[o]) + 0.7152 * float(data[o + 1]) + 0.0722 * float(data[o + 2])
			var b := 0.2126 * float(data[o + stride]) + 0.7152 * float(data[o + stride + 1]) \
				+ 0.0722 * float(data[o + stride + 2])
			acc += absf(a - b)
			n += 1
	return acc / maxf(float(n), 1.0)


static func _percentile(hist: PackedInt32Array, total: int, q: float) -> float:
	var want := float(total) * q
	var acc := 0
	for i in 256:
		acc += hist[i]
		if float(acc) >= want:
			return float(i)
	return 255.0


## Fallback for image formats the fast path does not handle. Four orders of
## magnitude slower, and it exists so a wrong format degrades into a slow answer
## rather than into a wrong one.
static func _measure_by_pixel(img: Image, px: int, py: int, total: int) -> Dictionary:
	var sum := 0.0
	var lit := 0
	var clipped := 0
	var dark := 0
	var orange := 0
	var orange_bright := 0
	for y in py:
		for x in px:
			var c := img.get_pixel(x, y)
			var r := c.r * 255.0
			var g := c.g * 255.0
			var b := c.b * 255.0
			var l := 0.2126 * r + 0.7152 * g + 0.0722 * b
			sum += l
			if l >= CLIP_LUMA:
				clipped += 1
			if l <= DARK_LUMA:
				dark += 1
			if l > DARK_LUMA:
				lit += 1
				if r - b > ORANGE_LEAD:
					orange += 1
					if l >= ORANGE_BRIGHT_LUMA:
						orange_bright += 1
	return {
		"ok": true, "slow": true,
		"mean": sum / float(total),
		"clipped": float(clipped) / float(total),
		"dark": float(dark) / float(total),
		"orange": float(orange) / maxf(float(lit), 1.0),
		"orange_bright": float(orange_bright) / maxf(float(lit), 1.0),
		"p50": 0.0, "p95": 0.0, "p99": 0.0,
	}

# ------------------------------------------------------------------- the checks
## Every threshold in this file, as a list of `{name, ok, got, floor_or_ceiling,
## limit, rubric}`. One function, so the test entry point and the report cannot
## disagree about what is being asserted.
##
## `poses` is a list of per-pose measurement dictionaries, each with the keys
## `report` (whole frame), `road` (road band) and `paint` (markings band).
static func checks(poses: Array) -> Array:
	var out: Array = []
	if poses.is_empty():
		out.append(_c("capture", false, "no poses measured", 0.0, 1.0, 0.0, "the gate"))
		return out

	var covered := 0.0
	var paint_ratio_sum := 0.0
	var paint_n := 0
	for p in poses:
		covered += float(p.get("covered_m", 0.0))
		var rep: Dictionary = p["report"]
		var road: Dictionary = p["road"]
		var name := String(p["name"])

		# LIGHTING - a night frame whose near field clips has no night in it.
		out.append(_c("%s: frame not blown out" % name,
			float(rep["clipped"]) <= MAX_FRAME_CLIPPED, "clipped",
			float(rep["clipped"]), 1.0, MAX_FRAME_CLIPPED, "lighting"))
		# ATMOSPHERE - and one that is all floor is just as wrong.
		out.append(_c("%s: frame has a floor" % name,
			float(rep["dark"]) <= MAX_FRAME_DARK, "dark",
			float(rep["dark"]), 1.0, MAX_FRAME_DARK, "atmosphere"))

		# ASPHALT. **Per pose, never averaged.** The first version of this file
		# averaged the road band over all six poses, and the before build passed
		# it: road means of 33, 91, 10, 26, 30 and *2.65* average to 32, well
		# clear of a 6.0 floor. One street where the road is 100% black and one
		# where it is blown out cancel out in a mean, and a mean is exactly the
		# statistic that lets a map look good on average and be unusable on the
		# stretch you actually drive. Every pose has to hold on its own.
		out.append(_c("asphalt %s: the road is visible" % name,
			float(road["mean"]) >= MIN_ROAD_LUMA, "road mean luma",
			float(road["mean"]), 1.0, MIN_ROAD_LUMA, "asphalt"))
		out.append(_c("asphalt %s: the road is not an orange polygon" % name,
			float(road["orange_bright"]) <= MAX_ROAD_ORANGE_BRIGHT,
			"bright orange share",
			float(road["orange_bright"]), 1.0, MAX_ROAD_ORANGE_BRIGHT, "asphalt"))
		# The same argument one step further out. `walk3` on the before build
		# measures a road band that is 100% below the dark threshold - not "dark
		# for a night scene", *absent* - and its mean of 2.65 is what the floor
		# above is set against.
		out.append(_c("asphalt %s: the road is not a black band" % name,
			float(road["dark"]) <= MAX_ROAD_DARK, "road dark share",
			float(road["dark"]), 1.0, MAX_ROAD_DARK, "asphalt"))
		# And is it a road? Every check above reads a rectangle of frame and
		# calls it tarmac because the pose put it there. Measured on
		# 2026-10-03: `walk2` framed a building wall and `walk3` bare terrain,
		# both at road detail 0.04-0.79 against 2.3-4.9 on the four poses that
		# were on tarmac, and both passed everything above - so the coverage gate
		# below was satisfied by two frames that contained no street. This check
		# goes first for that reason: a pose that fails it invalidates its own
		# numbers, and it is cheaper to find out from one threshold than from a
		# reader wondering why the junction is so smooth.
		out.append(_c("asphalt %s: the band is a road and not a surface" % name,
			float(road.get("detail", 0.0)) >= MIN_ROAD_DETAIL, "road detail",
			float(road.get("detail", 0.0)), 1.0, MIN_ROAD_DETAIL, "asphalt"))

		if p.has("paint") and bool(p["paint"].get("ok", false)):
			paint_ratio_sum += float(p["paint"]["p95"]) / maxf(float(road["mean"]), 0.001)
			paint_n += 1
			# MARKINGS, per pose as well: a centre line that reads on one street
			# and vanishes on the next is the same defect as an invisible road.
			# The markings band is a rectangle in normalised frame coordinates,
			# chosen before anyone looked at a frame, and on four of the six poses
			# it does not contain a lane line at all: a band of plain tarmac has a
			# p95/p50 near 1.4, and asserting "paint is 1.3x brighter than tarmac"
			# on a rectangle of tarmac asserts nothing while looking like a check.
			# So the check is made where there is a marking in the band, and the
			# poses where there is not are reported as skipped rather than as
			# passed - a skip that does not say so is how a suite dies quietly.
			var pa: Dictionary = p["paint"]
			var spread := float(pa["p95"]) / maxf(float(pa["p50"]), 0.001)
			var ratio := float(pa["p95"]) / maxf(float(road["mean"]), 0.001)
			if spread < MARKING_BAND_SPREAD:
				out.append(_c("markings %s: no marking in the band, nothing to check"
						% name, true, "p95/p50 = %.2f" % spread, spread,
					1.0, MARKING_BAND_SPREAD, "markings").merged(
					{"skipped": true}, true))
			else:
				out.append(_c("markings %s: paint reads brighter than the tarmac"
						% name, ratio >= MIN_PAINT_OVER_ROAD, "paint/road luma",
					ratio, 1.0, MIN_PAINT_OVER_ROAD, "markings"))

	# The gate from the decision document: one good 500 m stretch before the map
	# grows. Measured as the street each pose actually covers, not as the number
	# of poses - and note that the before build clears this one too, at 590 m,
	# which is the point: the gate is necessary and nowhere near sufficient.
	out.append(_c("the beauty pass covers one 500 m stretch",
		covered >= COVERAGE_M, "metres of street covered",
		covered, 1.0, COVERAGE_M, "the gate"))
	return out


## Every check carries the number it measured, not only the limit it was held
## to. A failure that says "road orange share, limit 0.45" and a failure that
## says "road orange share is 0.52, limit 0.45" are not the same failure report:
## the first one sends someone to the threshold file, the second one answers the
## question.
static func _c(name: String, ok: bool, got_label: String, got: float, dir: float,
		limit: float, rubric: String) -> Dictionary:
	return {
		"name": name, "ok": ok, "got_label": got_label, "got": got,
		"direction": dir, "limit": limit, "rubric": rubric,
	}


## The failing checks. A skipped check is not a failing one - it is a rectangle
## of frame with no marking in it - but it is returned separately by `skipped()`
## so nothing can quietly stop being measured without showing up in the report.
static func failures(checks: Array) -> Array:
	var out: Array = []
	for c in checks:
		if not bool(c["ok"]) and not bool(c.get("skipped", false)):
			out.append(c)
	return out


static func skipped(checks: Array) -> Array:
	var out: Array = []
	for c in checks:
		if bool(c.get("skipped", false)):
			out.append(c)
	return out