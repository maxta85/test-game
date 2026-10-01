extends SceneTree
## Checks the road markings without building the world.
##
## `_lane_markings` and `_junction_control` only need the graph and the batch
## accumulator, so they can be run in isolation and their instance transforms
## read back out. That makes the two things that actually go wrong - a line drawn
## across a junction's tarmac, and a give-way row painted where the patch is
## instead of at its edge - into assertions instead of something you notice in a
## screenshot from 420 m up.
##
##   godot --headless --path . --script res://Systems/road_render/markings_check.gd

var _fails := 0


func _initialize() -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())

	var wb := WorldBuilder.new()
	wb.graph = g
	wb._lane_markings()
	wb._junction_control()

	var lines := _instances(wb, "markings")
	var rows := _instances(wb, "giveway")
	print("MARKINGS line_instances=%d giveway_instances=%d" % [lines.size(), rows.size()])

	if lines.size() == 0:
		_fail("no lane markings emitted")
	if rows.size() == 0:
		_fail("no give-way rows emitted")

	# Nothing may be painted inside the tarmac patch a junction draws, so no
	# marking is a line through a give-way row. Stop bars sit one inset past the
	# patch edge and still pass; that inset is what this radius is for.
	for xf in lines:
		var p: Vector3 = xf.origin
		var q := Vector2(p.x, p.z)
		var node := _junction_near(g, q)
		if node < 0:
			continue
		var d := q.distance_to(g.node_pos(node))
		var r: float = g.width_for(int(g.nodes[node]["class"])) * 0.5
		if d < r:
			_fail("marking %.2f m from node %d is inside its %.2f m patch" % [d, node, r])

	# Give-way rows sit just outside the patch, not in the middle of it. The row
	# is laid across the approach, so its outer triangles are up to half a
	# carriageway further from the node than its centre ones: the near limit is
	# the patch, the far limit is the patch plus that spread.
	for xf in rows:
		var p: Vector3 = xf.origin
		var q := Vector2(p.x, p.z)
		var node := _junction_near(g, q)
		var r: float = g.width_for(int(g.nodes[node]["class"])) * 0.5
		var d := q.distance_to(g.node_pos(node))
		if d < r or d > r + 11.0:
			_fail("give-way triangle %.2f m from node %d, patch radius %.2f m" % [d, node, r])

	print("MARKINGS %s" % ("FAILURES=%d" % _fails if _fails > 0 else "ok"))
	quit(1 if _fails > 0 else 0)


## Every transform in a batch, across every material key in it.
func _instances(wb: WorldBuilder, batch: String) -> Array:
	var out: Array = []
	if not wb._batches.has(batch):
		return out
	var entry: Dictionary = wb._batches[batch]
	for key in entry["meshes"]:
		out.append_array(entry["meshes"][key]["list"])
	return out


## Index of the junction (3+ edges) nearest p, or -1 if the map has none.
func _junction_near(g: RoadGraph, p: Vector2) -> int:
	var best := -1
	var best_d := INF
	for i in g.nodes.size():
		var n: Dictionary = g.nodes[i]
		if int(n["edges"].size()) < 3:
			continue
		var d := p.distance_to(g.node_pos(i))
		if d < best_d:
			best_d = d
			best = i
	return best


func _fail(msg: String) -> void:
	_fails += 1
	push_error("MARKINGS: " + msg)