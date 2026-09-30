extends SceneTree
## One-shot: what did the real map actually produce, and does the start grid land
## on the road surface? Run:
##   /home/coder/tools/godot --headless --path . --script res://Tools/diag_osm.gd

func _initialize() -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var s := g.stats()
	print("--- real Cairns graph ---")
	print("  anchor street: %s" % OSMLayout.anchor().get("name", "(none)"))
	print("  nodes=%d edges=%d length=%.0f m streets=%d" % [
		s["nodes"], s["edges"], s["length_m"], s["streets"]])

	var spots := {
		"grid0": OSMLayout.start_grid_position(0),
		"grid1": OSMLayout.start_grid_position(1),
		"carmeet": OSMLayout.car_meet_position(),
	}
	for label in spots:
		var p: Vector3 = spots[label]
		var nr: Dictionary = g.nearest_road(p)
		print("  %-8s pos=(%.0f, %.0f)  on-road offset=%5.1f m  class=%d" % [
			label, p.x, p.z, float(nr["lateral"]), int(nr.get("class", -1))])

	# Where the real network actually sits, so the shot presets can be aimed at it.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for n in g.nodes:
		var q: Vector2 = g.node_pos(int(n["id"]))
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	print("  extent = %.0f x %.0f m, centre (%.0f, %.0f)" % [
		hi.x - lo.x, hi.y - lo.y, (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5])

	# Which arterials could carry the start line, and how far each is from the
	# middle of the city. Picking an anchor is a design decision, so do it on
	# numbers rather than on "whichever is longest".
	var mid := Vector2((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5)
	var runs: Array = []
	for c in OSMLayout.corridors():
		if int(c["class"]) < RoadGraph.RoadClass.ARTERIAL:
			continue
		var pts: PackedVector2Array = c["points"]
		if pts.size() < 2:
			continue
		var ln := 0.0
		for i in pts.size() - 1:
			ln += pts[i].distance_to(pts[i + 1])
		var c0 := (pts[0] + pts[pts.size() - 1]) * 0.5
		runs.append({"name": String(c["name"]), "len": ln, "mid": c0,
			"d": c0.distance_to(mid)})
	runs.sort_custom(func(a, b): return float(a["len"]) > float(b["len"]))
	# Hand the plot tool the placements the game actually uses, so the map
	# overview marks the real start line rather than a reimplementation of the
	# anchor rule in Python that can drift from World/osm_layout.gd.
	var sl: Dictionary = OSMLayout.start_line()
	var out := {
		"anchor": OSMLayout.anchor().get("name", ""),
		"start_line": [sl["pos"].x, sl["pos"].z],
		"grid": [OSMLayout.start_grid_position(0).x, OSMLayout.start_grid_position(0).z],
		"car_meet": [OSMLayout.car_meet_position().x, OSMLayout.car_meet_position().z],
	}
	var f := FileAccess.open("res://shots/placements.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
		print("  wrote shots/placements.json (anchor=%s)" % out["anchor"])

	print("  top arterials (len / midpoint / dist from centre):")
	for i in mini(runs.size(), 10):
		var r: Dictionary = runs[i]
		print("    %7.0f m  mid=(%5.0f,%6.0f)  %5.0f m out  %s" % [
			r["len"], r["mid"].x, r["mid"].y, r["d"], r["name"]])
	quit(0)
