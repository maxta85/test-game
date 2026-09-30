class_name RoadGraph
extends RefCounted
## Road network as a proper graph: nodes at intersections, edges between them.
##
## Built from authored "corridors" (a polyline per street) rather than from a
## hand-listed node soup. That matters: intersections are computed, so a street
## added later still joins up correctly, and the racing line, the traffic AI and
## the road meshes all read from one source of truth instead of drifting apart.

enum RoadClass { LANE, STREET, ARTERIAL, HIGHWAY }

const CLASS_WIDTH := {
	RoadClass.LANE: 6.0,
	RoadClass.STREET: 9.0,
	RoadClass.ARTERIAL: 14.0,
	RoadClass.HIGHWAY: 18.0,
}
const CLASS_LANES := {
	RoadClass.LANE: 1,
	RoadClass.STREET: 2,
	RoadClass.ARTERIAL: 2,
	RoadClass.HIGHWAY: 3,
}
## Speed limit in m/s, used by the traffic AI and the race AI.
const CLASS_SPEED := {
	RoadClass.LANE: 8.0,
	RoadClass.STREET: 13.0,
	RoadClass.ARTERIAL: 19.0,
	RoadClass.HIGHWAY: 25.0,
}

## nodes[i] = { id, pos: Vector2, edges: Array[int], class }
var nodes: Array = []
## edges[i] = { id, a: int, b: int, class, width, lanes, name }
var edges: Array = []
## Street names, so the HUD and the AI can say something sensible.
var street_names: Dictionary = {}


func width_for(cls: int) -> float:
	return float(CLASS_WIDTH.get(cls, 9.0))


func lanes_for(cls: int) -> float:
	return float(CLASS_LANES.get(cls, 2))


func speed_for(cls: int) -> float:
	return float(CLASS_SPEED.get(cls, 13.0))


## Builds the graph from corridors.
## corridor = { name, class, points: Array[Vector2], oneway: bool }
func build(corridors: Array) -> void:
	nodes.clear()
	edges.clear()
	street_names.clear()

	# Split every corridor's polyline at all intersection points, then weld the
	# coincident points into shared nodes. This is the whole trick: two streets
	# that cross produce exactly one shared node automatically.
	for corridor in corridors:
		var pts: Array = corridor["points"]
		if pts.size() < 2:
			continue
		var cls: int = int(corridor.get("class", RoadClass.STREET))
		var name: String = String(corridor.get("name", ""))
		street_names[name] = cls

		# Collect split parameters for every segment.
		var splits: Array = []      # one array of floats per segment
		for i in pts.size() - 1:
			var t_list: Array = [0.0, 1.0]
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			for other in corridors:
				if other == corridor:
					continue
				var op: Array = other["points"]
				for j in op.size() - 1:
					# Only bother with segments whose bounding boxes overlap.
					if not _boxes_overlap(a, b, op[j], op[j + 1]):
						continue
					var t := _segment_intersection(a, b, op[j], op[j + 1])
					# Ignore intersections that land on an endpoint: they are the
					# same junction the shared-node weld will produce anyway, and
					# keeping them makes sliver edges of a few centimetres.
					if t.x and t.x > 0.02 and t.x < 0.98:
						t_list.append(t.x)
			t_list.sort()
			# Drop split points that would create a degenerate edge.
			var kept: Array = []
			for t in t_list:
				if kept.is_empty() or float(t) - float(kept[kept.size() - 1]) > 0.02:
					kept.append(t)
			splits.append(kept)

		# Walk the split points, welding consecutive ends into edges.
		for i in pts.size() - 1:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var chain: Array = [a]
			for t in splits[i]:
				chain.append(a.lerp(b, float(t)))
			chain.append(b)
			for k in chain.size() - 1:
				_add_edge_between(chain[k], chain[k + 1], cls, name, corridor.get("oneway", false))
	# Weld near-coincident junctions once every corridor has been added.
	_merge_close_nodes(0.75)


## Nearly-parallel streets can produce two intersection points a few tens of
## centimetres apart, which would leave two junctions stacked on top of each
## other and split the network. Weld them into one.
func _merge_close_nodes(tolerance: float) -> void:
	var keep: Array = []          # original indices, in new-index order
	var remap: Dictionary = {}    # original index -> NEW sequential index
	for i in nodes.size():
		var p: Vector2 = nodes[i]["pos"]
		var merged := false
		for j in keep:
			if p.distance_to(nodes[j]["pos"]) < tolerance:
				remap[i] = remap[j]
				merged = true
				break
		if not merged:
			# `keep.size()` is the index this node will get in the rebuilt arrays.
			remap[i] = keep.size()
			keep.append(i)

	var new_nodes: Array = []
	for j in keep:
		var n: Dictionary = nodes[j].duplicate(true)
		n["edges"] = []
		new_nodes.append(n)
	var new_edges: Array = []
	for e in edges:
		var a: int = int(remap[int(e["a"])])
		var b: int = int(remap[int(e["b"])])
		if a == b:
			continue
		var dupe := false
		for f in new_edges:
			if (f["a"] == a and f["b"] == b) or (f["a"] == b and f["b"] == a):
				if int(e["class"]) > int(f["class"]):
					f["class"] = e["class"]
					f["width"] = e["width"]
					f["lanes"] = e["lanes"]
					f["name"] = e["name"]
				dupe = true
				break
		if dupe:
			continue
		var ne: Dictionary = e.duplicate()
		ne["id"] = new_edges.size()
		ne["a"] = a
		ne["b"] = b
		new_edges.append(ne)

	for i in new_nodes.size():
		new_nodes[i]["id"] = i
	for e in new_edges:
		new_nodes[int(e["a"])]["edges"].append(int(e["id"]))
		new_nodes[int(e["b"])]["edges"].append(int(e["id"]))
	nodes = new_nodes
	edges = new_edges


func _add_edge_between(p: Vector2, q: Vector2, cls: int, name: String, oneway: bool) -> void:
	if p.distance_squared_to(q) < 0.25:
		return
	var a := _node_at(p)
	var b := _node_at(q)
	if a == b:
		return
	if a > b:
		var tmp := a
		a = b
		b = tmp
	# No duplicate edges.
	for eid in nodes[a]["edges"]:
		var e: Dictionary = edges[eid]
		if (e["a"] == a and e["b"] == b) or (e["a"] == b and e["b"] == a):
			# A street crossing a higher-class road is upgraded in place.
			if cls > int(e["class"]):
				e["class"] = cls
				e["width"] = width_for(cls)
				e["lanes"] = lanes_for(cls)
				e["name"] = name
			return
	var id := edges.size()
	edges.append({
		"id": id, "a": a, "b": b, "class": cls,
		"width": width_for(cls), "lanes": lanes_for(cls),
		"name": name, "oneway": oneway,
	})
	nodes[a]["edges"].append(id)
	nodes[b]["edges"].append(id)


## Nodes are keyed on a 0.05 m grid so shared corners weld exactly.
func _node_at(p: Vector2) -> int:
	var key := "%d_%d" % [int(round(p.x * 20.0)), int(round(p.y * 20.0))]
	for n in nodes:
		if n["key"] == key:
			return int(n["id"])
	var id := nodes.size()
	nodes.append({"id": id, "pos": p, "key": key, "edges": [], "class": RoadClass.LANE})
	return id


static func _boxes_overlap(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	return (maxf(minf(a.x, b.x), minf(c.x, d.x)) <= minf(maxf(a.x, b.x), maxf(c.x, d.x))) \
		and (maxf(minf(a.y, b.y), minf(c.y, d.y)) <= minf(maxf(a.y, b.y), maxf(c.y, d.y)))


## Returns {x: t along AB, y: t along CD} or {x: false} when parallel/missing.
static func _segment_intersection(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Dictionary:
	var r := b - a
	var s := d - c
	var denom := r.cross(s)
	if absf(denom) < 1e-6:
		return {"x": false}
	var t := (c - a).cross(s) / denom
	var u := (c - a).cross(r) / denom
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return {"x": false}
	return {"x": t, "y": u}


# --------------------------------------------------------------------- queries

func node_pos(i: int) -> Vector2:
	return nodes[i]["pos"]


func edge_length(eid: int) -> float:
	var e: Dictionary = edges[eid]
	return node_pos(int(e["a"])).distance_to(node_pos(int(e["b"])))


func edge_dir(eid: int) -> Vector2:
	var e: Dictionary = edges[eid]
	return (node_pos(int(e["b"])) - node_pos(int(e["a"]))).normalized()


## Position along an edge a given distance from node `a`.
func point_on_edge(eid: int, distance: float, from_a: bool = true) -> Vector3:
	var e: Dictionary = edges[eid]
	var p0: Vector2 = node_pos(int(e["a"]))
	var p1: Vector2 = node_pos(int(e["b"]))
	var t: float = clampf(distance / maxf(p0.distance_to(p1), 0.01), 0.0, 1.0)
	var p: Vector2 = p0.lerp(p1, t) if from_a else p0.lerp(p1, 1.0 - t)
	return Vector3(p.x, 0.0, p.y)


## The other end of an edge, for driving from node to node.
func other_node(eid: int, node: int) -> int:
	var e: Dictionary = edges[eid]
	return int(e["b"]) if int(e["a"]) == node else int(e["a"])


## Nearest point on any road, as { edge, dist_along, point: Vector3, lateral: float }.
## The racing line, traffic and the reset-to-road button all use this.
func nearest_road(p: Vector3) -> Dictionary:
	var best := {"edge": -1, "dist_along": 0.0, "point": Vector3.ZERO, "lateral": 9999.0}
	var v := Vector2(p.x, p.z)
	for eid in edges.size():
		var e: Dictionary = edges[eid]
		var a := node_pos(int(e["a"]))
		var b := node_pos(int(e["b"]))
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 0.01:
			continue
		var t: float = clampf((v - a).dot(ab) / len2, 0.0, 1.0)
		var proj: Vector2 = a + ab * t
		var d: float = proj.distance_to(v)
		if d < float(best["lateral"]):
			best = {
				"edge": eid,
				"dist_along": t * sqrt(len2),
				"point": Vector3(proj.x, 0.0, proj.y),
				"lateral": d,
			}
	return best


## Builds a closed circuit through real streets.
##
## Greedy, not optimal: walk forward always taking the straightest unvisited
## continuation (which is what makes a lap feel like a lap rather than a
## zig-zag), then close the loop with the shortest path back to the start. Fast
## and deterministic, where an exhaustive search over a 250-node grid is
## exponential and would hang.
func find_loop(start: int, target_len_m: float) -> Array:
	# Sample starts across the whole graph, not just a few near `start`. The
	# greedy walk prefers going straight on, so a candidate only becomes a real
	# circuit when it happens to begin somewhere with blocks on more than one
	# side - a handful of nearby starts all make the same spike.
	var tries: Array = [start]
	var samples := 24
	for i in range(1, samples):
		tries.append(int(round(float(i) * float(nodes.size() - 1) / float(samples - 1))))

	var best: Array = []
	var best_len := 1e9
	for s in tries:
		var loop := _greedy_loop(int(s), target_len_m)
		if loop.size() < 4:
			continue
		if not _is_real_circuit(loop, target_len_m * 0.25):
			continue
		var l := _path_length(loop)
		if l < 250.0:
			continue
		if absf(l - target_len_m) < absf(best_len - target_len_m):
			best = loop
			best_len = l
	return best


## A circuit has to actually go round.
##
## `_greedy_loop` prefers straight-on movement, so on a network that ends in
## cul-de-sacs it runs to the map edge, gets stuck, and closes the loop with the
## shortest path straight back down the same street. The junction count and the
## total length both look plausible - it really is a closed walk of the right
## size - but the result is a there-and-back spike: on this network the 2283 m
## "circuit" had a 0 x 1142 m bounding box and no corners at all, which no car
## can drive and no race can be run on.
##
## A genuine circuit has extent on both axes. That is the cheap test for it, and
## it is the one that matters: a loop with no width is not a lap.
func _is_real_circuit(loop: Array, min_extent: float) -> bool:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in loop:
		var p := node_pos(int(n))
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var extent := hi - lo
	return extent.x >= min_extent and extent.y >= min_extent


func g_min(a: int, b: int) -> int:
	return mini(a, b)


func g_max(a: int, b: int) -> int:
	return maxi(a, b)


func _greedy_loop(start: int, target_len_m: float) -> Array:
	var path: Array = [start]
	var visited: Dictionary = {start: true}
	var node: int = start
	var prev_dir := Vector2.ZERO
	var length := 0.0
	var guard := 0
	while guard < 400:
		guard += 1
		if length > target_len_m * 1.6:
			break
		var best_eid := -1
		var best_score := -2.0
		for eid in nodes[node]["edges"]:
			var nxt: int = other_node(eid, node)
			if visited.has(nxt):
				continue
			var d := (node_pos(nxt) - node_pos(node)).normalized()
			# Prefer straight-on; the first move has no direction yet.
			var score: float = 1.0 if prev_dir == Vector2.ZERO else prev_dir.dot(d)
			# Prefer bigger roads slightly, so a lap uses the main streets.
			score += float(edges[eid]["class"]) * 0.05
			if score > best_score:
				best_score = score
				best_eid = eid
		if best_eid < 0:
			break
		var nxt2: int = other_node(best_eid, node)
		prev_dir = (node_pos(nxt2) - node_pos(node)).normalized()
		length += edge_length(best_eid)
		visited[nxt2] = true
		path.append(nxt2)
		node = nxt2
		if node == start:
			return path

	# Got stuck: close the loop with the shortest return path.
	var back := _shortest_path(node, start)
	if back.is_empty():
		return []
	return path + back


## Breadth-first shortest node path, inclusive of both ends.
func _shortest_path(from_node: int, to_node: int) -> Array:
	if from_node == to_node:
		return [from_node]
	var prev: Dictionary = {from_node: -1}
	var queue: Array = [from_node]
	var head := 0
	while head < queue.size():
		var n: int = queue[head]
		head += 1
		if n == to_node:
			break
		for eid in nodes[n]["edges"]:
			var nxt: int = other_node(eid, n)
			if not prev.has(nxt):
				prev[nxt] = n
				queue.append(nxt)
	if not prev.has(to_node):
		return []
	var out: Array = []
	var cur: int = to_node
	while cur != -1:
		out.push_front(cur)
		cur = int(prev[cur])
	return out


func _path_length(path: Array) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += node_pos(int(path[i])).distance_to(node_pos(int(path[i + 1])))
	return total


func stats() -> Dictionary:
	var total := 0.0
	for e in edges:
		total += edge_length(int(e["id"]))
	return {
		"nodes": nodes.size(),
		"edges": edges.size(),
		"length_m": total,
		"streets": street_names.size(),
	}
