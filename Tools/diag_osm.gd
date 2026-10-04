extends SceneTree
## One-shot: what did the real map actually produce, does the start grid land on the
## road surface, and is it on the same street the race starts on? Run:
##   /home/coder/tools/godot --headless --path . --script res://Tools/diag_osm.gd
##
## Exits non-zero when the anchor is not the street the routes start from. That is
## the whole point of the tripwire: the anchor and the racing grid agreeing is a fact
## about the world, and a diagnostic that only prints cannot hold it.

func _initialize() -> void:
	var corridors := OSMLayout.corridors()
	var g := RoadGraph.new()
	g.build(corridors)
	var s := g.stats()
	var pick: Dictionary = AnchorChoice.pick(corridors)
	print("--- real Cairns graph ---")
	print("  anchor street: %s  (%s)" % [
		OSMLayout.anchor().get("name", "(none)"),
		String(pick.get("reason", "no rule fired"))])
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

	# The tripwire. RoadGraph numbers nodes in corridor order, so node 0 is
	# corridors[0], which is the start node every route in RaceDef.catalogue() is
	# handed. If the world anchor is any other street then the grid the player is
	# standing on and the grid the race builds are different places, and nothing in
	# the test suite notices because both land on a road.
	var start_street := ""
	if not corridors.is_empty():
		start_street = String(corridors[0]["name"])
	var grid0: Vector3 = OSMLayout.start_grid_position(0)
	var node0: Vector2 = g.node_pos(0) if g.nodes.size() > 0 else Vector2.ZERO
	var apart: float = Vector2(grid0.x, grid0.z).distance_to(node0)
	print("  node 0 is on %s at (%.0f, %.0f); grid0 is %.0f m away" % [
		start_street, node0.x, node0.y, apart])

	# The race grid itself, computed the way RaceDirector computes it, so "are these
	# the same place" is answered by building both and measuring rather than by
	# reasoning about which function calls which.
	var d := RaceDef.sprint(g, 0, 900.0, "diag", "diag")
	if d.path.size() >= 2:
		var p0: Vector2 = g.node_pos(int(d.path[0]))
		var p1: Vector2 = g.node_pos(int(d.path[1]))
		var dir: Vector2 = (p1 - p0).normalized()
		var race0 := Vector3(
			p0.x - dir.x * RaceDirector.GRID_FIRST_ROW + dir.y * RaceDirector.GRID_COLUMN,
			0.0,
			p0.y - dir.y * RaceDirector.GRID_FIRST_ROW - dir.x * RaceDirector.GRID_COLUMN)
		var race_nr: Dictionary = g.nearest_road(race0)
		var race_half: float = g.width_for(
			int(g.edges[int(race_nr["edge"])]["class"])) * 0.5
		print("  race grid0 is at (%.0f, %.0f) on %s, %.0f m from node 0 and %.0f m "
			% [race0.x, race0.z, String(g.edges[int(race_nr["edge"])]["name"]),
				Vector2(race0.x, race0.z).distance_to(p0),
				float(race_nr["lateral"])]
			+ "off a %.1f m half-width carriageway" % race_half)
		print("  world grid0 is %.0f m from race grid0 (world on %s, race on %s)" % [
			Vector2(grid0.x, grid0.z).distance_to(Vector2(race0.x, race0.z)),
			start_street, String(g.edges[int(race_nr["edge"])]["name"])])
		if float(race_nr["lateral"]) > race_half:
			print("  [warn] the race grid is off the carriageway too - that is "
				+ "RaceDirector's placement, not the anchor's")

	# Connected components from node 0. A raw OSM import grows islands; the race
	# network and traffic routing both assume one city, so a street 1.3 km out on
	# its own is worth seeing by name rather than as a failing count.
	var comps := _components(g)
	comp_info(comps, g, start_street)

	# Both anchor rules against the same data, so the replacement is a measurement
	# and not a story. `bbox` is the rule that used to run: nearest arterial to the
	# middle of the bounding box. `picked` is what World/anchor_choice.gd chose.
	var box_mid := AnchorChoice.bbox_centre(corridors)
	var med_mid := AnchorChoice.median_centre(corridors)
	print("  centres: bbox (%.0f, %.0f) is %.0f m from the per-axis median "
		% [box_mid.x, box_mid.y, box_mid.distance_to(med_mid)]
		+ "(%.0f, %.0f)" % [med_mid.x, med_mid.y])
	var runs: Array = []
	for c in corridors:
		if int(c["class"]) < RoadGraph.RoadClass.ARTERIAL:
			continue
		var pts: PackedVector2Array = c["points"]
		if pts.size() < 2:
			continue
		var ln := AnchorChoice.run_length(pts)
		if ln < AnchorChoice.MIN_ANCHOR_LEN:
			continue
		var mid := AnchorChoice.run_midpoint(pts)
		runs.append({
			"name": String(c["name"]), "len": ln, "mid": mid,
			"d_box": mid.distance_to(box_mid), "d_med": mid.distance_to(med_mid),
			"node0": String(c["name"]) == start_street,
		})
	runs.sort_custom(func(a, b): return float(a["len"]) > float(b["len"]))
	# The rule that used to run, evaluated as that rule: min(distance to the bbox
	# centre) with the same length tie-break. Reading it off the top of a
	# length-sorted table would answer "longest arterial", which is a different rule
	# and would print the right street for the wrong reason.
	var old_winner := "none"
	var old_score := INF
	for r in runs:
		var sc: float = float(r["d_box"]) - float(r["len"]) * AnchorChoice.LEN_BONUS
		if sc < old_score:
			old_score = sc
			old_winner = String(r["name"])
	print("  top arterials (len / dist from bbox centre / dist from median centre):")
	for i in mini(runs.size(), 10):
		var r: Dictionary = runs[i]
		print("    %7.0f m  %5.0f m  %5.0f m  %s%s" % [
			r["len"], r["d_box"], r["d_med"], r["name"],
			"   <- node 0" if bool(r["node0"]) else ""])
	print("  old rule (nearest arterial to the bbox centre) would pick: %s" % old_winner)
	print("  World/anchor_choice.gd picks: %s" % String(pick.get("name", "(none)")))

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

	# Every placement on the carriageway, and the anchor on the racing street.
	var bad := 0
	for label in spots:
		var p: Vector3 = spots[label]
		var nr: Dictionary = g.nearest_road(p)
		var half: float = g.width_for(int(g.edges[int(nr["edge"])]["class"])) * 0.5
		if float(nr["lateral"]) > half:
			print("  [FAIL] %s is %.1f m off a %.1f m half-width carriageway" % [
				label, float(nr["lateral"]), half])
			bad += 1
	var anchor_name := String(OSMLayout.anchor().get("name", ""))
	if anchor_name != start_street:
		print("  [FAIL] anchor is %s but every route starts on %s: grid and racing "
			% [anchor_name, start_street])
		print("         line are %.0f m apart" % apart)
		bad += 1
	if bad == 0:
		print("  [ok] anchor, grid and car meet are on %s, the street every route " % start_street)
		print("       starts on, and all three are on the carriageway")
		var side := "east" if node0.x > grid0.x else "west"
		print("  [note] the route's first junction is at the %s end of the anchor "
			% side)
		print("         street; the world start line is at the street's midpoint, so")
		print("         race grid0 and world grid0 are still hundreds of metres apart.")
		print("         What changed is the STREET: the old rule chose %s, which no" % old_winner)
		print("         route touches, and put the two grids ~1.4 km apart across two")
		print("         suburbs.")
	quit(bad)


## Connected components of the built graph, each as a node list.
func _components(g: RoadGraph) -> Array:
	var seen := {}
	var out: Array = []
	for start in g.nodes.size():
		if seen.has(start):
			continue
		var group: Array = []
		var stack: Array = [start]
		seen[start] = true
		while stack.size() > 0:
			var n: int = stack.pop_back()
			group.append(n)
			for eid in g.nodes[n]["edges"]:
				var nxt: int = g.other_node(eid, n)
				if not seen.has(nxt):
					seen[nxt] = true
					stack.append(nxt)
		out.append(group)
	out.sort_custom(func(a, b): return a.size() > b.size())
	return out


## Print the census, naming the streets in each component that is not the city, so
## an outlying fragment is identified by name instead of only as a failing count.
func comp_info(comps: Array, g: RoadGraph, start_street: String) -> void:
	var parts: Array = []
	for group in comps:
		var names := {}
		for n in group:
			for eid in g.nodes[n]["edges"]:
				var nm := String(g.edges[eid]["name"])
				if not nm.is_empty():
					names[nm] = int(names.get(nm, 0)) + 1
		var street_names := names.keys()
		street_names.sort()
		var head := ", ".join(street_names.slice(0, 4))
		if street_names.size() > 4:
			head += ", +%d more" % (street_names.size() - 4)
		parts.append("%d nodes [%s]" % [group.size(), head])
	print("  components (largest first): %s" % ", ".join(parts))
	if comps.size() > 1:
		print("  [warn] %d components: the network is not one connected city. Streets "
			% comps.size())
		print("         off node 0's component (%s) cannot be driven to from the grid."
			% start_street)