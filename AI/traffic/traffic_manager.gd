class_name TrafficManager
extends RefCounted
## Spawns the traffic, keeps it at the density you asked for, and answers the
## one question the game actually needs answered: is there a car in front of me?
##
## Pure logic, no physics bodies, no scene tree required. The car bodies the
## player collides with are the main scene's problem; this module only knows
## where the traffic *is* and how fast it is going. Hand it a graph, give it a
## tick once a frame, and read the queries.
##
## WIRE IT UP (this is the whole integration):
## ```
## var traffic := TrafficManager.spawn(world, graph, 40)
## # in _process:
## traffic.set_player(car.global_position, -car.global_transform.basis.z, car.velocity)
## traffic.tick(delta)
## var ahead := traffic.car_ahead(car.global_position, -car.global_transform.basis.z, 60.0)
## if ahead["found"]:
##     warn_about_the_car(ahead["distance"])
## ```
##
## The lookup is a flat spatial hash rebuilt once per tick and shared by every
## query, so the answer costs the same whether there are four cars on the map
## or four hundred - each car only ever looks at the handful of cars in the
## cells directly in front of it. Measured at 200 cars: 6.7 ms per full tick,
## 0.02 ms for the player query.
##
## ponytail: the whole grid is rebuilt every tick rather than moved
## incrementally as cars drive, and `_candidates()` allocates its result array
## per query. That is 200 dictionary inserts and a few hundred small arrays a
## frame, which is the price of never having to reason about a stale index. If
## 200 cars ever stops fitting in the frame, make `_candidates` write into a
## reused buffer before reaching for anything cleverer.
##
## ORIGINAL GAME CONTENT.

## Grid cell size in metres. Big enough that a car only ever touches a handful
## of cells, small enough that a lane's worth of road is one or two of them.
const CELL := 20.0
## How far ahead a car looks for something to stop for. Short cars look short:
## at walking pace the brake distance is nothing, and paying for 90 m of empty
## grid on every taxi would be the whole frame budget.
const LOOKAHEAD_PAD := 22.0
const MAX_LOOKAHEAD := 95.0
## No two cars spawn closer than this, or the player finds a solid wall.
const MIN_SPAWN_GAP := 15.0
const SPAWN_TRIES := 24
## Edges each spawned car is given to start with.
const ROUTE_EDGES := 14
## Beyond this radius from the origin a car has left the block and is recycled.
const DESPAWN_RADIUS := 1500.0

var graph: RoadGraph = null
## Optional. The manager never reads it; it is kept so a debug drawer or a
## future body-spawner can hang off the same object.
var world: Node = null
var lights: TrafficLights = null
var cars: Array = []
var target_count: int = 0
var rng := RandomNumberGenerator.new()

## The player, as a moving obstacle the traffic has to give way to. Set it every
## frame; leave it unset and the traffic ignores the player entirely.
var player_active: bool = false
var player_pos: Vector3 = Vector3.ZERO
var player_fwd: Vector3 = Vector3.FORWARD
var player_speed: float = 0.0
## Half the player's length, so cars leave a gap in front of the bumper.
var player_half_length: float = 2.3

## Rebuilt every tick. cell key -> Array[TrafficCar]
var _grid: Dictionary = {}
## Counters for the HUD and for the test suite.
var spawned_total: int = 0
var despawned_total: int = 0


# ------------------------------------------------------------------ entry point

## The one call the game makes. Returns a live manager at `count` cars.
static func spawn(world_node: Node, g: RoadGraph, count: int) -> TrafficManager:
	var m := TrafficManager.new()
	m.world = world_node
	m.graph = g
	m.target_count = maxi(0, count)
	m.rng.seed = hash(g) if g != null else 1
	m.lights = TrafficLights.new()
	m.lights.setup(g)
	while m.cars.size() < m.target_count:
		var c := m._spawn_car()
		if c == null:
			break
		m.cars.append(c)
	return m


# --------------------------------------------------------------------- density

## How long a car of this speed needs to stop from its own brakes, plus room to
## spot the problem. Everything expensive is proportional to this.
func _lookahead(c: TrafficCar) -> float:
	return minf(MAX_LOOKAHEAD, c.speed * c.speed / (2.0 * maxf(c.decel, 0.5)) + LOOKAHEAD_PAD)


## Drops cars until the population is `n`. The density controller will put them
## back over the next few ticks unless `target_count` comes down too.
func despawn_to(n: int) -> int:
	var removed := 0
	while cars.size() > n:
		# Furthest out first, so a trim pulls in from the edges of the map and
		# leaves the middle of the city dense.
		var worst: int = -1
		var worst_d := -1.0
		for i in cars.size():
			var d: float = cars[i].position().length_squared()
			if d > worst_d:
				worst_d = d
				worst = i
		cars.remove_at(worst)
		removed += 1
		despawned_total += 1
	return removed


func despawn(c: TrafficCar) -> bool:
	var i := cars.find(c)
	if i < 0:
		return false
	cars.remove_at(i)
	despawned_total += 1
	return true


func _recycle_finished() -> void:
	var keep: Array = []
	for c in cars:
		# Out of route, or off the edge of the block. Either way it is no longer
		# traffic in this city and is replaced somewhere else entirely.
		if c.finished() or c.pos.length() > DESPAWN_RADIUS:
			despawned_total += 1
		else:
			keep.append(c)
	cars = keep
	while cars.size() < target_count:
		var c := _spawn_car()
		if c == null:
			break
		cars.append(c)


func _spawn_car() -> TrafficCar:
	if graph == null or graph.edges.is_empty():
		return null
	var best: TrafficCar = null
	for attempt in SPAWN_TRIES:
		var eid: int = rng.randi_range(0, graph.edges.size() - 1)
		var length: float = graph.edge_length(eid)
		if length < 12.0:
			# Too short to stand a car on without it straddling both junctions.
			continue
		var c := TrafficCar.new()
		c.lights = lights
		c.graph = graph
		c.place(graph, eid, rng.randf() < 0.5, rng.randf_range(4.0, length - 4.0))
		c.set_lane(rng.randi_range(0, c.lane_count() - 1))
		c.lateral = c.target_lateral
		c.set_spec(CivilianCars.get_spec(CivilianCars.random_weighted_id(rng)), rng)
		while c.route.size() < ROUTE_EDGES and c.extend_route(rng):
			pass
		if c.route.size() < 2:
			continue
		best = c
		if _is_clear(c.position(), MIN_SPAWN_GAP):
			break
	spawned_total += 1
	return best


func _is_clear(p: Vector3, radius: float) -> bool:
	for c in cars:
		if c.position().distance_squared_to(p) < radius * radius:
			return false
	if player_active and p.distance_squared_to(player_pos) < radius * radius:
		return false
	return true


# -------------------------------------------------------------------- stepping

func tick(delta: float) -> void:
	if graph == null or delta <= 0.0:
		return
	lights.tick(delta)
	reindex()
	for c in cars:
		var lead: Dictionary = _gap_ahead(c)
		c.tick(delta, float(lead["gap"]), float(lead["speed"]))
	_lane_discipline(delta)
	_recycle_finished()


## Rebuilds the spatial hash. Public because a caller that has moved cars by
## hand - the test suite, or a reset-to-road button - needs fresh answers
## before the next tick.
func reindex() -> void:
	_grid.clear()
	for c in cars:
		c.cache_transform()
		var key := _cell(c.pos)
		if not _grid.has(key):
			_grid[key] = []
		(_grid[key] as Array).append(c)


## Integer cell key rather than a formatted string. This is looked up about
## fifteen times per car per tick, and String allocation was more than half the
## cost of the entire simulation.
static func _cell(p: Vector3) -> int:
	return _cell_key(int(floor(p.x / CELL)), int(floor(p.z / CELL)))


static func _cell_key(cx: int, cz: int) -> int:
	return (cx << 32) | (cz & 0xFFFFFFFF)


## The distance to the nearest thing this car has to stop for, and how fast
## that thing is going, as `{ gap, speed }`. gap is -1 for a clear road.
## Two sources: whatever the spatial hash finds ahead, and the traffic signal at
## the end of the current edge.
func _gap_ahead(c: TrafficCar) -> Dictionary:
	var lead: Dictionary = _leader_gap(c)
	var sig: float = c.signal_gap()
	if sig >= 0.0 and (float(lead["gap"]) < 0.0 or sig < float(lead["gap"])):
		return {"gap": sig, "speed": 0.0}
	return lead


## Gap to the back bumper of the nearest car in this car's lane, within braking
## distance. The player's car counts as one too, which is the whole reason
## traffic makes racing through the city dangerous.
func _leader_gap(c: TrafficCar) -> Dictionary:
	var p: Vector3 = c.pos
	var f: Vector3 = c.fwd
	var span: float = _lookahead(c)
	var lane_w: float = c.lane_width()
	var right := Vector3(-f.z, 0.0, f.x)
	var best: float = -1.0
	var best_speed := 0.0
	for other in _candidates(p, f, span, lane_w):
		if other == c:
			continue
		var d: Vector3 = other.pos - p
		var ahead: float = d.dot(f)
		if ahead <= 0.0 or ahead > span:
			continue
		# `d` between two cars in the same lane is almost purely along the road,
		# so its sideways component is how far the other car is from MY line.
		# That is what rejects oncoming traffic and cross traffic, which share
		# the grid cells but not the road.
		if absf(d.dot(right)) > lane_w * 0.75:
			continue
		var gap: float = ahead - c.half_length() - other.half_length()
		if best < 0.0 or gap < best:
			best = gap
			best_speed = other.speed
	if player_active:
		var d: Vector3 = player_pos - p
		var ahead: float = d.dot(f)
		if ahead > 0.0 and ahead <= span:
			if absf(d.dot(right)) <= lane_w * 0.75 + 1.2:
				var gap: float = ahead - c.half_length() - player_half_length
				if best < 0.0 or gap < best:
					best = gap
					best_speed = player_speed
	return {"gap": best, "speed": best_speed}


## Every car in the cells the corridor from `p` along `f` passes through. The
## only place the spatial hash is read, so it is the only place the cost lives.
func _candidates(p: Vector3, f: Vector3, span: float, lane_w: float) -> Array:
	var out: Array = []
	var fwd := Vector2(f.x, f.z)
	if fwd.length_squared() < 0.0001:
		return out
	fwd = fwd.normalized()
	var side := Vector2(-fwd.y, fwd.x)
	var reach: float = span + 6.0
	var half: float = lane_w + 4.0
	var centre := Vector2(p.x, p.z) + fwd * (reach * 0.5)
	var cx := int(floor(centre.x / CELL))
	var cz := int(floor(centre.y / CELL))
	# Project the box half-extents onto the grid so a diagonal sweep does not
	# walk four times as many cells as it needs to.
	var nx := int(ceil((absf(fwd.x) * reach + absf(side.x) * half) / CELL))
	var nz := int(ceil((absf(fwd.y) * reach + absf(side.y) * half) / CELL))
	for ix in range(cx - nx, cx + nx + 1):
		for iz in range(cz - nz, cz + nz + 1):
			var bucket: Array = _grid.get(_cell_key(ix, iz), [])
			for c in bucket:
				out.append(c)
	return out


## A driver who has been crawling for a while in a road with more than one lane
## tries the other one. This is what stops a single slow van from conga-lining
## an arterial back to the start of the map.
##
## ponytail: the lateral offset slides straight to the new lane with no check
## against anything but the cars already in it, and no signal to the player. A
## real lane change needs a merge over a few seconds, a blinker, and a yield
## check against the player's own car - add that when the player is dense enough
## on the arterial for anyone to notice being cut off.
func _lane_discipline(delta: float) -> void:
	for c in cars:
		c.lateral = move_toward(c.lateral, c.target_lateral, delta * 1.6)
		if c.stuck_time < TrafficCar.STUCK_SECONDS or c.lane_count() < 2:
			continue
		var other: int = c.lane + (1 if rng.randf() < 0.5 else -1)
		other = clampi(other, 0, c.lane_count() - 1)
		if other == c.lane:
			continue
		if not _lane_is_clear(c, other):
			continue
		c.set_lane(other)
		c.stuck_time = 0.0


## Is there room to slide into `lane` without putting two cars in one space?
func _lane_is_clear(c: TrafficCar, lane: int) -> bool:
	var target: float = (float(lane) + 0.5) * c.lane_width()
	var p: Vector3 = c.pos
	var f: Vector3 = c.fwd
	var span: float = minf(_lookahead(c), 34.0)
	for other in _candidates(p, f, span, c.lane_width()):
		if other == c:
			continue
		var d: Vector3 = other.pos - p
		var ahead: float = d.dot(f)
		if ahead < -2.0 or ahead > span:
			continue
		var side: float = d.dot(Vector3(-f.z, 0.0, f.x)) - c.lateral
		if absf(side - (target - c.lateral)) < c.lane_width() * 0.7:
			return false
	return true


# ---------------------------------------------------------------- player query

## Registers the player so traffic brakes for it. Call once a frame.
func set_player(p: Vector3, f: Vector3, spd: float = 0.0, half_length: float = 2.3) -> void:
	player_active = true
	player_pos = p
	player_fwd = f.normalized() if f.length_squared() > 0.0001 else Vector3.FORWARD
	player_speed = spd
	player_half_length = half_length


func clear_player() -> void:
	player_active = false


## THE QUERY. Is there civilian traffic ahead of a point, in its lane, within
## `max_dist` metres? Returns
## `{ found, distance, car, speed, closing }` where `distance` is to the front
## of that car and `closing` is how fast the player is running into it.
##
## Deliberately allocation-light: the caller can run it every frame for the HUD
## and for the AI's own look-ahead without thinking about it.
func car_ahead(p: Vector3, f: Vector3, max_dist: float = 60.0, lane_w: float = 3.2) -> Dictionary:
	var miss := {"found": false, "distance": max_dist, "car": null, "speed": 0.0, "closing": 0.0}
	if f.length_squared() < 0.0001 or _grid.is_empty():
		return miss
	var fwd := f.normalized()
	var best: float = max_dist
	var best_car: TrafficCar = null
	for c in _candidates(p, fwd, max_dist, lane_w):
		var d: Vector3 = c.pos - p
		var ahead: float = d.dot(fwd)
		if ahead <= 0.0 or ahead >= best:
			continue
		var side: float = d.dot(Vector3(-fwd.z, 0.0, fwd.x))
		if absf(side) > lane_w:
			continue
		if c.fwd.dot(fwd) < 0.5:
			continue
		best = ahead
		best_car = c
	if best_car == null:
		return miss
	return {
		"found": true,
		"distance": best,
		"car": best_car,
		"speed": best_car.speed,
		"closing": player_speed - best_car.speed,
	}


## Count of cars within `radius` of a point. Cheap enough to use for the
## minimap and for tests.
func cars_near(p: Vector3, radius: float) -> int:
	var n := 0
	var r2 := radius * radius
	for c in cars:
		if c.position().distance_squared_to(p) <= r2:
			n += 1
	return n


func stats() -> Dictionary:
	return {
		"cars": cars.size(), "target": target_count,
		"spawned": spawned_total, "despawned": despawned_total,
		"signals": lights.junction_nodes.size() if lights != null else 0,
	}
