extends SceneTree
func _init() -> void:
	var g := RoadGraph.new()
	g.build(OSMLayout.corridors())
	var def: RaceDef = null
	for d in RaceDef.catalogue(g):
		if d.closed and d.valid(): def = d
	var m := Minimap.new()
	m.size = Vector2(236, 236)
	root.add_child(m)
	m.set_graph(g)
	m.set_route_from_def(def, g)
	m.set_player(Vector3(100, 0, 100), Vector3(0, 0, -1))   # facing north
	m.set_rivals([])
	await process_frame
	await process_frame
	print("ROT spin=%.4f (north should be 0) scale=%.5f px/m" % [m._spin_for(), m._scale])
	print("  north dir on screen: %s (want ~ (0,-1))" % str(m._screen_dir(Vector2(0,-1))))
	print("  east  dir on screen: %s (want ~ (1,0))" % str(m._screen_dir(Vector2(1,0))))
	m.set_player(Vector3(100, 0, 100), Vector3(1, 0, 0))    # facing east
	await process_frame
	print("EAST spin=%.4f; heading->screen %s (want ~ (0,-1))" % [
		m._spin_for(), str(m._screen_dir(Vector2(1,0)))])
	m.set_rotate(false)
	await process_frame
	print("NORTHUP spin=%.4f (want 0)" % m._spin_for())
	print("roads baked=%d segs, scale=%.5f" % [m._road_segments.size(), m._scale])
	# check every road segment lies inside the widget
	var out := 0
	for s in m._road_segments:
		for p in s:
			if absf(p.x) > 236.0/2 + 1.0 or absf(p.y) > 236.0/2 + 1.0: out += 1
	print("road endpoints outside widget: %d" % out)
	quit()
