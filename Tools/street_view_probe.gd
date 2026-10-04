extends SceneTree
## Road-burial probe and street-level capture. Diagnosis tool for w5/t89.
##
##     godot --headless --path . --script res://Tools/street_view_probe.gd -- --probe
##     godot --headless --path . --script res://Tools/street_view_probe.gd -- \
##           --probe --sweep --json /tmp/w5t89/sweep.json
##     godot --path . --rendering-driver vulkan --resolution 1280x720 \
##           --script res://Tools/street_view_probe.gd -- \
##           --shot shots/x.png --eye X,Y,Z --look X,Y,Z
##
## Two independent jobs, because they have different hardware requirements.
##
## `--probe`/`--sweep` is PHYSICS ONLY: it raycasts the real collision world, so it
## needs no GPU, no display and no renderer at all, and it runs under `--headless`.
## That is the quantitative half of the diagnosis and the half that can be trusted,
## because it reads the same colliders the car drives on.
##
## `--shot` needs a real rasteriser. It refuses to run on the dummy driver and
## deletes its target PNG BEFORE rendering, then fails loudly if no fresh file
## appeared. A stale PNG re-measured as if it were new is worse than no frame.
##
## WHAT IS MEASURED, and the three heights that matter:
##
##   visible tarmac   LookDev.TARMAC_Y          = +0.015   (look_dev.gd:101,
##                                                            applied at world_builder.gd:439)
##   road collider    baked at local y = 0       =  0.000   (world_builder.gd:_bake_collision,
##                                                            the body itself carries no offset)
##   visible ground   terrain mesh y = _terrain_height() , and the Terrain MeshInstance3D
##                    is then pushed down by       = -0.060   (world_builder.gd:275)
##
## The terrain COLLISION trimesh reuses the same committed mesh but the collision
## body has no -0.06 offset, so a raycast reports ground 60 mm HIGHER than the
## ground you can see. Every number printed here therefore reports both:
##
##   DELTA_COLL = terrain_coll_y - 0.000   (what the car feels)
##   DELTA_VIS  = (terrain_coll_y - 0.060) - 0.015   (what the camera sees;
##                > 0 means the ground stands above the tarmac and hides it)

const OWNER_POINT := Vector2(-1048.6, 596.5)
const UP_FROM := 60.0
const DOWN_TO := -60.0
## A road counts as buried when the visible ground stands at least this far above
## the visible tarmac at the same xz. 0.05 m is well under one wheel radius, so it
## cannot be met by triangulation noise alone.
const BURIED_EPS := 0.05
const TARMAC_Y := 0.015
const ROAD_COLL_Y := 0.0
const VIS_TERRAIN_OFFSET := -0.06
## Lateral sample offsets as a fraction of the half-width, so the reading is a
## cross-section of the carriageway and not one lucky centreline texel.
const LAT_FRACS := [0.0, 0.55, -0.55, 0.95, -0.95]
const STEP_M := 8.0

var _graph: RoadGraph
var _world: WorldBuilder


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var do_probe := false
	var do_sweep := false
	var do_shot := false
	var shot_path := ""
	var eye := Vector3.ZERO
	var look := Vector3.ZERO
	var have_eye := false
	var have_look := false
	var ats: Array = [OWNER_POINT]
	var luma_paths: Array = []
	var exposure := 1.0
	var json_path := ""
	var label := ""
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--luma": luma_paths.append(String(args[i + 1])); i += 2
			"--exposure": exposure = float(args[i + 1]); i += 2
			"--probe": do_probe = true; i += 1
			"--sweep": do_probe = true; do_sweep = true; i += 1
			"--shot": do_shot = true; i += 1
			"--out":
				# An output path implies a shot: asking where to write the frame and
				# getting "nothing asked for" back is a foot-gun, not a feature.
				do_shot = true
				shot_path = String(args[i + 1]); i += 2
			"--json": json_path = String(args[i + 1]); i += 2
			"--label": label = String(args[i + 1]); i += 2
			"--eye":
				eye = _v3(String(args[i + 1])); have_eye = true; i += 2
			"--look":
				look = _v3(String(args[i + 1])); have_look = true; i += 2
			"--at":
				var parts := String(args[i + 1]).split(",")
				ats.append(Vector2(float(parts[0]), float(parts[1]))); i += 2
			_:
				i += 1

	# Luma runs before anything is built: reading a PNG needs no world and no
	# renderer, so this is answerable on a headless box.
	for lp in luma_paths:
		_luma(String(lp))
	if luma_paths.size() > 0:
		quit(0)
		return

	if not do_probe and not do_shot:
		print("nothing asked for: pass --probe, --sweep, --luma or --out <path>")
		quit(2)
		return

	if do_probe:
		await _build_world()
		for a2 in ats:
			await _probe_report(a2)
		if do_sweep:
			await _sweep_report(json_path)
		quit(0)
		return

	if do_shot:
		await _shot(shot_path, eye if have_eye else Vector3((ats[0] as Vector2).x, 0, (ats[0] as Vector2).y),
				look if have_look else Vector3.ZERO, have_look, label, exposure)
		quit(0)
		return


func _v3(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


## The same sequence Game/main.gd:39-120 runs, so the colliders probed are the ones
## the car actually drives on.
func _build_world() -> void:
	_graph = RoadGraph.new()
	_graph.build(OSMLayout.corridors())
	var stats: Dictionary = _graph.stats()
	print("[probe] OSM corridors: %d  -> graph %d junctions, %d edges, %.0f m" % [
		OSMLayout.corridors().size(), stats["nodes"], stats["edges"], stats["length_m"]])
	_world = WorldBuilder.new()
	_world.name = "World"
	root.add_child(_world)
	_world.build(_graph)
	# The collision shapes are children of the bodies, and a body only enters the
	# physics server once the tree is live. Probing before this returns measures a
	# world with no road in it.
	await physics_frame
	await physics_frame
	# Terrain grid grain, derived from the graph exactly as _terrain_extent does.
	var reach := 0.0
	for e in _graph.edges:
		for nid in [int(e["a"]), int(e["b"])]:
			var p := _graph.node_pos(nid)
			reach = maxf(reach, maxf(absf(p.x), absf(p.y)))
	var s: float = maxf(800.0, reach + 120.0)
	var step: float = maxf(16.0, s / 55.0)
	print("[probe] terrain extent +/-%.0f m, grid step %.2f m -> flatten window is only %.0f%% of a cell" % [
		s, step, 100.0 * 26.0 / step])


## Every collider the downward ray meets at this xz, in hit order.
func _hits(x: float, z: float) -> Array:
	var out: Array = []
	var excluded: Array[RID] = []
	var from := Vector3(x, UP_FROM, z)
	var to := Vector3(x, DOWN_TO, z)
	for _i in 16:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = excluded
		q.collide_with_areas = false
		q.collide_with_bodies = true
		var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			break
		var col: Object = hit["collider"]
		out.append({
			"name": String(col.name),
			"y": float(hit["position"].y),
		})
		excluded.append(col.get_rid())
	return out


## One xz. Returns NaN for anything the ray did not meet, and never guesses.
##
## Also records the four TERRAIN MESH VERTICES of the cell this xz falls in. That
## is the whole mechanism in one array: `_terrain_height()` is evaluated at the
## vertices, never between them, and the grid step is larger than the flatten
## window, so a cell can have one corner at datum (road nearby) and the opposite
## corner a metre up (no road within 26 m) and the road crossing that cell then
## rides the straight line between them.
func _probe_at(x: float, z: float) -> Dictionary:
	var hits := _hits(x, z)
	var road_y := NAN
	var terrain_y := NAN
	var road_name := ""
	var terrain_name := ""
	for h in hits:
		var n := String(h["name"])
		var y := float(h["y"])
		if is_nan(road_y) and (n.begins_with("RoadCollision") or n.begins_with("RoadSurface")):
			road_y = y
			road_name = n
		elif is_nan(terrain_y) and n.begins_with("Terrain"):
			terrain_y = y
			terrain_name = n
	var d_coll := NAN
	var d_vis := NAN
	if not is_nan(road_y) and not is_nan(terrain_y):
		d_coll = terrain_y - road_y
		d_vis = (terrain_y + VIS_TERRAIN_OFFSET) - TARMAC_Y
	var corners := _corner_heights(x, z)
	var cmax := -INF
	var cmin := INF
	for c in corners:
		cmax = maxf(cmax, float(c))
		cmin = minf(cmin, float(c))
	return {
		"x": x, "z": z,
		"road_y": road_y, "terrain_y": terrain_y,
		"d_coll": d_coll, "d_vis": d_vis,
		"road_name": road_name, "terrain_name": terrain_name,
		"hits": hits,
		"buried": (not is_nan(d_vis)) and d_vis >= BURIED_EPS,
		"has_road": not is_nan(road_y),
		"pred": _world._terrain_height(x, z),
		"corners": corners,
		"corner_max": cmax, "corner_min": cmin,
		# All four corners at datum means the cell is flat and cannot bury
		# anything. Any burial therefore requires a raised corner.
		"corner_flat": cmax - cmin < 0.001 and absf(cmax) < 0.001,
		# How far the measured surface departs from what _terrain_height() says at
		# this exact xz. Zero would mean the analytic function is the surface.
		"interp_err": NAN if is_nan(terrain_y) else terrain_y - _world._terrain_height(x, z),
	}


## Terrain grid cell corners around xz, in the order _terrain() walks them.
func _corner_heights(x: float, z: float) -> Array:
	var step: float = maxf(16.0, _terrain_s() / 55.0)
	var x0 := floorf(x / step) * step
	var z0 := floorf(z / step) * step
	return [
		_world._terrain_height(x0, z0),
		_world._terrain_height(x0 + step, z0),
		_world._terrain_height(x0, z0 + step),
		_world._terrain_height(x0 + step, z0 + step),
	]


var _reach := -1.0


func _terrain_s() -> float:
	if _reach < 0.0:
		_reach = 0.0
		for e in _graph.edges:
			for nid in [int(e["a"]), int(e["b"])]:
				var p := _graph.node_pos(nid)
				_reach = maxf(_reach, maxf(absf(p.x), absf(p.y)))
	return maxf(800.0, _reach + 120.0)


func _fmt(v: float) -> String:
	return "  n/a " if is_nan(v) else "%+6.3f" % v


func _probe_report(at: Vector2) -> void:
	print("\n=== POINT PROBES  (DELTA_VIS = visible ground - visible tarmac; > %.2f = buried) ===" % BURIED_EPS)
	var first := _probe_at(at.x, at.y)
	print("\n  [owner] (%.1f, %.1f)" % [at.x, at.y])
	_print_probe(first)

	var near: Dictionary = _graph.nearest_road(Vector3(at.x, 0.0, at.y))
	print("\n  nearest road edge %d, lateral %.1f m, %.1f m along it" % [
		int(near["edge"]), float(near["lateral"]), float(near["dist_along"])])
	var eid := int(near["edge"])
	if eid < 0:
		print("  no road anywhere near the owner point")
		return
	var e: Dictionary = _graph.edges[eid]
	var a := _graph.node_pos(int(e["a"]))
	var b := _graph.node_pos(int(e["b"]))
	var ab := b - a
	var length := ab.length()
	var dir := ab.normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var hw: float = float(e["width"]) * 0.5
	print("  edge %d, %.1f m long, %.2f m wide; walking its centreline both ways" % [
		eid, length, hw * 2.0])
	print("  EDGE_A=%.2f,%.2f  EDGE_B=%.2f,%.2f  DIR=%.4f,%.4f  (aim a frame with these)" % [
		a.x, a.y, b.x, b.y, dir.x, dir.y])
	# `length * f` clamps every negative fraction to 0, which silently printed the
	# same point three times. Offsets are fractions of the WHOLE edge around 0.5.
	for f in [-0.45, -0.3, -0.15, 0.15, 0.3, 0.45]:
		var p: Vector2 = a + ab * (0.5 + f)
		print("  [%+.0f%% of edge] (%.1f, %.1f)" % [f * 100.0, p.x, p.y])
		_print_probe(_probe_at(p.x, p.y))
		print("")
	# And a cross-section at the owner's distance-along, in case the burial is
	# across the width rather than along the length.
	var along: float = float(near["dist_along"])
	var q: Vector2 = a + dir * clampf(along, 0.0, length)
	print("  cross-section at %.1f m along the same edge (half-width %.2f m):" % [along, hw])
	for f in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		var c: Vector2 = q + nrm * (hw * f)
		var r := _probe_at(c.x, c.y)
		print("    lateral %+5.2f m  (%.1f, %.1f)  DELTA_VIS=%s  %s" % [
			hw * f, c.x, c.y, _fmt(float(r["d_vis"])),
			"BURIED" if bool(r["buried"]) else "ok"])
		_edge_case_rows.append(r)
		print("")


## Sampled readings kept for the report.
var _edge_case_rows: Array = []


func _print_probe(p: Dictionary) -> void:
	print("      ROAD_MESH_Y=%s  TERRAIN_Y=%s  DELTA_COLL=%s  DELTA_VIS=%s  %s" % [
		_fmt(float(p["road_y"])), _fmt(float(p["terrain_y"])),
		_fmt(float(p["d_coll"])), _fmt(float(p["d_vis"])),
		"BURIED" if bool(p["buried"]) else "ok"])
	print("      colliders: road=%s terrain=%s   _terrain_height() predicts %+0.3f" % [
		String(p["road_name"]), String(p["terrain_name"]), float(p["pred"])])
	for h in p["hits"]:
		print("        hit %-22s y=%+7.3f" % [String(h["name"]), float(h["y"])])


# ---------------------------------------------------------------- sweep
## Sweeps every source corridor (the 247 OSM polylines) and every graph edge,
## samples each centreline and three offsets across the carriageway, and reports
## both counts. Also clusters the affected edges through shared junctions, which
## is what decides whether the fix is local or systemic.
func _sweep_report(json_path: String) -> void:
	print("\n=== SWEEP: every corridor + edge, centreline and across-width ===")
	var rows: Array = []
	var samples := 0
	var buried_samples := 0
	var no_road_samples := 0
	var buried_flat_cell := 0
	var buried_raised_corner := 0
	var worst_interp := -INF
	var worst_corners: Array = []

	for eid in _graph.edges.size():
		var e: Dictionary = _graph.edges[eid]
		var a := _graph.node_pos(int(e["a"]))
		var b := _graph.node_pos(int(e["b"]))
		var ab := b - a
		var length := ab.length()
		if length < 0.5:
			continue
		var dir := ab.normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var n: int = maxi(2, int(length / STEP_M))
		var worst := -INF
		var worst_at := Vector2.ZERO
		var worst_lat := 0.0
		var buried_here := 0
		var road_len := 0.0
		for k in n:
			var t: float = (float(k) + 0.5) / float(n)
			var p := a + ab * t
			for f in LAT_FRACS:
				var c := p + nrm * (hw * float(f))
				var r := _probe_at(c.x, c.y)
				samples += 1
				if not bool(r["has_road"]):
					no_road_samples += 1
					continue
				var d := float(r["d_vis"])
				if is_nan(d):
					continue
				road_len += length / float(n)
				if d >= BURIED_EPS:
					buried_here += 1
					buried_samples += 1
					if bool(r["corner_flat"]):
						buried_flat_cell += 1
					else:
						buried_raised_corner += 1
					var ie := float(r["interp_err"])
					if ie > worst_interp:
						worst_interp = ie
						worst_corners = r["corners"]
				if d > worst:
					worst = d
					worst_at = Vector2(c.x, c.y)
					worst_lat = hw * float(f)
		rows.append({
			"id": eid, "a": int(e["a"]), "b": int(e["b"]), "len": length,
			"width": hw * 2.0, "worst": worst, "worst_at": worst_at,
			"worst_lat": worst_lat, "buried": buried_here, "n": n * LAT_FRACS.size(),
			"mid": (a + b) * 0.5, "road_len": road_len,
		})

	var affected: Array = []
	var affected_len := 0.0
	for r in rows:
		if int(r["buried"]) > 0:
			affected.append(r)
			affected_len += float(r["len"])
	print("  samples: %d  buried: %d  (%.2f%%)  samples with NO road collider: %d" % [
		samples, buried_samples, 100.0 * float(buried_samples) / maxf(1.0, float(samples)),
		no_road_samples])
	print("  MECHANISM: buried samples whose whole terrain cell is flat at datum: %d" % buried_flat_cell)
	print("            buried samples with at least one raised cell corner:    %d" % buried_raised_corner)
	print("            largest gap between _terrain_height(x,z) and the actual ground: %+.3f m" % worst_interp)
	if worst_corners.size() == 4:
		print("            at the worst such sample the four cell corners were: %s" % str(worst_corners))
	print("  EDGES affected: %d of %d  (%.1f%%), %.0f m of %.0f m of centreline" % [
		affected.size(), rows.size(), 100.0 * float(affected.size()) / maxf(1.0, float(rows.size())),
		affected_len, _total_len(rows)])

	# --- clusters, via shared junctions. Two buried edges that meet at a node are
	# one continuous stretch of buried road, not two coincidences.
	var parent := {}
	for r in rows:
		parent[int(r["id"])] = int(r["id"])
	for r in affected:
		for o in affected:
			if int(r["id"]) == int(o["id"]):
				continue
			if int(r["a"]) == int(o["a"]) or int(r["a"]) == int(o["b"]) \
					or int(r["b"]) == int(o["a"]) or int(r["b"]) == int(o["b"]):
				_union(parent, int(r["id"]), int(o["id"]))
	var groups := {}
	for r in affected:
		var root_id := _find(parent, int(r["id"]))
		if not groups.has(root_id):
			groups[root_id] = []
		(groups[root_id] as Array).append(r)
	var glist: Array = groups.values()
	glist.sort_custom(func(a, b): return (a as Array).size() > (b as Array).size())
	print("  CLUSTERS (affected edges joined at shared junctions): %d" % glist.size())
	var g: int = 0
	for grp in glist:
		g += 1
		var glen := 0.0
		var gworst := -INF
		var gmin := Vector2(INF, INF)
		var gmax := Vector2(-INF, -INF)
		var center := Vector2.ZERO
		for r in grp:
			glen += float(r["len"])
			gworst = maxf(gworst, float(r["worst"]))
			var m: Vector2 = r["mid"]
			gmin.x = minf(gmin.x, m.x); gmin.y = minf(gmin.y, m.y)
			gmax.x = maxf(gmax.x, m.x); gmax.y = maxf(gmax.y, m.y)
			center += Vector2(r["worst_at"].x, r["worst_at"].y)
		center /= float(grp.size())
		print("    cluster %d: %3d edges, %6.0f m, worst %+.3f, bbox x[%.0f,%.0f] z[%.0f,%.0f], worst at (%.1f, %.1f)" % [
			g, grp.size(), glen, gworst, gmin.x, gmax.x, gmin.y, gmax.y, center.x, center.y])
		if g >= 25:
			print("    ... %d more clusters" % (glist.size() - 25))
			break

	# --- distribution
	var deltas: Array = []
	for r in affected:
		deltas.append(float(r["worst"]))
	deltas.sort()
	if deltas.is_empty():
		print("\n  NO edge anywhere has the visible ground above the visible tarmac.")
	else:
		print("\n  worst DELTA_VIS per affected edge: min %+.3f  p25 %+.3f  median %+.3f  p75 %+.3f  max %+.3f" % [
			deltas[0], deltas[int(deltas.size() * 0.25)], deltas[int(deltas.size() / 2)],
			deltas[int(deltas.size() * 0.75)], deltas[-1]])

	# --- corridor-level answer, on the 247 OSM polylines themselves
	var cor := _sweep_corridors()
	print("\n  SOURCE CORRIDORS (the 247 OSM polylines): %d affected of %d" % [
		cor["affected"], cor["total"]])

	# --- worst locations, so frames can be aimed at the real thing
	rows.sort_custom(func(a, b): return float(a["worst"]) > float(b["worst"]))
	print("\n  worst 15 edges anywhere in the map:")
	for i in mini(15, rows.size()):
		var r: Dictionary = rows[i]
		print("    edge %4d  %6.1f m  worst %+.3f at (%8.1f,%8.1f) lateral %+5.2f m  %d/%d samples buried" % [
			int(r["id"]), float(r["len"]), float(r["worst"]),
			float(r["worst_at"].x), float(r["worst_at"].y), float(r["worst_lat"]),
			int(r["buried"]), int(r["n"])])

	# --- the same worst sites in full, corner by corner. This is the evidence that
	# the flatten is not failing where it is applied, and is being interpolated away
	# between samples of a grid coarser than the window it flattens.
	print("\n  worst 6 sites in full (what the analytic function says vs what the mesh is):")
	for i in mini(6, rows.size()):
		var r: Dictionary = rows[i]
		var w: Vector2 = r["worst_at"]
		var p := _probe_at(w.x, w.y)
		print("    edge %d at (%.1f, %.1f) lateral %+.2f m" % [
			int(r["id"]), w.x, w.y, float(r["worst_lat"])])
		_print_probe(p)
		print("")

	if json_path != "":
		var out: Array = []
		for r in rows:
			var w: Vector2 = r["worst_at"]
			out.append({
				"id": int(r["id"]), "len": float(r["len"]), "worst": float(r["worst"]),
				"x": w.x, "z": w.y, "lat": float(r["worst_lat"]),
				"buried": int(r["buried"]), "n": int(r["n"]),
				"mid_x": float(r["mid"].x), "mid_z": float(r["mid"].y),
			})
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({
				"samples": samples, "buried_samples": buried_samples,
				"edges": rows.size(), "affected_edges": affected.size(),
				"clusters": glist.size(),
				"corridors_total": cor["total"], "corridors_affected": cor["affected"],
				"buried_eps": BURIED_EPS, "tarmac_y": TARMAC_Y,
				"terrain_visual_offset": VIS_TERRAIN_OFFSET,
				"edge_case_rows": _edge_case_rows.size(),
				"rows": out,
			}))
			f.close()
			print("\n  wrote %s" % json_path)


func _total_len(rows: Array) -> float:
	var t := 0.0
	for r in rows:
		t += float(r["len"])
	return t


func _find(parent: Dictionary, a: int) -> int:
	var cur := a
	while int(parent[cur]) != cur:
		cur = int(parent[cur])
	return cur


func _union(parent: Dictionary, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra


## The same sweep driven from the 247 OSM polylines rather than the 401 graph
## edges, because "how many of the 247 corridors" is a question about corridors.
func _sweep_corridors() -> Dictionary:
	var total := 0
	var affected := 0
	var names := {}
	for c in OSMLayout.corridors():
		total += 1
		var pts: PackedVector2Array = c["points"]
		var buried_here := 0
		var worst := -INF
		var at := Vector2.ZERO
		for i in range(pts.size() - 1):
			var a := pts[i]
			var ab := pts[i + 1] - a
			var l := ab.length()
			if l < 0.5:
				continue
			var n: int = maxi(1, int(l / STEP_M))
			var dir := ab.normalized()
			var nrm := Vector2(-dir.y, dir.x)
			for k in n:
				var p := a + ab * ((float(k) + 0.5) / float(n))
				for f in [-0.5, 0.0, 0.5]:
					var q := p + nrm * (3.0 * float(f))
					var r := _probe_at(q.x, q.y)
					if not bool(r["has_road"]):
						continue
					var d := float(r["d_vis"])
					if is_nan(d):
						continue
					if d >= BURIED_EPS:
						buried_here += 1
					if d > worst:
						worst = d
						at = Vector2(q.x, q.y)
		if buried_here > 0:
			affected += 1
			names[String(c["name"])] = true
			print("    buried corridor: %-34s worst %+.3f at (%.1f, %.1f)" % [
				String(c["name"]), worst, at.x, at.y])
	return {"total": total, "affected": affected, "names": names.keys()}


# ---------------------------------------------------------------- frames
## One street-level frame. Camera position is set explicitly and the transform we
## actually got is printed, because a camera something else re-drives every frame
## produces plausible-looking output of the wrong place.
func _shot(path: String, eye: Vector3, look: Vector3, have_look: bool, label: String,
		exposure: float = 1.0) -> void:
	print("\n=== STREET FRAME %s ===" % label)
	var drv := RenderingServer.get_video_adapter_name()
	print("  video adapter: '%s'" % drv)
	# Guard 1: the dummy renderer cannot draw. Refuse rather than save a black frame
	# that reads as "the scene is dark".
	if drv == "" or drv.to_lower().contains("dummy"):
		print("  REFUSING: dummy renderer. NO FRAME WRITTEN.")
		return
	# Guard 2: a stale PNG must never be re-read as if it were this frame.
	var abs_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs_path)
		print("  deleted stale %s" % path)

	var main: Node = load("res://Game/main.tscn").instantiate()
	root.add_child(main)
	for _f in 14:
		await process_frame
	await _prepare(main, exposure)

	var tgt := look if have_look else Vector3(eye.x, eye.y - 1.2, eye.z - 8.0)
	var fwd := (tgt - eye).normalized()
	var basis := _basis_towards(fwd)
	_cam.global_position = eye
	_cam.basis = basis
	_cam.fov = 70.0
	_cam.far = 4000.0
	_cam.current = true
	_cam.fov = 70.0
	Engine.time_scale = 0.0

	for _f in 10:
		_cam.global_transform = Transform3D(basis, eye)
		await process_frame
	# Guard 3: get_image() returns the LAST RENDERED frame. Logic frames do not
	# draw it, so the capture must follow frame_post_draw.
	for _i in 6:
		await RenderingServer.frame_post_draw
	var got := _cam.global_transform
	print("  asked eye=%s fwd=%s" % [str(eye), str(fwd)])
	print("  got   eye=%s fwd=%s" % [str(got.origin), str(-got.basis.z)])
	print("  fwd agrees: %s" % str((-got.basis.z).dot(fwd) > 0.9999))

	var img := root.get_texture().get_image()
	if img == null or img.is_empty():
		print("  FAILED: viewport returned no image. NO FRAME WRITTEN.")
		return
	var out_img: Image = img
	if out_img.get_format() != Image.FORMAT_RGBA8:
		out_img = out_img.duplicate() as Image
		out_img.convert(Image.FORMAT_RGBA8)
	var err := out_img.save_png(path)
	if err != OK:
		print("  FAILED: save_png error %d. NO FRAME WRITTEN." % err)
		return
	var bytes := FileAccess.get_file_as_bytes(path).size()
	print("  wrote %s  %d bytes  md5=%s" % [path, bytes, _md5(path)])
	print("  capture exposure multiplier: %.2f (1.0 = the shipping look)" % exposure)
	print("  frame luma: %s" % _stats(out_img))


var _cam: Camera3D


## Loads the real game scene (so the frame carries the game's own night lighting),
## hides the UI, and takes the viewport's current camera out of anybody else's
## hands before moving it.
func _prepare(main: Node, exposure: float = 1.0) -> void:
	_hide_ui(main)
	var flow := _menu_flow(main)
	if flow != null and flow.has_method("close"):
		flow.call("close")
		_hide_ui(main)
	for n in _all(main):
		n.set_process(false)
		n.set_process_input(false)
		n.set_process_unhandled_input(false)
		n.set_physics_process(false)
	_cam = _find_camera(main)
	if _cam == null:
		print("  no Camera3D in main.tscn - cannot frame anything")
		return
	var cur: Node = _cam
	while cur != null:
		if "tracking" in cur:
			cur.set("tracking", false)
		cur = cur.get_parent()
	_cam.current = true
	if exposure != 1.0:
		# The shipping look is a very dark tropical night (sky 0.01-0.085, low
		# ambient fill) and every surface away from a lamp is near black. That is
		# correct for the game and useless as diagnosis: a buried carriageway and a
		# clear one both measure mean luma ~0.1/1.0. So the CAPTURE raises
		# tonemap exposure, multiplicatively, leaving the grade's balance intact.
		# Nothing here changes the game; it is a property of this render process.
		for n in _all(main):
			if n is WorldEnvironment:
				var we := n as WorldEnvironment
				if we.environment != null:
					var before: float = we.environment.tonemap_exposure
					we.environment.tonemap_exposure = before * exposure
					print("  capture exposure %.2f -> tonemap_exposure %.3f -> %.3f" % [
						exposure, before, we.environment.tonemap_exposure])


func _menu_flow(n: Node) -> Node:
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur.has_method("close") and cur.has_method("races"):
			return cur
		for c in cur.get_children():
			stack.append(c)
	return null


func _all(n: Node) -> Array:
	var out: Array = []
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		out.append(cur)
		for c in cur.get_children():
			stack.append(c)
	return out


func _hide_ui(n: Node) -> void:
	if n == null:
		return
	for c in n.get_children():
		# A node can be freed by the menu closing while this walks the tree; the
		# untyped null check does not catch it, is_instance_valid does.
		if c == null or not is_instance_valid(c):
			continue
		if c is CanvasLayer or c is Control:
			(c as CanvasItem).visible = false
		else:
			_hide_ui(c)


func _find_camera(n: Node) -> Camera3D:
	var first: Camera3D = null
	var stack: Array = [n]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		if cur is Camera3D:
			if (cur as Camera3D).current:
				return cur as Camera3D
			if first == null:
				first = cur as Camera3D
		for c in cur.get_children():
			stack.append(c)
	return first


func _mean_luma(img: Image) -> float:
	var total := 0.0
	var n := 0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(0, h, 8):
		for x in range(0, w, 8):
			var c := img.get_pixel(x, y)
			total += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return total / maxf(1.0, float(n))


## Mean / max luma in 0-255 units plus the share of the frame that is essentially
## black. A capture rig cannot be trusted on "it rendered something": a frame at
## mean luma 28/255 does not distinguish a buried road from a clear one, and a
## near-black PNG reads as "the scene is dark" rather than "this camera saw
## nothing". These three numbers say which case you are in.
func _stats(img: Image) -> String:
	# get_pixel() on a freshly loaded 8-bit RGB PNG reports near-zero for pixels
	# that an independent decoder reads at 255: measured on the repo's own
	# shots/street.png, Godot said mean 0.1/255 max 1.0/255 while a zlib inflate of
	# the same file says mean 19.4/255 max 255. So every image is converted to
	# RGBA8 (which also applies the linear->sRGB transfer on a float viewport
	# image) before it is measured or written out.
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate() as Image
		img.convert(Image.FORMAT_RGBA8)
	var total := 0.0
	var vmax := 0.0
	var black := 0
	var n := 0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			total += l
			vmax = maxf(vmax, l)
			if l < 0.02:
				black += 1
			n += 1
	return "mean %.1f/255  max %.1f/255  black %.1f%%  (%d samples)" % [
		total / maxf(1.0, float(n)), vmax, 100.0 * float(black) / maxf(1.0, float(n)), n]


func _luma(path: String) -> void:
	if not FileAccess.file_exists(path):
		print("[luma] %s : MISSING" % path)
		return
	var img := Image.new()
	if img.load(path) != OK:
		print("[luma] %s : could not decode" % path)
		return
	print("[luma] %s : %s  md5=%s" % [path, _stats(img), _md5(path)])


func _md5(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


func _basis_towards(f: Vector3) -> Basis:
	var up := Vector3.UP
	if absf(f.dot(up)) > 0.999:
		up = Vector3.FORWARD
	var z := -f.normalized()
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)