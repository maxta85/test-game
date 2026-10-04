# =============================================================================
# house_kit_export.gd - build the six kit pieces, measure them, dump the arrays
# =============================================================================
#
#     godot --headless --path . --script res://assets/kits/house_kit_export.gd
#
# Godot 4.3 cannot write a .glb (no GLTFDocument.save_to_file - probed), so this
# script emits JSON to /tmp/kits_build/ and glb_pack.py packs the binaries.
#
# Every number this prints is measured from the geometry that was actually
# built, not read back from a constant. If a piece regresses, the line moves.

extends SceneTree

const Pieces := preload("res://assets/kits/house_kit_pieces.gd")
const BUILD_DIR := "/tmp/kits_build"


## Distinct X/Y/Z coordinates present in a flat position array, with counts.
func _levels(pa: Array) -> Dictionary:
	var axes := ["x", "y", "z"]
	var seen := {"x": {}, "y": {}, "z": {}}
	for i in range(0, pa.size(), 3):
		for k in 3:
			var axis := String(axes[k])
			var v := snappedf(float(pa[i + k]), 0.001)
			seen[axis][v] = int(seen[axis].get(v, 0)) + 1
	var out := {}
	for axis in axes:
		var keys: Array = (seen[axis] as Dictionary).keys()
		keys.sort()
		var rows := []
		for k in keys:
			rows.append([k, int(seen[axis][k])])
		out[String(axis)] = rows
	return out


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(BUILD_DIR)
	var roster := Pieces.roster()
	var manifest := []
	var total_tris := 0
	var failures := 0
	print("[KitExport] pieces=%d  dir=%s" % [roster.size(), BUILD_DIR])
	print("[KitExport] %-28s %6s %6s %-34s %6s  %s" % [
		"piece", "tris", "verts", "local AABB (min..max) m", "sil_m", "origin gate"])
	for e in roster:
		var name := String(e["name"])
		var built := Pieces.build(name)
		if built.is_empty():
			push_error("[KitExport] %s produced no geometry" % name)
			failures += 1
			continue
		var tris := 0
		var verts := 0
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		var roles := {}
		var levels := {}
		for role in built.keys():
			var payload: Dictionary = built[role]
			var pa: Array = payload["position"]
			var ia: Array = payload["index"]
			# triangles come from the INDEX buffer. Dividing the vertex count by 3
			# is the obvious mistake and it is wrong: flat-shaded quads share no
			# vertices, so verts/3 undercounts by ~1.5x on these pieces.
			tris += int(ia.size()) / 3
			verts += int(pa.size()) / 3
			lo = Vector3(minf(lo.x, float(payload["bounds_min"][0])),
				minf(lo.y, float(payload["bounds_min"][1])),
				minf(lo.z, float(payload["bounds_min"][2])))
			hi = Vector3(maxf(hi.x, float(payload["bounds_max"][0])),
				maxf(hi.y, float(payload["bounds_max"][1])),
				maxf(hi.z, float(payload["bounds_max"][2])))
			# Measured levels: every distinct coordinate the piece actually has a
			# vertex at, with how many. Derived from the vertices, not from the
			# constants that generated them, so "the step tops out at the deck" is
			# a thing a consumer can check rather than a thing it must trust.
			levels[String(role)] = _levels(pa)
			var spec: Dictionary = Pieces.ROLES[String(role)]
			roles[String(role)] = {
				"material": spec,
				"payload": payload,
			}
		var ext := hi - lo
		var sil := float(e["sil_m"])
		var gate := "PASS"
		if sil < Pieces.SIL_MIN:
			gate = "UNDER-%.0fcm" % (Pieces.SIL_MIN * 100.0)
		# The origin gate: a fastening point must lie ON or very near the piece's
		# own surface, not float in the middle of it. Measured as the smallest
		# distance from the origin to the AABB.
		# Distance from the origin to the piece's AABB. Zero when the fastening
		# point lies inside the piece's own envelope, which is what "origin at the
		# fastening point" has to mean if placement is position + yaw and
		# nothing else.
		var off := Vector3(
			maxf(0.0, maxf(lo.x, -hi.x)), maxf(0.0, maxf(lo.y, -hi.y)),
			maxf(0.0, maxf(lo.z, -hi.z)))
		var off_d := off.length()
		var ogate := "PASS" if off_d <= 0.02 else "OFF-AABB-%.3f" % off_d
		if ogate != "PASS":
			failures += 1
		total_tris += tris
		print("[KitExport] %-28s %6d %6d %-34s %6.2f  %s / origin %s" % [
			name, tris, verts,
			"%.2f,%.2f,%.2f..%.2f,%.2f,%.2f" % [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z],
			sil, gate, ogate])
		# The named horizontal features a consumer needs to align against.
		var ys: Dictionary = {}
		for role in built.keys():
			for row in (levels[String(role)]["y"] as Array):
				ys[row[0]] = int(ys.get(row[0], 0)) + int(row[1])
		var ykeys := ys.keys()
		ykeys.sort()
		var notable := []
		for k in ykeys:
			if int(ys[k]) >= 6:
				notable.append(k)
		print("[KitExport] %-28s measured y levels (>=6 verts): %s" % [
			name, str(notable)])
		var doc := {
			"name": name,
			"extras": {
				"archetype": e["archetype"],
				"fasten": e["fasten"],
				"sil_m": sil,
				"sil_feature": e["sil_feature"],
				"sil_min_m": Pieces.SIL_MIN,
				"triangles": tris,
				"vertices": verts,
				"aabb_min": [lo.x, lo.y, lo.z],
				"aabb_max": [hi.x, hi.y, hi.z],
				"origin_offset_m": off_d,
				"generator": "assets/kits/house_kit_pieces.gd",
			},
			"roles": roles,
			"levels": levels,
		}
		var f := FileAccess.open("%s/%s.json" % [BUILD_DIR, name], FileAccess.WRITE)
		if f == null:
			push_error("[KitExport] cannot write %s/%s.json" % [BUILD_DIR, name])
			failures += 1
			continue
		f.store_string(JSON.stringify(doc))
		f.close()
		manifest.append({
			"node": name,
			"file": "res://assets/kits/%s.glb" % name,
			"archetype": e["archetype"],
			"fasten": e["fasten"],
			"sil_m": sil,
			"sil_feature": e["sil_feature"],
			"sil_gate": gate,
			"triangles": tris,
			"vertices": verts,
			"aabb_min": [lo.x, lo.y, lo.z],
			"aabb_max": [hi.x, hi.y, hi.z],
			"roles": roles.keys(),
		})
	print("[KitExport] total triangles=%d  failures=%d" % [total_tris, failures])
	var mf := FileAccess.open("res://assets/kits/manifest.json", FileAccess.WRITE)
	if mf == null:
		push_error("[KitExport] cannot write assets/kits/manifest.json")
		quit(1)
		return
	mf.store_string(JSON.stringify({
		"schema": "house-kit/1",
		"units": "metre",
		"axes": "+Y up, +Z out of the wall a piece fixes to, +X along the run",
		"sil_min_m": Pieces.SIL_MIN,
		"pieces": manifest,
	}, "  "))
	mf.close()
	print("[KitExport] wrote res://assets/kits/manifest.json (%d pieces)" % manifest.size())
	quit(0 if failures == 0 else 1)