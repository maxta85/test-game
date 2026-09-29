class_name TrafficLights
extends RefCounted
## Signal cycles for the junctions, and the one thing a traffic car asks before
## it enters an intersection.
##
## Junctions with three or more approaches get a light; everything else is
## give-way and cars just drive through. A light runs two phases rather than one
## per approach: the east-west approaches go together, then the north-south
## ones. That is how a real four-way works, and it is the cheapest thing that
## does not put an intersection into gridlock.
##
## Pure logic and time-driven. `tick(delta)` is called once a frame by whoever
## owns the clock, and `state_for(node, edge)` is a dictionary lookup - a car
## asks on the last tick of every edge, so it has to be free.
##
## ORIGINAL GAME CONTENT.

enum State { GREEN, AMBER, RED }

## Seconds each. The all-red between phases is not a real-world quantity, it is
## the gap that stops the last car of one phase from still being on the box when
## the first of the next arrives.
const GREEN_TIME := 9.0
const AMBER_TIME := 2.6
const ALL_RED_TIME := 1.4

## Junctions at or above this many approaches get signals. Below it, a give-way
## reads better than a light.
const MIN_APPROACHES := 3

## node id -> { edge id -> phase (0 or 1) }
var _phase_of: Dictionary = {}
## Junction positions, so a caller can hang signal props on them if it wants.
var junction_nodes: Array = []

var _timer: float = 0.0
var _active: int = 0

# ponytail: two phases per junction (east-west, then north-south), not one per
# approach, and the phase a given edge gets is fixed rather than adaptive. A
# junction where every approach runs every phase, or one that stretches a phase
# on demand, needs a real conflict table - per-approach phases if the arterial
# ever gets a fourth arm or a filter turn.


func setup(g: RoadGraph) -> void:
	_phase_of.clear()
	junction_nodes.clear()
	_timer = 0.0
	_active = 0
	if g == null:
		return
	for n in g.nodes:
		if n["edges"].size() < MIN_APPROACHES:
			continue
		var node: int = int(n["id"])
		junction_nodes.append(node)
		var groups: Dictionary = {0: [], 1: []}
		for eid in n["edges"]:
			var out_dir: Vector2 = g.node_pos(g.other_node(int(eid), node)) - g.node_pos(node)
			# Which way does this approach send you when you turn onto it? An
			# east-west street continues east-west, so the two of them share a
			# phase and never send cars into each other.
			var axis: int = 0 if absf(out_dir.x) >= absf(out_dir.y) else 1
			groups[axis].append(eid)
		# A junction with only one axis of approach (a T off a through road, say)
		# runs a single phase; splitting it would leave one group permanently red.
		var both: bool = not (groups[0] as Array).is_empty() and not (groups[1] as Array).is_empty()
		var map := {}
		for eid in groups[0]:
			map[eid] = 0
		for eid in groups[1]:
			map[eid] = 1 if both else 0
		_phase_of[node] = map


## Named `signals_at` rather than `has_signal` because Object already owns a
## method called has_signal and shadowing it breaks the object contract.
func signals_at(node: int) -> bool:
	return _phase_of.has(node)


func phase_of(node: int, edge: int) -> int:
	var m: Dictionary = _phase_of.get(node, {})
	return int(m.get(edge, 0))


## The signal a car sees as it approaches `node` along `edge`. A junction with
## no signal is green, so traffic on the residential grid never has to ask.
func state_for(node: int, edge: int) -> int:
	if not _phase_of.has(node):
		return State.GREEN
	if phase_of(node, edge) != _active:
		return State.RED
	return State.AMBER if _in_amber() else State.GREEN


## True while the current phase is between green and red. Cars that make a
## judgement call need to know; the automated ones just stop.
func _in_amber() -> bool:
	return _timer >= GREEN_TIME and _timer < GREEN_TIME + AMBER_TIME


## How long until this approach next turns green. Exposed so the HUD and the
## race director can warn the player without duplicating the phase maths.
func time_to_green(node: int, edge: int) -> float:
	if not _phase_of.has(node):
		return 0.0
	if state_for(node, edge) == State.GREEN:
		return 0.0
	# `_timer` runs green -> amber -> all-red, so the wait is whatever is left of
	# those two states combined.
	return AMBER_TIME + ALL_RED_TIME - (_timer - GREEN_TIME)


func tick(delta: float) -> void:
	_timer += delta
	var cycle: float = GREEN_TIME + AMBER_TIME + ALL_RED_TIME
	if _timer >= cycle:
		_timer = fmod(_timer, cycle)
		_active = 1 - _active


func stats() -> Dictionary:
	return {"signals": _phase_of.size(), "phase": _active, "t": _timer}
