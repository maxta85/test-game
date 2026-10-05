extends SceneTree
##
## t191 corridor audit: does any solid prop stand in the Hoare Street drivable
## corridor?
##
##     godot --headless --path . --script res://World/corridor_audit.gd -- \
##           --screen=on --out=/tmp/reports
##     godot --headless --path . --script res://World/corridor_audit.gd -- \
##           --screen=off --out=/tmp/reports          # the BEFORE picture
##
## WHY THIS IS NOT A COUNT OF WHAT `world_builder.gd` SAYS IT DID
##
## A change that fixes a road obstruction and then reports its own success is not
## evidence. `WorldBuilder._screen_verge()` records how many placements it pushed;
## if that number is wrong, if the push lands the trunk somewhere else just as bad,
## or if a plant's mesh origin is not where its trunk is, the self-report is still a
## happy number. So this reads the **built geometry**: every `MultiMeshInstance3D` in
## the finished world, every instance transform out of the MultiMesh, and for each
## one the trunk measured from that mesh's own vertices. Nothing here asks
## `WorldBuilder` what it did - its self-report is printed beside the answer, not
## merged into it.
##
## WHY GEOMETRY AND NOT NAMES
##
## The first version of this identified plants by node and material name and measured
## **zero** instances while the world plainly contained 3256 of them, and then
## printed `ROAD_OBSTRUCTION_COUNT=0`. The batches are `MultiMeshInstance3D` HOLDERS
## whose own `multimesh` is null and whose children are auto-named, `ArtKitBatch`'s
## default label is the same string for the scrub batch and the tree batch, and the
## materials are unnamed `StandardMaterial3D`. So the name was always going to be the
## wrong tool. Classification is now measured: a column that stands on the ground,
## its radius, and how wide the whole prop is.
##
## WHY THE TRUNK AND NOT THE MESH BOUNDS
##
## A paperbark's canopy is 15-20 m across, so its mesh AABB overlaps the carriageway
## from almost any legal footpath position - an AABB test calls every street tree in
## the city an obstruction and is useless. What a car meets is the column reaching the
## ground, so the trunk is measured from the vertices within `TRUNK_TOP_M` of y = 0,
## which for a canopy mesh is the trunk and nothing else. `WorldBuilder`'s own palm
## crown note says the same thing from the drawing side: a car passes under a frond.
##
## AND WHY THE ORIGIN'S HEIGHT DECIDES WHAT COUNTS
##
## A palm's fronds are drawn at `h * 0.5`, i.e. 3.25 m and up, and their instance
## origin is up there with them. A car is 1.4 m tall. So an instance whose world origin
## is above `GROUND_TOLERANCE_M` is not standing on the road at all and is skipped -
## which is what keeps the frond batch out of the obstruction count without naming it.
##
## THE CORRIDOR IS HOARE'S OWN
##
## Measured against Hoare Street's own carriageway - the graph edges whose `name` is
## `"Hoare Street"`, at `RoadGraph.width_for(class)` - not against "the nearest road to
## this prop". Those differ wherever a service lane runs beside the arterial: a palm
## planted off the lane has the lane as its nearest corridor while still standing in
## Hoare's lanes, and a nearest-road test would call it clear.
##
## AND IT FAILS LOUDLY WHEN IT MEASURED NOTHING
##
## `MEASURED_PLANT_INSTANCES` is the count of instances the trunk test actually ran
## on. Zero of them is a broken audit, not a clean road, and the script exits 3.

const HOARE := "Hoare Street"
## Vertices at or below this local height are trunk. A canopy bottom sits well above
## it; a palm trunk spans it.
const TRUNK_TOP_M := 0.60
## An instance origin within this of the ground is standing on the road. A palm crown
## is at 3.25 m and up.
const GROUND_TOLERANCE_M := 0.50
## Wider than this is a wall or a building, not a prop. The world holds *props* to a
## metre (`WorldBuilder.PROP_CLEARANCE`); buildings have their own clearance and their
## own test, and counting them here would double-count a different system.
const PROP_MAX_RADIUS_M := 2.50
## A prop shallower than this is ROAD FURNITURE, not a plant.
##
## Without this the audit counts the thing it is auditing: the first GPU run reported
## 190,628 map-wide "obstructions" whose worst offenders were `Batch_drainage`,
## `Batch_markings` and `Batch_footpaths` - gully grates, lane paint and paving, all of
## which are IN the carriageway by design and all of which are flat. The world's road
## geometry is 95,659 footpath + 46,306 kerb + 23,153 channel + 10,210 marking
## instances, and every one of them is standing on the ground at y ~ 0. So a plant is
## required to have HEIGHT: nothing shorter than a kerb can obstruct a car.
const MIN_PLANT_HEIGHT_M := 3.00
## Whole-prop width at or below this, and taller than `COLUMN_HEIGHT_M`, is a coconut
## palm shaft or a pole rather than a tree: a scaled palm trunk is 0.68 m across and
## the paperbark variants measure 1.93-2.48 m.
const COLUMN_WIDTH_M := 1.20
## The height at which a thin thing is a column rather than a stem prop.
const COLUMN_HEIGHT_M := 5.0
## The clearance the world itself holds props to. Re-declared rather than read,
## because an audit that imports the constant it audits cannot catch it being wrong.
const CLEARANCE_M := 1.0
## How far off Hoare a prop may stand and still be considered a Hoare obstruction.
const REACH_M := 60.0


func _initialize() -> void:
	var screen_on := true
	var out := "/tmp/reports"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screen="):
			screen_on = a.substr(9) == "on"
		elif a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)

	WorldBuilder.verge_screening = screen_on
	print("[audit] building the world with verge_screening=%s" % ("on" if screen_on else "off"))
	var graph := RoadGraph.new()
	graph.build(OSMLayout.corridors())
	var root := Node3D.new()
	root.name = "AuditRoot"
	get_root().add_child(root)
	var world := WorldBuilder.new()
	world.name = "World"
	root.add_child(world)
	world.build(graph)
	await process_frame

	var hoare: Array = []
	var hoare_m := 0.0
	for e in graph.edges:
		if String(e["name"]) != HOARE:
			continue
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		if a.distance_squared_to(b) < 0.01:
			continue
		hoare.append({"a": a, "b": b, "hw": graph.width_for(int(e["class"])) * 0.5,
			"cls": int(e["class"])})
		hoare_m += a.distance_to(b)
	if hoare.is_empty():
		print("[audit] FATAL: %s is not in the road graph" % HOARE)
		quit(2)
		return
	print("[audit] %s: %d edge(s), %.1f m, half-width %.2f..%.2f m" % [HOARE,
		hoare.size(), hoare_m, _min_hw(hoare), _max_hw(hoare)])
	var solid: Dictionary = world.get("_solid")
	print("[audit] worldbuilder self-report (NOT the answer): %s" % JSON.stringify(solid.get("verge_screen", {})))

	# ---- read the built geometry ------------------------------------------
	var rows: Array = []
	var tally := {"mmi_nodes": 0, "labels": {}}
	_collect(root, rows, tally)
	await process_frame

	# WHICH BATCH IS THIS, and how close does anything actually get? The first
	# version of this audit collected nothing and still printed a zero, so the
	# census is printed before the verdict and the run is fatal if it is empty.
	var labels: Dictionary = tally["labels"]
	var ranked: Array = labels.keys()
	ranked.sort_custom(func(p, q): return int(labels[p]) > int(labels[q]))
	print("")
	print("[audit] batches carrying a multimesh: %d" % int(tally["mmi_nodes"]))
	for l in ranked:
		print("[audit]   %-52s %d instance(s)" % [String(l), int(labels[l])])

	var by_kind := {}
	var standing := 0
	var not_standing := 0
	var too_wide := 0
	var no_trunk := 0
	var furniture := 0
	var near_hoare := 0
	var obstructions: Array = []
	var closest := INF
	var closest_row: Dictionary = {}
	var nearest5: Array = []
	# Map-wide, using the graph's OWN corridor index, so "which street is this
	# standing in" is answerable. The Hoare count below is the number the task asks
	# for; this one says where the worst intrusions actually are, which may not be
	# Hoare.
	var roads := OSMBuildings.road_index(graph)
	var road_names: Dictionary = {}
	for e in graph.edges:
		road_names[int(e["id"])] = String(e["name"])
	var mapwide: Array = []

	for r in rows:
		var mesh: Mesh = r["mesh"]
		var xf: Transform3D = r["xf"]
		# The AABB THROUGH THE INSTANCE TRANSFORM, not the mesh's own. This is not a
		# detail: the palm trunk mesh is a UNIT-height cylinder and the height comes
		# from `scaled_local(Vector3(1, h, 1))` at the placement, so measuring the mesh
		# alone classified all 2176 palm trunks as 1 m "road furniture" and the audit
		# silently never looked at a single palm. The first run of this reported 23
		# obstructions and every one of them was a paperbark.
		var box: AABB = xf * mesh.get_aabb()
		var wide := maxf(box.size.x, box.size.z)
		wide = wide  # kept for the report
		# Road furniture, not a plant. See MIN_PLANT_HEIGHT_M.
		if box.size.y < MIN_PLANT_HEIGHT_M:
			furniture += 1
			continue
		var trunk := _trunk_radius(mesh)
		if trunk <= 0.0:
			no_trunk += 1
			continue
		if trunk > PROP_MAX_RADIUS_M:
			too_wide += 1
			continue
		if xf.origin.y > GROUND_TOLERANCE_M:
			not_standing += 1
			continue
		standing += 1
		# Named from the measured shape, because the first two naming attempts were
		# both wrong and both looked fine in the output: naming by node text found
		# nothing (the batches are auto-named holders), and naming by width called
		# every 2176 palm trunk a "bush" because a scaled trunk is 0.68 m wide.
		#  A verge coconut palm is a thin tall column; a paperbark is a broad tall
		#  thing; anything else standing taller than a kerb is a stem prop.
		var kind := "tree"
		if wide <= COLUMN_WIDTH_M and box.size.y >= COLUMN_HEIGHT_M:
			kind = "palm_trunk"
		elif box.size.y < COLUMN_HEIGHT_M:
			kind = "stem_prop"
		by_kind[kind] = int(by_kind.get(kind, 0)) + 1
		var here := Vector2(xf.origin.x, xf.origin.z)
		var near := _near_hoare(here, hoare)
		if float(near["d"]) < closest:
			closest = float(near["d"])
			closest_row = r
		nearest5.append({"d": float(near["d"]), "label": String(r["label"]),
			"pos": xf.origin, "trunk_r": trunk})
		nearest5.sort_custom(func(p, q): return float(p["d"]) < float(q["d"]))
		if nearest5.size() > 5:
			nearest5.resize(5)

		# Map-wide, from the graph's own index. Same test, and it names the street.
		var rc := OSMBuildings.nearest_corridor(here, roads)
		if int(rc["seg"]) >= 0:
			var road_gap := float(rc["d"]) - float(rc["hw"])
			if road_gap - trunk - CLEARANCE_M < 0.0:
				var rid := -1
				for j in (roads["segs"] as Array).size():
					if j == int(rc["seg"]):
						rid = j
				mapwide.append({
					"kind": kind, "label": String(r["label"]),
					"x": xf.origin.x, "z": xf.origin.z, "trunk_r": trunk,
					"street": String(road_names.get(rid, "<unnamed>")),
					"intrudes_m": trunk + CLEARANCE_M - road_gap,
				})

		if float(near["d"]) >= REACH_M:
			continue
		near_hoare += 1
		var intrudes := (float(near["d"]) - float(near["hw"])) - trunk - CLEARANCE_M
		if intrudes < 0.0:
			obstructions.append({
				"kind": kind, "label": String(r["label"]),
				"x": xf.origin.x, "z": xf.origin.z,
				"trunk_r": trunk, "prop_width": wide, "prop_height": box.size.y,
				"d_to_centreline": float(near["d"]), "hw": float(near["hw"]),
				"gap_to_kerb": float(near["d"]) - float(near["hw"]),
				"intrudes_m": -intrudes,
			})

	obstructions.sort_custom(func(p, q): return float(p["intrudes_m"]) > float(q["intrudes_m"]))
	mapwide.sort_custom(func(p, q): return float(p["intrudes_m"]) > float(q["intrudes_m"]))
	var hx0 := INF
	var hx1 := -INF
	var hz0 := INF
	var hz1 := -INF
	for s in hoare:
		for q in [s["a"], s["b"]]:
			hx0 = minf(hx0, q.x)
			hx1 = maxf(hx1, q.x)
			hz0 = minf(hz0, q.y)
			hz1 = maxf(hz1, q.y)
	print("")
	print("[audit] %s centreline bbox %.0f,%.0f .. %.0f,%.0f" % [HOARE, hx0, hz0, hx1, hz1])
	print("[audit] CONTROL distance from a point ON %s to %s: %.3f m (must be ~0)" % [
		HOARE, HOARE, float((_near_hoare(hoare[0]["a"], hoare) as Dictionary)["d"])])
	print("[audit] MultiMeshInstance3D with a multimesh   : %d" % int(tally["mmi_nodes"]))
	print("[audit] instances in the whole world           : %d" % rows.size())
	print("[audit] closest instance to %s : %.1f m" % [HOARE, closest])
	for n5 in nearest5:
		print("[audit]   d=%8.1f  %-46s pos=%s trunk_r=%.2f" % [
			float(n5["d"]), String(n5["label"]), str((n5["pos"] as Vector3).round()),
			float(n5["trunk_r"])])
	print("[audit] MAP-WIDE obstructions on any carriageway: %d" % mapwide.size())
	var mw_kinds := _counts(mapwide)
	for o in mapwide.slice(0, 25):
		print("[audit]   MAP %-12s %-40s %-22s at (%8.1f,%8.1f) trunk_r=%.2f INTRUDES %.2f m" % [
			String(o["kind"]), String(o["street"]), String(o["label"]),
			float(o["x"]), float(o["z"]), float(o["trunk_r"]), float(o["intrudes_m"])])
	print("[audit] MAP by kind: %s" % JSON.stringify(mw_kinds))
	print("[audit] closest instance to %s : %.1f m  label=%s pos=%s origin_y=%.2f trunk_r=%.2f" % [
		HOARE, closest, String(closest_row.get("label", "<none>")),
		str((closest_row.get("xf", Transform3D.IDENTITY) as Transform3D).origin.round()),
		(closest_row.get("xf", Transform3D.IDENTITY) as Transform3D).origin.y,
		_trunk_radius(closest_row.get("mesh")) if closest_row.has("mesh") else 0.0])
	print("[audit]   road furniture, shorter than %.1f m: %d" % [MIN_PLANT_HEIGHT_M, furniture])
	print("[audit]   no ground-level part (skipped)      : %d" % no_trunk)
	print("[audit]   trunk wider than %.1f m (skipped)    : %d" % [PROP_MAX_RADIUS_M, too_wide])
	print("[audit]   origin above %.1f m (crowns, skipped): %d" % [GROUND_TOLERANCE_M, not_standing])
	print("[audit] MEASURED_PLANT_INSTANCES               : %d   by kind %s" % [standing, JSON.stringify(by_kind)])
	print("[audit] standing within %d m of %s   : %d" % [int(REACH_M), HOARE, near_hoare])
	print("[audit] OBSTRUCTIONS on %s: %d" % [HOARE, obstructions.size()])
	if obstructions.is_empty():
		print("[audit] none")
	else:
		var kinds := {}
		for o in obstructions:
			kinds[String(o["kind"])] = int(kinds.get(String(o["kind"]), 0)) + 1
		print("[audit] by kind: %s" % JSON.stringify(kinds))
		for o in obstructions.slice(0, 40):
			print("[audit]   %-12s %-22s at (%8.1f,%8.1f) trunk_r=%.2f w=%.1f  d=%.2f hw=%.2f gap=%.2f  INTRUDES %.2f m" % [
				String(o["kind"]), String(o["label"]), float(o["x"]), float(o["z"]),
				float(o["trunk_r"]), float(o["prop_width"]), float(o["d_to_centreline"]),
				float(o["hw"]), float(o["gap_to_kerb"]), float(o["intrudes_m"])])
		if obstructions.size() > 40:
			print("[audit]   ... and %d more (all of them are in the file)" % (obstructions.size() - 40))

	var verdicts := {
		"SCREEN": "on" if screen_on else "off",
		"STREET": HOARE,
		"WORLD_INSTANCES": rows.size(),
		"MEASURED_PLANT_INSTANCES": standing,
		"NEAR_HOARE": near_hoare,
		"ROAD_OBSTRUCTION_COUNT": obstructions.size(),
		"OBSTRUCTION_KINDS": _counts(obstructions),
		"MAPWIDE_OBSTRUCTION_COUNT": mapwide.size(),
		"MAPWIDE_KINDS": mw_kinds,
		"WORST_MAPWIDE_INTRUSION_M": (float(mapwide[0]["intrudes_m"]) if not mapwide.is_empty() else 0.0),
		"WORST_INTRUSION_M": (float(obstructions[0]["intrudes_m"]) if not obstructions.is_empty() else 0.0),
		"SELF_REPORT": solid.get("verge_screen", {}),
	}
	print("")
	print("VERDICT_JSON=%s" % JSON.stringify(verdicts))
	var f := FileAccess.open("%s/t191-corridor-%s.txt" % [out,
		("screened" if screen_on else "unscreened")], FileAccess.WRITE)
	if f != null:
		for o in obstructions:
			f.store_line(JSON.stringify(o))
		f.close()
	print("[audit] ROAD_OBSTRUCTION_COUNT=%d" % obstructions.size())

	if standing == 0:
		print("[audit] FATAL: the trunk test ran on zero instances - this audit measured nothing and its 0 is not a result")
		quit(3)
		return
	quit(0)


## Every MultiMeshInstance3D below `n` that actually carries a multimesh, with its
## instance transforms and the mesh behind them. Holder nodes (a
## `MultiMeshInstance3D` used as a parent, whose own `multimesh` is null) are stepped
## over but still descended into.
func _collect(n: Node, rows: Array, tally: Dictionary) -> void:
	for c in n.get_children():
		if c is MultiMeshInstance3D:
			var mmi := c as MultiMeshInstance3D
			var mm := mmi.multimesh
			if mm != null and mm.mesh != null:
				tally["mmi_nodes"] = int(tally["mmi_nodes"]) + 1
				var label := "%s [%s]" % [_label_for(mmi), _mesh_sig(mm.mesh)]
				var labels: Dictionary = tally["labels"]
				labels[label] = int(labels.get(label, 0)) + mm.instance_count
				var xf := mmi.global_transform
				for i in mm.instance_count:
					var t := mm.get_instance_transform(i)
					rows.append({"mesh": mm.mesh, "label": label,
						"xf": Transform3D(xf.basis * t.basis, xf * t.origin)})
		_collect(c, rows, tally)


## A readable name from the node chain, for the report only. Never used to decide
## whether something is measured - see the header.
func _label_for(mmi: MultiMeshInstance3D) -> String:
	var parts: Array[String] = []
	var cur: Node = mmi
	while cur != null and parts.size() < 5:
		var nm := String(cur.name)
		# Auto-generated names are noise; the BATCH name above them is the part that
		# says what the batch is, and it is only useful if it survives the filter.
		if nm != "" and not nm.begins_with("@") and not nm.begins_with("MultiMesh") \
				and nm.findn("MultiMesh") < 0:
			parts.push_front(nm)
		cur = cur.get_parent()
	return "/".join(parts) if not parts.is_empty() else "<unnamed>"


## An identity for a mesh that cannot collide with another: its surface count, vertex
## count and AABB. The node chain alone was not enough - the first two runs printed
## `root/AuditRoot/World` for two different batches, because a `MultiMeshInstance3D`
## used as a HOLDER and its unnamed children resolve to the same chain.
func _mesh_sig(mesh: Mesh) -> String:
	var a := mesh.get_aabb()
	return "v=%d s=%d aabb=%.2fx%.2fx%.2f" % [
		mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if mesh.get_surface_count() > 0 else 0,
		mesh.get_surface_count(), a.size.x, a.size.y, a.size.z]


## Widest horizontal extent of the whole prop, so a canopy-bearing plant can be told
## from a bare column without being told which one it is.
func _mesh_width(mesh: Mesh) -> float:
	var a := mesh.get_aabb()
	return maxf(a.size.x, a.size.z)


## Trunk radius: the widest horizontal distance from the centroid of the vertices at
## or below `TRUNK_TOP_M` to those same vertices. Using the centroid rather than the
## origin is what makes this work for a mesh whose origin is in the middle of a canopy.
func _trunk_radius(mesh: Mesh) -> float:
	if mesh.get_surface_count() == 0:
		return 0.0
	var arrays := mesh.surface_get_arrays(0)
	if arrays.size() <= Mesh.ARRAY_VERTEX:
		return 0.0
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return 0.0
	var sum := Vector2.ZERO
	var n := 0
	for v in verts:
		if v.y <= TRUNK_TOP_M:
			sum += Vector2(v.x, v.z)
			n += 1
	if n == 0:
		return 0.0
	var c := sum / float(n)
	var worst := 0.0
	for v in verts:
		if v.y > TRUNK_TOP_M:
			continue
		worst = maxf(worst, Vector2(v.x, v.z).distance_to(c))
	return worst


## Distance to the nearest point of Hoare's carriageway, and the gap from its kerb.
func _near_hoare(p: Vector2, hoare: Array) -> Dictionary:
	var best_d := INF
	var best_hw := 0.0
	var best_cls := -1
	for s in hoare:
		var a: Vector2 = s["a"]
		var b: Vector2 = s["b"]
		var u := b - a
		var l2 := u.length_squared()
		var t := 0.0 if l2 < 1e-9 else clampf((p - a).dot(u) / l2, 0.0, 1.0)
		var d := p.distance_to(a + u * t)
		if d < best_d:
			best_d = d
			best_hw = float(s["hw"])
			best_cls = int(s["cls"])
	return {"d": best_d, "hw": best_hw, "cls": best_cls, "gap": best_d - best_hw}


func _counts(rows: Array) -> Dictionary:
	var out := {}
	for r in rows:
		out[String(r["kind"])] = int(out.get(String(r["kind"]), 0)) + 1
	return out


func _min_hw(segs: Array) -> float:
	var m := INF
	for s in segs:
		m = minf(m, float(s["hw"]))
	return m


func _max_hw(segs: Array) -> float:
	var m := 0.0
	for s in segs:
		m = maxf(m, float(s["hw"]))
	return m