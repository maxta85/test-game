class_name Pedestrians
extends Node3D
## People on the footpaths, because the shops are open and somebody has to be
## standing outside them.
##
## Not a simulation and not pretending to be one. Each pedestrian is a capsule
## on a short loop between two points on the footpath, bobbing on a phase of its
## own so a crowd does not move in lockstep. The point is that the commercial
## strip has life on it; the point is not that these have opinions about
## junctions.
##
## `spawn()` places them along the kerb of the arterial roads near the middle
## of the map, which is where the shops are - derived from the road graph rather
## than hardcoded to a street name, so it follows whatever the world agent
## authors.
##
## ORIGINAL GAME CONTENT.

const HEIGHT := 1.75
const RADIUS := 0.26
## How far the capsule's collision reaches out from the footpath edge.
const COLLISION_LAYER := 4      ## project.godot 3d_physics/layer_3 = "traffic"
## Distance out from the kerb face that the footpath centre sits, matching
## WorldBuilder's FOOTPATH layout.
const FOOTPATH_OUT := 0.5 + 0.8
## Bob amplitude and cycle. A person walking, not a person sprinting.
const BOB := 0.045
const BOB_HZ := 1.9

## Populated by spawn(); each entry is { node, mesh, a, b, t, speed, phase }.
var walkers: Array = []


## Builds the crowd under this node and returns the count placed.
func spawn(g: RoadGraph, count: int, seed_value: int = 0) -> int:
	var spots: Array = _footpath_spots(g, count, seed_value)
	for i in spots.size():
		var w := _walker(spots[i], i)
		_place(w, 0.0)      # stand them up now, not on the next frame
	return spots.size()


func _footpath_spots(g: RoadGraph, count: int, seed_value: int) -> Array:
	var out: Array = []
	if g == null or count <= 0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value if seed_value != 0 else 77003
	# The commercial strip: the biggest roads, nearest the middle of the map.
	var cands: Array = []
	for e in g.edges:
		if int(e["class"]) < RoadGraph.RoadClass.STREET:
			continue
		var p: Vector2 = g.node_pos(int(e["a"])).lerp(g.node_pos(int(e["b"])), 0.5)
		cands.append({"edge": int(e["id"]), "d": p.length(), "len": g.edge_length(int(e["id"]))})
	cands.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var tries := 0
	while out.size() < count and tries < count * 12 and not cands.is_empty():
		tries += 1
		var c: Dictionary = cands[rng.randi_range(0, mini(cands.size(), 24) - 1)]
		if float(c["len"]) < 20.0:
			continue
		var eid: int = int(c["edge"])
		var e: Dictionary = g.edges[eid]
		var half: float = float(e["width"]) * 0.5
		var a := Vector2(g.node_pos(int(e["a"])))
		var b := Vector2(g.node_pos(int(e["b"])))
		var dir: Vector2 = (b - a).normalized()
		var side: float = 1.0 if rng.randf() < 0.5 else -1.0
		var off: float = side * (half + FOOTPATH_OUT)
		var s0: float = rng.randf_range(4.0, maxf(5.0, float(c["len"]) * 0.5))
		var walk: float = rng.randf_range(6.0, 16.0)
		out.append({
			"a": a + dir * s0 + Vector2(-dir.y, dir.x) * off,
			"b": a + dir * minf(s0 + walk, float(c["len"]) - 2.0) + Vector2(-dir.y, dir.x) * off,
			"speed": rng.randf_range(0.9, 1.5),
			"phase": rng.randf() * TAU,
		})
	return out


func _walker(s: Dictionary, i: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "Ped%d" % i
	add_child(root)

	var mesh := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = RADIUS
	cap.height = HEIGHT
	mesh.mesh = cap
	mesh.position.y = 0.5 * HEIGHT
	mesh.material_override = MatLib.wall(Color(0.10, 0.09, 0.11))
	root.add_child(mesh)

	# The collision stays put and only the visual bobs, because shoving a static
	# body around every frame is how you get cars launched off the road.
	var body := StaticBody3D.new()
	body.collision_layer = COLLISION_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = RADIUS
	shape.height = HEIGHT
	cs.shape = shape
	cs.position.y = 0.5 * HEIGHT
	body.add_child(cs)
	root.add_child(body)

	var w := {
		"node": root, "mesh": mesh,
		"a": _to3(s["a"]), "b": _to3(s["b"]),
		"t": 0.0, "speed": float(s["speed"]), "phase": float(s["phase"]),
	}
	walkers.append(w)
	return w


static func _to3(p: Vector2) -> Vector3:
	return Vector3(p.x, WorldBuilder.KERB_HEIGHT, p.y)


## Puts one pedestrian where it belongs, and steps it forward by `delta`.
func _place(w: Dictionary, delta: float) -> void:
	var n: Node3D = w["node"]
	if not is_instance_valid(n):
		return
	w["t"] = fmod(float(w["t"]) + delta * float(w["speed"]), 1.0)
	var a: Vector3 = w["a"]
	var b: Vector3 = w["b"]
	# Ping-pong along the footpath with a smooth turn at each end, so nobody
	# teleports back to where they started.
	var t: float = float(w["t"])
	var u: float = 1.0 - absf(t * 2.0 - 1.0)
	n.position = a.lerp(b, u)
	var dir: Vector3 = (b - a) if t < 0.5 else (a - b)
	if dir.length_squared() > 0.0001:
		n.rotation.y = atan2(-dir.x, -dir.z)
	var mesh: MeshInstance3D = w["mesh"]
	mesh.position.y = 0.5 * HEIGHT + sin(t * TAU * BOB_HZ + float(w["phase"])) * BOB


func _process(delta: float) -> void:
	for w in walkers:
		_place(w, delta)
