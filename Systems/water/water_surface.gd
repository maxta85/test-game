class_name WaterSurface
extends Node3D
## The mapped water, as geometry that sits on the terrain and reads at night.
##
## One node, built from nothing: given a RoadGraph for the carriageway test and
## a ground height function, it triangulates the OSM water rings, drapes them on
## the ground, gives them the project's water material and makes them move.
##
## Three decisions that are measurements rather than taste, and the numbers they
## came from are in Tests/test_water.gd:
##
## 1. Draped, not flat. Water is level in the world and this is a game, where
##    the ground is an analytic surface undulating by a couple of metres and the
##    roads are cut flat into it. A water plane at one y is either buried where
##    the ground rises or hanging in the air where it falls, and neither is
##    fixable from here. Following the ground costs 10 cm of lift and no
##    invented level, and at the gradients the terrain actually has, a surface
##    that tilts with it is not readable as anything but water.
## 2. Ear-clipped, not fanned. The Barron rings are sinuous channels, and a fan
##    from the centroid would throw triangles out over the bank on every bend.
##    `Geometry2D.triangulate_polygon` is the standard library's own ear clipper
##    and handles the concavity.
## 3. One material per body, with a flow direction. `MatLib.water()` is already
##    the project's water: near-mirror, dark teal-black, alpha 0.86, which is
##    what makes the sodium lamps reflect down the river under NightEnv's SSR.
##    A static mirror reads as a hole in the ground at night, so the ripple
##    normals scroll. The direction is the body's principal axis, measured from
##    its own vertices - the honest simplification is that a channel that bends
##    90 degrees scrolls along its chord, which at these gradients nobody can
##    see. Per-body rather than one global direction because the pools and the
##    creek do not run the same way.
##
## No collider, deliberately. The level would have to be a wall of its own to
## stop a car, and a wall that floats above the bank reads worse than a car
## driving into a creek. The carriageway test is what keeps a road out of the
## water; see WaterClearance.

## How far the surface sits above the ground. Not zero: the terrain mesh is
## drawn at its height minus 0.06, and coplanar surfaces z-fight.
##
## 0.20 m is the leftover after the drape was measured, not a number someone
## liked. Sweeping EDGE with a 1.5 m probe across every triangle of every body,
## the gap between the water and the ground runs from 0.149 m under to 0.434 m
## over - the 0.20 lift plus or minus the chord of the ground between two
## vertices 16 m apart, which is as good as a draped surface gets on a ground
## that undulates 2.2 m. Tests/test_water.gd probes all of it and fails if the
## low end goes under zero.
const LIFT := 0.20
## Longest edge allowed in the draped ring, in metres. One terrain grid cell,
## which is the coarsest the terrain mesh itself resolves: sample the ground
## any finer and the water is denser than the ground it is lying on. This also
## decides the triangle count - 223 triangles for the whole map at 16.0, against
## 1506 at 2.0 and the same 5 draw calls.
const EDGE := 16.0
## Texture travel along the flow, in UV units per second. UVs are baked in world
## metres times UV_SCALE, so 0.17 is 0.5 m/s of ripple - a drift, not a torrent.
const FLOW := 0.17
## UVs are world metres times this, so one tile is 2.9 m of water.
const UV_SCALE := 0.35

var graph: RoadGraph
var ground: Callable
var plan: Dictionary = {}

var _mats: Array[StandardMaterial3D] = []
var _dirs: Array[Vector3] = []
var _offset := 0.0
static var _ripple: NoiseTexture2D = null


## Builds the node. Returns self, so the caller can `add_child()` the result.
func setup(g: RoadGraph, ground_h: Callable) -> WaterSurface:
	graph = g
	ground = ground_h
	plan = _plan()
	_build()
	return self


## What the build decided and what it cost. No geometry in it, so the test can
## check the decisions without a scene.
func _plan() -> Dictionary:
	var rows: Array = []
	var roads := WaterClearance.road_index(graph) if graph != null else {"segs": [], "grid": {}}
	for b in OSMWater.bodies():
		var clear: Dictionary = WaterClearance.report(b["ring"], roads)
		clear["id"] = b["id"]
		clear["area"] = b["area"]
		clear["ring"] = b["ring"]
		rows.append(clear)
	return {"rows": rows, "segments": roads["segs"].size()}


func _build() -> void:
	var kept: Array = []
	var dropped := 0
	for r in plan["rows"]:
		if not bool(r["clear"]):
			# Water on the carriageway is a disagreement between two layers of the
			# same extraction, not a thing to clip away quietly. It goes in the
			# report and out of the world.
			dropped += 1
			continue
		kept.append(r)
	plan["dropped"] = dropped
	plan["built"] = kept.size()
	plan["read"] = plan["rows"].size()

	var verts := 0
	var faces := 0
	var lo := INF
	var hi := -INF
	for r in kept:
		var built := _body(r)
		verts += int(built["verts"])
		faces += int(built["faces"])
		lo = minf(lo, float(built["low"]))
		hi = maxf(hi, float(built["high"]))
	plan["verts"] = verts
	plan["faces"] = faces
	plan["nodes"] = kept.size()
	plan["surface_low"] = lo
	plan["surface_high"] = hi
	print("[OSM water] %d of %d mapped water bodies surfaced (%d dropped for the carriageway), %d triangles, %d draw calls, surface %.2f..%.2f m"
		% [kept.size(), plan["read"], dropped, faces, _mats.size(), lo, hi])


## One body: triangulate, drape, material.
func _body(r: Dictionary) -> Dictionary:
	var ring := _densify(r["ring"])
	var idx := Geometry2D.triangulate_polygon(ring)
	if idx.is_empty():
		push_warning("WaterSurface: ring %d would not triangulate" % int(r["id"]))
		return {"verts": 0, "faces": 0, "low": 0.0, "high": 0.0}

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0, idx.size() - 2, 3):
		var a := ring[idx[i]]
		var b := ring[idx[i + 1]]
		var c := ring[idx[i + 2]]
		# `triangulate_polygon` hands back the ring's own winding, which is not
		# the winding that puts the normal up, so the normal is decided from the
		# triangle rather than assumed. The test re-checks every one of them.
		if _tri_normal(a, b, c) < 0.0:
			var swap := b
			b = c
			c = swap
		for p in [a, b, c]:
			_vert(st, p)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Water_%d" % int(r["id"])
	mi.mesh = mesh
	mi.material_override = _material(r)
	add_child(mi)

	_mats.append(mi.material_override as StandardMaterial3D)
	_dirs.append(_flow_dir(ring))
	var lo := INF
	var hi := -INF
	for i in ring.size():
		var y := _height(ring[i])
		lo = minf(lo, y)
		hi = maxf(hi, y)
	return {
		"verts": mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		"faces": idx.size() / 3,
		"low": lo,
		"high": hi,
	}


func _vert(st: SurfaceTool, p: Vector2) -> void:
	var y := _height(p)
	st.set_normal(Vector3.UP)
	st.set_uv(p * UV_SCALE)
	st.add_vertex(Vector3(p.x, y, p.y))


## Ground plus the lift, in world space.
func _height(p: Vector2) -> float:
	return float(ground.call(p.x, p.y)) + LIFT


## The water material for one body: the project's, with a scrolling ripple.
##
## The normal map is the whole trick. NightEnv turns on SSR and glow, and a
## roughness-0.04 surface with no normal detail is a perfect mirror - it reflects
## the same smooth sky for every pixel and reads as a hole rather than a river.
## Scrolling the normals is what breaks the reflection up into the moving,
## broken highlight that says water.
func _material(r: Dictionary) -> StandardMaterial3D:
	var m := MatLib.water()
	m.normal_enabled = true
	m.normal_texture = ripple()
	m.normal_scale = 0.30
	# UVs are already in world metres, so the material must not rescale them;
	# only the offset moves, and that is the flow.
	m.uv1_scale = Vector3.ONE
	m.uv1_offset = Vector3.ZERO
	return m


## One shared ripple texture for every body. Five identical 256x256 normal maps
## would be five generated textures and five GPU uploads for the same pattern.
static func ripple() -> NoiseTexture2D:
	if _ripple == null:
		_ripple = MatLib.noise_tex(256, 1.1, 4, 61, true)
	return _ripple


## Which way the body runs, from its own vertices: the longest principal axis of
## the ring's point covariance. Measured rather than named, because the data
## carries no flow direction and guessing one from the map's compass bearing would
## be inventing data the extraction did not have.
static func _flow_dir(ring: PackedVector2Array) -> Vector3:
	var n := float(ring.size())
	if n < 3.0:
		return Vector3(1, 0, 0)
	var c := Vector2.ZERO
	for p in ring:
		c += p
	c /= n
	var xx := 0.0
	var zz := 0.0
	var xz := 0.0
	for p in ring:
		var d := p - c
		xx += d.x * d.x
		zz += d.y * d.y
		xz += d.x * d.y
	# Dominant eigenvector of the 2x2 covariance. tan(2t) = 2xz / (xx - zz) is
	# the closed form; the degenerate case is a circle, which has no direction
	# to prefer and can take either.
	var ang := 0.5 * atan2(2.0 * xz, xx - zz)
	return Vector3(cos(ang), 0.0, sin(ang))


func _process(delta: float) -> void:
	_offset = fposmod(_offset + delta * FLOW, 1.0)
	for i in _mats.size():
		var d := _dirs[i]
		_mats[i].uv1_offset = Vector3(d.x * _offset, 0.0, d.z * _offset)


## Split any edge longer than EDGE, so the draped surface cannot chord over a
## terrain cell. The ring is a closed loop, so a long edge is split from both
## ends and the shared points are not duplicated.
func _densify(ring: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		out.append(a)
		var n := int(ceil(a.distance_to(b) / EDGE))
		for k in range(1, n):
			out.append(a.lerp(b, float(k) / float(n)))
	return out


static func _tri_normal(a: Vector2, b: Vector2, c: Vector2) -> float:
	# Y component of (b - a) x (c - a). Positive means the face looks up.
	return (b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)
