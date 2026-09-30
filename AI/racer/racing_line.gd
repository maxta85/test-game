class_name RacingLine
extends RefCounted
## A smoothed racing line through a route, plus the speed the line allows at
## every point on it.
##
## Pure geometry: no physics, no scene tree, no car. The driver in
## `AI/ai_racer.gd` only ever asks this line where to aim and how fast it may
## go, which is what keeps an AI that looks fast from being one that drives
## through a corner on luck.
##
## ORIGINAL GAME CONTENT.

## Metres between line samples. Small enough that a corner is several samples
## wide, so the speed profile has something to shape.
const SAMPLE_SPACING := 4.0
## Laplacian passes used to smooth the junction-to-junction polyline. Enough to
## take the sawtooth out of a street grid so the driver is not hunting between
## apexes, and deliberately no more: smoothing is a low-pass filter, and pushed
## too far it rounds every corner off the circuit and leaves a smooth oval with
## no corners to brake for.
const SMOOTH_PASSES := 6
## Metres of inside bias at a corner, capped so the line cannot leave the road on
## a narrow street. The road width is not known per point here, so this is a
## fixed budget rather than "half the road".
const APEX_BUDGET := 1.6
const GRAVITY := 9.81

## Fraction of the friction circle a clean lap is assumed to use. Deliberately
## under the tyres' peak mu: a profile that asks for more grip than the car has
## is a profile the driver cannot hold, and an AI that cannot hold its line
## spends the lap in the recovery state.
const GRIP := 0.62

## Samples either side of a point used to measure its curvature. One sample is
## too tight: a corner rounded over three samples reads as three impossibly sharp
## corners, and the profile brakes for all of them.
const CORNER_BASELINE := 3

var points: Array = []        ## Array[Vector2], evenly spaced around the line
var speed: Array = []         ## Array[float] m/s the line allows at each point
var limit: Array = []         ## Array[float] m/s, the road's own speed limit
var width: Array = []         ## Array[float], road width in metres at each point
var spacing: float = SAMPLE_SPACING
var length: float = 0.0
var closed: bool = true

## How hard the line assumes the car can brake and accelerate, m/s^2. The driver
## scales these by skill before building.
var brake_decel: float = 9.0
var accel_rate: float = 6.0


static func from_route(route: Array, graph: RoadGraph, is_closed: bool) -> RacingLine:
	var line := RacingLine.new()
	line.closed = is_closed
	var raw := _resample(route, is_closed)
	if raw.size() < 4:
		return line
	var ring := raw.duplicate()
	_smooth(ring, is_closed)
	_apex(ring, is_closed)
	_clamp_to_streets(ring, raw, is_closed)
	line.points = ring
	var m: Dictionary = _measure(ring, is_closed)
	line.length = float(m["length"])
	line.spacing = maxf(float(m["spacing"]), 0.5)
	line._build_profile(graph)
	return line


# ------------------------------------------------------------------- geometry

## Even spacing along the route, so the speed profile means the same thing at
## every point and a car can be tracked by a moving index.
static func _resample(route: Array, is_closed: bool) -> Array:
	var src: Array = []
	for p in route:
		src.append(p if p is Vector2 else Vector2(p))
	if src.size() < 2:
		return src
	# find_loop hands back a closed ring with its first junction repeated at the
	# end; that duplicate is not a second sample.
	if is_closed and src[0].distance_to(src[src.size() - 1]) < 0.01:
		src.resize(src.size() - 1)
	if src.size() < 3:
		return src

	var total := 0.0
	for i in src.size():
		total += src[i].distance_to(src[(i + 1) % src.size()])
	if total < 1.0:
		return []
	var count: int = maxi(4, int(round(total / SAMPLE_SPACING)))
	var out: Array = []
	if is_closed:
		for k in count:
			out.append(_point_at(src, total * float(k) / float(count), true))
	else:
		count += 1
		for k in count:
			out.append(_point_at(src, total * float(k) / float(count - 1), false))
	return out


## Position `s` metres along the polyline.
static func _point_at(src: Array, s: float, wrap: bool) -> Vector2:
	var n := src.size()
	for i in n:
		var a: Vector2 = src[i]
		var b: Vector2 = src[(i + 1) % n]
		var seg: float = a.distance_to(b)
		if seg < 0.001:
			continue
		if s <= seg or (not wrap and i == n - 1):
			return a.lerp(b, clampf(s / seg, 0.0, 1.0))
		s -= seg
	return src[0]


## Laplacian smoothing: each point walks a fraction of the way toward the
## midpoint of its neighbours. A junction-to-junction polyline is all corners;
## this is what turns it into a line a car can actually hold.
static func _smooth(pts: Array, is_closed: bool) -> void:
	var n := pts.size()
	for _pass in SMOOTH_PASSES:
		var src: Array = pts.duplicate()
		for i in n:
			var a: Vector2 = src[(i - 1 + n) % n] if is_closed else src[maxi(i - 1, 0)]
			var b: Vector2 = src[(i + 1) % n] if is_closed else src[mini(i + 1, n - 1)]
			pts[i] = src[i].lerp((a + b) * 0.5, 0.5)


## Bias each corner toward its inside. Curvature is read off the smoothed line,
## so this adds a racing line's shape without needing the unsmoothed polyline.
static func _apex(pts: Array, is_closed: bool) -> void:
	var n := pts.size()
	var src: Array = pts.duplicate()
	for i in n:
		var a: Vector2 = src[(i - 1 + n) % n] if is_closed else src[maxi(i - 1, 0)]
		var b: Vector2 = src[i]
		var c: Vector2 = src[(i + 1) % n] if is_closed else src[mini(i + 1, n - 1)]
		var into: Vector2 = b - a
		var out: Vector2 = c - b
		if into.length_squared() < 0.001 or out.length_squared() < 0.001:
			continue
		# Positive cross product turns left, so the inside is to the left.
		var turn: float = into.normalized().cross(out.normalized())
		var amount: float = clampf(turn * APEX_BUDGET * 2.0, -APEX_BUDGET, APEX_BUDGET)
		var fwd: Vector2 = into.normalized() + out.normalized()
		if fwd.length_squared() < 0.001:
			continue
		pts[i] = b + fwd.normalized().orthogonal() * amount


## How far the smoothed line may stray from the street it came from.
##
## Smoothing is a low-pass filter and it does not know where the kerb is: given
## enough passes it rounds a corner by cutting the block behind it, and a driver
## that follows such a line faithfully drives across a city block. So every
## point is pulled back to within this of the route it was smoothed from, which
## is well inside even the narrowest lane.
const MAX_STREET_OFFSET := 2.5


## Pulls the smoothed line back onto the streets. The two lists are in the same
## order and the same spacing, so each point only has to look at its neighbours'
## worth of the original to find the street it belongs to.
static func _clamp_to_streets(pts: Array, raw: Array, is_closed: bool) -> void:
	var n := pts.size()
	var window: int = maxi(4, int(SMOOTH_PASSES))
	for i in n:
		var best := Vector2.ZERO
		var best_d := INF
		for k in range(-window, window + 1):
			# A closed line wraps around; an open one stops at its ends.
			var j: int = posmod(i + k, n) if is_closed else clampi(i + k, 0, n - 1)
			var d: float = pts[i].distance_squared_to(raw[j])
			if d < best_d:
				best_d = d
				best = raw[j]
		var off: Vector2 = pts[i] - best
		if off.length() > MAX_STREET_OFFSET:
			pts[i] = best + off.normalized() * MAX_STREET_OFFSET


## Length and mean spacing of the finished line. Smoothing shortens a line a
## little, so the spacing the profile was built with has to be the spacing the
## smoothed points actually ended up with, not the one they were sampled at.
static func _measure(pts: Array, is_closed: bool) -> Dictionary:
	var segs: int = pts.size() if is_closed else pts.size() - 1
	var total := 0.0
	for i in maxi(segs, 0):
		total += pts[i].distance_to(pts[(i + 1) % pts.size()])
	return {"length": total, "spacing": total / float(maxi(segs, 1))}


# -------------------------------------------------------------- speed profile

## The speed the line allows at every point: what the corner needs, what the road
## speed limit allows, then a braking pass backwards and an acceleration pass
## forwards so the profile is one a car can actually follow.
func _build_profile(graph: RoadGraph) -> void:
	var n := points.size()
	speed.clear()
	limit.clear()
	for i in n:
		var p: Vector2 = points[i]
		var near: Dictionary = graph.nearest_road(Vector3(p.x, 0.0, p.y))
		var cap: float = 30.0
		var w: float = 9.0
		if int(near["edge"]) >= 0:
			var cls: int = int(graph.edges[int(near["edge"])]["class"])
			cap = graph.speed_for(cls)
			w = graph.width_for(cls)
		limit.append(cap)
		width.append(w)
		speed.append(minf(cap, _corner_speed(i)))

	# Backwards: you must be slow enough NOW to make the next corner.
	var laps: int = 2 if closed else 1
	for _l in laps:
		for k in n:
			var i: int = (n - 1 - k) if closed else (n - 2 - k)
			if i < 0:
				break
			var j: int = (i + 1) % n
			speed[i] = minf(float(speed[i]), sqrt(pow(float(speed[j]), 2.0) + 2.0 * brake_decel * spacing))
	# Forwards: and you cannot be going that fast again the moment you exit.
	for _l in laps:
		for k in n:
			var i2: int = k if closed else k + 1
			if i2 >= n:
				break
			var j2: int = (i2 - 1 + n) % n
			speed[i2] = minf(float(speed[i2]), sqrt(pow(float(speed[j2]), 2.0) + 2.0 * accel_rate * spacing))


## Speed a curve of the local radius can be taken at, before the driver's skill
## and the road limit get a say.
func _corner_speed(i: int) -> float:
	var n := points.size()
	var k: int = CORNER_BASELINE
	var ia: int = (i - k + n) % n
	var ic: int = (i + k) % n
	var a: Vector2 = points[ia]
	var b: Vector2 = points[i]
	var c: Vector2 = points[ic]
	var ab: float = a.distance_to(b)
	var bc: float = b.distance_to(c)
	var ca: float = c.distance_to(a)
	if ab < 0.001 or bc < 0.001 or ca < 0.001:
		return 60.0
	# Menger curvature of the triangle, so a corner spread over several samples
	# is not read as three impossible corners.
	var area: float = absf((b - a).cross(c - a)) * 0.5
	var radius: float = (ab * bc * ca) / maxf(4.0 * area, 0.0001)
	return sqrt(GRIP * GRAVITY * maxf(radius, 1.0))


# -------------------------------------------------------------------- queries

func size() -> int:
	return points.size()


## Where a car is on the line. Searches a window either side of `from` so this
## is cheap per frame instead of re-scanning the whole line; the caller re-seeds
## `from` whenever the car teleports.
##
## `window` is in samples either side. The car itself only needs a couple -
## it is by definition near the last index - but looking up *another* car needs
## a lot more, and quietly handing back a nearby sample for a car 20 m up the
## road is how a driver ends up reasoning about a car that is not there.
func project(v: Vector2, from: int, window: int = 2) -> Dictionary:
	var n := points.size()
	if n < 2:
		return {"i": 0, "s": 0.0, "lateral": 0.0, "dir": Vector2.RIGHT}
	var best_i: int = clampi(from, 0, n - 1)
	var best := _closest_on(best_i, v)
	# Walk outwards while the line keeps getting nearer: the car is close to one
	# place on the line, not spread over it.
	for step in range(1, maxi(window, 1) + 1):
		var found := false
		for sign_i in [1, -1]:
			var j: int = best_i + sign_i * step
			if j < 0 or j >= n:
				continue
			var c := _closest_on(j, v)
			if c["d"] < best["d"]:
				best = c
				best_i = j
				found = true
		if not found and step >= maxi(window, 2):
			break
	var i2: int = best_i
	return {
		"i": i2,
		"s": float(i2) * spacing + float(best["t"]) * _seg_len(i2),
		"lateral": float(best["lateral"]),
		"dir": best["dir"],
	}


func _closest_on(i: int, v: Vector2) -> Dictionary:
	var n := points.size()
	var a: Vector2 = points[i]
	var b: Vector2 = points[(i + 1) % n]
	var ab: Vector2 = b - a
	var len2: float = ab.length_squared()
	if len2 < 0.0001:
		return {"d": INF, "t": 0.0, "lateral": 0.0, "dir": Vector2.RIGHT}
	var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
	var q: Vector2 = a + ab * t
	var off: Vector2 = v - q
	var dir: Vector2 = ab.normalized()
	return {
		"d": off.length_squared(),
		"t": t,
		"lateral": off.dot(dir.orthogonal()),
		"dir": dir,
	}


func _seg_len(i: int) -> float:
	var n := points.size()
	return points[i].distance_to(points[(i + 1) % n])


## The fastest the car may be going *here* and still make every corner within
## `ahead_m`, given the deceleration it is willing to use. This is what makes a
## driver brake before a corner rather than at it, and it is also the honest
## place for skill to live: a cautious driver plans with less deceleration, so it
## has to start slowing earlier for the same corner.
func allowed_speed(i: int, ahead_m: float, decel: float) -> float:
	var n := points.size()
	if n == 0:
		return 0.0
	var steps: int = clampi(int(round(ahead_m / maxf(spacing, 0.1))), 1, n - 1)
	var v: float = speed_at(i)
	for k in range(1, steps + 1):
		var j: int = (i + k) % n if closed else mini(i + k, n - 1)
		v = minf(v, sqrt(pow(float(speed[j]), 2.0) + 2.0 * decel * float(k) * spacing))
	return v


## Half the road width at a point, less a margin: how far off the centre line a
## car can sit and still be on the tarmac. Overtaking is decided against this.
func room_at(i: int) -> float:
	if width.is_empty():
		return 3.0
	return maxf(float(width[clampi(i, 0, width.size() - 1)]) * 0.5 - 0.9, 0.6)


func speed_at(i: int) -> float:
	if speed.is_empty():
		return 0.0
	return float(speed[clampi(i, 0, speed.size() - 1)])


func limit_at(i: int) -> float:
	if limit.is_empty():
		return 0.0
	return float(limit[clampi(i, 0, limit.size() - 1)])


## Road width at a point, in metres.
func width_at(i: int) -> float:
	if width.is_empty():
		return 9.0
	return float(width[clampi(i, 0, width.size() - 1)])


## A point on the line, pushed sideways. The lateral offset is what overtaking,
## defending and running wide are all built out of.
func point_at(i: int, lateral: float = 0.0) -> Vector2:
	var n := points.size()
	if n == 0:
		return Vector2.ZERO
	var k: int = ((i % n) + n) % n if closed else clampi(i, 0, n - 1)
	var p: Vector2 = points[k]
	if absf(lateral) < 0.001:
		return p
	var j: int = (k + 1) % n if closed else mini(k + 1, n - 1)
	var dir: Vector2 = (points[j] - p)
	if dir.length_squared() < 0.0001:
		return p
	return p + dir.normalized().orthogonal() * lateral


func direction_at(i: int) -> Vector2:
	var n := points.size()
	if n == 0:
		return Vector2.RIGHT
	var k: int = ((i % n) + n) % n if closed else clampi(i, 0, n - 1)
	var j: int = (k + 1) % n if closed else mini(k + 1, n - 1)
	var d: Vector2 = points[j] - points[k]
	return d.normalized() if d.length_squared() > 0.0001 else Vector2.RIGHT
