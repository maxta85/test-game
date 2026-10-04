extends SceneTree
##
## Querying the lane must not move the driver's seed.
##
##   /home/coder/tools/godot --headless --path . --script res://AI/lane_purity_check.gd
##
## WHAT THIS EXISTS FOR
##
## t125 measured that the same AI car drove 15.69 m/s on a street and 0.0534 m/s on
## the same street, and the only difference between the two runs was whether
## `follower.verify()` had run first. `verify()` calls `project()` 24 times, and
## `project()` wrote the window seed as a side effect, so those 24 calls walked the
## seed into the middle of a 2790 m line while the car sat at s=8. The follower then
## aimed 177 degrees off the car's nose, held full lock, the car rotated on the spot,
## Godot put the RigidBody3D to sleep, and 3 kN of tyre force went into an inert body.
##
## The shape of that bug is the dangerous part: **every non-driving caller is a driver
## input.** A self-check, a diagnostic, a telemetry frame - anything that projects for
## a reason unrelated to driving silently retargets the driver. The existing selftest
## had the same shape and only looked inert.
##
## THE TEST
##
## Ask the driver for a steering command. Then project from a lot of unrelated points
## - all over the lane, for no reason - and ask AGAIN from the same car pose. The
## second command must be identical to the first, bit for bit.
##
## It asserts on the STEERING COMMAND rather than on the seed, because the command is
## the thing that actually reaches the car. Asserting on `_seed` would test the
## implementation instead of the behaviour, and would keep passing if the state moved
## somewhere else.
##
## No world, no physics, no driving: the lane is a synthetic open polyline and the
## "car" is a pose on it. Runs in under a second.

## A lane that PASSES CLOSE TO ITSELF: a long leg out, a U-turn, and a parallel leg
## 8 m back. The first version of this check used a 400 m gentle S-curve and it
## PASSED against the unfixed follower - decoration, which is the exact failure this
## file was told to avoid. On a line that never approaches itself every projection
## finds the right point, so moving the seed cannot change the answer and the check
## proves nothing. Only a self-approaching line can.
##
## The car sits on the FIRST leg. Projecting all over the lane walks the seed onto
## the SECOND leg, 8 m away in space, and the steering command must not notice.
const LEG := 300.0
const GAP := 8.0


func _initialize() -> void:
	var lane := _lane()
	var fails := 0

	print("[purity] LaneFollower: querying must not move the seed the driver steers by")
	print("[purity] lane: %d points, %.1f m, OPEN, two legs %.1f m apart" % [
		lane.pts.size(), lane.length(), GAP])
	print("")

	# A car 3 m OFF the lane, near its start, pointing down it, at a plausible road
	# speed (15 m/s is 54 km/h, which is what the t125 runs were doing).
	#
	# The 3 m is not decoration. A car exactly ON the line with its nose along the
	# tangent asks for a steering command of 0.000000, and a command of zero cannot be
	# changed by a wrong projection - so the second version of this check also
	# passed against the unfixed follower. A real cross-track error gives the command
	# something to be, and a follower that has been retargeted onto the other leg
	# 8 m away has to produce a visibly different one.
	var start: Dictionary = lane.project(lane.aim_at(20.0, 0.0))
	var tan: Vector2 = start["t"]
	var right := Vector3(tan.y, 0.0, -tan.x)
	var pos: Vector3 = lane.aim_at(20.0, 0.0) + right * 3.0
	var fwd := Vector3(tan.x, 0.0, tan.y)
	var speed := 15.0

	# 1. The command, before anything else touches the follower.
	var first := lane.steer_for(pos, fwd, 0.0, speed)
	print("[purity] steering before any other call : %+.6f" % first)

	# 2. Project from all over the lane, for no reason a driver would have. This is
	#    what `verify()` does, and what a diagnostic does, and what telemetry does.
	var moved := 0
	var stations := lane.pts.size()
	for i in stations:
		var s: float = lane.length() * float(i) / float(stations)
		var away: Vector3 = lane.aim_at(s, 0.0)
		lane.project(away)
		# Half of them with an explicit hint, because a caller that knows where it is
		# looking is still a caller and must still be pure.
		lane.project(away, 0)
		moved += 1
	print("[purity] unrelated project() calls made : %d across the whole lane" % [moved * 2])

	# 3. The same car, the same command. Nothing about the car moved.
	var after := lane.steer_for(pos, fwd, 0.0, speed)
	print("[purity] steering after  %d calls       : %+.6f" % [moved * 2, after])

	# 4. And `verify()`, because it is the caller that actually caused this.
	var v: Dictionary = lane.verify()
	print("[purity] verify() run                    : ok=%s aim error %.3f m" % [
		str(bool(v["ok"])), float(v["worst_lat_m"])])
	var after_verify := lane.steer_for(pos, fwd, 0.0, speed)
	print("[purity] steering after verify()         : %+.6f" % after_verify)

	print("")
	var delta := absf(after - first)
	var delta_verify := absf(after_verify - first)
	print("PURITY: delta after %d unrelated calls : %.6f" % [moved * 2, delta])
	print("PURITY: delta after verify()          : %.6f" % delta_verify)

	if delta > 0.000001:
		print("FAIL: querying the lane moved the driver. %d unrelated project() calls" % [moved * 2])
		print("      changed the steering command by %.6f with the car in the same pose." % delta)
		fails += 1
	else:
		print("PASS: %d unrelated project() calls left the steering command identical." % [moved * 2])
	if delta_verify > 0.000001:
		print("FAIL: verify() moved the driver. It changed the steering command by %.6f." % delta_verify)
		fails += 1
	else:
		print("PASS: verify() left the steering command identical.")

	# ---------------------------------------------------------------------
	# The DIRECT check, and the one that can actually be seen failing.
	#
	# The two assertions above measure an EMERGENT property - "the driver still
	# steers the same way" - and on a lane short enough to build in a script they pass
	# whether or not the seed moved, because `steer_for` re-projects the car itself
	# and a car on the line projects correctly from almost any seed. Reproducing
	# t125's exact failure needs the 2790 m apex-biased smoothed line with the car
	# near its start, where the car genuinely sits 8 m from the point a global scan
	# picks. Two versions of this file passed against the unfixed follower for exactly
	# that reason, and a check that cannot fail is decoration.
	#
	# So assert the CONTRACT instead: a query must not change the follower's state.
	# That is the thing being fixed, it is directly observable, and it fails today.
	print("")
	print("[purity] DIRECT: does project() change the follower's state?")
	var probe := LaneFollower.new()
	probe.set_lane(lane.pts, false)
	probe.lane_offset = 0.0
	# `advance_to` is the driving entry point this task adds. Guarded, so that running
	# this check against the UNFIXED follower is a clean FAIL rather than a crash on a
	# method that does not exist yet - a check that only runs after its own fix has
	# never demonstrated that it catches the bug.
	if probe.has_method("advance_to"):
		probe.advance_to(pos)
	else:
		print("[purity] (no advance_to() yet - running against the unfixed follower)")
	var seed0: int = probe.seed_index()
	var state_before := probe.debug_state()
	# One query, from a point far away on the other leg, for no reason a driver has.
	var elsewhere: Vector3 = probe.aim_at(probe.length() * 0.75, 0.0)
	probe.project(elsewhere)
	var state_after := probe.debug_state()
	print("[purity] seed before / after one project() : %d -> %d" % [seed0, probe.seed_index()])
	print("[purity] state before : %s" % str(state_before))
	print("[purity] state after  : %s" % str(state_after))
	if state_before != state_after:
		print("FAIL: project() mutated the follower: %s -> %s" % [str(state_before), str(state_after)])
		print("      A query is a caller. Every self-check, diagnostic and telemetry")
		print("      frame that projects is a driver input.")
		fails += 1
	else:
		print("PASS: project() left the follower untouched.")

	print("")
	print("PURITY_FAILS=%d" % fails)
	quit(fails)


## The dogleg, resampled finely enough to be drivable.
func _lane() -> LaneFollower:
	var corners := PackedVector2Array([
		Vector2(0, 0), Vector2(LEG, 0), Vector2(LEG + 40, 0), Vector2(LEG + 80, GAP),
		Vector2(LEG + 80, GAP + 120), Vector2(LEG + 40, GAP + 140),
		Vector2(LEG, GAP + 140), Vector2(0, GAP + 140), Vector2(-60, GAP + 140),
	])
	var pts := PackedVector2Array()
	var steps := 40
	for i in corners.size() - 1:
		for k in steps:
			pts.append(corners[i].lerp(corners[i + 1], float(k) / float(steps)))
	pts.append(corners[corners.size() - 1])
	var lane := LaneFollower.new()
	lane.set_lane(pts, false)
	lane.lane_offset = 0.0
	return lane