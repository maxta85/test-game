class_name RaceDef
extends RefCounted
## A race definition: a record the garage menu reads and the director executes.
##
## Deliberately holds no state and no dependencies beyond the road graph it was
## built from - it is data, not a system.
##
## ORIGINAL GAME CONTENT. Cairns is fictionalised; every route is generated
## from the authored street corridors, none are copied from anywhere.

enum Kind { SPRINT, CIRCUIT, TIME_ATTACK, PURSUIT, TOUGE }

const KIND_NAMES := ["Sprint", "Circuit", "Time Attack", "Pursuit", "Touge"]

var id: String = ""
var display_name: String = ""
var kind: int = Kind.CIRCUIT
## Ordered junction ids along the route. A closed route (what find_loop returns)
## repeats its first node at the end, so path[0] is the start/finish line.
var path: Array = []
var laps: int = 1
var opponents: int = 3
var entry_fee: int = 0
## Paid to the winner in full; every other position is a fraction of it.
var payout: int = 0
## 1..5. The garage sorts and colours by it; the race AI reads it for skill.
var difficulty: int = 1
## Closed routes are lapped until `laps` is met. Open routes (sprint, pursuit)
## end the moment the last junction is reached.
var closed: bool = true
## Pursuit pressure thresholds, in metres of lead, as pure data. No system reads
## this yet - the police escalation AI is not built.
var escalation: Array = []


func kind_name() -> String:
	return KIND_NAMES[clampi(kind, 0, KIND_NAMES.size() - 1)]


## A definition the director can actually run. A route that could not be found
## in the network is invalid rather than silently empty.
func valid() -> bool:
	return path.size() >= 4


## Metres from path[0] to the last junction, closing the loop for a circuit.
func length_m(graph: RoadGraph) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += graph.node_pos(int(path[i])).distance_to(graph.node_pos(int(path[i + 1])))
	return total


## Winner takes the lot; the last finisher takes a share. Losers get nothing.
func payout_for_position(pos: int, entrants: int) -> int:
	if pos < 1 or entrants < 1 or pos > entrants:
		return 0
	return int(round(float(payout) * float(entrants - pos + 1) / float(entrants)))


# ------------------------------------------------------------------- factories

static func circuit(graph: RoadGraph, start_node: int, target_len: float, p_id: String, p_name: String, p_laps: int) -> RaceDef:
	var d := _new(Kind.CIRCUIT, p_id, p_name, target_len / maxf(float(p_laps), 1.0))
	d.path = _straightest_first(graph, _grow_circuit(graph, start_node, target_len, RoadGraph.RoadClass.HIGHWAY, false))
	d.closed = true
	d.laps = maxi(p_laps, 1)
	d.difficulty = 2 + mini(p_laps, 3)
	return d


static func time_attack(graph: RoadGraph, start_node: int, target_len: float, p_id: String, p_name: String, p_laps: int) -> RaceDef:
	var d := circuit(graph, start_node, target_len, p_id, p_name, p_laps)
	d.kind = Kind.TIME_ATTACK
	d.opponents = 0
	d.difficulty = 3
	return d


## Point A to point B with no laps. Built by cutting the return leg off a real
## circuit, so the finish is a couple of kilometres down the street from the
## start rather than back where you began.
static func sprint(graph: RoadGraph, start_node: int, target_len: float, p_id: String, p_name: String) -> RaceDef:
	var d := _new(Kind.SPRINT, p_id, p_name, target_len)
	var loop: Array = _grow_circuit(graph, start_node, target_len, RoadGraph.RoadClass.HIGHWAY, false)
	d.path = loop.slice(0, maxi(4, int(float(loop.size()) * 0.6)))
	d.closed = false
	d.laps = 1
	d.difficulty = 2
	return d


static func pursuit(graph: RoadGraph, start_node: int, target_len: float, p_id: String, p_name: String) -> RaceDef:
	var d := _new(Kind.PURSUIT, p_id, p_name, target_len)
	var loop: Array = _grow_circuit(graph, start_node, target_len, RoadGraph.RoadClass.HIGHWAY, false)
	d.path = loop.slice(0, maxi(4, int(float(loop.size()) * 0.75)))
	d.closed = false
	d.laps = 1
	d.opponents = 3
	d.difficulty = 4
	# Metres of lead before pressure escalates, cheapest level first.
	d.escalation = [400.0, 900.0, 1600.0]
	return d


## A technical run down the back streets: lanes and side streets only, and the
## tightest corner available every time - a touge is a corner, not a straight.
static func touge(graph: RoadGraph, start_node: int, target_len: float, p_id: String, p_name: String) -> RaceDef:
	var d := _new(Kind.TOUGE, p_id, p_name, target_len)
	d.path = _straightest_first(graph, _touge_route(graph, start_node, target_len))
	d.closed = true
	d.laps = 2
	d.difficulty = 5
	return d


## One race of every kind, for the garage menu.
static func catalogue(graph: RoadGraph) -> Array:
	return [
		sprint(graph, 0, 900.0, "gordon_sprint", "Gordon Street Sprint"),
		circuit(graph, 0, 700.0, "mulgrave_circuit", "Mulgrave Road Circuit", 3),
		time_attack(graph, 0, 700.0, "nightfall_tt", "Nightfall Time Attack", 3),
		pursuit(graph, 0, 1100.0, "heat_run", "Heat Run"),
		touge(graph, 0, 500.0, "ridge_touge", "Ridge Touge"),
	]


static func _new(kind: int, p_id: String, p_name: String, target_len: float) -> RaceDef:
	var d := RaceDef.new()
	d.kind = kind
	d.id = p_id
	d.display_name = p_name
	# Entry scales with how hard the route is, payout with how long it is.
	d.entry_fee = 40 + int(target_len * 0.06)
	d.payout = 200 + int(target_len * 0.25)
	return d


## Puts the start/finish line on the straightest junction of a closed route.
##
## A circuit's start line belongs on its fastest straight, not wherever the route
## builder happened to begin: cars arrive at the line travelling the opposite way
## to the opening street, so anything that reads "forwards" off the first edge
## rejects a perfectly good crossing. Rotating the route is free, and every
## reader then gets path[0] as a start/finish line a real circuit would use.
##
## Accepts a route with or without the closing junction repeated, and always
## returns one with it, which is the convention the rest of the game reads.
static func _straightest_first(graph: RoadGraph, path: Array) -> Array:
	var ring: Array = path.duplicate()
	if ring.size() > 2 and int(ring[0]) == int(ring[ring.size() - 1]):
		ring.resize(ring.size() - 1)
	var count := ring.size()
	if count < 4:
		return path
	var best := 0
	var best_dot := -2.0
	for i in count:
		var a: Vector2 = graph.node_pos(int(ring[(i - 1 + count) % count]))
		var b: Vector2 = graph.node_pos(int(ring[i]))
		var c: Vector2 = graph.node_pos(int(ring[(i + 1) % count]))
		var straight: float = (b - a).normalized().dot((c - b).normalized())
		if straight > best_dot:
			best_dot = straight
			best = i
	var out: Array = []
	for k in count:
		out.append(int(ring[(best + k) % count]))
	out.append(int(ring[best]))
	return out


## A closed loop through the streets that actually goes round something.
##
## RoadGraph.find_loop cannot be used for a race route. On this network its
## greedy walk runs straight to the map edge and then shortest-paths back along
## the same street, so what it calls a circuit is 2 km of out-and-back with no
## corners at all: nothing to race on, and nothing for a driver to brake for. It
## still satisfies "returns a closed loop", which is why it went unnoticed. (The
## brief for the race system stated the opposite; measured, it is a there-and-
## back - extent 0 x 1142 m, zero corners.)
##
## So the route is built here instead, by growing a cycle rather than by walking
## one. Find a small loop, then repeatedly replace one of its edges with a detour
## around the block behind it. Every step is a shortest path that avoids the rest
## of the circuit, so the result is a simple cycle by construction: it cannot
## double back on itself, and it cannot come out as a there-and-back.
static func _grow_circuit(graph: RoadGraph, start: int, target_len: float, max_class: int, technical: bool) -> Array:
	var best: Array = []
	var best_score := -INF
	# A circuit is worth starting from more than one place: the map is not evenly
	# walkable, and the corner of it is a handful of lanes with no block in it.
	var n := graph.nodes.size()
	for s in [start, n / 6, n / 3, n / 2, (2 * n) / 3, (5 * n) / 6]:
		var seed: Array = _seed_cycle(graph, clampi(int(s), 0, n - 1), max_class)
		if seed.size() < 4:
			continue
		var grown: Array = _grow_from(graph, seed, max_class, target_len, technical)
		if not _goes_round_something(graph, grown):
			continue      # a there-and-back is not a circuit, however long it is
		var length := _loop_length(graph, grown)
		# Nearest the length asked for, and long before short.
		var score: float = -absf(length - target_len) * 0.5 + minf(length, 4000.0) * 0.05
		if score > best_score:
			best_score = score
			best = grown
	return best


## The smallest loop through a node: two of its neighbours joined by a path that
## does not come back through it. On a street grid that is one city block.
static func _seed_cycle(graph: RoadGraph, start: int, max_class: int) -> Array:
	var neighbours: Array = []
	for eid in graph.nodes[start]["edges"]:
		if int(graph.edges[eid]["class"]) <= max_class:
			neighbours.append(int(graph.other_node(eid, start)))
	for i in neighbours.size():
		for j in range(i + 1, neighbours.size()):
			var a: int = neighbours[i]
			var b: int = neighbours[j]
			var path: Array = _path_avoiding(graph, a, b, {start: true}, max_class, true)
			if path.size() >= 3:
				var out: Array = [start]
				out.append_array(path)
				return out
	return []


## Grows a cycle by detouring its edges around blocks until it stops growing.
static func _grow_from(graph: RoadGraph, seed: Array, max_class: int, target_len: float, technical: bool) -> Array:
	var cyc: Array = seed.duplicate()
	var in_cyc := {}
	for n in cyc:
		in_cyc[int(n)] = true
	var grown := true
	var rounds := 0
	while grown and rounds < 300:
		grown = false
		rounds += 1
		if _loop_length(graph, cyc) >= target_len * 1.8:
			break
		for i in cyc.size():
			var a: int = int(cyc[i])
			var b: int = int(cyc[(i + 1) % cyc.size()])
			var detour: Array = _path_avoiding(graph, a, b, in_cyc, max_class, false)
			if detour.size() < 3:
				continue
			if technical and _detour_corners(graph, detour) < 2:
				continue      # a technical run detours round corners, not round blocks
			cyc = _splice(cyc, i, detour)
			in_cyc.clear()
			for n in cyc:
				in_cyc[int(n)] = true
			grown = true
			break       # re-index from the new cycle before choosing again
	return cyc


## Shortest path from a to b that touches none of `blocked` except b, and does
## not simply step straight from a to b (which is not a detour).
static func _path_avoiding(graph: RoadGraph, a: int, b: int, blocked: Dictionary, max_class: int, allow_direct: bool) -> Array:
	var prev := {a: -1}
	var queue: Array = [a]
	var head := 0
	var found := false
	while head < queue.size():
		var n: int = queue[head]
		head += 1
		if n == b:
			found = true
			break
		for eid in graph.nodes[n]["edges"]:
			if int(graph.edges[eid]["class"]) > max_class:
				continue
			var nxt: int = int(graph.other_node(eid, n))
			if prev.has(nxt):
				continue
			if n == a and nxt == b and not allow_direct:
				continue
			if blocked.has(nxt) and nxt != b:
				continue
			prev[nxt] = n
			queue.append(nxt)
	if not found:
		return []
	var out: Array = []
	var cur := b
	while cur != -1:
		out.push_front(cur)
		if cur == a:
			break
		cur = int(prev[cur])
	return out


## Replaces edge i -> i+1 of the cycle with the detour, which starts at i and
## ends at i+1.
static func _splice(cyc: Array, i: int, detour: Array) -> Array:
	var out: Array = []
	for k in range(i + 1):
		out.append(int(cyc[k]))
	# The detour's first node is cyc[i], already in; its last is cyc[i+1], which
	# is the node this edge used to end on, so it is kept here and cyc[i+1] is
	# not repeated.
	for k in range(1, detour.size()):
		out.append(int(detour[k]))
	for k in range(i + 2, cyc.size()):
		out.append(int(cyc[k]))
	return out


static func _detour_corners(graph: RoadGraph, path: Array) -> int:
	var corners := 0
	for i in range(1, path.size() - 1):
		var a: Vector2 = (graph.node_pos(int(path[i])) - graph.node_pos(int(path[i - 1]))).normalized()
		var b: Vector2 = (graph.node_pos(int(path[i + 1])) - graph.node_pos(int(path[i]))).normalized()
		var deg: float = rad_to_deg(a.angle_to(b))
		if deg > 25.0 and deg < 150.0:
			corners += 1
	return corners


static func _loop_length(graph: RoadGraph, path: Array) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += graph.node_pos(int(path[i])).distance_to(graph.node_pos(int(path[i + 1])))
	return total


## A loop only counts as a race route if it turns corners and covers ground in
## both directions. A there-and-back is closed and long and useless to race on.
static func _goes_round_something(graph: RoadGraph, path: Array) -> bool:
	if path.size() < 6:
		return false
	var corners := 0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in path.size():
		var p: Vector2 = graph.node_pos(int(path[i]))
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
		if i == 0 or i == path.size() - 1:
			continue
		var a: Vector2 = (p - graph.node_pos(int(path[i - 1]))).normalized()
		var b: Vector2 = (graph.node_pos(int(path[i + 1])) - p).normalized()
		var deg: float = rad_to_deg(a.angle_to(b))
		if deg > 25.0 and deg < 150.0:
			corners += 1
	# Two real corners is a rounded rectangle, which is a perfectly good street
	# circuit; what it must not be is a shape that never turns.
	return corners >= 2 and (hi.x - lo.x) > 120.0 and (hi.y - lo.y) > 120.0


## A technical run: lanes and side streets only, detoured around corners rather
## than around the long way round a block.
static func _touge_route(graph: RoadGraph, start: int, target_len: float) -> Array:
	var n := graph.nodes.size()
	for s in [start, n / 4, n / 2, (3 * n) / 4]:
		var path: Array = _grow_circuit(graph, clampi(int(s), 0, n - 1), target_len, RoadGraph.RoadClass.STREET, true)
		if _goes_round_something(graph, path):
			return path
	return []
