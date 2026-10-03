class_name LaneFollower
extends RefCounted
## Steers a car down a street, on the free side of it.
##
## Pure pursuit: aim at a point AHEAD on the lane and steer at that point. Plus a
## yaw-damping term. No cross-track term fighting a heading term.
##
## WHY IT IS BUILT THIS WAY, MEASURED (2026-10-03, t119/t121)
##
## The obvious controller - heading error to the street tangent, plus a
## proportional cross-track term - is what `Tools/playable_probe.gd` used, and on a
## dead straight it cannot hold a line. Worked out rather than guessed: with a
## heading gain of 2.4 per radian and a cross-track gain of 0.10 per metre, the
## equilibrium is
##
##     2.4 * heading_error + 0.10 * lateral_error = 0
##
## so the car settles at a steady heading error of `(0.10/2.4) * lateral_error`
## radians - about **7.3 degrees at 3 m off line**, and the error grows in
## proportion to how far off line it already is. A straight road has no curvature
## to correct that heading against, so it integrates: on Hoare Street's 1344 m
## dead-straight fragment the car was 3.07 m off its target after 4.2 s, clipped a
## prop by 0.05 m at 115 km/h, was off the road by s=453 and in a building by
## s=464. Mean |lat| over the run was 19.23 m against a -4.25 m target.
##
## The cure is not a bigger cross-track gain. Raising it 0.10 -> 0.25 was measured
## and it **diverges**: mean |lat| 28.90 m, 44.04 m off the centreline, stopping at
## s=420 m of an 824.5 m street. A gain this loop cannot tolerate is not a weak
## default, it is the stability limit, and the reason is on display above - the two
## terms fight, so more of the weak one is more fighting.
##
## Pure pursuit has no such pair to fight. There is one demand - point at the lane
## a little way ahead - and it goes to zero as the car converges, so lateral error
## cannot buy its way into a standing heading error. The yaw-damping term is there
## because pure pursuit alone oscillates when the look-ahead is short relative to
## the speed, and an oscillating driver is its own defect.
##
## ## What this does and does not fix
##
## It fixes a straight line, and it makes a curve smoother. It does NOT know where
## the free space is: `lane_offset` is set by the caller from a measurement (see
## `Tools/street_blockers.gd`), because only the physics server knows which kerb has
## the palms on it. This follower will happily hold a lane straight through a tree
## if it is told to.

## Aim point this far ahead as a floor, and this much more per m/s, capped.
## Short at parking speed so it does not saw at the wheel, long at speed so it
## does not weave. Same shape and the same numbers as `AIRacer`, deliberately: the
## AI and this follower should not disagree about what "looking ahead" means.
const LOOKAHEAD_MIN := 6.0
const LOOKAHEAD_PER_MPS := 0.6
const LOOKAHEAD_MAX := 26.0

## Steer per radian of angle to the aim point. Positive steer is a LEFT turn on
## CarBody - it yaws from -Z toward -X - so the aim angle is negated. Derived from
## the physics rather than from a remembered sign: the opposite convention drives a
## car away from its lane and looks like a broken car rather than a sign error.
const AIM_GAIN := 2.6

## Largest aim angle pure pursuit will chase, in radians.
##
## `atan2` returns anything up to +/-PI/2 when the aim point is abeam or behind,
## and at AIM_GAIN 2.6 that is a demand for full lock and then some. A car that
## points away from its aim point therefore sits at full lock **permanently** and
## describes a circle: measured, the first version of this follower left the road
## 2.4 s after the start and ended 150 m off the line, having driven 571 m of path
## to reach s=389 m. Bounding the angle is the standard remedy and it is a defect
## fix rather than a tune - the failure is structural, not a matter of level.
const AIM_ANGLE_MAX := 0.60

## How far either side of the seed `project()` will look, in METRES OF ARC LENGTH.
##
## DERIVED, NOT CHOSEN. The follower asks `project()` where the car is once per
## physics step, and then uses that `s` for exactly two things: `aim_at(s)` as the
## car's position, and `aim_at(s + lookahead_for(v))` as the aim point. The furthest
## along the line the driver ever *uses* is therefore `s + LOOKAHEAD_MAX`. Looking
## any further ahead cannot change a steering command, so a window of LOOKAHEAD_MAX
## metres ahead is not a tuning compromise - it is the whole of the used range.
##
## The same distance BEHIND the seed, and for the opposite reason: after a shunt or
## a spin the car can be a long way behind where the driver last thought it was,
## and a window that only looked forward would report a stale `s` and aim forward
## of a car that is already pointing backwards.
##
## Measured justification for it being large enough: at 60 Hz a car at 200 km/h
## covers 0.93 m per step, so consecutive seeds are under a metre apart, and
## LOOKAHEAD_MAX is 26 m - about 28 steps of slack. It is small against a lap
## (1760 m on the test circuit), which is the entire point: the failure being fixed
## was the scan reaching 135 m away onto another leg of the lap.
const WINDOW_M := LOOKAHEAD_MAX

## Beyond this, the driver has genuinely MOVED rather than projected, and the
## search is widened. See `advance_to`.
const RESEED_DIST := 40.0

## How FAR the widened search looks, in metres of arc length. NOT infinite.
##
## An unbounded re-seed is what t124 tried and reverted: it changed nothing, so that
## path was not on the one that mattered. It is still the wrong shape - on a line
## that approaches itself a global scan can hand back a point on a different leg, which
## is the failure the window exists to prevent - so the widened search stays bounded.
## 200 m is about one second of travel at 200 km/h, which covers a car that has been
## flung or reset; a car further off the line than that is genuinely off it, and the
## right response is to rebuild the lane, which `AIRacer.reset()` does.
const RESEAT_WINDOW_M := 200.0

## Steer per rad/s of yaw, subtracted. Yawing left makes yaw positive and positive
## steer yaws left, so damping is subtraction. At 0 this is plain pure pursuit and
## it oscillates at speed; measured on Hoare, pure pursuit alone weaves with a
## mean |steer| well below 1.0 but a lateral error that never settles.
const YAW_DAMP := 0.35

## Speed, in m/s, below which the aim angle is faded out. Walking pace, deliberately.
##
## This replaces a YAW-RATE floor, which was the right idea applied to the wrong
## quantity and switched the follower off in normal use. A pursuit controller's aim
## angle has to be faded at a standstill, where any correction is noise; fading it
## by yaw rate instead looks like the same thing and is not. **On a straight road at
## speed the yaw rate is zero** - that is what straight means - so a yaw-rate fade
## removes the follower's entire lateral authority at precisely the moment it is
## needed. Measured: with a yaw-rate floor of 0.13 rad/s the car held a mean |lat|
## of 0.26 m against a 4.25 m target, i.e. it drove the CENTRELINE, and stopped dead
## on the prop that blocks the centreline at s=168.5 m of 1407.5 m.
##
## Speed is the right gate because the thing being suppressed - jitter from a car
## that is not going anywhere - is a function of not going anywhere.
const SPEED_FLOOR := 3.0

## How far the lane's tangent may turn over one look-ahead and still count as
## "straight" for `verify()`. 0.05 rad is 2.9 degrees, which at a 12 m look-ahead
## is 1.0 m of lateral lane movement - below that the lane is straight for the
## purposes of "a car sitting on it should not be steering".
##
## Checked rather than assumed: Aumuller's only interior vertex turns 2.1 degrees,
## so all 24 of its samples are correctly classified straight, and Hoare has one
## sample over tolerance out of 24. The classifier is not quietly excluding corners
## on the street where it matters.
const STRAIGHT_TOL_RAD := 0.05

## Upper bound on the steer a correct follower asks for on a straight, in units of
## full lock. See `verify()` for why this is not zero.
const STRAIGHT_STEER_MAX := 0.25

## The lane, and how far along it. Array[Vector2], the polyline being followed.
var pts := PackedVector2Array()
var _cum := PackedFloat32Array()
var _total := 0.0
var closed := false

## Metres from the centreline to the lane, POSITIVE TO THE RIGHT OF TRAVEL.
##
## This is the offset `Tools/street_blockers.gd` reports, on the same axis (its
## `right` is `(tan.y, -tan.x)`). On both streets measured so far the clear band
## is +2.5 .. +6.0 m, because the palms are all on the other kerb. The middle of
## that band is the default.
var lane_offset := 4.25

## Which segment the last `project()` call landed on. The window is centred here.
##
## State, not a constant: this class is one car at a time, and a second car on the
## same lane would need its own follower or an explicit `hint` on every call.
var _seed := 0
## Where the car was the last time the driver advanced. The re-seed escape compares
## against this, so it fires on the car having MOVED rather than on anyone having
## PROJECTED. Zero means "no advance yet".
var _last_advance := Vector3.ZERO

## Public read of the window seed. Public because "is this caller's seed where I left
## it" is a question a self-check has to be able to ask, and reading a private field
## from a test is not an answer.
func seed_index() -> int:
	return _seed

## The state `project()` must NOT touch, for a purity check. A query that changes
## the seed is a query that is also a driver input.
##
## Deliberately only the seed. Memoising the last RESULT inside `project()` would be
## the same sin wearing a different hat, and a purity check that permits it is not
## checking purity.
func debug_state() -> Dictionary:
	return {"seed": _seed}

## Largest steer this follower will ever ask for. Reported, not hidden.
var peak_steer := 0.0
var last_aim := Vector3.ZERO


## Hand it a street or a lap. Cumulative distances are built once here so
## `project()` and `aim_at()` are walks and not a re-measure every frame.
##
## On a CLOSED lane the closing segment (last point back to first) counts towards
## the length and appears in the cumulative table, and `aim_at` WRAPS rather than
## clamps - a driver on a lap has to be able to aim past the start line, and a
## clamp would quietly aim it at the far end of the lap instead, which on a street
## circuit is a different part of the road.
func set_lane(points: PackedVector2Array, is_closed: bool = false) -> void:
	pts = points
	closed = is_closed
	var n := pts.size()
	_cum = PackedFloat32Array()
	_cum.resize(n + 1)
	_total = 0.0
	for i in n:
		_cum[i] = _total
		var j: int = ((i + 1) % n) if closed else mini(i + 1, n - 1)
		_total += pts[i].distance_to(pts[j])
	_cum[n] = _total
	_seed = 0
	_last_advance = Vector3.ZERO
	peak_steer = 0.0


func length() -> float:
	return _total


## Distance along the lane of `p`, its signed offset from it, the unit tangent
## there, and the index of the segment it landed on. **PURE: it changes nothing.**
##
## PURE, and that is the fix rather than a detail. This used to write the window
## seed as a side effect, which made every non-driving caller a driver input:
## `verify()` calls it 24 times and walked the seed into the middle of a 2790 m line
## while the car sat at s=8, after which the follower aimed 177 degrees off the car's
## nose, held full lock, the car rotated on the spot, Godot put the RigidBody3D to
## sleep, and 3 kN of tyre force went into an inert body. Measured: `speed_mps`
## 15.69 with the self-check afterwards, 0.0534 with it beforehand.
##
## A self-check, a diagnostic and a telemetry frame are all callers, and none of them
## is the driver. Reading the lane and advancing along it are different operations
## and they now have different entry points: `project()` for the first,
## `advance_to()` for the second, and only the second touches the seed.
##
## `hint` is the seed to search around. Pass -1 (the default) for the one this
## follower holds. Neither value is written back.
func project(p: Vector3, hint: int = -1) -> Dictionary:
	if pts.size() < 2:
		return {"s": 0.0, "lat": 0.0, "t": Vector2(1, 0), "i": 0, "dist": INF}
	var seed := _seed if hint < 0 else _wrap(clampi(hint, 0, pts.size() - 1))
	return _scan(seed, p, WINDOW_M)


## Project AND move the driver's seed. The driving path, and the only one allowed
## to change state.
##
## The re-seed escape stays, and it now fires on **MOTION** rather than on
## projection: if the car has travelled further than `RESEED_DIST` since the last
## advance, the window is centred where it used to be and cannot be trusted, so the
## search is widened. Firing it on projection instead - which is what it did, since
## every projection went through the same path - meant a self-check could trigger it,
## and a global scan on a self-approaching line can return a point on a different leg.
func advance_to(p: Vector3, hint: int = -1) -> Dictionary:
	if pts.size() < 2:
		return {"s": 0.0, "lat": 0.0, "t": Vector2(1, 0), "i": 0, "dist": INF}
	var seed := _seed if hint < 0 else _wrap(clampi(hint, 0, pts.size() - 1))
	var found := _scan(seed, p, WINDOW_M)
	if _last_advance != Vector3.ZERO and p.distance_to(_last_advance) > RESEED_DIST:
		found = _scan(int(found["i"]), p, RESEAT_WINDOW_M)
	_seed = int(found["i"])
	_last_advance = p
	return found


## Nearest point to `p` within `window_m` of arc length either side of segment
## `from`. Walks outward in both directions and stops when the arc budget is spent,
## which is what keeps a closed loop from being re-scanned every frame.
func _scan(from: int, p: Vector3, window_m: float) -> Dictionary:
	var best := _closest_on(from, p)
	var spent := 0.0
	var step := 1
	while spent < window_m and step < pts.size():
		var moved := false
		for direction in [1, -1]:
			var j := _wrap(from + direction * step)
			if j == int(best["i"]) and step > 1:
				continue
			var c := _closest_on(j, p)
			if c["d"] < float(best["d"]):
				best = c
				moved = true
		spent += _seg_len(int(best["i"])) * float(step)
		step += 1
		if not moved and step > 2:
			# The nearest point has stopped improving and the arc budget is spent;
			# walking the rest of a lap would cost O(n) per frame for nothing.
			if spent >= window_m:
				break
	return _finish(best)


## Wrap a segment index on a closed lane, clamp it on an open one.
func _wrap(i: int) -> int:
	var n := pts.size()
	if closed:
		return ((i % n) + n) % n
	return clampi(i, 0, n - 1)


## Index of the segment containing distance `s` along the lane. Used by `verify()`
## to hand `project()` an honest seed, since its samples are far apart.
func _segment_at(s: float) -> int:
	if pts.size() < 2:
		return 0
	var d: float = fposmod(s, _total) if closed and _total > 0.0001 else clampf(s, 0.0, _total)
	for i in pts.size() - 1:
		if _cum[i + 1] >= d:
			return i
	return pts.size() - 2


func _seg_len(i: int) -> float:
	var n := pts.size()
	if n < 2:
		return 0.0
	return pts[i].distance_to(pts[_wrap(i + 1)])


## Nearest point to `p` on one segment. Same shape as `RacingLine._closest_on`,
## and the same normal: `orthogonal()`, so `lat` is measured on the axis
## `lane_offset` is expressed in.
func _closest_on(i: int, p: Vector3) -> Dictionary:
	var n := pts.size()
	var a := pts[i]
	var b := pts[_wrap(i + 1)]
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.0001:
		return {"d": INF, "t": 0.0, "lat": 0.0, "tan": Vector2(1, 0), "i": i, "dist": INF}
	var v := Vector2(p.x, p.z)
	var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
	var q := a + ab * t
	var off := v - q
	var seg := sqrt(len2)
	var tan: Vector2 = ab / seg
	return {
		"d": off.length_squared(),
		"t": t,
		"lat": off.dot(_right(tan)),
		"tan": tan,
		"i": i,
		"dist": off.length(),
		"s": _cum[i] + seg * t,
	}


## The dictionary `project` hands back, derived from one segment's nearest point.
func _finish(c: Dictionary) -> Dictionary:
	var tan: Vector2 = c["tan"]
	return {"s": float(c["s"]), "lat": float(c["lat"]), "t": tan,
		"i": int(c["i"]), "dist": float(c["dist"])}


## Right of travel, in the same handedness `lane_offset` is measured on.
static func right_of(tangent: Vector2) -> Vector2:
	return Vector2(tangent.y, -tangent.x)


func _right(tangent: Vector2) -> Vector2:
	return Vector2(tangent.y, -tangent.x)


## The lane point `s` metres along, offset `lane_offset` to the right of travel,
## at `height`. Where the driver is actually aiming.
##
## Wraps on a closed lane, clamps on an open one - see `set_lane`.
func aim_at(s: float, height: float) -> Vector3:
	var d: float = s
	if closed and _total > 0.0001:
		d = fposmod(s, _total)
	elif _total > 0.0001:
		d = clampf(s, 0.0, _total)
	for i in pts.size() - 1:
		if _cum[i + 1] >= d or i == pts.size() - 2:
			# The SEGMENT length, not `_cum[i]` and not its square root.
			#
			# `_cum[i]` is the distance to the START of this segment, so dividing by
			# it is wrong; and `sqrt(_cum[i + 1] - _cum[i])` is worse than wrong,
			# because it is only right when the cumulative distance happens to equal
			# the segment length squared. On Hoare's first segment (30.9 m long,
			# starting at s=0) it gave a tangent 5.56x too long, so the lane offset
			# was applied along a non-unit vector and the aim point landed 23.6 m
			# from the centreline instead of 4.25. Nothing errored: the car was
			# simply spawned in a field and drove off into a building.
			var seg: float = maxf(_cum[i + 1] - _cum[i], 0.0001)
			var u: float = clampf((d - _cum[i]) / seg, 0.0, 1.0)
			var p: Vector2 = pts[i].lerp(pts[i + 1], u)
			var tan: Vector2 = (pts[i + 1] - pts[i]) / seg
			p += _right(tan) * lane_offset
			return Vector3(p.x, height, p.y)
	var p2: Vector2 = pts[pts.size() - 1]
	return Vector3(p2.x, height, p2.y)


## Look-ahead for a speed, in metres.
func lookahead_for(speed_mps: float) -> float:
	return clampf(LOOKAHEAD_MIN + speed_mps * LOOKAHEAD_PER_MPS, LOOKAHEAD_MIN, LOOKAHEAD_MAX)


## The steer command, in [-1, 1], for a car at `pos` facing `forward`.
##
## One demand only: point the front of the car at the lane ahead of it. There is no
## second term to fight this one, which is the entire point - see the header.
## `advance` false makes this a PURE query: it answers "what steer would this pose
## get" without moving the seed.
##
## Needed because `verify()` asks exactly that question, 24 times, and asking it used
## to retarget the driver - the same defect one level up. A question with no side
## effect is worth having even when the caller already knows not to keep the answer;
## the caller that did not know was the whole bug.
func steer_for(pos: Vector3, forward: Vector3, yaw_rate: float, speed_mps: float,
		advance: bool = true, hint: int = -1) -> float:
	if pts.size() < 2:
		return 0.0
	# `advance_to`, not `project`: steering is the one caller that is allowed to move
	# the seed. Everything else - `verify`, a diagnostic, telemetry - reads, and
	# `hint` is how a caller that is NOT the driver says where it is looking, since
	# the follower's own seed deliberately no longer moves for it.
	var here: Dictionary = advance_to(pos, hint) if advance else project(pos, hint)
	var ahead: Vector3 = aim_at(float(here["s"]) + lookahead_for(speed_mps), pos.y)
	last_aim = ahead

	var to := ahead - pos
	to.y = 0.0
	if to.length_squared() < 0.04:
		# Standing on the aim point: the only useful demand left is "stop rotating",
		# which is what keeps a car that has arrived from sawing at the wheel.
		return clampf(-YAW_DAMP * yaw_rate, -1.0, 1.0)

	# Angle to the aim point in the car's own frame. `basis.inverse() * to` puts +X
	# to the car's right, so a point to the right is local.x > 0, and positive steer
	# is a LEFT turn, hence the negation. Deriving it from the transform is the
	# point: hard-coding the opposite sign gives a car that drives away from its lane
	# and reads as an undrivable car.
	var basis: Basis = _basis_from(forward)
	var local: Vector3 = basis.inverse() * to
	var aim_angle := clampf(atan2(local.x, -local.z), -AIM_ANGLE_MAX, AIM_ANGLE_MAX)

	# Fade the angle out below walking pace rather than normalising by speed, which
	# would be a division by zero at a standstill. Gated on SPEED, not on yaw rate -
	# see SPEED_FLOOR for why that distinction is the whole ballgame.
	var eff := aim_angle
	if speed_mps < SPEED_FLOOR:
		eff *= clampf(speed_mps / SPEED_FLOOR, 0.0, 1.0)

	var steer: float = clampf(-eff * AIM_GAIN - YAW_DAMP * yaw_rate, -1.0, 1.0)
	peak_steer = maxf(peak_steer, absf(steer))
	return steer


## A level basis whose -Z is `forward`. Built rather than taken from a transform so
## a caller can feed a bare Vector3 - which is all a measurement harness has, and
## all it should have to know.
func _basis_from(forward: Vector3) -> Basis:
	var f := forward
	f.y = 0.0
	if f.length_squared() < 0.000001:
		return Basis.IDENTITY
	f = f.normalized()
	var right := Vector3(-f.z, 0.0, f.x)
	return Basis(right, Vector3.UP, -f)


## Checks the follower's own geometry, and returns what it found.
##
## These exist because of a bug this file shipped for one run: `aim_at` divided a
## polyline segment by `sqrt(cumulative_distance)` instead of by the segment length,
## which made the tangent 5.56x too long, put the lane offset 23.6 m from the
## centreline instead of 4.25, and drove the car into a field. Nothing errored and
## no assertion fired - the numbers were plausible and the output looked like a
## driver making a mess of a street.
##
## So the invariant is pinned here: **the aim point must project back to
## `lane_offset`.** If the tangent is not a unit vector, or the offset is applied
## along the wrong axis, or the offset is applied twice, this reports it. A caller
## that cannot afford to trust the follower reads this; a test can assert on it.
func verify(samples: int = 24) -> Dictionary:
	var fails: Array[String] = []
	var worst_lat := 0.0
	var worst_at := -1.0
	var worst_len := 0.0
	var worst_steer := 0.0
	var straight := 0
	var curving := 0
	if pts.size() < 2:
		return {"ok": false, "fails": ["no lane"], "worst_lat": 0.0}

	# Walk the stations in order AND carry the segment index, passing it as an
	# explicit hint.
	#
	# Not tidiness. `project()` without a hint uses the seed the follower already
	# holds, and `verify()` samples this line every `_total / samples` metres -
	# 116 m on a 2790 m lap - which is four times the 26 m window. So the seed is
	# always stale by the time each probe runs, the `RESEED_DIST` escape fires, and
	# `verify()` measures a GLOBAL scan on a line that passes close to itself. That
	# is how it reported the aim point 7.4 m from the lane while the windowed round
	# trip was 0.00 m out: the check was auditing the thing that had been fixed
	# instead of the fix.
	var idx := 0
	for k in samples:
		var s: float = _total * (float(k) + 0.5) / float(samples)
		var aim: Vector3 = aim_at(s, 0.0)
		idx = _segment_at(s)
		# 1. The aim point is where it claims to be, laterally.
		var back: Dictionary = project(aim, idx)
		var lat := absf(float(back["lat"]) - lane_offset)
		if lat > worst_lat:
			worst_lat = lat
			worst_at = s
		# 2. The tangent the projection returns is a unit vector. A non-unit tangent
		#    is the signature of dividing by the wrong length, which is the bug this
		#    whole check exists for.
		var t: Vector2 = back["t"]
		worst_len = maxf(worst_len, absf(t.length() - 1.0))

		# 3. Standing ON the lane and pointing down it, the follower must not ask to
		#    steer - but ONLY where the lane is straight. On a corner the lane turns,
		#    so a correct follower is *supposed* to be steering, and this check
		#    originally asserted zero everywhere and failed on Hoare's two corners
		#    with a saturated 1.000. An invariant that is only true on straights
		#    has to say so, and has to report how many samples it skipped, or it is
		#    a check that will be "fixed" by loosening a number with nothing said.
		var look: float = lookahead_for(10.0)
		var ahead_t: Vector2 = project(aim_at(s + look, 0.0), idx)["t"]
		if acos(clampf(t.normalized().dot(ahead_t.normalized()), -1.0, 1.0)) > STRAIGHT_TOL_RAD:
			curving += 1
			continue
		straight += 1
		var fwd := Vector3(t.x, 0.0, t.y)
		# Pure: `verify()` is a self-check and must not be a driver input.
		var steer: float = steer_for(aim, fwd, 0.0, 10.0, false, idx)
		worst_steer = maxf(worst_steer, absf(steer))

	if worst_lat > 0.25:
		fails.append("aim_at is %.2f m from the lane it should be on (worst at s=%.1f m, wanted %+.2f)" % [
			worst_lat, worst_at, lane_offset])
	if worst_len > 0.01:
		fails.append("projection tangent is not a unit vector (worst |len|-1 = %.4f)" % worst_len)
	if straight > 0 and worst_steer > STRAIGHT_STEER_MAX:
		fails.append("a car sitting on a STRAIGHT part of the lane is told to steer %.3f, over the %.2f bound (%d straight samples)" % [worst_steer, STRAIGHT_STEER_MAX, straight])
	if straight == 0:
		fails.append("no straight samples to check - the whole lane curves at this look-ahead")
	return {"ok": fails.is_empty(), "fails": fails,
		"worst_lat_m": worst_lat, "worst_tangent_len_err": worst_len,
		"worst_steer_on_straight": worst_steer,
		"straight_steer_bound": STRAIGHT_STEER_MAX,
		"straight_tol_rad": STRAIGHT_TOL_RAD,
		"straight_samples": straight, "curving_samples": curving}


## Everything a caller needs to judge a run, so two runs can be compared without
## reading prose.
func telemetry() -> Dictionary:
	return {
		"lane_offset_m": lane_offset,
		"lane_length_m": _total,
		"aim_gain": AIM_GAIN,
		"aim_angle_max_rad": AIM_ANGLE_MAX,
		"yaw_damp": YAW_DAMP,
		"lookahead_min_m": LOOKAHEAD_MIN,
		"lookahead_max_m": LOOKAHEAD_MAX,
		"speed_floor_mps": SPEED_FLOOR,
		"peak_steer": peak_steer,
	}