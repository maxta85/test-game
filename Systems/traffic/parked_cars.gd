class_name ParkedCars
extends RefCounted
## The cars already at the kerb when you get there.
##
## Two jobs. Visually they are most of what makes a street look inhabited at
## 1am - a suburb with nothing on it reads as a parking lot. Mechanically they
## are the walls a street race threads between, and they are the reason a
## shortcut down a laneway is a gamble rather than a free line.
##
## Placement is data first: `place()` returns plain dictionaries so it can be
## checked headlessly and so the main scene can decide what a parked car looks
## like. `build()` is the convenience wrapper that puts collision bodies under
## a parent node and is all the game has to call.
##
## ORIGINAL GAME CONTENT.

## How far in from the kerb face a parked car's near side sits. The kerb face
## is the edge of the road surface, so anything inside this is on tarmac.
const KERB_SETBACK := 0.40
## Metres of kerb a car has to fit into to count as parked rather than driving.
## Used by the test suite to prove cars are not sitting in a travel lane.
const KERB_DEPTH := 2.6
## Kerbside pitch, as a multiple of the car's own length. Roughly "one car plus
## a gap", which is what makes a run of parked cars read as parked cars.
const SPACING := 1.25
## Fraction of edges that get any parking at all. Arterials mostly clear.
const PEAK_DENSITY := 0.62
## Occupancy grid for the placement pass. Manunda has a couple of streets that
## drift within a metre of each other for forty metres, and a car parked on one
## of them lands inside the car parked on the other.
const GRID := 8.0

const COLLISION_LAYER := 4      ## project.godot 3d_physics/layer_3 = "traffic"


## Where the parked cars go. Returns
## `[{ position, heading, lateral, road_half_width, edge, s, spec }]`.
static func place(g: RoadGraph, seed_value: int = 0, density: float = 1.0) -> Array:
	var out: Array = []
	if g == null:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value if seed_value != 0 else 90210
	var taken := {}
	for e in g.edges:
		# Motorways and lanes do not have kerbside parking, and an arterial is
		# mostly clear because that is where people turn into driveways.
		var cls: int = int(e["class"])
		if cls >= RoadGraph.RoadClass.HIGHWAY:
			continue
		var chance: float = PEAK_DENSITY * density
		if cls == RoadGraph.RoadClass.ARTERIAL:
			chance *= 0.45
		if rng.randf() > chance:
			continue
		var length: float = g.edge_length(int(e["id"]))
		# Keep clear of the junctions: a car parked across the mouth of a side
		# street is not an obstacle, it is a modelling accident.
		var run: float = length - 12.0
		if run < 8.0:
			continue
		var s: float = rng.randf_range(6.0, 9.0)
		while s < run:
			var here: Dictionary = _one(g, int(e["id"]), s, rng)
			if _fits(here, taken):
				out.append(here)
				_reserve(here, taken)
			s += float((here["spec"] as CarSpec).body_length) * SPACING * rng.randf_range(1.0, 1.6)
	return out


static func _cell(p: Vector3) -> String:
	return "%d_%d" % [int(floor(p.x / GRID)), int(floor(p.z / GRID))]


static func _reserve(p: Dictionary, taken: Dictionary) -> void:
	var key := _cell(p["position"])
	if not taken.has(key):
		taken[key] = []
	(taken[key] as Array).append([p["position"], float((p["spec"] as CarSpec).body_length)])


## Nose-to-nose clearance against everything already placed, wherever it is.
static func _fits(p: Dictionary, taken: Dictionary) -> bool:
	var pos: Vector3 = p["position"]
	var mine: float = float((p["spec"] as CarSpec).body_length)
	var cx := int(floor(pos.x / GRID))
	var cz := int(floor(pos.z / GRID))
	for ix in range(cx - 1, cx + 2):
		for iz in range(cz - 1, cz + 2):
			for other in taken.get("%d_%d" % [ix, iz], []):
				if pos.distance_to(other[0]) < 0.5 * (mine + float(other[1])):
					return false
	return true


static func _one(g: RoadGraph, eid: int, s: float, rng: RandomNumberGenerator) -> Dictionary:
	var e: Dictionary = g.edges[eid]
	var half: float = float(e["width"]) * 0.5
	var spec: CarSpec = CivilianCars.get_spec(CivilianCars.random_weighted_id(rng))
	# Both kerbs. A two-way street parks on both sides; that is also why the
	# outermost lane is the slow one and why overtaking on a suburban street is
	# a decision rather than a given.
	var side: float = 1.0 if rng.randf() < 0.5 else -1.0
	var lateral: float = side * (half - KERB_SETBACK - 0.5 * spec.body_width)
	var centre: Vector3 = g.point_on_edge(eid, s, true)
	var a: Vector2 = g.node_pos(int(e["a"]))
	var dir: Vector2 = (g.node_pos(int(e["b"])) - a).normalized()
	var fwd := Vector3(dir.x, 0.0, dir.y)
	# Kerbside cars all face the way the traffic flows on their side of the road.
	if side < 0.0:
		fwd = -fwd
	return {
		"position": centre + Vector3(-fwd.z, 0.0, fwd.x) * lateral,
		"heading": fwd,
		"lateral": lateral,
		"road_half_width": half,
		"edge": eid,
		"s": s,
		"spec": spec,
	}


## Places the cars and drops a collision box for each under `parent`.
## Returns the same array `place()` produced.
static func build(g: RoadGraph, parent: Node, seed_value: int = 0, density: float = 1.0) -> Array:
	var out: Array = place(g, seed_value, density)
	if parent == null:
		return out
	var mat := MatLib.wall(Color(0.16, 0.16, 0.17))
	for i in out.size():
		var p: Dictionary = out[i]
		var spec: CarSpec = p["spec"]
		var xf := Transform3D(Basis.from_euler(Vector3(0, atan2(-p["heading"].x, -p["heading"].z), 0)),
			p["position"] + Vector3(0.0, 0.5 * spec.body_height, 0.0))
		var body := StaticBody3D.new()
		body.name = "ParkedCar%d" % i
		body.collision_layer = COLLISION_LAYER
		body.collision_mask = 0
		body.transform = xf
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(spec.body_width, spec.body_height, spec.body_length)
		mesh.mesh = box
		mesh.material_override = mat
		body.add_child(mesh)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = box.size
		cs.shape = shape
		body.add_child(cs)
		parent.add_child(body)
	return out
