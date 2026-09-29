class_name TrafficCar
extends RefCounted
## One civilian vehicle, as a route and a number.
##
## There is no RigidBody here and there never will be. A traffic car is a list
## of edge ids, a distance along that list, a lateral offset from the
## centreline and a speed - and its world position is *derived* from those four
## things every time you ask. That is what lets 200 of them run on the CPU
## alongside the player's physics without a single contact between them, and
## what lets the whole system be unit-tested headlessly in milliseconds.
##
## The split that matters: this class knows how to DRIVE (where am I, how fast
## should I be going, how hard do I brake for a wall this far ahead). The
## manager knows what IS in front. Nobody else has to care which is which, and
## a test can hand `tick()` an obstacle distance directly and watch the braking
## curve without spawning a whole city.
##
## ORIGINAL GAME CONTENT.

## Metres of clear road the car insists on keeping in front of its own bumper.
## Two cars nose to tail keep twice this, which reads as a real gap and is what
## stops the stream from locking solid at a red light.
const MIN_GAP := 2.0
## How far back from the stop line the car settles.
const STOP_SETBACK := 2.0
## Seconds spent crawling before it decides the lane it is in is the problem.
const STUCK_SECONDS := 5.0
## Seconds of headway a driver wants on a moving car ahead. Pure stopping-
## distance alone brakes a stopped queue to a standstill behind a car that is
## still moving, and the whole street stop-starts; the headway term is what
## keeps a convoy rolling.
const HEADWAY := 1.5
## Fraction of the tyre's grip a driver plans to use when stopping. Under 1.0
## on purpose: the theoretical minimum stopping distance is where a car is
## running out of road, not where a person starts braking. Planning to use
## 45% of the available deceleration means the brake goes on at roughly 1.5x
## the distance it strictly needs, which is what "early and predictable"
## actually looks like to somebody in the car behind.
const BRAKE_SAFETY := 0.45
## Fraction of drivers who obey the signals. Everyone else is a run-the-red,
## which the design brief asks for: perfectly obedient traffic is a video game
## artefact, and a city where nobody ever runs a light has no tension in it.
const OBEDIENT_FRACTION := 0.86

var graph: RoadGraph = null
var lights: TrafficLights = null
var spec: CarSpec = null

## Edge ids this car intends to drive, in order. Grown on demand.
var route: Array = []
## Index of the edge we are currently on.
var edge_i: int = 0
## Metres along the current edge, measured from the node we entered it by.
var along: float = 0.0
## True when travelling a->b on the current edge, false for b->a.
var from_a: bool = true
## Lane index, 0 being the one nearest the centreline (the fast lane). There
## are `lane_count()` of them in our direction, not `lanes` - see that function.
var lane: int = 0
## Metres right of the centreline. Positive because this is right-hand traffic.
var lateral: float = 0.0
## Where `lateral` is easing towards, so a lane change is a slide not a teleport.
var target_lateral: float = 0.0

var speed: float = 0.0
## The compliance roll, drawn once at spawn: 1.0 obeys the signals, below 1.0
## this driver runs reds. See OBEDIENT_FRACTION.
var obedience: float = 1.0
## Seconds spent crawling below walking pace. Reset when we get moving again.
var stuck_time: float = 0.0
## True when the last tick found something in front worth stopping for.
var blocked: bool = false

# --- driving character, derived once from the car's own numbers ------------
## m/s^2 off the line. Second-gear tractive force over mass - see _pull().
var accel: float = 2.5
## m/s^2 under braking. Grip and centre-of-gravity limited, so the tall loaded
## van sheds speed harder than the low hatchback on the same rubber.
var decel: float = 5.0
## Fraction of the posted limit this driver is content to do.
var cruise_factor: float = 0.9


# ------------------------------------------------------------------ lifecycle

## Puts a car on `edge` somewhere in the middle, pointing at the far end.
func place(g: RoadGraph, edge: int, forward_from_a: bool, distance: float) -> void:
	graph = g
	route = [edge]
	edge_i = 0
	from_a = forward_from_a
	along = clampf(distance, 0.0, maxf(graph.edge_length(edge) - 1.0, 0.0))
	lane = 0
	set_lane(0)
	speed = 0.0
	stuck_time = 0.0


## Gives the car its personality. Call once, after `place`.
func set_spec(s: CarSpec, rng: RandomNumberGenerator = null) -> void:
	spec = s
	if s == null:
		return
	accel = _pull(s) / s.mass
	# Grip and centre of gravity height, both of which the spec already has:
	# a tall loaded van sheds speed harder than a low hatchback for the same
	# rubber, which is exactly the difference a player feels rear-ending one.
	decel = maxf(2.4, 9.81 * s.tyre_peak_mu * 0.72
		* (1.0 - clampf((s.cg_height - 0.50) * 0.35, 0.0, 0.25)))
	# Somebody who accelerates slowly also cruises a long way under the limit.
	cruise_factor = clampf(0.42 + accel * 0.15, 0.45, 1.0)
	if rng != null:
		# Real drivers are not identical even in the same model year.
		cruise_factor = clampf(cruise_factor * rng.randf_range(0.90, 1.05), 0.4, 1.0)
		obedience = 1.0 if rng.randf() < OBEDIENT_FRACTION else 0.0
	else:
		obedience = 1.0


## Steady tractive force in newtons: what the gearbox and torque curve can put
## down in second gear, capped by what the tyres will hold.
##
## This is deliberately not CarSpec.zero_to_hundred(). That integrates an
## untraction-limited first gear, so it reports the same 2 s for an econobox and
## a supercar and cannot tell a tray truck from a city car. Second-gear pull is
## the number that describes how a car actually gets back up to speed in a
## queue, which is the only acceleration the traffic model ever asks about.
static func _pull(s: CarSpec) -> float:
	var share := 0.55                      # fraction of the car's mass on the driven axle
	if s.drive == "rwd":
		share = 1.0
	elif s.drive == "awd":
		share = clampf(s.torque_split + 0.35, 0.35, 0.9)
	var traction: float = s.tyre_peak_mu * s.mass * 9.81 * share
	var second: float = float(s.gears[2]) if s.gears.size() > 2 else float(s.gears[1])
	var peak := 0.0
	for point in s.torque_curve:
		peak = maxf(peak, float(point[1]))
	return minf(peak * s.final_drive * second * 0.88 / s.tyre_radius, traction)


## World position and heading as of the start of the current tick.
##
## `position()` and `heading()` are pure derivations from the graph, so they are
## always correct - but they walk four dictionaries each, and the manager needs
## both of them for every car in every query, every frame. `cache_transform()`
## fills these once per tick and everything downstream reads the fields.
## Anything that moves a car by hand must call `TrafficManager.reindex()`.
var pos: Vector3 = Vector3.ZERO
var fwd: Vector3 = Vector3.FORWARD

# ------------------------------------------------------------------- geometry

func edge() -> int:
	return int(route[edge_i])


func current() -> Dictionary:
	return graph.edges[edge()]


func edge_class() -> int:
	return int(current()["class"])


## Lanes available in ONE direction. The graph's `lanes` counts the whole road,
## both ways - Manunda's 9 m street is one lane each side of a centreline, not
## a four-lane divided - so the traffic carriageway is half of it. Capped
## against the road width so the outermost lane always stays on the tarmac.
func lane_count() -> int:
	return maxi(1, int(ceil(float(int(current()["lanes"])) * 0.5)))


func lane_width() -> float:
	var w: float = float(current()["width"])
	var lanes := maxf(1.0, float(int(current()["lanes"])))
	return minf(w / lanes, w * 0.5 / float(lane_count()))


## The node we came in by, and the node we are driving at.
func exit_node() -> int:
	var e: Dictionary = current()
	return int(e["b"]) if from_a else int(e["a"])


## Hot path. Computes both transforms from one pair of graph lookups rather
## than two, because the manager needs both of them for every car in every
## query, and RoadGraph's dictionaries are not free.
func cache_transform() -> void:
	var e: Dictionary = current()
	var a: Vector2 = graph.node_pos(int(e["a"]))
	var b: Vector2 = graph.node_pos(int(e["b"]))
	var d: Vector2 = (b - a) if from_a else (a - b)
	if d.length_squared() < 0.0001:
		d = Vector2(0.0, 1.0)
	d = d.normalized()
	fwd = Vector3(d.x, 0.0, d.y)
	var t: float = clampf(along / maxf(a.distance_to(b), 0.01), 0.0, 1.0)
	var centre: Vector2 = a.lerp(b, t) if from_a else a.lerp(b, 1.0 - t)
	pos = Vector3(centre.x, 0.0, centre.y) + Vector3(-fwd.z, 0.0, fwd.x) * lateral


## World position, derived. Never stored, never integrated, so it cannot drift
## away from the route the car thinks it is driving.
func position() -> Vector3:
	return point_at(graph.point_on_edge(edge(), along, from_a), heading())


func heading() -> Vector3:
	var e: Dictionary = current()
	var d: Vector2 = graph.node_pos(int(e["b"])) - graph.node_pos(int(e["a"]))
	if not from_a:
		d = -d
	if d.length_squared() < 0.0001:
		return Vector3.FORWARD
	d = d.normalized()
	return Vector3(d.x, 0.0, d.y)


## Offsets a centreline point sideways. Positive is to the driver's right.
func point_at(centre: Vector3, fwd: Vector3) -> Vector3:
	return centre + Vector3(-fwd.z, 0.0, fwd.x).normalized() * lateral


func set_lane(l: int) -> void:
	lane = clampi(l, 0, lane_count() - 1)
	target_lateral = (float(lane) + 0.5) * lane_width()


func speed_limit() -> float:
	return graph.speed_for(edge_class())


## The speed this driver would like to be doing, unobstructed.
func cruise_speed() -> float:
	return maxf(1.0, speed_limit() * cruise_factor)


func half_length() -> float:
	return 0.5 * (spec.body_length if spec != null else 4.5)


# --------------------------------------------------------------------- driving

## Moves the car forward, and turns it at junctions.
##
## `gap` is clear road ahead of the front bumper: metres until something the car
## must not hit, or -1 for a clear road. `ahead_speed` is how fast that
## something is going (0 for a stop line, -1 when there is nothing). The signal
## is deliberately NOT folded in here - `tick` reads it off the car itself, so a
## vehicle gap can never be mistaken for a stop line and park the car short of
## every junction.
func tick(delta: float, gap: float, ahead_speed: float = -1.0) -> void:
	var want: float = cruise_speed()
	blocked = gap >= 0.0
	if blocked:
		var free: float = maxf(0.0, gap - MIN_GAP)
		# Braking distance from the comfortable deceleration the tyre can give.
		# Solving for the speed we may carry at this gap is what makes the car
		# start slowing early and smoothly instead of stamping on the brakes at
		# the last moment - the whole difference between traffic that feels
		# alive and traffic that feels like a bug.
		want = minf(want, sqrt(2.0 * decel * BRAKE_SAFETY * free))
		if ahead_speed > 0.0:
			# Only for something that is actually moving. A stopped car and a
			# red light are handled by the braking distance alone; the headway
			# term exists to stop a queue braking to a standstill behind a car
			# that is still rolling, and it makes no sense against a wall.
			want = minf(want, ahead_speed + free / HEADWAY)
		if gap <= MIN_GAP + 0.35:
			want = 0.0

	if speed < want:
		speed = minf(want, speed + accel * delta)
	elif blocked:
		# Braking FOR something. It has to come out of the tyre at the rate the
		# curve above assumed, or the car sails past its own stopping point and
		# only the hard stop line saves it.
		speed = maxf(want, speed - decel * delta)
	else:
		# Lifting off a cruise speed. Engine braking plus a closed throttle is a
		# fraction of the brakes, and coasting down is what a real car does.
		speed = maxf(want, speed - decel * 0.55 * delta)
	speed = maxf(speed, 0.0)

	if speed < 1.2:
		stuck_time += delta
	else:
		stuck_time = 0.0

	_advance(delta)


func _advance(delta: float) -> void:
	var moved: float = speed * delta
	var limit: float = graph.edge_length(edge())
	var at_line: bool = signal_gap() >= 0.0
	if at_line:
		limit -= STOP_SETBACK + half_length()
	while moved > 0.0:
		if along + moved <= limit:
			along += moved
			return
		if at_line:
			# The stop line is the end of the road for this car. It stops on the
			# line; rolling over into the junction is precisely what the braking
			# curve above exists to prevent, and this is the guarantee.
			along = limit
			return
		moved -= maxf(0.0, limit - along)
		if not _next_edge():
			return
		# The gap that stopped us was measured to the line we just crossed, so
		# the new edge is fresh road and gets its full length back.
		limit = graph.edge_length(edge())
		at_line = signal_gap() >= 0.0
		if at_line:
			limit -= STOP_SETBACK + half_length()


## Chooses where to go next, and rolls over into it. A dead end is the only
## legal reason to turn around.
func _next_edge() -> bool:
	var node: int = exit_node()
	along = 0.0
	edge_i += 1
	if edge_i >= route.size():
		# Ran out of road. Mark the route finished rather than inventing a
		# continuation here; the manager recycles the car.
		edge_i = route.size() - 1
		speed = 0.0
		return false
	from_a = int(graph.edges[route[edge_i]]["a"]) == node
	return true


## Picks the next edge out of `node` when arriving along `from_edge`, legally.
## Returns -1 when there is nowhere legal to go.
func choose_next_edge(node: int, from_edge: int, rng: RandomNumberGenerator = null) -> int:
	var options: Array = []
	var weights: Array = []
	var heading := (graph.node_pos(node) - graph.node_pos(graph.other_node(from_edge, node))).normalized()
	for eid in graph.nodes[node]["edges"]:
		var cand: Dictionary = graph.edges[eid]
		var nxt: int = graph.other_node(eid, node)
		# One-ways are the hard rule: only the stored direction exists.
		if bool(cand.get("oneway", false)) and int(cand["a"]) != node:
			continue
		if eid == from_edge and graph.nodes[node]["edges"].size() > 1:
			# Reversing out of an intersection is not a manoeuvre, it is a bug.
			# At a dead end it is the only option and we allow it.
			continue
		var d: Vector2 = graph.node_pos(nxt) - graph.node_pos(node)
		if d.length_squared() < 0.0001:
			continue
		d = d.normalized()
		var score: float = 0.55 + heading.dot(d) * 0.45
		# Main roads carry more traffic, so a driver drifts onto them.
		score += float(cand["class"]) * 0.06
		if rng != null:
			score += rng.randf() * 0.35
		options.append(eid)
		weights.append(maxf(score, 0.001))
	if options.is_empty():
		return -1
	var total := 0.0
	for w in weights:
		total += float(w)
	var pick := 0.0
	if rng != null:
		pick = rng.randf() * total
	for i in options.size():
		pick -= float(weights[i])
		if pick <= 0.0:
			return int(options[i])
	return int(options[options.size() - 1])


## Grows the route by one legal edge. The manager calls this when a car nears
## the end of what it was told to drive.
func extend_route(rng: RandomNumberGenerator = null) -> bool:
	if graph == null or route.is_empty():
		return false
	var last: int = int(route[route.size() - 1])
	# The junction we drive out of: between the last two edges, or - for a car
	# still on its only edge - the far end of that edge.
	var node: int = graph.other_node(last, int(route[route.size() - 2])) if route.size() > 1 else exit_node()
	var nxt: int = choose_next_edge(node, last, rng)
	if nxt < 0:
		return false
	route.append(nxt)
	return true


## True once the car has driven off the end of its route and needs recycling.
func finished() -> bool:
	return edge_i >= route.size() - 1 and along >= graph.edge_length(edge()) - 0.01


# ------------------------------------------------------------------- signals

## Metres from the FRONT BUMPER to where the car has to be stopped, in the
## shape `tick()` wants, or -1 when there is nothing to stop for.
##
## The line it brakes for is STOP_SETBACK short of the actual stop line, and
## that is also exactly where `_advance` puts the hard clamp. Measure one of the
## two from the car's nose and the other from its centre and they disagree, and
## the car sits at the line still demanding full throttle.
func signal_gap() -> float:
	if lights == null or obedience < 1.0:
		return -1.0
	if lights.state_for(exit_node(), edge()) == TrafficLights.State.GREEN:
		return -1.0
	return graph.edge_length(edge()) - STOP_SETBACK - (along + half_length())
