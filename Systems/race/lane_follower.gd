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

## Largest steer this follower will ever ask for. Reported, not hidden.
var peak_steer := 0.0
var last_aim := Vector3.ZERO


## Hand it a street. Cumulative distances are built once here so `at()` is a walk
## and not a re-measure every physics frame.
func set_lane(points: PackedVector2Array, is_closed: bool = false) -> void:
	pts = points
	closed = is_closed
	_cum = PackedFloat32Array()
	_cum.resize(pts.size())
	_total = 0.0
	for i in pts.size():
		_cum[i] = _total
		if i + 1 < pts.size():
			_total += pts[i].distance_to(pts[i + 1])
	peak_steer = 0.0


func length() -> float:
	return _total


## Distance along the lane of `p`, its signed offset from it, and the unit tangent
## there. `s` grows along the lane regardless of which side the point is on.
func project(p: Vector3, hint: int = 0) -> Dictionary:
	var best_s := 0.0
	var best_lat := 0.0
	var best_t := Vector2(1, 0)
	var best_d := INF
	var best_i := 0
	var v := Vector2(p.x, p.z)
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		var proj := a + ab * t
		var w := v - proj
		var d := w.length()
		if d < best_d:
			best_d = d
			best_i = i
			best_s = _cum[i] + sqrt(len2) * t
			best_t = ab / sqrt(len2)
			best_lat = _right(best_t).dot(w)
	return {"s": best_s, "lat": best_lat, "t": best_t, "i": best_i, "dist": best_d}


## Right of travel, in the same handedness `lane_offset` is measured on.
static func right_of(tangent: Vector2) -> Vector2:
	return Vector2(tangent.y, -tangent.x)


func _right(tangent: Vector2) -> Vector2:
	return Vector2(tangent.y, -tangent.x)


## The lane point `s` metres along, offset `lane_offset` to the right of travel,
## at `height`. Where the driver is actually aiming.
func aim_at(s: float, height: float) -> Vector3:
	var d: float = clampf(s, 0.0, maxf(_total, 0.001))
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
func steer_for(pos: Vector3, forward: Vector3, yaw_rate: float, speed_mps: float) -> float:
	if pts.size() < 2:
		return 0.0
	var here := project(pos)
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

	for k in samples:
		var s: float = _total * (float(k) + 0.5) / float(samples)
		var aim: Vector3 = aim_at(s, 0.0)
		# 1. The aim point is where it claims to be, laterally.
		var back: Dictionary = project(aim)
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
		var ahead_t: Vector2 = project(aim_at(s + look, 0.0))["t"]
		if acos(clampf(t.normalized().dot(ahead_t.normalized()), -1.0, 1.0)) > STRAIGHT_TOL_RAD:
			curving += 1
			continue
		straight += 1
		var fwd := Vector3(t.x, 0.0, t.y)
		var steer: float = steer_for(aim, fwd, 0.0, 10.0)
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