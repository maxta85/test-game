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
	d.path = _straightest_first(graph, graph.find_loop(start_node, target_len))
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
	var loop: Array = graph.find_loop(start_node, target_len)
	d.path = loop.slice(0, maxi(4, int(float(loop.size()) * 0.6)))
	d.closed = false
	d.laps = 1
	d.difficulty = 2
	return d


static func pursuit(graph: RoadGraph, start_node: int, target_len: float, p_id: String, p_name: String) -> RaceDef:
	var d := _new(Kind.PURSUIT, p_id, p_name, target_len)
	var loop: Array = graph.find_loop(start_node, target_len)
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
		sprint(graph, 0, 900.0, "esplanade_sprint", "Esplanade Sprint"),
		circuit(graph, 0, 700.0, "manunda_circuit", "Manunda Street Circuit", 3),
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
## find_loop closes the lap wherever its greedy walk happens to land, which here
## is a hairpin: cars arrive at the line travelling the opposite way to the
## opening straight, so anything that reads "forwards" off the first edge rejects
## a perfectly good crossing. Rotating the route is free, and every reader then
## gets path[0] as a start/finish line a real circuit would use - on the fast
## straight, not in a corner.
static func _straightest_first(graph: RoadGraph, path: Array) -> Array:
	if path.size() < 5 or int(path[0]) != int(path[path.size() - 1]):
		return path
	var ring := path.slice(0, path.size() - 1)
	var count := ring.size()
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


## The back streets are not evenly walkable - the corner of the map is a handful
## of lanes with no loop in it - so try a spread of start nodes and keep the
## longest run that closes.
static func _touge_route(graph: RoadGraph, start: int, target_len: float) -> Array:
	var n := graph.nodes.size()
	var best: Array = []
	var best_len := 0.0
	for s in [start, n / 4, n / 2, (3 * n) / 4]:
		var path: Array = _touge_loop(graph, clampi(int(s), 0, n - 1), target_len)
		var length := 0.0
		for i in path.size() - 1:
			length += graph.node_pos(int(path[i])).distance_to(graph.node_pos(int(path[i + 1])))
		if length > best_len:
			best = path
			best_len = length
	return best


## Greedy walk over the narrow end of the network: the sharpest corner available
## until the route is long enough, then straight home to close the loop. Only
## ever walks lanes and side streets, and only the last step is allowed back onto
## the start. Returns [] if it cannot get home, which makes the definition
## invalid rather than a route that teleports across the map.
static func _touge_loop(graph: RoadGraph, start: int, target_len: float) -> Array:
	var home: Vector2 = graph.node_pos(start)
	var path: Array = [start]
	var visited := {start: true}
	var node := start
	var came_from := -1
	var prev := Vector2.ZERO
	var length := 0.0
	var guard := 0
	while guard < 800 and length <= target_len * 6.0:
		guard += 1
		var heading_home := length >= target_len
		var best_eid := -1
		var best_score := -INF
		for eid in graph.nodes[node]["edges"]:
			if int(graph.edges[eid]["class"]) > RoadGraph.RoadClass.STREET:
				continue
			var nxt: int = graph.other_node(eid, node)
			if visited.has(nxt) and nxt != start and not heading_home:
				continue
			var d: Vector2 = (graph.node_pos(nxt) - graph.node_pos(node)).normalized()
			var score := 0.0
			if heading_home:
				# Distance home dominates by a mile, so the walk never dithers;
				# the alignment and the no-backtracking terms only break ties,
				# which is what stops it pacing up and down one block.
				score = -graph.node_pos(nxt).distance_to(home) * 10.0 \
						+ d.dot((home - graph.node_pos(node)).normalized()) \
						- (1.0 if nxt == came_from else 0.0)
			else:
				# A touge corner is a corner: the sharpest turn available wins.
				score = (1.0 if prev == Vector2.ZERO else -prev.dot(d)) + float(graph.edges[eid]["class"]) * 0.1
			if score > best_score:
				best_score = score
				best_eid = eid
		if best_eid < 0:
			# Nowhere narrow left to go: drop the trail and keep exploring.
			visited.clear()
			visited[node] = true
			continue
		var step_to: int = graph.other_node(best_eid, node)
		came_from = node
		prev = (graph.node_pos(step_to) - graph.node_pos(node)).normalized()
		length += graph.edge_length(best_eid)
		visited[step_to] = true
		path.append(step_to)
		node = step_to
		# Only a run worth driving counts. Left ungated, the sharpest-corner
		# preference turns into the first triangle it finds - 50 m of back
		# street - whatever length was asked for.
		if node == start and length >= target_len:
			return path
	return []
