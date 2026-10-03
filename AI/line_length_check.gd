extends SceneTree
##
## Is the AI's 2790.3 m line correct, or is it a defect? Measure it.
##
##   /home/coder/tools/godot --headless --path . --script res://AI/line_length_check.gd
##
## THE QUESTION, which t123 flagged and t124 and t126 both carried forward as a
## caveat: `AI/street_ai_probe.gd` reports the driver's line as 2790.3 m where Hoare
## Street is 1407.5 m — 1.98x. Every AI number since is a percentage of the LINE, so
## none of them is comparable to the 99%-of-the-street the player probe measured.
##
## This is a MEASUREMENT question first. Nothing here changes a line, and if the line
## is right it stays right.
##
## The five candidates, and each one is ruled in or out by a number below:
##
##   (a) it is a loop that traverses the street and returns, so 2x is arithmetic
##   (b) it includes a return leg through a car park or a side street
##   (c) the closing segment is counted twice
##   (d) smoothing genuinely lengthens a grid-shaped street, cutting corners outward
##   (e) it is simply a bug
##
## No world, no physics, no driving: `RacingLine.from_route` is pure geometry over a
## polyline and a graph, and this runs in a second.

const STREET := "Hoare Street"


func _initialize() -> void:
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var pts := _pick(STREET)
	if pts.size() < 2:
		print("LINE FATAL: no corridor named %s" % STREET)
		quit(2)
		return

	var route: Array = []
	for p in pts:
		route.append(p)

	var poly := _poly_len(pts)
	var wrapped := _poly_len_wrapped(pts)
	print("[line] %s" % STREET)
	print("[line] input polyline : %d points, %.1f m" % [pts.size(), poly])
	print("[line] same, summing a CLOSING segment : %.1f m  (%.3fx)" % [
		wrapped, wrapped / maxf(poly, 0.001)])
	print("[line]   first point %s, last %s, straight between them %.1f m" % [
		str(pts[0].round()), str(pts[pts.size() - 1].round()),
		pts[0].distance_to(pts[pts.size() - 1])])
	print("")

	var line := RacingLine.from_route(route, graph, false)
	var n := line.points.size()
	print("[line] RacingLine.from_route(route, graph, is_closed = FALSE)")
	print("[line]   line.closed flag   : %s" % str(line.closed))
	print("[line]   points             : %d" % n)
	print("[line]   line.length        : %.1f m" % line.length)
	print("[line]   line.spacing       : %.3f m" % line.spacing)
	print("[line]   expected samples for %.1f m at %.1f m spacing : %d" % [
		poly, RacingLine.SAMPLE_SPACING, int(round(poly / RacingLine.SAMPLE_SPACING))])
	print("[line]   ratio to the street: %.3fx" % [line.length / maxf(poly, 0.001)])
	print("")

	# ---- (a) Is it a loop? Does it come back to where it started?
	var gap: float = Vector2(line.points[0]).distance_to(Vector2(line.points[n - 1]))
	print("(a) is it a loop?")
	print("    distance from the first sample to the last: %.1f m" % gap)
	print("    first sample %s, last sample %s" % [
		str(line.points[0].round()), str(line.points[n - 1].round())])
	if gap < 5.0:
		print("    VERDICT (a): it CLOSES on itself - but that is NOT benign, and the")
		print("    first version of this file said it was. See (e): the ends are together")
		print("    because the resampler ran off the end of an OPEN polyline, wrapped to the")
		print("    first point and walked the street a SECOND time, then carried on along a")
		print("    1401.5 m phantom leg drawn straight across the map. A real loop would")
		print("    return by a road; this one returns by teleporting to (199, -838).")
	else:
		print("    VERDICT (a): RULED OUT. It does not return to its start; the ends are")
		print("    %.1f m apart, so this is not a lap of anything." % gap)
	print("")

	# ---- (b) Does it go somewhere the street does not? Max distance from the input.
	var worst := 0.0
	var worst_at := 0
	var worst_p := Vector2.ZERO
	var off_road := 0
	for i in n:
		var q: Vector2 = line.points[i]
		var d := _dist_to_poly(q, pts)
		if d > worst:
			worst = d
			worst_at = i
			worst_p = q
		if d > 9.0:
			off_road += 1
	print("(b) does it leave the street?")
	print("    furthest sample from the street centreline: %.1f m at index %d %s" % [
		worst, worst_at, str(worst_p.round())])
	print("    samples more than 9 m off the centreline  : %d of %d (%.0f%%)" % [
		off_road, n, 100.0 * float(off_road) / maxf(float(n), 1.0)])
	if off_road == 0:
		print("    VERDICT (b): RULED OUT. Every sample is on the street. There is no leg")
		print("    through a car park or a side street.")
	else:
		print("    VERDICT (b): it strays. Those samples are not on %s." % STREET)
	print("")

	# ---- (c) Is the closing segment counted twice?
	print("(c) is the closing segment double-counted?")
	print("    sum of consecutive samples (open)  : %.1f m" % _sum(line.points, false))
	print("    sum of consecutive samples (closed): %.1f m" % _sum(line.points, true))
	print("    line.length reported              : %.1f m" % line.length)
	if absf(line.length - _sum(line.points, true)) < 2.0:
		print("    VERDICT (c): line.length is the CLOSED perimeter - it includes the")
		print("    last-to-first segment, even though the line was built as OPEN.")
	else:
		print("    VERDICT (c): line.length is neither the open nor the closed sum, so it")
		print("    is computed some other way and needs a look.")
	print("")

	# ---- (d) Could smoothing alone explain the extra length?
	var straight := _resampled_open(route)
	var before := _sum(straight, false)
	print("(d) could smoothing alone account for it?")
	print("    length after resampling, before smoothing : %.1f m" % before)
	print("    length after the full from_route pipeline  : %.1f m" % line.length)
	print("    the pipeline added %.1f m (%.3fx)" % [
		line.length - before, line.length / maxf(before, 0.001)])
	if absf(line.length - before) / maxf(before, 0.001) < 0.10:
		print("    VERDICT (d): RULED OUT. Smoothing moved the length by under 10%, which is")
		print("    nothing like the 1.98x in question. Smoothing is not the cause.")
	else:
		print("    VERDICT (d): the pipeline itself is where the length appears.")
	print("")

	# ---- The bridge between "line" and "street": where do the samples stop being
	# the street? That is what lets a run measured in line-metres be re-expressed in
	# street-metres, which is the whole reason this file exists.
	var first_off := -1
	var on_street := 0
	for i in n:
		if _dist_to_poly(Vector2(line.points[i]), pts) > 9.0:
			if first_off < 0:
				first_off = i
		else:
			on_street += 1
	print("(e) WHERE does the line stop being the street?")
	print("    samples on the street centreline : %d of %d (%.0f%%)" % [
		on_street, n, 100.0 * float(on_street) / maxf(float(n), 1.0)])
	print("    first sample more than 9 m off   : %s" % [
		"never" if first_off < 0 else "index %d of %d" % [first_off, n]])
	if first_off > 0:
		var on_len := 0.0
		for i in first_off:
			on_len += Vector2(line.points[i]).distance_to(Vector2(line.points[i + 1]))
		print("    arc length of the on-street part : %.1f m of the street's %.1f m (%.1f%%)" % [
			on_len, poly, 100.0 * on_len / maxf(poly, 0.001)])
		print("    that index is %.2fx the %.d samples a correct resample would produce" % [
			float(first_off) / maxf(float(int(round(poly / RacingLine.SAMPLE_SPACING))), 1),
			int(round(poly / RacingLine.SAMPLE_SPACING))])
	print("    VERDICT (e): the on-street part IS the street, %.1f m of it. Everything" % poly)
	print("    after it is the phantom closing leg, walked twice and piled at the start.")
	print("")

	print("SUMMARY LINE_LEN=%.1f STREET_LEN=%.1f RATIO=%.3f SAMPLES=%d LOOP=%s" % [
		line.length, poly, line.length / maxf(poly, 0.001), n,
		"yes" if gap < 5.0 else "no"])
	quit(0)


## The same polyline length, summed WITH the closing segment - the arithmetic
## `RacingLine._resample` does, because it walks `src[(i + 1) % src.size()]`
## without consulting `is_closed`.
func _poly_len_wrapped(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in pts.size():
		total += pts[i].distance_to(pts[(i + 1) % pts.size()])
	return total


func _poly_len(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	return total


func _sum(points: Array, closed: bool) -> float:
	var total := 0.0
	var n := points.size()
	for i in n - 1:
		total += Vector2(points[i]).distance_to(Vector2(points[i + 1]))
	if closed and n > 1:
		total += Vector2(points[n - 1]).distance_to(Vector2(points[0]))
	return total


## Even spacing along the OPEN polyline, i.e. what `RacingLine` would have
## produced had `_resample` respected `is_closed` when it measured the route.
func _resampled_open(route: Array) -> Array:
	var src: Array = []
	for p in route:
		src.append(p)
	if src.size() < 3:
		return src
	var total := 0.0
	for i in src.size() - 1:
		total += Vector2(src[i]).distance_to(Vector2(src[i + 1]))
	var count: int = maxi(4, int(round(total / 4.0)))
	var out: Array = []
	for k in count:
		out.append(_point_at(src, total * float(k) / float(count - 1)))
	return out


func _point_at(src: Array, s: float) -> Vector2:
	var n := src.size()
	for i in n:
		var a: Vector2 = src[i]
		var b: Vector2 = src[(i + 1) % n]
		var seg: float = a.distance_to(b)
		if seg < 0.001:
			continue
		if s <= seg or i == n - 1:
			return a.lerp(b, clampf(s / seg, 0.0, 1.0))
		s -= seg
	return src[0]


func _dist_to_poly(q: Vector2, pts: PackedVector2Array) -> float:
	var best := INF
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((q - a).dot(ab) / len2, 0.0, 1.0)
		best = minf(best, (q - (a + ab * t)).length())
	return best


func _pick(want: String) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_len := 0.0
	for c in OSMLayout.corridors():
		if String(c.get("name", "")) != want:
			continue
		var p: PackedVector2Array = c["points"]
		var run := 0.0
		for i in p.size() - 1:
			run += p[i].distance_to(p[i + 1])
		if p.size() >= 2 and run > best_len:
			best_len = run
			best = p
	return best