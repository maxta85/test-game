extends SceneTree
## t183 probe - measures, on THIS map, the three graph invariants that the
## 2legibility fix replaces the two stale absolute counts (359 / 401) with.
## Not named test_*.gd, so ./test.sh does not discover it. Run with:
##
##   /home/coder/tools/godot --headless --path . --script res://Tests/t183_probe.gd
##
## Why a probe and not the suite: t183 was authored in wt/w3, whose branch did not
## carry Tests/test_2legibility.gd. It needs Minimap, TrackMarker and RoundResult,
## and none of those three classes existed there (measured: `grep -rn "class_name
## [[:space:]]+Minimap" --include='*.gd' .` returned nothing, and so did the other
## two), so the suite could not be fixed in place without producing a suite that
## cannot compile - and an uncompilable suite costs the whole run its summary.
## The suite HAS since been fixed and applied on this branch, so this probe is no
## longer the only evidence for the three invariants; it is kept because it
## measures them with no Minimap in the way at all, and because its numbers are
## what the docstring in Tests/test_2legibility.gd quotes.

func _initialize() -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var stats := g.stats()
	var nodes: int = int(stats["nodes"])
	var edges: int = int(stats["edges"])

	var oob := 0
	var degenerate := 0
	var used := {}
	for e in g.edges:
		var a := int(e["a"])
		var b := int(e["b"])
		if a < 0 or b < 0 or a >= nodes or b >= nodes:
			oob += 1
			continue
		used[a] = true
		used[b] = true
		if g.node_pos(a).distance_squared_to(g.node_pos(b)) < 0.01:
			degenerate += 1
	var orphans: int = nodes - used.size()

	print("PROBE stats: nodes=%d edges=%d length_m=%.1f streets=%d"
		% [nodes, edges, float(stats["length_m"]), int(stats["streets"])])
	print("PROBE INV1 out_of_range_edges  = %d   (assert == 0)" % oob)
	print("PROBE INV2 orphan_junctions    = %d   (assert == 0)" % orphans)
	print("PROBE INV3 degenerate_edges    = %d   (assert == 0)" % degenerate)
	print("PROBE length floor 31000      = %s   (%.1f km)"
		% [str(float(stats["length_m"]) > 31000.0), float(stats["length_m"]) / 1000.0])
	print("PROBE stale pins in the old suite: nodes==359 -> %s, edges==401 -> %s"
		% [str(nodes == 359), str(edges == 401)])
	quit()