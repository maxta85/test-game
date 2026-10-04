extends SceneTree
## Is there a drivable line down this street? Measured, not assumed.
##
##   /home/coder/tools/godot --headless --path . \
##       --script res://Tools/street_blockers.gd -- --street="Aumuller Street"
##   ... -- --street="Aumuller Street" --at=47.1
##
## WHY THIS EXISTS. Three agents have now measured a car stopping dead on a
## `PropCollision_*` body part-way down Aumuller Street, and every one of those
## measurements came from ONE collision event captured by a car as it drove. That
## cannot answer the question the owner actually asked, which is not "is there an
## obstacle" but "can it be driven past".
##
## It cannot, for three reasons, and this tool exists for each of them:
##
##   1. A CAR STOPS AT THE FIRST ONE. A drive reports one blocker however many are
##      downstream, so "blocked at 47 m" says nothing about the other 777 m.
##   2. A COLLIDER NAME SAYS NOTHING ABOUT WHERE IT IS. `PropCollision_x2_z-1` is
##      a name, not a position. A palm 5 m out on the shoulder and a palm on the
##      centreline are the same string; one is scenery and one is a wall.
##   3. THE BLOCKER CANNOT HAVE BEEN THE ONE THAT STOPPED THE CAR, IF THE CAR
##      NEVER GOT PAST THE FIRST. So a second reported blocker downstream of the
##      first is untested, not disproven, and nobody can tell which.
##
## So this asks the physics server directly, at every station along the street's
## own polyline, and answers the one question that decides playability: at each
## station, how wide is the CLEAR corridor across the carriageway? A car needs
## about 1.9 m plus margin; the answer is the narrowest such width over the whole
## street and where it occurs.
##
## It is a `--script` SceneTree run and not a test suite on purpose: it needs a
## fully built world (26 s of CPU, 195k terrain triangles) and the suites
## deliberately do not pay that cost.

const STREET_NAME := "Aumuller Street"
## Stations per metre of centreline. 4/m is one query every 25 cm, finer than a
## car is wide, so nothing can hide between two of them.
const STATIONS_PER_M := 4.0
## The sweep box is this tall, centred `BOX_LIFT` above the tarmac, so it spans
## the road surface up to about a metre above it. That is CAR_HEIGHT with room to
## spare: it catches bollards, kerb-height planters and anything a car body would
## meet, and deliberately does not catch a tree canopy at 4 m, which a car passes
## under happily and which would otherwise read as a blocker.
const SWEEP_H := 2.0
const BOX_LIFT := 0.5
## Lateral resolution of the corridor measurement.
const BAND_W := 0.5
## What a car needs. `CarBody` is about 4.4 m long and 1.9 m wide; 2.6 m is that
## width plus a hand's worth of margin either side, which is what a driver will
## accept before deciding to turn around.
const CAR_CLEAR := 2.6
## Half the width a car needs, so a candidate lane offset is only clear if this
## much room exists either side of it. The lane is reported as "clear" only when
## the WHOLE car is inside the clear run, not merely its centreline: a car tracking
## a line whose centre is 0.2 m from a palm is not drivable, it is parked.
const CAR_HALF := 0.95
## Candidate constant lateral offsets to score, in metres on the SURVEY's axis.
## The point is to find out whether the street has ONE line that works end to end,
## which is what "a person can drive it" reduces to.
const LANE_CANDIDATES := [-6.0, -5.5, -5.0, -4.5, -4.0, -3.5, -3.0, -2.5, -2.0, -1.5,
	-1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0]
## Colliders that ARE the ground. They occupy every station by definition, and
## reporting them would bury the answer.
const GROUND := ["RoadCollision", "TerrainCollision", "OuterFloor"]

var _pts := PackedVector2Array()
var _total := 0.0
var _graph: RoadGraph = null


func _initialize() -> void:
	var want := STREET_NAME
	var at := -1.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--street="):
			want = a.substr(9)
		elif a.begins_with("--at="):
			at = a.substr(5).to_float()
	_main(want, at)


func _main(want: String, at: float) -> void:
	print("[blockers] building world (this is the 26 s part)...")
	_graph = RoadGraph.new()
	_graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "BlockerProbeRoot"
	get_root().add_child(root)
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(_graph)

	# `build()` runs during add_child and the colliders are added as children of
	# the world, so the physics server needs frames before any query can see them.
	for _i in 4:
		await process_frame

	_pts = _pick(want)
	if _pts.is_empty():
		print("BLOCKERS FATAL: no corridor named %s" % want)
		quit(2)
		return
	for i in _pts.size() - 1:
		_total += _pts[i].distance_to(_pts[i + 1])
	var space := world.get_world_3d().direct_space_state
	print("[blockers] %s: %.1f m of centreline, %d points, sweep every %.2f m" % [
		want, _total, _pts.size(), 1.0 / STATIONS_PER_M])

	if at >= 0.0:
		_at_station(space, at)
		quit(0)
		return

	var r := _corridor_survey(space)
	_report(r)
	quit(0)


## Walk the whole street and measure the clear corridor at every station.
##
## One full-width query per station first: that is cheap and it answers "is this
## station clear at all". Only a station that is NOT clear pays for the 28-band
## localisation, which is what turns "something is here" into "here is how much
## room is left and how far off the centreline it is".
func _corridor_survey(space: PhysicsDirectSpaceState3D) -> Dictionary:
	var stations := 0
	var blocked_stations := 0
	# [{ first_s, last_s, width, lat_lo, lat_hi }]
	var pinches: Array = []
	# {name: {first_s, last_s, stations}}
	var bodies := {}
	# {"<offset>": narrowest clear width a whole car gets at that offset}
	var lane := {}
	for c in LANE_CANDIDATES:
		lane["%.1f" % float(c)] = 2.0 * hw_typical()
	# Census of what is UNDER THE CENTRELINE, separately from what is beside it.
	# A corridor polyline is a line on a map; the carriageway is generated from the
	# road graph. They can disagree, and when they do the street is not a street.
	# A 1400 m name in the map data proves nothing about 1400 m of road.
	var road_stations := 0
	var bare_run := 0
	var bare_worst := 0
	var bare_worst_s := -1.0
	var bare_starts: Array = []

	var s := 0.0
	while s < _total:
		var pose := _pose(s)
		var hw := _half_width(pose["pos"])
		stations += 1

		# 0.4 m box, not the carriageway-width one: this asks whether TARMAC is
		# under the centreline, and a 14 m box would happily find the road of a
		# street running 6 m to the side and call this one paved.
		if GROUND.has("RoadCollision") and _has(space, pose["pos"], pose["t"], 0.2, "RoadCollision"):
			road_stations += 1
			bare_run = 0
		else:
			bare_run += 1.0 / STATIONS_PER_M
			if bare_run > bare_worst:
				bare_worst = bare_run
				bare_worst_s = s - bare_run + 1.0 / STATIONS_PER_M
			if absf(bare_run - 1.0 / STATIONS_PER_M) < 0.0001:
				bare_starts.append(s)

		var names := _names_in(space, pose["pos"], pose["t"], hw)
		var clear_names: Array = []
		for n in names:
			if not GROUND.has(String(n)):
				clear_names.append(String(n))
		if clear_names.is_empty():
			if not pinches.is_empty():
				pinches[pinches.size() - 1]["last_s"] = s
			s += 1.0 / STATIONS_PER_M
			continue

		blocked_stations += 1
		var band := _bands(space, pose["pos"], pose["t"], hw)
		var width := _widest_clear(band, hw)
		var free := _widest_clear_range(band, hw)
		# Score every candidate lane offset at every blocked station, not just the
		# widest run: "there is a 9.5 m gap over here" is not the question, "is
		# there ONE offset that a whole car fits inside at EVERY station" is.
		for cand in LANE_CANDIDATES:
			var w := _clear_about(band, hw, float(cand))
			var key := "%.1f" % float(cand)
			if not lane.has(key) or w < float(lane[key]):
				lane[key] = w
		if pinches.is_empty() or absf(float(pinches[pinches.size() - 1]["width"]) - width) > 0.4:
			pinches.append({"first_s": s, "last_s": s, "width": width,
				"lat_lo": free[0], "lat_hi": free[1]})
		else:
			pinches[pinches.size() - 1]["last_s"] = s
		for n in clear_names:
			if not bodies.has(n):
				bodies[n] = {"first_s": s, "last_s": s, "stations": 0}
			var e: Dictionary = bodies[n]
			e["last_s"] = s
			e["stations"] = int(e["stations"]) + 1
		s += 1.0 / STATIONS_PER_M

	var worst := CAR_CLEAR
	var worst_s := -1.0
	for p in pinches:
		if float(p["width"]) < worst:
			worst = float(p["width"])
			worst_s = float(p["first_s"])
	if pinches.is_empty():
		worst = INF
	return {"stations": stations, "blocked": blocked_stations,
		"pinches": pinches, "bodies": bodies, "lane": lane,
		"road_stations": road_stations, "bare_worst": bare_worst,
		"bare_worst_s": bare_worst_s, "bare_starts": bare_starts,
		"worst": worst, "worst_s": worst_s}


## Is `name` inside the swept box? Same query as `_sweep`, filtered.
func _has(space: PhysicsDirectSpaceState3D, centre: Vector3, tan: Vector2,
		half_w: float, name: String) -> bool:
	for b in _sweep(space, centre, tan, half_w):
		if String(b.name) == name:
			return true
	return false


## Widest carriageway width on this street, for seeding the lane scores before
## anything blocked has been seen.
func hw_typical() -> float:
	var pose := _pose(_total * 0.5)
	return _half_width(pose["pos"])


## Width of the clear run that CONTAINS a car whose centre sits at `offset`, or
## 0.0 when the car straddles a blocked band.
##
## One quantity on one scale, so the numbers are comparable: 0.0 means "no", and
## anything else is metres of free road around the car. An earlier version returned
## the full carriageway width when nothing overlapped the car and the leftover room
## when something did, which put 14.00 (the whole street) and 0.00 (blocked) in the
## same column and hid the difference between "clear" and "very clear".
func _clear_about(band: Array, half_w: float, offset: float) -> float:
	var lo := offset - CAR_HALF
	var hi := offset + CAR_HALF
	for i in band.size():
		if not bool(band[i]):
			continue
		var b_lo := -half_w + float(i) * BAND_W
		if b_lo + BAND_W > lo + 0.001 and b_lo < hi - 0.001:
			return 0.0
	# Unobstructed under the car: widen out to the edges of the clear run it is in.
	var run_lo := -half_w
	var run_hi := half_w
	for i in band.size():
		var b_lo2 := -half_w + float(i) * BAND_W
		var b_hi2 := b_lo2 + BAND_W
		if b_hi2 <= lo + 0.001:
			run_lo = b_hi2
		elif b_lo2 >= hi - 0.001:
			run_hi = minf(run_hi, b_lo2)
	return run_hi - run_lo


## Body names across the whole carriageway at one station.
func _names_in(space: PhysicsDirectSpaceState3D, centre: Vector3, tan: Vector2,
		half_w: float, depth: float = 0.30) -> Array:
	var out: Array = []
	for b in _sweep(space, centre, tan, half_w, depth):
		var n := String(b.name)
		if not out.has(n):
			out.append(n)
	return out


## Which lateral bands contain something. `bands[i]` is true when band i is
## blocked, so it is the complement of "clear" - named for what it measures.
func _bands(space: PhysicsDirectSpaceState3D, centre: Vector3, tan: Vector2,
		half_w: float) -> Array:
	var out: Array = []
	var right := Vector3(tan.y, 0.0, -tan.x)
	var n := int(floor(half_w * 2.0 / BAND_W))
	for i in n:
		var off := -half_w + float(i) * BAND_W
		var c := centre + right * (off + BAND_W * 0.5)
		var hit := false
		for b in _sweep(space, c, tan, BAND_W * 0.5):
			if not GROUND.has(String(b.name)):
				hit = true
				break
		out.append(hit)
	return out


## Widest contiguous run of clear bands, in metres, and the lateral span it covers.
func _widest_clear(band: Array, half_w: float) -> float:
	var span := _widest_clear_range(band, half_w)
	return float(span[1]) - float(span[0])


func _widest_clear_range(band: Array, half_w: float) -> Array:
	var best_lo := 0
	var best_hi := 0
	var best_len := 0
	var cur := -1
	# `i >= band.size()` is the closing sentinel and MUST count as blocked. An
	# earlier version wrote `i < size and band[i]`, which made the sentinel
	# *clear* - and a run that reaches the far kerb is then never closed, never
	# compared, and silently loses to a shorter run. That is not a rounding
	# error: it reported 0.00 m of clear lane at a station with 13.5 m clear.
	for i in band.size() + 1:
		var blocked: bool = i >= band.size() or bool(band[i])
		if not blocked:
			if cur < 0:
				cur = i
			continue
		if cur >= 0:
			var l := i - cur
			if l > best_len:
				best_len = l
				best_lo = cur
				best_hi = i
			cur = -1
	return [-half_w + float(best_lo) * BAND_W, -half_w + float(best_hi) * BAND_W]


## A box `2 * half_w` across the carriageway, `SWEEP_H` tall and `depth` deep along
## the street, swept at one point. The default depth of 0.30 m is right for the
## corridor survey, whose stations are every 0.25 m so consecutive boxes overlap
## and cover the street continuously; it is far too shallow for asking what a CAR
## is touching, which is what `_at_station` is for.
func _sweep(space: PhysicsDirectSpaceState3D, centre: Vector3, tan: Vector2,
		half_w: float, depth: float = 0.30) -> Array:
	var box := BoxShape3D.new()
	box.size = Vector3(half_w * 2.0, SWEEP_H, depth)
	# Local X runs across the carriageway, local Z along it. Built from explicit
	# columns: Basis(x, y, z) takes three Vector3s and a Vector2 in the third slot
	# is a parse error, not a coercion.
	var right := Vector3(tan.y, 0.0, -tan.x)
	var fwd := Vector3(tan.x, 0.0, tan.y)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = box
	params.transform = Transform3D(Basis(right, Vector3.UP, fwd), centre)
	params.collision_mask = 0xFFFFFFFF
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var out: Array = []
	for r in space.intersect_shape(params, 64):
		out.append(r["collider"])
	return out


## Everything near the carriageway at one station, with a downward ray per band so
## each body's HEIGHT is measured rather than guessed from its name.
##
## `CollisionObject3D` has no `get_aabb()` in Godot 4 - that is a VisualInstance3D
## method - so asking one for its extents is a runtime error, not a null. A
## downward ray per lateral band answers the same question for less: how high does
## the obstruction stand at this point across the carriageway.
##
## The sweep here is AT_DEPTH deep along the street, not SWEEP_H's 0.30 m, and that
## difference is the whole reason this mode exists. A contact reported at a car's
## CENTRE is with something up to half a car length ahead of it, and the 0.30 m
## box the corridor survey uses cannot see that: it reported a bare carriageway at
## every lateral offset for stations where the drive log plainly had the car
## touching a prop. Asking "what is at the station where the car is" and getting
## "nothing" is a question about the sweep, not about the street.
const AT_DEPTH := 6.0


func _at_station(space: PhysicsDirectSpaceState3D, at: float) -> void:
	var pose := _pose(at)
	var hw := _half_width(pose["pos"])
	var tan: Vector2 = pose["t"]
	var right := Vector2(tan.y, -tan.x)
	print("")
	print("[blockers --at=%.1f] half-width %.2f m, centre (%.1f, %.1f), swept %.1f m deep" % [
		at, hw, pose["pos"].x, pose["pos"].z, AT_DEPTH])
	print("the depth is a car: contacts reported at a car's centre are up to half a")
	print("car length ahead of it, and a 0.30 m slice cannot see them.")
	print("")
	var seen := {}
	var off := -hw
	while off < hw - 0.001:
		var c: Vector3 = pose["pos"] + Vector3(right.x, 0.0, right.y) * (off + BAND_W * 0.5)
		for n in _names_in(space, c - Vector3(0.0, BOX_LIFT, 0.0), tan, BAND_W * 0.5, AT_DEPTH):
			var key := "%s@%+.2f" % [n, off]
			if seen.has(key):
				continue
			seen[key] = true
			var top = _top_of(space, c, n)
			print("  lat %+6.2f..%+6.2f  %-26s top of obstruction %s" % [
				off, off + BAND_W, n,
				"not under this ray" if top == null else "y=%.2f m" % float(top)])
		off += BAND_W


## Top of `name` above `x`, or null if nothing of that name is over `x`.
func _top_of(space: PhysicsDirectSpaceState3D, x: Vector3, name: String):
	var params := PhysicsRayQueryParameters3D.new()
	params.from = x + Vector3(0.0, 8.0, 0.0)
	params.to = x - Vector3(0.0, 8.0, 0.0)
	var hit := space.intersect_ray(params)
	if hit.is_empty() or String((hit["collider"] as Node).name) != name:
		return null
	return (hit["position"] as Vector3).y


# ------------------------------------------------------------------ geometry

func _pose(d: float) -> Dictionary:
	var acc := 0.0
	for i in _pts.size() - 1:
		var a := _pts[i]
		var b := _pts[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		if acc + seg >= d:
			var u := (d - acc) / seg
			var p := a.lerp(b, u)
			return {"pos": Vector3(p.x, LookDev.TARMAC_Y + BOX_LIFT, p.y), "t": (b - a) / seg}
		acc += seg
	var p := _pts[_pts.size() - 1]
	return {"pos": Vector3(p.x, LookDev.TARMAC_Y + BOX_LIFT, p.y),
		"t": (_pts[_pts.size() - 1] - _pts[_pts.size() - 2]).normalized()}


func _half_width(p: Vector3) -> float:
	if _graph == null:
		return 7.0
	var near: Dictionary = _graph.nearest_road(p)
	var eid := int(near["edge"])
	if eid < 0:
		return 7.0
	return float(_graph.edges[eid]["width"]) * 0.5


## The longest run of that street name. `OSMLayout.anchor()` is not a substitute:
## it scores by centrality with the length worth 0.01 m per metre, so it returns a
## different and much shorter street, and every number here would be about a road
## nobody looked at.
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


# -------------------------------------------------------------------- report

func _report(r: Dictionary) -> void:
	print("")
	print("=".repeat(78))
	print("CARRIAGEWAY CORRIDOR SURVEY")
	print("=".repeat(78))
	print("%d stations swept over %.1f m, %d of them with something in the carriageway" % [
		int(r["stations"]), _total, int(r["blocked"])])
	print("a car needs about %.1f m of clear width; the survey resolves %.1f m" % [
		CAR_CLEAR, BAND_W])
	print("")
	_road_census(r)
	if (r["pinches"] as Array).is_empty():
		print("NOTHING in the carriageway at any station. The whole street is clear.")
		print("")
		_lane_report(r)
		print("Report line: BLOCKERS=0 NARROWEST=%.1f" % CAR_CLEAR)
		print("=".repeat(78))
		return

	print("%8s %8s  %9s  %-22s %s" % ["from_s", "to_s", "clear_m", "lateral span", "note"])
	for p in r["pinches"]:
		var w := float(p["width"])
		print("%8.1f %8.1f  %9.2f  %+5.2f..%+5.2f       %s" % [
			float(p["first_s"]), float(p["last_s"]), w,
			float(p["lat_lo"]), float(p["lat_hi"]), _note(w)])
	print("")
	print("bodies found in the carriageway:")
	var names: Array = (r["bodies"] as Dictionary).keys()
	names.sort_custom(func(a: String, b: String) -> bool:
		return float((r["bodies"] as Dictionary)[a]["first_s"]) < float((r["bodies"] as Dictionary)[b]["first_s"]))
	for n in names:
		var e: Dictionary = (r["bodies"] as Dictionary)[n]
		print("  %-26s s=%.1f..%.1f m, %d stations" % [
			n, float(e["first_s"]), float(e["last_s"]), int(e["stations"])])
	print("")
	var worst := float(r["worst"])
	# worst_s is -1.0 when no station was worse than CAR_CLEAR, because the scan
	# seeds `worst` with that threshold. Printing "at s=-1.0 m" turns a sentinel
	# into a location, which is the same class of lie as a header that describes a
	# format the rows do not emit.
	var where := "at no station" if float(r["worst_s"]) < 0.0 else "at s=%.1f m" % float(r["worst_s"])
	print("NARROWEST CLEAR CORRIDOR : %.2f m %s" % [
		999.0 if worst == INF else worst, where])
	if worst >= CAR_CLEAR:
		print("VERDICT: DRIVABLE. Every station leaves at least %.1f m of lane, so the" % worst)
		print("         street can be driven end to end without leaving the carriageway.")
	else:
		print("VERDICT: BLOCKED. At s=%.1f m only %.2f m of carriageway is clear and a car" % [
			float(r["worst_s"]), worst])
		print("         needs about %.1f m. There is no line through that station." % CAR_CLEAR)
	print("")
	_lane_report(r)
	print("Report line: BLOCKERS=%d NARROWEST=%s" % [
		names.size(), "none" if worst == INF else "%.2f" % worst])
	print("=".repeat(78))


## Which constant lateral offset a whole car fits inside at EVERY station.
##
## This is the question behind "can a person drive it". "Every station has some
## clear lane" is necessary and not sufficient: a lane that hops from the left of
## the street to the right between two stations 20 m apart is a lane no driver
## follows and no controller tracks. So every candidate offset is scored against
## every station and the winner is the one whose WORST station still has room.
func _lane_report(r: Dictionary) -> void:
	var lane: Dictionary = r["lane"]
	var rows: Array = []
	for k in lane:
		rows.append([float(k), float(lane[k])])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	print("constant lane offsets, scored by the NARROWEST station on the whole street")
	print("(a car %.2f m wide must fit either side of the offset; positive is the" % (CAR_HALF * 2.0))
	print("opposite side to the obstructions, which are all on the negative kerb)")
	print("")
	print("  %8s  %12s  %s" % ["offset", "worst_m", "verdict"])
	var best := -1.0
	var best_w := -1.0
	for row in rows:
		var off := float(row[0])
		var w := float(row[1])
		var tag := "no line"
		if w >= CAR_HALF * 2.0:
			tag = "a whole car fits end to end"
		elif w > 0.0:
			tag = "straddles something"
		print("  %+8.1f  %12.2f  %s" % [off, w, tag])
		if w > best_w:
			best_w = w
			best = off
	print("")
	if best_w >= CAR_HALF * 2.0:
		var span: Array = []
		for row in rows:
			if float(row[1]) >= CAR_HALF * 2.0:
				span.append(float(row[0]))
		print("CLEAR LINE BAND        : %+.1f .. %+.1f m off the centreline (all of it" % [
			span[0], span[span.size() - 1]])
		print("                         fits a whole %.2f m car at every one of the" % (CAR_HALF * 2.0))
		print("                         %d stations on the street)" % int(r["stations"]))
		print("BEST CONSTANT LINE      : %+.1f m, %.2f m of room at its worst station." % [best, best_w])
		print("Report line: LANE=%+.1f LANE_WORST_M=%.2f" % [best, best_w])
	else:
		print("NO CONSTANT LINE: the best offset (%+.1f m) only ever has %.2f m of room." % [best, best_w])
		print("Report line: LANE=none LANE_WORST_M=%.2f" % best_w)


func _note(w: float) -> String:
	if w >= CAR_CLEAR:
		return "passable - keep to the free side"
	if w >= 1.9:
		return "a bare car width - swerve hard"
	return "below car width - no line"


## How much of this "street" has tarmac under its centreline.
##
## A corridor polyline in the map data is a LINE. The carriageway the car drives on
## is generated from the road graph, and the two are built from the same fetch but
## are not the same object. A long straight run in the name list can therefore be a
## fragment stitched across the map rather than a road anyone built, and the only
## way to know is to ask the collider what is underneath, station by station.
##
## This is asked with a 0.4 m box on the centreline, not the carriageway-width one
## the corridor survey uses: a wide box finds the road of a street running a few
## metres to the side and reports this one as paved.
func _road_census(r: Dictionary) -> void:
	var on := int(r["road_stations"])
	var total := int(r["stations"])
	var bare := total - on
	print("ROAD BENEATH THE CENTRELINE: %d of %d stations (%.0f%%)" % [
		on, total, 100.0 * float(on) / maxf(float(total), 1.0)])
	if bare == 0:
		print("  the whole polyline is tarmac. It is a street.")
	else:
		print("  %d stations (%.0f m) have NO road on the centreline." % [
			bare, bare / STATIONS_PER_M])
		print("  longest bare run: %.1f m starting at s=%.1f m" % [
			float(r["bare_worst"]), float(r["bare_worst_s"])])
		var starts: Array = r["bare_starts"]
		if starts.size() > 12:
			print("  %d bare runs start at: %s ... (truncated)" % [
				starts.size(), str(starts.slice(0, 12))])
		else:
			print("  %d bare runs start at: %s" % [starts.size(), str(starts)])
		print("  A run of bare stations means the polyline is not following a road there.")
	print("")