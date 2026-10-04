class_name WorldBuilder
extends Node3D
## Turns the road graph into actual geometry: terrain, road surface, kerbs,
## lane markings, footpaths, buildings, palms, streetlights and power lines.
##
## Everything repeated (palms, houses, poles, kerb sections) goes into a
## MultiMesh, so a suburb of a few thousand objects still costs a handful of
## draw calls. This is the substitute for Nanite that ENGINE_DECISION.md
## describes.

const KERB_HEIGHT := 0.14
const FOOTPATH_WIDTH := 1.6
## Paving slabs along the footpath, and the joint left between them.
##
## The footpath used to be one unbroken box per 4 m piece, which at night renders
## as a flat pale wedge with no joints, no scale reference and nothing for a
## streetlight to catch - the brightest surface at ground level in
## `ART_DIRECTION.md`, and completely featureless.
##
## 1.0 m slabs on a 4 cm joint. The joint is a real gap - the slab is inset by half
## the joint on each side - so what shows through is the dark ground below, which
## at night is the value a joint should be. This is render-only and costs no draw
## calls: every slab goes into the same `footpaths` MultiMesh batch under the same
## `footpath` material, so it is instances, not draw calls.
##
## Measured on `World/slab_capture.gd`, same camera before and after, paving band
## of the frame: dark transverse joint lines per pixel column went 1.235 -> 6.149,
## 0.895 -> 7.895 and 1.381 -> 7.800 on three streets 240 m apart, while band mean,
## clipped% and dark% all held. The before numbers are not zero - the unbroken
## ribbon already had faint minima from the 12 cm overlap between consecutive 4 m
## pieces - which is why the metric counts joint lines rather than measuring total
## row-to-row variation. See `_joint_lines` in the capture script for why the
## obvious metric pointed the wrong way.
const SLAB_LEN := 1.0
const SLAB_JOINT := 0.04
const PALM_SPACING := 17.0
## Grid resolution of the mapped-footprint coverage test. Coarse on purpose: it
## answers plot-sized questions, and a fine grid costs 16x the marks for nothing.
const OSM_CELL := 16.0

## The terrain carve. The ground under a street is held at CARVE_Y, which is
## below LookDev.TARMAC_Y (0.015) and below the -0.06 the terrain mesh is
## dropped by, so the tarmac is what a wheel or a raycast finds first. Deep
## enough to survive a coarse grid interpolating across it, shallow enough that
## the 6 cm step where the carve meets natural ground is not a visible lip.
const CARVE_Y := -0.14

## How far past the back of the footpath the carve still holds, so the verge
## between the path and the first building is ground rather than a trench.
const CARVE_MARGIN := 3.0

## Width of the smooth blend from CARVE_Y back to natural ground. Squared-and-
## doubled (`u*u*(3-2u)`) so the join has no slope discontinuity - a linear
## blend leaves a visible crease running the length of every street.
const CARVE_BLEND := 18.0

## Subdivisions applied to a grid cell that could contain part of a street
## corridor. The base grid is ~27.5 m and the widest carriageway is 14 m, so a
## cell can be wider than the thing being carved and a vertex-only carve is a
## coin flip. 4 puts a sample every ~7 m, which resolves a 12 m corridor.
const CARVE_SUBDIV := 4
## How far back from the back of the footpath a frontage building stands. Wide
## enough that the carport does not hang over the verge.
const FRONTAGE_OFFSET := 3.0
## Frontage plot pitch. Two houses either side of a 22 m pitch is a normal
## suburban lot spacing for the block sizes this map actually has.
const PLOT_PITCH := 22.0

## Side of a solid-geometry bucket, in metres. One trimesh per bucket per family,
## so the physics broadphase can throw away a quarter of the city without
## looking at its triangles. Larger than the 160 m road chunk on purpose: the
## road surface is one flat sheet you drive on and never approach from the side,
## while a bucket of buildings is approached from every direction and is only
## worth subdividing until the cells stop beating in the same walk.
const SOLID_CELL := 240.0
## How far below y=0 a wall's collider reaches. Mirrors
## `OSMBuildings.SOLID_FLOOR` and is not read from it, for the same reason that
## file does not read CLEARANCE from here: two files being edited at once should
## not be able to take each other down.
const SOLID_FLOOR := -0.30
## The clearance every wall in this world is held to, measured from the edge of a
## carriageway. Matches `OSMBuildings.CLEARANCE`, which the mapped footprints are
## clipped to, so a car cannot be stopped by a wall on one frontage and pass
## through the wall on the next. Tests/test_world.gd asserts the invariant from
## the geometry, not from these two agreeing.
const BUILDING_CLEARANCE := 2.5
## The looser clearance a prop is held to. A car stops for a light pole in the
## footpath and drives through a garden tree, so the two cannot share a number -
## but neither can be zero, because a bin in the middle of a lane is a car that
## stops for no visible reason.
const PROP_CLEARANCE := 1.0
## Plants a car is meant to drive through. Matched by name, because the geometry
## cannot tell them apart: a rain tree's canopy is a 6 m sphere and a car's is a
## 2 m box, and the only thing that says which of the two this one is comes from
## the placement list.
const SOLID_FREE_PROPS := ["bush_scrub"]
## A prop part wider than this, standing on the ground, is a canopy rather than a
## trunk or a post, and is left out of the collider. Measured across the union of
## the parts that reach the ground, per kind: palm trunks and steel posts are
## well under a metre, every canopy is well over three.
const PROP_SOLID_WIDTH := 3.0

## Artkit planting for the blocks the kit fills. Registered names only - anything
## else is skipped by `ArtKitScatter` and reported, not silently dropped.
##
## Free-standing yard things only. `_vegetation()` already owns the road verge, so
## anything placed here that belongs on the footpath would double up with it.
const YARD_PROPS := [
	"palm_alexandrine", "tree_rain_tree", "palm_fan", "bush_scrub", "bin",
]

var graph: RoadGraph
var rng := RandomNumberGenerator.new()

# Collected batches, flushed into MultiMeshes at the end.
var _batches: Dictionary = {}
var _materials: Dictionary = {}

# Solid collision geometry, bucketed per SOLID_CELL and flushed into one
# StaticBody3D each. Two families rather than one so a wall can never be mistaken
# for a garden bin - the contact test asserts on which one it hit, and a single
# merged bucket would make that assertion unanswerable.
var _solid_build: Dictionary = {}     ## Vector2i -> SurfaceTool
var _solid_prop: Dictionary = {}      ## Vector2i -> SurfaceTool
var _solid: Dictionary = {}           ## what the pass built, for the tests
var _roads: Dictionary = {}           ## OSMBuildings.road_index(graph), built once
var _kit_extents: Dictionary = {}     ## building kind -> measured box extents
var _prop_extents: Dictionary = {}    ## prop name -> measured box extents

# Named nodes the game needs to find.
var car_meet: Node3D
var streets_lights: Node3D


func build(g: RoadGraph) -> void:
	graph = g
	rng.seed = 20260929
	_terrain()
	_road_surface()
	_kerbs_and_footpaths()
	_lane_markings()
	_junction_control()
	_intersections()
	_drainage()
	_buildings()
	_vegetation()
	_streetlights()
	_power_lines()
	_car_meet()
	_skyline()
	_flush_batches()
	_bake_collision()
	# Last, because the night layer rewrites the light nodes `_streetlights()`
	# just created and needs `graph` to aim them. See `World/night_pass.gd`: the
	# lamps are the only source with shape, so how they emit is a night decision,
	# not a geometry one, and it belongs in one file rather than here.
	NightPass.install(self)


## The night. Installed from `build()` rather than from `Game/main.gd` because the
## thing being rewritten is the lamps this node created, and a `NightPass` that
## could be forgotten at the call site would be a night that silently does not
## apply. `tests` can suppress it with `NightPass.pending = {"enabled": false}`.
func _night_pass() -> NightPass:
	return get_node_or_null(NodePath(NightPass.NODE_NAME)) as NightPass


## The Cairns CBD, on the horizon.
##
## Manunda is low-rise, so without something to look at the sky is a flat empty
## band and the suburb reads as a diorama. Cairns has a real CBD a few km inland
## and it is honest to put it there: a ring of towers with lit window grids and
## aircraft warning beacons. It is also the cheapest depth cue in the game - the
## whole thing is unlit boxes in two MultiMeshes, and it gives every long shot a
## floor and every straight a vanishing point.
func _skyline() -> void:
	var tower_mesh := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	var glass_key := "tower_glass"
	_materials[glass_key] = MatLib.wall(Color(0.055, 0.060, 0.075))
	var win_key := "tower_window"
	if not _materials.has(win_key):
		_materials[win_key] = MatLib.emissive(Color(0.85, 0.88, 1.0), 0.9)
	var beacon_key := "tower_beacon"
	if not _materials.has(beacon_key):
		_materials[beacon_key] = MatLib.emissive(Color(1.0, 0.15, 0.10), 6.0)

	var centre := Vector2(-150.0, 620.0)      ## inland, the way Cairns actually is
	var towers := 0
	for i in 46:
		var a: float = TAU * float(i) / 46.0 + rng.randf_range(-0.05, 0.05)
		var dist: float = rng.randf_range(1500.0, 2300.0)
		var p: Vector2 = centre + Vector2(cos(a), sin(a)) * dist
		var w: float = rng.randf_range(26.0, 52.0)
		var d: float = rng.randf_range(26.0, 52.0)
		# A few real towers, mostly low CBD blocks. Uniform height reads as a fence.
		var h: float = rng.randf_range(45.0, 150.0) if rng.randf() < 0.3 else rng.randf_range(18.0, 55.0)
		var basis := Basis.from_euler(Vector3(0, a, 0))
		var base := Vector3(p.x, 0.0, p.y)
		_add("skyline", tower_mesh,
			Transform3D(basis, base + Vector3(0, h * 0.5, 0)).scaled_local(Vector3(w, h, d)), glass_key)

		# Window bands. A tower with no lit windows is a black rectangle at night,
		# which is worse than no tower at all.
		var bands: int = clampi(int(h / 14.0), 2, 9)
		for b in bands:
			if rng.randf() < 0.35:
				continue
			var y: float = h * (float(b) + 0.5) / float(bands)
			_add("skyline", tower_mesh,
				Transform3D(basis, base + basis * Vector3(0, y, -d * 0.5 - 0.3))
					.scaled_local(Vector3(w * 0.86, h / float(bands) * 0.42, 0.4)), win_key)
		if h > 90.0:
			_add("skyline", tower_mesh,
				Transform3D(basis, base + Vector3(0, h + 1.5, 0)).scaled_local(Vector3(1.6, 3.0, 1.6)), beacon_key)
		towers += 1
	print("[World] %d CBD towers on the horizon" % towers)


# --------------------------------------------------------------------- batches
func _mat(key: String) -> StandardMaterial3D:
	if not _materials.has(key):
		match key:
			"asphalt": _materials[key] = MatLib.wet_asphalt()
			# Four grains of tarmac, one per chunk. See `_asphalt_key`.
			"asphalt0": _materials[key] = MatLib.wet_asphalt(0.06, 0)
			"asphalt1": _materials[key] = MatLib.wet_asphalt(0.06, 1)
			"asphalt2": _materials[key] = MatLib.wet_asphalt(0.06, 2)
			"asphalt3": _materials[key] = MatLib.wet_asphalt(0.06, 3)
			"paint_white": _materials[key] = MatLib.paint_white()
			"paint_yellow": _materials[key] = MatLib.paint_yellow()
			# The road edge is four surfaces, not one. See `LookDev` for the
			# material and the reason: a kerb face and a footpath are 1.5 m apart
			# and a metre apart in height, and drawing both in the same grey is
			# what made every street read as one continuous pale ledge.
			"kerb_face": _materials[key] = LookDev.kerb_face_mat()
			"kerb_top": _materials[key] = LookDev.kerb_top_mat()
			"channel": _materials[key] = LookDev.channel_mat()
			"footpath": _materials[key] = LookDev.footpath_mat()
			# Still the default and still the drainage. It is no longer the road
			# edge, which is the point.
			"concrete": _materials[key] = MatLib.concrete()
			"ground": _materials[key] = MatLib.ground()
			_: _materials[key] = MatLib.concrete()
	return _materials[key]


## Adds one instance of a mesh to a named batch.
func _add(batch: String, mesh: ArrayMesh, xform: Transform3D, mat_key: String) -> void:
	if not _batches.has(batch):
		_batches[batch] = {"meshes": {}, "xforms": []}
	var entry: Dictionary = _batches[batch]
	if not entry["meshes"].has(mat_key):
		entry["meshes"][mat_key] = {"mesh": mesh, "list": []}
	entry["meshes"][mat_key]["list"].append(xform)


func _flush_batches() -> void:
	for batch in _batches:
		var entry: Dictionary = _batches[batch]
		var holder := MultiMeshInstance3D.new()
		holder.name = "Batch_" + batch
		for mat_key in entry["meshes"]:
			var rec: Dictionary = entry["meshes"][mat_key]
			var list: Array = rec["list"]
			if list.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = rec["mesh"]
			mm.instance_count = list.size()
			# A fixed cull radius keeps distance culling from popping whole batches
			# out. Real per-object LOD and occlusion culling are Phase 10 work.
			mm.custom_aabb = AABB(Vector3(-900, -20, -900), Vector3(1800, 120, 1800))
			for i in list.size():
				mm.set_instance_transform(i, list[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = _mat(mat_key)
			holder.add_child(mmi)
		add_child(holder)


# --------------------------------------------------------------------- terrain
## Half-extent the terrain has to cover, with margin.
##
## This cannot be a constant. It was 800, which was right for the old authored
## block and wrong the moment the roads became real OpenStreetMap data: those
## span -1192..1394 in X and -1501..1301 in Z, so roughly 700 m of real street
## had no floor under it at all. A car that drifted out there fell through the
## world with nothing to catch it. Derived from the graph so the next map change
## cannot reopen the hole.
func _terrain_extent() -> float:
	var reach := 0.0
	for e in graph.edges:
		for nid in [int(e["a"]), int(e["b"])]:
			var p := graph.node_pos(nid)
			reach = maxf(reach, maxf(absf(p.x), absf(p.y)))
	return maxf(800.0, reach + 120.0)


## The terrain grid's cell size. The cell count is held roughly constant as the
## extent grows, so covering four times the area does not quietly quadruple the
## triangle count and the collision mesh with it. Split out so the subgrade suite
## can ask the builder for the real step instead of re-deriving it and drifting.
func _terrain_step() -> float:
	return maxf(16.0, _terrain_extent() / 55.0)


func _terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := _terrain_extent()
	var step := _terrain_step()
	var n := int(s / step)
	for gz in range(-n, n):
		for gx in range(-n, n):
			var x0 := float(gx) * step
			var z0 := float(gz) * step
			# A cell that could contain any part of a street corridor gets
			# subdivided, so the carve is resolved by a sample rather than
			# interpolated across. Everywhere else stays one quad - the far
			# field is most of the area and none of it is paved.
			var sub := _cell_subdivisions(Vector2((x0 + x0 + step) * 0.5, (z0 + z0 + step) * 0.5), step)
			var fine := step / float(sub)
			for iz in range(sub):
				for ix in range(sub):
					var cx0 := x0 + float(ix) * fine
					var cz0 := z0 + float(iz) * fine
					var cx1 := cx0 + fine
					var cz1 := cz0 + fine
					_terrain_quad(st, cx0, cz0, cx1, cz1)

	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.material_override = _mat("ground")
	mi.position.y = -0.06
	add_child(mi)

	# The terrain needs collision. Without it the only thing the car can stand on
	# is the road trimesh, so driving off the kerb drops you into a void with no
	# surface to catch you - which is exactly what it did. Reusing the committed
	# mesh means the collision surface is the visible one, not an approximation
	# of it, and it costs one more StaticBody rather than a second piece of
	# geometry.
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = _trimesh(mesh)
	cs.shape.backface_collision = true
	body.add_child(cs)
	add_child(body)

	# The terrain only covers +/-800 m. The road network does not, so the far
	# field is still a hole at the map edge. This floor is well below the lowest
	# terrain height, which means it is only ever reached by driving off the
	# world rather than by driving across it.
	var skirt := StaticBody3D.new()
	skirt.name = "OuterFloor"
	skirt.collision_layer = 1
	skirt.collision_mask = 0
	var scs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6000.0, 40.0, 6000.0)
	scs.shape = box
	scs.position = Vector3(0.0, -22.0, 0.0)
	skirt.add_child(scs)
	add_child(skirt)
	print("[World] terrain collision: %d triangles" % int(cs.shape.get_faces().size() / 3))


## One cell of terrain, as two triangles from four sampled corners.
##
## Corners walked counter-clockwise seen from above, so `_quad` reads +Y as the
## outward normal. Walked the other way it reads -Y, which is the ground lit from
## underneath - black at any exposure.
func _terrain_quad(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float) -> void:
	var p00 := Vector3(x0, _terrain_height(x0, z0), z0)
	var p10 := Vector3(x1, _terrain_height(x1, z0), z0)
	var p01 := Vector3(x0, _terrain_height(x0, z1), z1)
	var p11 := Vector3(x1, _terrain_height(x1, z1), z1)
	_quad(st, p00, p01, p11, p10)
	_quad(st, p00, p11, p10, p01)


## How finely to divide one base-grid cell. 1 unless the cell's footprint could
## reach into a street corridor, in which case CARVE_SUBDIV.
##
## The half-diagonal is in the reach test because what matters is not the cell
## CENTRE's distance to the road but whether any corner of the cell is inside
## the corridor - a road clipping the corner of an otherwise distant cell still
## buries the carriageway.
func _cell_subdivisions(centre: Vector2, step: float) -> int:
	var near := OSMBuildings.nearest_corridor(centre, _road_grid())
	if int(near["seg"]) < 0:
		return 1
	var reach := _carve_half_width(near) + CARVE_BLEND + step * 0.70711
	if float(near["d"]) >= reach:
		return 1
	return CARVE_SUBDIV


## Flat flood-prone plain with a shallow dish, a creek line to the west, and a
## gentle rise toward the hills. The creek is what stops it reading as a table.
##
func _terrain_height(x: float, z: float) -> float:
	var h := 0.0
	# Broad, very gentle tilt: this suburb is flat but it is not level.
	h += 1.4 * sin(x * 0.0016) * cos(z * 0.0019)
	h += 0.6 * sin(x * 0.006 + 1.7) * sin(z * 0.005)
	# The creek / drainage corridor, running roughly north-south out west.
	var creek_x := -620.0 + 40.0 * sin(z * 0.004)
	var d := absf(x - creek_x)
	if d < 46.0:
		h -= 2.4 * (1.0 - d / 46.0)
	# Keep the roads themselves clear of the ground. This used to be a flatten
	# toward 0.0 over 26 m, which is wrong twice over, and both halves of the
	# wrongness showed up as the terrain burying the street:
	#
	# 1. Flattening *toward* 0.0 leaves the ground at 0.0, which is 15 mm BELOW
	#    the tarmac (LookDev.TARMAC_Y), so the road wins - but only just, and only
	#    exactly on the centreline where the flatten is complete. A grid vertex
	#    20 m out is barely flattened at all (w*w = 0.053), so it keeps its full
	#    +/-2.0 m of undulation.
	# 2. It only ever moved the SURFACE at a sampled vertex. The grid is
	#    `step` = 27.5 m across and the widest carriageway here is 14 m, so the
	#    quad spanning a road interpolates between a flattened vertex and an
	#    unflattened one and ramps straight back up over the carriageway. There
	#    was no guarantee any vertex landed inside the road at all.
	#
	# So: a hard carve to a level safely under the tarmac, across the full
	# lateral width the builder actually paves, then a smooth blend back out to
	# natural ground so the carve does not leave a trench wall at its edge.
	# 3. Assigning the carve height outright also FILLS. Where the natural
	#    ground is already below the road - the creek depression is -2.4 m, the
	#    broad tilt bottoms out near -1.3 m - forcing h = CARVE_Y built a 1.3 m
	#    earthwork and put the ground through the creek's water surface, which is
	#    the only thing the `water` suite holds over this function. A carve
	#    removes material; it never creates it. So both branches take the minimum
	#    of the natural ground and the ramp: high ground gets cut down to
	#    CARVE_Y, hollows are left exactly as they were. That also bounds the
	#    height the blend ever has to cross at 2.0 m, which keeps the surface
	#    gentle enough that a water triangle's chord cannot dip under it.
	var near: Dictionary = OSMBuildings.nearest_corridor(Vector2(x, z), _road_grid())
	var lateral := float(near["d"])
	var corridor := _carve_half_width(near)
	if lateral < corridor:
		h = minf(h, CARVE_Y)
	elif lateral < corridor + CARVE_BLEND:
		var u: float = (lateral - corridor) / CARVE_BLEND
		h = minf(h, lerpf(CARVE_Y, h, u * u * (3.0 - 2.0 * u)))
	return h


## How far out from the centreline the terrain is held clear, on the widest road
## this map has. Derived from the same lateral budget the builder paves with
## (`LookDev.channel_to_back_of_footpath`) plus a margin for the verge, so adding
## a section to the street cannot silently leave it buried.
func _carve_half_width(near: Dictionary) -> float:
	if int(near["seg"]) < 0:
		return 0.0
	return float(near["hw"]) + LookDev.channel_to_back_of_footpath() + CARVE_MARGIN


## One quad, two triangles, from four corners walked in order around the patch.
##
## **The order of a, b, c, d is the caller's OUTWARD normal**, taken as
## `_tri_normal(a, b, c)`, and the triangles are emitted *reversed* to get it.
## That indirection is not decoration. Godot only draws a face whose
## right-hand-rule normal points away from the camera, i.e. INTO the surface -
## the exact opposite of the outward normal it wants to light it with. Deriving
## both from one cross product forces a choice between being lit correctly and
## being visible at all, and this world picked wrong in both directions:
##
##   - the carriageway was lit correctly and culled from every frame above it
##   - the terrain was drawn and lit from underneath, i.e. pure black
##
## So: the normal stays as the caller ordered it, and the winding is reversed
## to match. Callers must pass corners such that a->b->c reads as outward.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var n := _tri_normal(a, b, c)
	st.set_normal(n)
	st.set_uv(Vector2(a.x, a.z) * 0.02)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(Vector2(c.x, c.z) * 0.02)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(Vector2(b.x, b.z) * 0.02)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(Vector2(a.x, a.z) * 0.02)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(Vector2(d.x, d.z) * 0.02)
	st.add_vertex(d)
	st.set_normal(n)
	st.set_uv(Vector2(c.x, c.z) * 0.02)
	st.add_vertex(c)


static func _tri_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	return n.normalized() if n.length_squared() > 0.000001 else Vector3.UP


# --------------------------------------------------------------- road surfaces
## Edge length in metres, used to cut the carriageway into chunks.
const ROAD_CHUNK_M := 160.0

## The road, cut into chunks instead of one city-sized mesh.
##
## A single 2.6 x 2.8 km surface is one object with one bounding box, and its
## centre is out in the middle of the map. Renderers choose a mesh's lights by
## that centre, so the 1278 streetlights that are actually near the camera are
## never among the ones assigned to it - the tarmac went unlit while the same
## frame's directional light lit it perfectly. Chunking puts each stretch of
## road in a box small enough that the lamps above it are the lamps that light
## it. Same reason the junction patches are chunked.
##
## Measured, at the "street" preset, by Systems/road_render/draw_calls.gd:
## road tarmac went from 2 meshes / 10 draw calls to 136 meshes / 35 draw calls
## in that frame, and the median road pixel went from literally 0.00 to 51.52.
## So this is a correctness fix bought with draw calls, not a performance win -
## do not assume otherwise. 101 of the 136 chunks were frustum-culled at street
## level, but from the air it is 58 draw calls, because then they all are in
## frame. ROAD_CHUNK_M = 160 m is inherited, not chosen by measurement: it has
## not been swept, so the honest statement is that it works and nobody has found
## the knee. Sweep it before treating the draw-call cost above as fixed.
##
## Chunk key (cell) -> SurfaceTool, filled as the geometry is emitted.
func _cell_key(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / ROAD_CHUNK_M), floori(p.y / ROAD_CHUNK_M))


## Which grain of tarmac a chunk gets.
##
## The asphalt material is triplanar, so its texture is sampled from world
## position and every 16.7 m of road shows the same tile of grain - a regular
## grid over the whole map that reads as wallpaper, not as tarmac. A per-chunk UV
## offset cannot fix that because the shader never reads the UVs; a different
## material can, and a different material per chunk is a different draw call.
## Hence four variants and a hash: the repeat becomes 160 m and non-obvious
## instead of 16.7 m and obvious, at the cost measured in the commit.
##
## Hashing the cell rather than the chunk's first edge keeps a junction patch and
## the road either side of it on the same grain, so the patch does not read as a
## differently-coloured square of tarmac.
func _asphalt_key(cell: Vector2i) -> String:
	return "asphalt%d" % (absi(cell.x * 31 + cell.y * 17) % 4)


func _road_surface() -> void:
	var cells := {}
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var dir := (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var uv_len: float = a.distance_to(b)
		var a0 := Vector3(a.x - nrm.x * hw, 0.0, a.y - nrm.y * hw)
		var a1 := Vector3(a.x + nrm.x * hw, 0.0, a.y + nrm.y * hw)
		var b0 := Vector3(b.x - nrm.x * hw, 0.0, b.y - nrm.y * hw)
		var b1 := Vector3(b.x + nrm.x * hw, 0.0, b.y + nrm.y * hw)
		_road_quad(_cell(cells, (a + b) * 0.5), a0, a1, b1, b0, uv_len, hw)
	for key in cells:
		var mi := MeshInstance3D.new()
		mi.name = "RoadSurface_%d_%d" % [key.x, key.y]
		mi.mesh = (cells[key] as SurfaceTool).commit()
		mi.material_override = _mat(_asphalt_key(key))
		mi.position.y = LookDev.TARMAC_Y
		add_child(mi)


## The SurfaceTool for the chunk containing p, created on first use.
func _cell(cells: Dictionary, p: Vector2) -> SurfaceTool:
	var key := _cell_key(p)
	if not cells.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		cells[key] = st
	return cells[key]


static func _road_quad(st: SurfaceTool, a0: Vector3, a1: Vector3, b1: Vector3, b0: Vector3,
		length: float, half_width: float) -> void:
	# Wound so the right-hand-rule normal points down, into the tarmac. Godot
	# draws a face only when that normal points away from the camera, so the
	# other order is a road you can only see from underneath - the carriageway
	# was simply absent from every frame shot from above.
	var verts := [a0, b1, a1, a0, b0, b1]
	var uvs := [
		Vector2(0, 0), Vector2(half_width * 2.0, 0),
		Vector2(half_width * 2.0, length), Vector2(0, 0),
		Vector2(half_width * 2.0, length), Vector2(0, length),
	]
	for i in verts.size():
		st.set_normal(Vector3.UP)
		st.set_uv(uvs[i])
		st.add_vertex(verts[i])


## The road edge: a dished channel, a kerb on the channel's back lip, and a
## footpath behind that. Three surfaces, three materials, and one transform per
## side of the street.
##
## What this replaced, and why it was wrong: one `Vector3(1.0, KERB_HEIGHT, 1.0)`
## box per 4.2 m, centred 0.5 m outside the carriageway edge, in the same
## `concrete` material as the footpath. Three consequences, all of them visible
## in the before frame:
##   - a **1.0 m wide** top. A kerb is 0.30 m. At 1.0 m it is not a kerb, it is a
##     plinth, and it is what gives every street in the map its "low concrete wall
##     with a ledge along it" read.
##   - the footpath started at carriageway-edge + 0.5 while the plinth ran to
##     +1.0, so **half the kerb was under the footpath** and the other half stuck
##     out as a bench. Two surfaces fighting over 0.5 m of ground.
##   - the kerb butted straight onto the tarmac, with **no channel at all**, so
##     there was nothing between the carriageway and the kerb for a streetlight to
##     reflect in and no line to read the edge of the road by.
##
## The transverse budget, outboard from the carriageway edge:
##
##     channel 0.00 .. 0.45 | kerb 0.45 .. 0.75 | footpath 0.75 .. 2.35 | drain
##
## and it all comes from `LookDev`, so moving one section cannot silently eat the
## next one's ground.
func _kerbs_and_footpaths() -> void:
	var kerb_face_mesh := LookDev.kerb_face_mesh()
	var kerb_top_mesh := LookDev.kerb_top_mesh()
	var channel_mesh := LookDev.channel_mesh()
	var walk_mesh := _box_mesh(Vector3(1.0, 0.02, 1.0), Vector3(0, 0, 0))
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 2.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var pieces := int(length / 4.0)
		for i in pieces:
			var t0 := float(i) / float(maxi(pieces, 1))
			var t1 := float(i + 1) / float(maxi(pieces, 1))
			var mid: Vector2 = a.lerp(b, (t0 + t1) * 0.5)
			var ang := atan2(dir.x, dir.y)
			# One piece long enough to meet its neighbours, as before.
			var run := length / float(maxi(pieces, 1)) + 0.12
			for side in [-1.0, 1.0]:
				var p: Vector2 = mid + nrm * hw * side
				# Skip kerbs where a side street joins, so junctions do not get walls.
				if _blocked_by_junction(Vector3(p.x, 0, p.y)):
					continue
				# `Basis.from_euler(0, ang, 0)` sends local +X to -nrm (see the
				# drainage note for the same derivation), and every profile in
				# `LookDev` is authored with local +X pointing *away* from the
				# carriageway. So the +1 side is yawed by a further PI and both
				# sides then place from the carriageway edge outwards. Getting
				# this backwards does not look wrong - it looks like the kerb is
				# facing the wrong way, which at night is invisible - so it is
				# asserted in `World/look_dev_test.gd` instead.
				var yaw := ang if side < 0.0 else ang + PI
				var edge_xf := Transform3D(Basis.from_euler(Vector3(0, yaw, 0)),
					Vector3(p.x, 0, p.y))
				# Two meshes, two materials, one transform: the face is dark and
				# the top is not, and that difference is the whole reason the
				# kerb has an edge you can see at night.
				_add("kerbs", kerb_face_mesh, edge_xf.scaled_local(Vector3(1.0, 1.0, run)),
					"kerb_face")
				_add("kerbs", kerb_top_mesh, edge_xf.scaled_local(Vector3(1.0, 1.0, run)),
					"kerb_top")
				# The channel sits on the carriageway side of the kerb, in the
				# profile's own local +X, so it needs no separate placement: same
				# origin, and its mesh is authored from x=0.
				_add("channels", channel_mesh,
					edge_xf.scaled_local(Vector3(1.0, 1.0, run)), "channel")
				var wp: Vector2 = mid + nrm * (hw + LookDev.KERB_TOP_W + FOOTPATH_WIDTH * 0.5) * side
				# Slabs, not one ribbon. Each slab is inset by half the joint on
				# each side, so the joint is a gap you can see the ground through
				# rather than a line painted on a continuous box.
				#
				# Tiled on the TRUE piece length, not on `run`: `run` carries a 12 cm
				# overlap so neighbouring kerb pieces meet, and tiling slabs on an
				# overlapped length leaves a short slab at every piece boundary -
				# a rhythm that is regular everywhere except every 4 m, which is
				# worse than no rhythm at all.
				#
				# `wp + dir * off`, NOT `mid + dir * off`. The first version of this
				# loop recomputed the position from `mid` and silently dropped the
				# lateral offset, which laid every slab down the CENTRE of the
				# carriageway: 62290 slabs of pavement in the middle of the road,
				# and the footpaths underneath them unchanged. It rendered
				# convincingly - it is paving, receding, lit - and it only showed up
				# because the rig's `--tint` control on the BEFORE build put magenta
				# footpath where the AFTER build had bare carriageway.
				var piece_len := length / float(maxi(pieces, 1))
				var n_slabs := maxi(1, int(round(piece_len / SLAB_LEN)))
				var slot := piece_len / float(n_slabs)
				var slab_len: float = maxf(slot - SLAB_JOINT, 0.2)
				for s in n_slabs:
					var off := (float(s) + 0.5) * slot - piece_len * 0.5
					var c: Vector2 = wp + dir * off
					var wxf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)),
						Vector3(c.x, KERB_HEIGHT, c.y))
					_add("footpaths", walk_mesh,
						wxf.scaled_local(Vector3(FOOTPATH_WIDTH, 1.0, slab_len)),
						"footpath")


func _blocked_by_junction(p: Vector3) -> bool:
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		if Vector2(p.x, p.z).distance_to(n["pos"]) < float(graph.width_for(int(n["class"]))) * 0.62 + 1.0:
			return true
	return false


## Lane markings: the boundaries between lanes, the lines along the kerb, and the
## stop / give-way rows at the mouths of the approaches.
##
## What was here before was one line down the middle of every road and nothing
## else - no lane boundaries, no edge lines, no junction control - so a street
## read as a grey ribbon with a dotted spine. Markings are placed from the road
## class rather than by eye: `lanes_for()` gives the lane count, and lane i's
## boundary sits at width * i / lanes, which is where the real marking is. The
## centre boundary (on an even lane count) is the only one that changes colour
## or rhythm, because that is the only one that means something.
##
## Every marking is now a **flat quad** (`LookDev.paint_quad`) rather than a
## 0.012 m box. That is not a rounding change: a 12 mm slab has a vertical side,
## and at the 1.05 m "kerb" camera a vertical side facing the camera is a bright
## specular line running the length of every dash in frame - which is what the
## before shot shows down both edge lines. The height and the width now live in
## `LookDev`, beside the road-edge section they have to agree with.
const EDGE_LINE_INSET := 0.35
const SOLID_PITCH := 4.0
const DASH_PITCH := 7.0
const DASH_RUN := 3.0


func _lane_markings() -> void:
	# One quad for every marking. `_add` keys a batch's meshes by material key
	# alone, so a second mesh under a key already in use would silently rescale
	# the first one's instances; scale per instance instead, the way the kerbs do.
	var box := LookDev.paint_quad()
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 6.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var ang := atan2(dir.x, dir.y)
		var cls := int(e["class"])
		var w: float = float(e["width"])
		var lanes := int(graph.lanes_for(cls))
		var basis := Basis.from_euler(Vector3(0, ang, 0))
		# Not the whole edge: at a junction mouth the tarmac belongs to the
		# junction, and a lane line drawn across it is a line through a give-way
		# row. `_clear_span` trims back to where the carriageway starts.
		var span := _clear_span(a, dir, length)
		for i in range(1, lanes):
			var centre := i * 2 == lanes
			_stripe_run(box, basis, a, dir, nrm, span, -w * 0.5 + w * float(i) / float(lanes),
					centre and cls >= RoadGraph.RoadClass.ARTERIAL)
		# Edge lines, set in from the kerb, on anything wider than a single lane.
		if cls >= RoadGraph.RoadClass.STREET:
			for side in [-1.0, 1.0]:
				_stripe_span(box, basis, a, dir, nrm, span, (w * 0.5 - EDGE_LINE_INSET) * side)


## Where on an edge the tarmac stops being junction and starts being carriageway,
## as distances along the edge from `a`. Both ends are trimmed; a short edge that
## is junction all the way along returns a span with hi <= lo and places nothing.
func _clear_span(a: Vector2, dir: Vector2, length: float) -> Vector2:
	var lo := 0.0
	while lo < length * 0.5 and _in_junction(a + dir * lo):
		lo += 1.0
	var hi := length
	while hi > lo and _in_junction(a + dir * hi):
		hi -= 1.0
	return Vector2(lo, hi)


func _in_junction(p: Vector2) -> bool:
	return _blocked_by_junction(Vector3(p.x, 0.0, p.y))


## Dashes on the rhythm of a lane line, or an unbroken run of boxes for a solid
## line. One box per dash rather than one long strip, so the line bends with the
## road instead of chording across a curve.
func _stripe_run(mesh: ArrayMesh, basis: Basis, a: Vector2, dir: Vector2, nrm: Vector2,
		span: Vector2, offset: float, solid: bool) -> void:
	var pitch := SOLID_PITCH if solid else DASH_PITCH
	var run := SOLID_PITCH if solid else DASH_RUN
	var key := "paint_yellow" if solid else "paint_white"
	var t := span.x
	while t < span.y - 1.0:
		var len := minf(run, span.y - t)
		_add("markings", mesh, _mark_xf(basis, a, dir, nrm, t + len * 0.5, offset, len), key)
		t += pitch


## An unbroken line: one box for the whole span, clipped to it.
func _stripe_span(mesh: ArrayMesh, basis: Basis, a: Vector2, dir: Vector2, nrm: Vector2,
		span: Vector2, offset: float) -> void:
	var len := span.y - span.x
	if len < 1.0:
		return
	_add("markings", mesh, _mark_xf(basis, a, dir, nrm, (span.x + span.y) * 0.5, offset, len),
			"paint_white")


func _mark_xf(basis: Basis, a: Vector2, dir: Vector2, nrm: Vector2, along: float,
		offset: float, len: float) -> Transform3D:
	var p := a + dir * along + nrm * offset
	# Y scale is 1.0, not a thickness: the quad is already flat. Scaling it would
	# scale a zero-height plane, which is the sort of thing that looks like a
	# working number and does nothing.
	return Transform3D(basis, Vector3(p.x, LookDev.PAINT_Y, p.y)).scaled_local(
			Vector3(LookDev.LINE_W, 1.0, len))


## Stop bars and give-way rows, on the mouth of each approach.
##
## The road carrying less than the widest road at an intersection stops; the one
## carrying more gives way. Where every approach is the same class - the
## residential crossroads - neither marking is correct, so neither is drawn:
## give-way rows on all four arms of a suburban street junction is the single
## fastest way to make a city look like a diagram.
##
## Rows and bars sit just outside the junction patch, at the radius
## `_intersections` draws tarmac to, so they land on the edge of the patch rather
## than under it.
##
## The bar is `BAR_W` along the road and the **approach's own width minus the two
## edge-line insets** across it. The old code scaled it to the full `w` of the
## edge, which is what put a stop bar *underneath* the edge lines it is supposed
## to stop in front of: two parallel white bands 0.4 m deep, 0.23 m apart, on
## every junction mouth in the map. That is the seam.
func _junction_control() -> void:
	var box := LookDev.paint_quad()
	var tri := _tri_marker_mesh()
	for ni in graph.nodes.size():
		var n: Dictionary = graph.nodes[ni]
		if int(n["edges"].size()) < 3:
			continue
		var lo := RoadGraph.RoadClass.HIGHWAY
		var hi := RoadGraph.RoadClass.LANE
		for ei in n["edges"]:
			var ec := int(graph.edges[int(ei)]["class"])
			lo = mini(lo, ec)
			hi = maxi(hi, ec)
		if lo == hi:
			continue
		var p: Vector2 = n["pos"]
		var r: float = graph.width_for(int(n["class"])) * 0.5
		for ei in n["edges"]:
			var e: Dictionary = graph.edges[int(ei)]
			var cls := int(e["class"])
			var w: float = float(e["width"])
			var dir := (graph.node_pos(graph.other_node(int(ei), ni)) - p).normalized()
			var ang := atan2(dir.x, dir.y)
			var basis := Basis.from_euler(Vector3(0, ang, 0))
			var mouth := p + dir * (r + EDGE_LINE_INSET + 0.25)
			var xf := Transform3D(basis, Vector3(mouth.x, LookDev.PAINT_Y, mouth.y))
			if cls < hi:
				# Stop bar: across the approach, inside the edge lines. Two
				# junctions a few metres apart would otherwise paint this one on
				# the other's tarmac, which is the same mistake as painting it on
				# your own patch and just as visible from the car.
				var span := maxf(w - EDGE_LINE_INSET * 2.0, 1.0)
				if not _patched_by_other(ni, mouth):
					_add("markings", box,
						xf.scaled_local(Vector3(span, 1.0, LookDev.BAR_W)), "paint_white")
			else:
				# Give way: a row of triangles, apexes to the junction. The guard
				# is per triangle, not per row: a row is as wide as the approach,
				# so on a pair of junctions four metres apart its far end can land
				# on the neighbour even when its centre cannot.
				var count := maxi(1, int(w / 0.9))
				var pitch := w / float(count)
				for i in count:
					var at := mouth + Vector2(-dir.y, dir.x) * ((float(i) - (count - 1) * 0.5) * pitch)
					if _patched_by_other(ni, at):
						continue
					_add("giveway", tri,
						Transform3D(basis, Vector3(at.x, LookDev.PAINT_Y, at.y)), "paint_white")


## True when some junction other than `node` has already laid tarmac over p.
func _patched_by_other(node: int, p: Vector2) -> bool:
	for j in graph.nodes.size():
		if j == node or int(graph.nodes[j]["edges"].size()) < 3:
			continue
		if p.distance_to(graph.node_pos(j)) < graph.width_for(int(graph.nodes[j]["class"])) * 0.5:
			return true
	return false


## A flat give-way triangle, apex pointing down local -Z, i.e. at whatever the
## instance is aimed at. Wound and normalised the way `_junction_fan` does it,
## which is the one winding in this file that is known to face a camera above.
static func _tri_marker_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [Vector3(0, 0, -0.3), Vector3(0.3, 0, 0.3), Vector3(-0.3, 0, 0.3)]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x, v.z) * 0.5)
		st.add_vertex(v)
	return st.commit()


func _intersections() -> void:
	var cells := {}
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		var p: Vector2 = n["pos"]
		_junction_fan(_cell(cells, p), p, graph.width_for(int(n["class"])) * 0.5, true)
	for key in cells:
		var mi := MeshInstance3D.new()
		mi.name = "Intersections_%d_%d" % [key.x, key.y]
		mi.mesh = (cells[key] as SurfaceTool).commit()
		mi.material_override = _mat(_asphalt_key(key))
		mi.position.y = LookDev.JUNCTION_Y
		add_child(mi)


## The patch of tarmac where three or more streets meet: a fan of 10 triangles
## around the centre. At these radii and heights nobody can tell it is not a
## perfect polygon.
##
## Emitted directly rather than through _quad, because a fan is not a quad.
## `_quad(st, centre, v0, v1, v1)` passed v1 as both the third and fourth
## corner, which left a zero-area triangle behind every sector: half of every
## junction was a hole in the tarmac, and the junction collider carried twice
## the triangles it needed. Both the visible patch and the collision patch are
## built here so they cannot drift apart again.
##
## Winding points down, normal points up - the same contract as _road_quad,
## because this is the same tarmac. with_uv is false for the collider, which
## has no material to sample.
static func _junction_fan(st: SurfaceTool, p: Vector2, r: float, with_uv: bool) -> void:
	var segs := 10
	var centre := Vector3(p.x, 0, p.y)
	for i in segs:
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		for v in [centre,
				Vector3(p.x + cos(a0) * r, 0, p.y + sin(a0) * r),
				Vector3(p.x + cos(a1) * r, 0, p.y + sin(a1) * r)]:
			st.set_normal(Vector3.UP)
			if with_uv:
				st.set_uv(Vector2(v.x, v.z) * 0.02)
			st.add_vertex(v)


func _drainage() -> void:
	# Open concrete channels, the reason Manunda floods and the reason every
	# kerb here has one.
	#
	# Measured, not assumed: the channel is DRAIN_W wide and DRAIN_DEPTH deep
	# with its top flush with the road and its centre DRAIN_OFF outside the
	# carriageway edge, so on a street it occupies hw+0.15 .. hw+1.75 and a car
	# leaving the tarmac is 150 mm from falling in. Nothing stopped it: the kerb
	# is 140 mm of visual geometry with no collider, and the channel had no lip.
	#
	# Each rail is DRAIN_RAIL_W square and stands DRAIN_DEPTH proud - as proud as
	# the channel is deep, so the lip you see is the same measure as the hole
	# behind it. Centred ON the channel edge rather than tucked inside it: a rail
	# against the edge opens a 150 mm gap between itself and the trench it is
	# there to hold. For that reason it also runs DRAIN_DEPTH * 2 tall, from the
	# trench floor to the lip, lining the wall it sits over instead of perching
	# on it.
	#
	# Local +X on this transform points away from the carriageway (the basis below
	# is yawed by atan2(dir.x, dir.y), which sends local +X to -nrm, and the piece
	# sits at +nrm). So -DRAIN_W/2 is the road-side edge and +DRAIN_W/2 the far
	# one, measured: the two rail origins come out 0.800 m either side of the
	# channel's, and 0.15 and 1.75 past the carriageway edge. Both rails are the
	# same mesh, offset per instance.
	#
	# **The drain is measured from the back of the footpath, not from the
	# carriageway edge.** It used to be measured from the edge, which put a 1.6 m
	# trench at carriageway + 0.95 - i.e. underneath the kerb *and* underneath the
	# footpath, three surfaces fighting over the same metre of ground. That is
	# what the dark slots along the kerb in the before frame are. Cairns puts the
	# open drain in the nature strip behind the footpath anyway.
	# (`LookDev.back_of_footpath_to_drain_centre()`, not a const: it is a sum of
	# five other dimensions, and GDScript will not fold a function call into a
	# constant expression.)
	const DRAIN_W := LookDev.DRAIN_W
	const DRAIN_DEPTH := LookDev.DRAIN_DEPTH
	const DRAIN_RAIL_W := LookDev.DRAIN_RAIL_W
	var channel := _box_mesh(Vector3(DRAIN_W, DRAIN_DEPTH, 4.0), Vector3(0, -DRAIN_DEPTH * 0.5, 0))
	var rail := _box_mesh(Vector3(DRAIN_RAIL_W, DRAIN_DEPTH * 2.0, 4.0), Vector3.ZERO)
	var water := _box_mesh(Vector3(1.1, 0.02, 4.0), Vector3.ZERO)
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 12.0:
			continue
		var dir := seg / length
		var ang := atan2(dir.x, dir.y)
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		var pieces := int(length / 8.0)
		for i in pieces:
			var mid: Vector2 = a.lerp(b, (float(i) + 0.5) / float(maxi(pieces, 1)))
			var p := mid + nrm * (hw + LookDev.back_of_footpath_to_drain_centre())
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var xf := Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(p.x, 0, p.y))
			_add("drainage", channel, xf.scaled_local(Vector3(1.0, 1.0, 8.4)), "concrete")
			for edge in [-DRAIN_W * 0.5, DRAIN_W * 0.5]:
				_add("drainage", rail,
					xf.scaled_local(Vector3(1.0, 1.0, 8.4)).translated_local(Vector3(edge, 0.0, 0.0)),
					"concrete")
			_add("drainage_water", water,
				Transform3D(Basis.from_euler(Vector3(0, ang, 0)), Vector3(p.x, 0.02, p.y)),
				"asphalt")


# ----------------------------------------------------------------- primitives
static func _box_mesh(size: Vector3, offset: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := size * 0.5
	# BOX_CORNERS/BOX_FACES, the same tables `_solid_box()` builds colliders from.
	# A collider sized off a different box than the mesh it wraps is a collider
	# that does not fit.
	var corners: Array[Vector3] = []
	for c in BOX_CORNERS:
		corners.append(c * h + offset)
	for f in BOX_FACES:
		_quad(st, corners[int(f[0])], corners[int(f[1])], corners[int(f[2])], corners[int(f[3])])
	var mesh := st.commit()
	return mesh


# ------------------------------------------------------------------ colliders
func _bake_collision() -> void:
	# One trimesh for the drivable surface. Cheaper and far more robust than
	# thousands of box colliders, and the car only ever needs the road.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var dir := (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var hw: float = float(e["width"]) * 0.5
		_road_quad(st,
			Vector3(a.x - nrm.x * hw, 0, a.y - nrm.y * hw),
			Vector3(a.x + nrm.x * hw, 0, a.y + nrm.y * hw),
			Vector3(b.x + nrm.x * hw, 0, b.y + nrm.y * hw),
			Vector3(b.x - nrm.x * hw, 0, b.y - nrm.y * hw),
			a.distance_to(b), hw)
	for n in graph.nodes:
		if n["edges"].size() < 3:
			continue
		var p: Vector2 = n["pos"]
		_junction_fan(st, p, graph.width_for(int(n["class"])) * 0.5, false)
	var body := StaticBody3D.new()
	body.name = "RoadCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = _trimesh(st.commit())
	# Raycast wheels come from above; a one-sided trimesh wound the wrong way
	# would silently let the whole car fall through the world.
	cs.shape.backface_collision = true
	body.add_child(cs)
	add_child(body)
	print("[World] road collider: %d triangles" % int(cs.shape.get_faces().size() / 3))
	# After the road, so the walls and posts read in build order in the log.
	_bake_solid()


static func _trimesh(mesh: ArrayMesh) -> ConcavePolygonShape3D:
	var shape := ConcavePolygonShape3D.new()
	if mesh == null or mesh.get_surface_count() == 0:
		return shape
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# SurfaceTool.commit() leaves ARRAY_INDEX null when no index buffer was built,
	# so this cannot be a typed PackedInt32Array assignment.
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if indices == null or (indices as PackedInt32Array).is_empty():
		# Already a triangle soup: three vertices per face, in order. Handing it
		# over as it stands is not a shortcut, it is the same array - walking it a
		# face at a time would rebuild a byte-identical PackedVector3Array, and
		# there are six figures of faces in the solid pass to do that for.
		var whole: int = verts.size() - verts.size() % 3
		shape.set_faces(verts if whole == verts.size() else verts.slice(0, whole))
		return shape
	var faces: Array = []
	var idx: PackedInt32Array = indices
	for i in range(0, idx.size() - 2, 3):
		faces.append(verts[idx[i]])
		faces.append(verts[idx[i + 1]])
		faces.append(verts[idx[i + 2]])
	shape.set_faces(faces)
	return shape


# =============================================================================
# Solid geometry. Everything above this line is drawn; everything in this
# section is the same world again, as triangles a car cannot pass through.
# =============================================================================

## The two families, in one list, so the flush and the report cannot disagree
## about what exists.
const SOLID_FAMILIES := [["build", "BuildingCollision"], ["prop", "PropCollision"]]

## The eight corners and six faces of a box, shared by `_box_mesh()` and
## `_solid_box()`. One table, because a collider built from a different one than
## the mesh it wraps is a collider that does not fit.
const BOX_CORNERS := [
	Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
	Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1),
]
const BOX_FACES := [
	[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
	[3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5],
]


## What the solid pass built. Faces and bodies per family, how many footprints
## and props went into them, and what the road screen had to do about the rest.
## Read by Tests/test_world.gd, which is the only thing that should have to look
## at a triangle count to decide whether the world is solid.
func solid_stats() -> Dictionary:
	return _solid.duplicate()


func _solid_at(fam: Dictionary, p: Vector2) -> SurfaceTool:
	var key := Vector2i(floori(p.x / SOLID_CELL), floori(p.y / SOLID_CELL))
	var st: SurfaceTool = fam.get(key, null)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		fam[key] = st
	return st


## Twelve triangles, axis-aligned or not.
##
## No normals and no UVs: a collision shape is a triangle list and reads nothing
## else, so `set_normal` per vertex would be six figures of calls storing six
## figures of values nobody will look at. Winding is `BOX_FACES`, the same table
## the visible mesh uses; a trimesh collides from either side once
## `backface_collision` is on, so it is not load-bearing here.
static func _solid_box(st: SurfaceTool, centre: Vector3, size: Vector3, basis: Basis) -> void:
	if st == null or size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return
	var h := size * 0.5
	var corners: Array[Vector3] = []
	for c in BOX_CORNERS:
		corners.append(centre + basis * (c * h))
	for f in BOX_FACES:
		st.add_vertex(corners[int(f[0])])
		st.add_vertex(corners[int(f[1])])
		st.add_vertex(corners[int(f[2])])
		st.add_vertex(corners[int(f[0])])
		st.add_vertex(corners[int(f[2])])
		st.add_vertex(corners[int(f[3])])


## A vertical solid from the ground up to `top`: a trunk, a pole, a post. From
## `SOLID_FLOOR` rather than 0, for the reason `OSMBuildings.solid_geometry()`
## gives.
func _solid_post(fam: Dictionary, p: Vector2, radius: float, top: float) -> void:
	if top <= SOLID_FLOOR:
		return
	_solid_box(_solid_at(fam, p),
		Vector3(p.x, (SOLID_FLOOR + top) * 0.5, p.y),
		Vector3(radius * 2.0, top - SOLID_FLOOR, radius * 2.0), Basis.IDENTITY)


## Every mapped footprint, as its own walls and roof.
##
## The buckets are chosen by centroid, so a footprint that straddles a cell
## boundary lands wholly in one of them and that cell's body is wider than
## `SOLID_CELL`. That is the price of not clipping rings to cell edges, and it is
## cheap: a ConcavePolygonShape3D is one broadphase box whatever you put in it, so
## the subdivision only pays off where the contents are small, and the largest
## thing that can inflate a bucket is a stadium.
func _solid_osm(entries: Array) -> void:
	var n := 0
	for e in entries:
		var ring: PackedVector2Array = e["ring"]
		if ring.size() < 3:
			continue
		var mid := Vector2.ZERO
		for p in ring:
			mid += p
		OSMBuildings.solid_geometry(_solid_at(_solid_build, mid / float(ring.size())), e)
		n += 1
	_solid["osm_buildings"] = n


## The kit's buildings and props, each wrapped in a box measured off the mesh it
## is standing in for.
##
## One box per placement rather than the mesh itself. A kit building is six to
## nine parts - wall panels, a roof, a veranda, a carport, a window - and taking
## its trimesh would mean re-baking 661 unique meshes a second time for no gain
## at this count: the box is twelve triangles against several hundred, and the
## thing a car has to not pass through is the wall, which the box is.
func _solid_kit(placements: Array) -> void:
	var buildings := 0
	var props := 0
	var free_props := 0
	for d in placements:
		var pos: Vector3 = d["pos"]
		var yaw := float(d.get("yaw", 0.0))
		var scale := float(d.get("scale", 1.0))
		# Rotation only. `ArtKitBatch.place()` folds the instance scale into the
		# basis, and handing that to `_solid_box()` would scale the box twice -
		# once through the half-extents and once through the basis.
		var rot := Basis.from_euler(Vector3(0.0, yaw, 0.0))
		if d.has("building"):
			var ext: Dictionary = _kit_extent(String(d["building"]))
			_solid_box(_solid_at(_solid_build, Vector2(pos.x, pos.z)),
				pos + rot * (Vector3(0.0, (float(ext["y0"]) + float(ext["y1"])) * 0.5,
					(float(ext["back"]) - float(ext["front"])) * 0.5) * scale),
				Vector3(float(ext["half"]) * 2.0, float(ext["y1"]) - float(ext["y0"]),
					float(ext["front"]) + float(ext["back"])) * scale, rot)
			buildings += 1
		elif d.has("prop"):
			var pe: Dictionary = _prop_extent(String(d["prop"]))
			if not bool(pe["solid"]):
				# A scrub bush: drawn, not solid. Counted, because "how many props
				# the screen left out" and "how many it left in" are the same
				# question and one of the two answers has to be visible.
				free_props += 1
				continue
			_solid_box(_solid_at(_solid_prop, Vector2(pos.x, pos.z)),
				pos + rot * ((pe["centre"] as Vector3) * scale),
				(pe["size"] as Vector3) * scale, rot)
			props += 1
	_solid["kit_buildings"] = buildings
	_solid["kit_props"] = props
	_solid["kit_props_free"] = free_props


## A building kind's own measured box, in its own local frame: `front` toward
## local -Z, `back` toward +Z, `half` across X, `y0`/`y1` bottom to top.
##
## Maxed over all sixteen designs rather than read off one. A collider sized to
## the design it was measured from leaves the fifteen others sticking out into
## the road, and a per-placement box would give the frontage a ragged 1.5 m line
## of colliding edges down a straight street - which reads from the driver's
## seat as a fence. Over-covering costs nothing here: the extra volume is inside
## the yard the setback already reserved.
func _kit_extent(kind: String) -> Dictionary:
	if _kit_extents.has(kind):
		return _kit_extents[kind]
	var front := 0.0
	var back := 0.0
	var half := 0.0
	var y0 := INF
	var y1 := -INF
	for v in ArtKitBuildings.HOUSE_VARIANTS:
		for part in ArtKitBuildings.variant(kind, v):
			var aabb: AABB = (part as ArtKitPart).mesh.get_aabb()
			front = maxf(front, -aabb.position.z)
			back = maxf(back, aabb.end.z)
			half = maxf(half, maxf(absf(aabb.position.x), aabb.end.x))
			y0 = minf(y0, aabb.position.y)
			y1 = maxf(y1, aabb.end.y)
	var out := {"front": front, "back": back, "half": half,
		"y0": minf(y0, 0.0), "y1": maxf(y1, 1.0)}
	_kit_extents[kind] = out
	return out


## A prop's solid base: the union box of the parts that stand on the ground and
## are narrower than PROP_SOLID_WIDTH, or `solid: false` for a plant a car is
## meant to drive through.
##
## The two tests are the whole trick and neither one works alone. A palm's parts
## are a trunk and nine fronds: union all of them and the collider is a 7 m
## sphere nobody can drive under or past. Take only what reaches the ground and
## you get the trunk, which is the part a car actually meets. A bin's parts are
## all one mesh and it is narrow, so it survives both tests; scrub is excluded by
## name, because the mesh says "irregular bush" and the world says "you drive
## through those".
func _prop_extent(name: String) -> Dictionary:
	if _prop_extents.has(name):
		return _prop_extents[name]
	var out := {"size": Vector3.ZERO, "centre": Vector3.ZERO, "solid": false}
	if ArtKitProps.has(name) and not SOLID_FREE_PROPS.has(name):
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		var any := false
		for v in ArtKitProps.VARIANTS:
			for part in ArtKitProps.variant(name, v):
				var aabb: AABB = (part as ArtKitPart).mesh.get_aabb()
				if aabb.position.y > 0.05:
					continue
				if maxf(aabb.size.x, aabb.size.z) >= PROP_SOLID_WIDTH:
					continue
				lo = Vector3(minf(lo.x, aabb.position.x), minf(lo.y, aabb.position.y),
					minf(lo.z, aabb.position.z))
				hi = Vector3(maxf(hi.x, aabb.end.x), maxf(hi.y, aabb.end.y),
					maxf(hi.z, aabb.end.z))
				any = true
		if any:
			out = {"size": hi - lo, "centre": (lo + hi) * 0.5, "solid": true}
	_prop_extents[name] = out
	return out


## Holds every prop placement off the carriageway, or takes it out.
##
## The check is on the placement's own box, not on its position, because a
## 6 m-wide palm centred in a lane is a thing you hit and a point test calls it
## clear. Four rotated corners, the worst of them decides.
##
## Where it fails, the placement is pushed straight out along the line from the
## nearest corridor rather than dropped, because a bin half a metre into a lane
## is a bin that belongs in the yard it was aimed at - and the push is re-tested,
## so the output is verified clear rather than assumed clear. Only a prop that
## will not come clear, which means one whose escape line runs along the road,
## is removed, and those are counted with a reason.
func _screen_placements(placements: Array) -> Dictionary:
	var roads := _road_grid()
	var out: Array = []
	var moved := 0
	var dropped := 0
	var reasons: Array[String] = []

	for d in placements:
		if not d.has("prop"):
			out.append(d)
			continue
		var pe: Dictionary = _prop_extent(String(d["prop"]))
		var pos: Vector3 = d["pos"]
		var yaw := float(d.get("yaw", 0.0))
		var scale := float(d.get("scale", 1.0))
		var here := Vector2(pos.x, pos.z)
		var worst := _prop_clear(here, pe, yaw, scale, roads)
		if not bool(pe["solid"]) or worst >= 0.0:
			out.append(d)
			continue

		# Push out along the way out of the nearest carriageway.
		var near := OSMBuildings.nearest_corridor(here, roads)
		var away := here - (near["point"] as Vector2)
		if away.length() < 0.05:
			dropped += 1
			reasons.append("%s sits on a centreline with no way out" % String(d["prop"]))
			continue
		away = away.normalized()
		var fixed: Dictionary = d.duplicate()
		# Enough to put the whole box on the clearance line, not just its origin:
		# the deficit `worst` is measured from the *worst corner*, so it already
		# includes everything the box overhangs by, and the reach and the margin
		# are what land it on the far side instead of exactly on it. Pushing by a
		# fixed 2 m - which is what this was - leaves a wide palm a corner in the
		# lane and drops it every time.
		var reach := _prop_reach(pe, yaw, scale)
		var to := here + away * (-worst + reach + PROP_CLEARANCE)
		fixed["pos"] = Vector3(to.x, pos.y, to.y)
		if _prop_clear(to, pe, yaw, scale, roads) < 0.0:
			dropped += 1
			reasons.append("%s at %.0f,%.0f could not be moved clear of the carriageway"
				% [String(d["prop"]), pos.x, pos.z])
			continue
		moved += 1
		out.append(fixed)

	_solid["props_moved"] = moved
	_solid["props_dropped"] = dropped
	_solid["props_dropped_reasons"] = reasons
	return {"out": out, "moved": moved, "dropped": dropped, "reasons": reasons}


## How far a placement's box reaches from its origin in the ground plane, at its
## own yaw. The rotated half-diagonal, which is the same number whichever corner
## is worst.
func _prop_reach(pe: Dictionary, yaw: float, scale: float) -> float:
	var size: Vector3 = pe["size"]
	var hx := absf(size.x) * 0.5 * scale
	var hz := absf(size.z) * 0.5 * scale
	var c := absf(cos(yaw))
	var s := absf(sin(yaw))
	return sqrt(hx * hx + hz * hz)


## The worst (distance to a carriageway edge - PROP_CLEARANCE) over the four
## rotated corners of a placement's box.
func _prop_clear(p: Vector2, pe: Dictionary, yaw: float, scale: float, roads: Dictionary) -> float:
	var size: Vector3 = pe["size"]
	var centre: Vector3 = pe["centre"]
	var c := cos(yaw)
	var s := sin(yaw)
	var worst := INF
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			# The box centre in the ground plane first, then the corner, both
			# rotated - the centre is not at the placement's origin for a prop
			# whose mesh does not sit on it.
			var local := Vector3(size.x * 0.5 * sx, 0.0, size.z * 0.5 * sz)
			local.x += centre.x
			local.z += centre.z
			var off := Vector2(local.x * c + local.z * s, -local.x * s + local.z * c) * scale
			var near := OSMBuildings.nearest_corridor(p + off, roads)
			if int(near["seg"]) < 0:
				continue
			worst = minf(worst, float(near["d"]) - float(near["hw"]) - PROP_CLEARANCE)
	return worst if worst < INF else INF


## The road index, built once. `RoadGraph.nearest_road()` scans all 401 edges,
## and this pass asks the same question about ~1000 placements x 4 corners.
func _road_grid() -> Dictionary:
	if _roads.is_empty() and graph != null:
		_roads = OSMBuildings.road_index(graph)
	return _roads


## Commits every bucket into a StaticBody3D per cell, then reports.
##
## Called from `_bake_collision()` after the road surface, so the bodies land in
## the tree in the order they were built and the log reads in build order.
func _bake_solid() -> void:
	for family in SOLID_FAMILIES:
		var key := String(family[0])
		var prefix := String(family[1])
		var fam: Dictionary = _solid_build if key == "build" else _solid_prop
		var faces := 0
		var bodies := 0
		for cell in fam:
			var mesh: ArrayMesh = (fam[cell] as SurfaceTool).commit()
			if mesh.get_surface_count() == 0:
				continue
			var shape := _trimesh(mesh)
			if shape.get_faces().is_empty():
				continue
			faces += shape.get_faces().size() / 3

			var body := StaticBody3D.new()
			body.name = "%s_x%d_z%d" % [prefix, cell.x, cell.y]
			body.collision_layer = 1
			body.collision_mask = 0
			var cs := CollisionShape3D.new()
			cs.shape = shape
			# Seen from both sides, for the reason the road collider gives: a
			# trimesh wound one way is invisible from the other, and a wall you
			# cannot hit from the far side is a wall you are already inside.
			shape.backface_collision = true
			body.add_child(cs)
			add_child(body)
			bodies += 1
		fam.clear()
		_solid["%s_bodies" % key] = bodies
		_solid["%s_faces" % key] = faces
		print("[World] %s: %d bodies, %d triangles" % [prefix, bodies, faces])


# =============================================================================
# Props. These are what make it read as a tropical Queensland suburb at night
# rather than as a grey road network.
# =============================================================================

## Real mapped buildings, then the artkit for whatever the map did not cover.
##
## `OSMBuildings` owns the footprints. It brings 2198 rings out of
## `assets/maps/cairns_buildings.json`, the carriageway test that keeps a car out of
## a wall, and the stumps a Queenslander stands on. None of that is expressible as
## an artkit placement - `wrap_footprint()` takes a storey count and no lift - so
## the footprints keep their own material batching and the kit is given the gap.
##
## The kit goes in through `ArtKitScatter` and nowhere else. That is what makes it
## one mesh per material rather than one per placement: a raw generator called in
## the loop builds fresh geometry every time, every signature differs, and a suburb
## arrives as ~2200 draw calls instead of ~20.
func _buildings() -> void:
	var osm := OSMBuildings.build(self, graph)
	_solid_osm(osm.get("buildings", []))
	var fill := _artkit_fill(osm)
	# Screen before the kit ever sees the list: a placement that is moved after
	# `ArtKitScatter.populate()` has already baked it into a merged mesh would
	# move the collider and leave the tree where it was.
	var screened := _screen_placements(fill)
	fill = screened["out"]
	var scatter := ArtKitScatter.attach(self, fill)
	_solid_kit(fill)
	print("[World] artkit filled the gaps OSM left: %d buildings, %d props, %d draw calls, %d instances, %.0fk triangles"
		% [int(scatter.stats.get("buildings", 0)), int(scatter.stats.get("props", 0)),
			int(scatter.stats.get("nodes", 0)), int(scatter.stats.get("instances", 0)),
			float(scatter.stats.get("triangles", 0)) / 1000.0])
	_solid["kit_skipped"] = (scatter.stats.get("skipped", []) as Array).size()


## The kit's placement list: buildings and yard planting along the frontages OSM
## left empty.
##
## Frontages, not blocks, and that is the whole difference between art and a
## curiosity. `_blocks()` finds 19 blocks on this map - real OSM data is mostly
## T-junctions, so almost nothing is ever fully enclosed - and 19 blocks put 21
## houses in a 31 km city. A road already knows its own frontage: walk its length
## at a setback and build on the side the map left blank. That scales with the
## street network rather than with the junctions.
##
## The cells are the other half of the decision. OSM covers western Cairns unevenly,
## and without a coverage test the fill either doubles up on mapped houses or leaves
## a hole where the map ran out; both read as a bug from the driver's seat.
##
## The setback is the kind's own measured depth, not a constant, and the yaw is
## turned around. `ArtKitBuildings` lays every wall out with *the outside face at
## local -Z* (see `_wall()` in artkit/buildings.gd) - doors, shopfronts, verandas
## and balconies all live on that side - while `ArtKitBatch.facing()` aims local
## +Z at whatever it is given. Aimed straight at the road, every one of the 661
## fill buildings stood with its back to the street and its blank gable over the
## footpath. So the placement adds half a turn, and the setback is measured from
## the face that is now the front: a house's carport reaches 7.7 m, a walk-up's
## balcony 9.8, and a constant would either hang the carport over the verge or
## leave the balcony inside it.
func _artkit_fill(osm: Dictionary) -> Array:
	var cells := _osm_cells(osm.get("buildings", []))
	var out: Array = []
	var n := 0

	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var length: float = a.distance_to(b)
		if length < PLOT_PITCH:
			continue
		var dir := (b - a) / length
		var nrm := Vector2(-dir.y, dir.x)
		var plots := maxi(1, int(length / PLOT_PITCH))
		var step: float = length / float(plots)
		var kind := _kind_for(int(e["class"]))
		var ext: Dictionary = _kit_extent(kind)
		# Back of footpath, then a front yard, off this edge's own width, so a
		# highway frontage stands further back than a lane's - and then the
		# building's own depth, so its front face lands on that line instead of
		# its origin.
		var off: float = _frontage_offset(float(e["width"])) + float(ext["front"])

		for side in [-1.0, 1.0]:
			for i in plots:
				var p: Vector2 = a.lerp(b, (float(i) + 0.5) / float(plots)) + nrm * (off * side)
				var pos := Vector3(p.x, 0.0, p.y)
				# Front to the road. `facing()` aims +Z, the kit builds its
				# frontage at -Z, so the half turn is not a fudge factor - it is
				# the difference between a street of houses and a street of back
				# walls.
				var yaw := ArtKitBatch.facing(pos,
					Vector3(p.x - nrm.x * off * side, 0.0, p.y - nrm.y * off * side)) + PI
				if _skip_building(p, yaw, ext, cells):
					continue
				out.append({
					"building": kind,
					"pos": pos,
					"yaw": yaw,
					"seed": n,
				})
				n += 1

				# Yard planting in the half pitch to the next plot.
				var q: Vector2 = p + dir * (step * 0.5)
				if not _skip_frontage(q, cells, off):
					var q3 := Vector3(q.x, 0.0, q.y)
					out.append({
						"prop": YARD_PROPS[posmod(n, YARD_PROPS.size())],
						"pos": q3,
						"yaw": ArtKitBatch.facing(q3, Vector3(p.x, 0.0, p.y)),
						"seed": n,
					})
					n += 1
	return out


## What stands on this class of road. Shops follow the big roads rather than a
## hardcoded patch of the map - the same call the block grid used to make, so the
## commercial strip still lands where anyone actually drives.
func _kind_for(cls: int) -> String:
	match cls:
		RoadGraph.RoadClass.ARTERIAL: return "qld_shop"
		RoadGraph.RoadClass.HIGHWAY: return "walk_up_block"
		_: return "qld_house"


## Nothing to build a *building* on.
##
## The clearance test is on the box, not on the position, and that is the whole
## reason this is separate from `_skip_frontage`. A Queenslander measures 17.9 m
## across at the widest of its sixteen designs, so a plot placed legally by its
## own front face has side corners a further 8.9 m down the street - and at the
## end of a block one of those corners lands in the crossing carriageway. The
## origin test passed; a house was standing in the road with its back corner in
## it. The box test is what `Tests/test_world.gd` asserts against, and it is
## checked before the placement is emitted rather than after, because after is a
## second pass over a list the kit has already baked.
func _skip_building(p: Vector2, yaw: float, ext: Dictionary, cells: Dictionary) -> bool:
	if cells.has(Vector2i(int(floor(p.x / OSM_CELL)), int(floor(p.y / OSM_CELL)))):
		return true
	if _blocked_by_junction(Vector3(p.x, 0.0, p.y)):
		return true
	return not _kit_box_clear(p, yaw, ext)


## Whether all four rotated corners of a kit building's box are BUILDING_CLEARANCE
## clear of every carriageway, measured against the road grid rather than
## `RoadGraph.nearest_road()` - four corners times a few thousand placements is
## tens of millions of edge tests the other way.
func _kit_box_clear(p: Vector2, yaw: float, ext: Dictionary) -> bool:
	var roads := _road_grid()
	if roads.is_empty():
		return true
	var half := float(ext["half"])
	var front := float(ext["front"])
	var back := float(ext["back"])
	var c := cos(yaw)
	var s := sin(yaw)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var local := Vector2(sx * half, -front if sz > 0.0 else back)
			var corner := p + Vector2(local.x * c + local.y * s, -local.x * s + local.y * c)
			var near := OSMBuildings.nearest_corridor(corner, roads)
			if int(near["seg"]) < 0:
				continue
			if float(near["d"]) - float(near["hw"]) < BUILDING_CLEARANCE:
				return false
	return true


## Nothing to put a *prop* on: too near a carriageway, in a junction mouth, or on
## a cell OSM has already put a real house on.
##
## `min_offset` is the setback the neighbouring building is standing at, so a yard
## plant lands in the same line rather than a couple of metres out in the lane.
func _skip_frontage(p: Vector2, cells: Dictionary, min_offset: float = -1.0) -> bool:
	if _too_close_to_road(p, min_offset):
		return true
	if _blocked_by_junction(Vector3(p.x, 0.0, p.y)):
		return true
	return cells.has(Vector2i(int(floor(p.x / OSM_CELL)), int(floor(p.y / OSM_CELL))))


## Occupancy grid over the mapped rings, one cell per OSM_CELL.
##
## Bounding boxes rather than edge walking: the only question asked downstream is
## "is this block mapped at all", so marking a few cells too many cannot change an
## answer, and 2198 small rings cost one tight loop each. A mapped stadium can span
## a hundred cells, so anything that big contributes its middle cell alone - a
## sparse mark can only ever make a block look emptier than it is, and the fallback
## house lands in ground the map never claimed.
func _osm_cells(entries: Array) -> Dictionary:
	var cells := {}
	for e in entries:
		var ring: PackedVector2Array = e.get("ring", PackedVector2Array())
		if ring.size() < 3:
			continue
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for q in ring:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
		var x0 := int(floor(lo.x / OSM_CELL))
		var x1 := int(floor(hi.x / OSM_CELL))
		var z0 := int(floor(lo.y / OSM_CELL))
		var z1 := int(floor(hi.y / OSM_CELL))
		if (x1 - x0 + 1) * (z1 - z0 + 1) > 64:
			cells[Vector2i(int(floor((lo.x + hi.x) * 0.5 / OSM_CELL)),
				int(floor((lo.y + hi.y) * 0.5 / OSM_CELL)))] = true
			continue
		for gx in range(x0, x1 + 1):
			for gz in range(z0, z1 + 1):
				cells[Vector2i(gx, gz)] = true
	return cells


## How far back from a road's centreline a frontage building stands: half the
## carriageway, the footpath behind it, then the yard.
func _frontage_offset(width: float) -> float:
	return width * 0.5 + FOOTPATH_WIDTH + FRONTAGE_OFFSET


## Too near a carriageway to build on.
##
## Measured to the kerb, not to the centreline. The old test was a bare
## `lateral < BUILDING_SETBACK` - 9 m from the middle of the road - which on a
## 9 m street is inside its own kerb, so it rejected every residential frontage in
## the city and left only the arterials standing. Measured: 413 buildings, all of
## them `qld_shop`, zero houses, on a network that is 270 streets and 131 arterials.
func _too_close_to_road(p: Vector2, min_offset: float = -1.0) -> bool:
	var roads := _road_grid()
	if (roads["segs"] as Array).is_empty():
		return true
	var near: Dictionary = OSMBuildings.nearest_corridor(p, roads)
	if int(near["seg"]) < 0:
		return false
	var want: float = min_offset if min_offset >= 0.0 else _frontage_offset(float(near["hw"]) * 2.0)
	return float(near["d"]) < want

## Coconut palms. The single most identifiable thing about a north Queensland
## street, and they break up the roofline so the suburb is not a row of boxes.
func _vegetation() -> void:
	var trunk_mesh := _palm_trunk_mesh(0.34, 1.0)
	var frond_mesh := _frond_mesh()

	_materials["palm_trunk"] = MatLib.palm_bark()
	_materials["palm_frond"] = MatLib.foliage(Color(0.10, 0.24, 0.09))

	var palms := 0
	var bushes := 0
	var big_trees := 0
	# Verge scrub and the street paperbarks go through `ArtKitBatch`, not
	# `_add`, for two reasons that were both measured in the before frames. The
	# old scrub was a single `_icosphere(randf_range(1.4, 2.6))` shared by all
	# 1234 bushes, and under sodium light a 2.4 m green dome reads as a brown
	# tent - it was in every frame. And the kerb had nothing above 13 m on it, so
	# a 4-lane divided arterial read as a corridor of equal-height boxes. The
	# batched path costs 3 draw calls for the scrub (one per variant) instead of
	# one, and gets real silhouettes plus a 15-20 m canopy for free.
	var scrub := ArtKitBatch.new()
	var canopy := ArtKitBatch.new()
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 20.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var count := int(length / PALM_SPACING)
		for i in count:
			var mid: Vector2 = a.lerp(b, (float(i) + rng.randf()) / float(maxi(count, 1)))
			var side: float = 1.0 if rng.randf() < 0.5 else -1.0
			var off: float = float(graph.edges[e["id"]]["width"]) * 0.5 + FOOTPATH_WIDTH + rng.randf_range(1.0, 3.0)
			var p: Vector2 = mid + nrm * off * side
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var h := rng.randf_range(6.5, 13.0)
			var lean := rng.randf_range(-0.09, 0.09)
			var xf := Transform3D(Basis.from_euler(Vector3(lean, rng.randf() * TAU, 0)), Vector3(p.x, 0, p.y))
			_add("palms", trunk_mesh, xf.scaled_local(Vector3(1.0, h, 1.0)), "palm_trunk")
			# The shaft only, not the crown: a car passes under a frond, and a
			# frond collider is a 7 m sphere over the footpath. The shaft mesh is
			# unit height centred on its own origin, so `h * 0.5` is where the
			# drawn trunk actually stops, which is the same place.
			_solid_post(_solid_prop, p, 0.36, h * 0.5)
			var frond_count := 9
			for f in frond_count:
				var ang := TAU * float(f) / frond_count + rng.randf() * 0.2
				var droop := rng.randf_range(0.35, 0.75)
				# h * 0.5, not h. The shaft mesh is a unit height centred on its own
				# origin, and `scaled_local` then stretches it either side of that
				# origin, so its top lands at h/2 - not at h. Placing the crown at
				# h left every palm wearing its fronds a trunk-height in the air.
				_add("fronds", frond_mesh,
					Transform3D(Basis.from_euler(Vector3(droop, ang, 0)), Vector3(p.x, h * 0.5, p.y))
						.scaled_local(Vector3(1.0, 1.0, 1.0)), "palm_frond")
			palms += 1

		# Low scrub along the verges. Variant comes from the edge id, not the
		# placement index, so it is stable per run - the memo is keyed on
		# (name, variant), and the batch needs the same resource every time.
		var scrub_n := maxi(int(length / 22.0), 1)
		for i in scrub_n:
			var mid2: Vector2 = a.lerp(b, (float(i) + rng.randf() * 0.8) / float(scrub_n))
			var p2: Vector2 = mid2 + nrm * (float(graph.edges[e["id"]]["width"]) * 0.5 + 3.5) * (1.0 if rng.randf() < 0.5 else -1.0)
			scrub.add_array(ArtKitProps.variant("bush_scrub", posmod(i, ArtKitProps.VARIANTS)),
				Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)), Vector3(p2.x, 0.4, p2.y)))
			bushes += 1

		# Street paperbarks. Offset is half the carriageway plus 2.2-3.4 m, and
		# the crown reaches 2.6-4.1 m out, so on a 14 m road the canopy edge
		# lands ~1.5 m inside the far kerb line. That overhang is the point: it
		# is what a 4-lane divided arterial under paperbarks actually looks like,
		# and it is what the reference frames show.
		var tree_n := maxi(int(length / 34.0), 1)
		for i in tree_n:
			var mid3: Vector2 = a.lerp(b, (float(i) + 0.35 + rng.randf() * 0.3) / float(tree_n))
			var side3: float = 1.0 if (i % 2) == 0 else -1.0
			var p3: Vector2 = mid3 + nrm * (float(graph.edges[e["id"]]["width"]) * 0.5 + rng.randf_range(2.2, 3.4)) * side3
			if _blocked_by_junction(Vector3(p3.x, 0, p3.y)):
				continue
			canopy.add_array(ArtKitProps.variant("tree_paperbark", posmod(i + int(e["id"]), ArtKitProps.VARIANTS)),
				ArtKitBatch.place(Vector3(p3.x, 0.0, p3.y), rng.randf() * TAU))
			big_trees += 1

	if scrub.instances() > 0:
		scrub.build(self)
	if canopy.instances() > 0:
		canopy.build(self)
	print("[World] %d palms, %d bushes, %d paperbarks" % [palms, bushes, big_trees])


func _streetlights() -> void:
	## Sodium lamps. Warm orange, spaced the way a suburban council actually
	## spaces them - alternating sides, at the kerb, every ~34 m.
	var pole := _tapered_cylinder_mesh(0.09, 0.13, 1.0, 6)
	var arm := _tapered_cylinder_mesh(0.11, 0.085, 1.0, 6)
	var shade := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	var lamp := _box_mesh(Vector3(1, 1, 1), Vector3.ZERO)
	_materials["pole"] = MatLib.wall(Color(0.16, 0.17, 0.17))
	if not _materials.has("lamp_glow"):
		# 1.15 blew the lens to pure white, which is a second, smaller version of
		# the same defect the energy cut fixed on the road: a clipped highlight
		# with no detail left in it. 0.85 keeps the lens clearly the brightest
		# thing in frame while still having a visible surface.
		_materials["lamp_glow"] = MatLib.emissive(MatLib.SODIUM, 0.85)

	var count := 0
	for ei in graph.edges.size():
		var e: Dictionary = graph.edges[ei]
		if int(e["class"]) < RoadGraph.RoadClass.STREET:
			continue
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 24.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var n := maxi(int(length / 21.0), 1)
		for i in n:
			var mid: Vector2 = a.lerp(b, (float(i) + 0.5) / float(n))
			var side: float = 1.0 if (ei + i) % 2 == 0 else -1.0
			var off: float = float(e["width"]) * 0.5 + 1.2
			var p: Vector2 = mid + nrm * off * side
			## A lamp inside the junction box is skipped, which is right - but the
			## skip was the *only* rule, and it left a gap at every junction in the
			## map. Measured on the `junction` pose: road mean 9.8/255 with 68% of
			## the band below the dark threshold, against 90.7 and 20% on a mid-block
			## street. The brightest 260 m of a night city with 1278 lamps in it has
			## no lamps in it, because that is exactly where the lamp loop gets
			## suppressed. So a suppressed lamp slides *along* the street until it
			## clears the box: the pole still stands clear of the junction and the
			## junction still gets lit.
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				var slid := false
				for nudge in [7.0, -7.0, 13.0, -13.0]:
					var q: Vector2 = p + dir * nudge
					if not _blocked_by_junction(Vector3(q.x, 0, q.y)):
						p = q
						slid = true
						break
				if not slid:
					continue
			var h := 7.0
			var base := Vector3(p.x, KERB_HEIGHT, p.y)
			_add("poles", pole, Transform3D(Basis(), base).scaled_local(Vector3(1.0, h, 1.0)), "pole")
			# A light pole is in the footpath, so it is a wall. `width * 0.5 + 1.2`
			# puts its face 1.2 m clear of the kerb, which is more than half a car,
			# so it is something you clip a mirror on rather than drive through.
			_solid_post(_solid_prop, p, 0.15, KERB_HEIGHT + h * 0.5)
			var tip: Vector3 = base + Vector3(nrm.x * -1.4 * side, h, nrm.y * -1.4 * side)
			# Cobra double-arm luminaire: a tapered arm out to the head, then a
			# DARK shade overhanging a glowing lens tucked underneath it.
			#
			# It was a box at `tip` and an arm box, which is why the head read as a
			# floating orange rectangle in every delivered frame - there was no
			# silhouette above the glow, so at night the only thing to see was the
			# lit face. The shade is in the dark `pole` material and overhangs the
			# lens by 0.12 m on the road side and 0.05 m at the back, so the head
			# has an outline and the lens reads as *under* something.
			var arm_yaw := atan2(-dir.x, -dir.y)
			_add("poles", arm, Transform3D(Basis.from_euler(Vector3(0, arm_yaw, 0)),
					tip + Vector3(0, -0.24, 0)).scaled_local(Vector3(0.11, 0.11, 1.5)),
				"pole")
			# Tilted 9 degrees so the lens face looks down at the road rather than
			# out at the camera - a level cobra head is a bright disc to a driver.
			var shade_tilt := Transform3D(Basis.from_euler(Vector3(0.16, arm_yaw, 0)),
					tip + Vector3(0, 0.10, 0)).scaled_local(Vector3(0.58, 0.09, 1.06))
			_add("poles", shade, shade_tilt, "pole")
			_add("lamps", lamp, Transform3D(Basis.from_euler(Vector3(0.16, arm_yaw, 0)),
					tip + Vector3(0, 0.015, 0)).scaled_local(Vector3(0.40, 0.07, 0.84)),
				"lamp_glow")

			var l := OmniLight3D.new()
			l.light_color = MatLib.SODIUM
			l.light_energy = Look.STREETLIGHT_ENERGY
			l.omni_range = Look.STREETLIGHT_RANGE
			l.omni_attenuation = Look.STREETLIGHT_ATTENUATION
			# 1121 lamps all injecting into a 70 m fog slab turns the sky into
			# sodium soup - the exact failure night_env.gd warns about. Street
			# lighting only needs to light tarmac; the fog is there for
			# headlight beams, which stay volumetric.
			l.light_volumetric_fog_energy = 0.0
			l.position = tip - Vector3(0, 0.3, 0)
			l.shadow_enabled = false   # hundreds of shadow-casting lights would melt a CPU raster
			# The role tag is how `NightPass` knows which of these it owns. The
			# street standards get road-aimed cone optics; the junction fills below
			# deliberately stay omnidirectional, because their whole job is an even
			# lift over a box rather than a pool.
			l.set_meta("night_role", "street")
			add_child(l)
			count += 1
	_junction_fill()
	print("[World] %d streetlights" % count)


## One light over every junction box, with no standard under it.
##
## The lamp loop above deliberately stands every standard clear of the junction
## box (a pole in the box is a pole a car hits), and nothing was put back in its
## place. Measured on the `junction` pose that left the busiest 20 m of the map
## with road mean 7.875/255 and 72.4% of the band under the dark threshold -
## already outside the 0.75 limit before this task touched a lamp, and *worse*
## at every lower global energy tried (see the sweep table on
## `Look.STREETLIGHT_ENERGY`). No single energy value fixes the arterial and the
## junction at once because they need opposite moves.
##
## This is the fix that does not cost anything elsewhere: mounted at
## `JUNCTION_FILL_HEIGHT`, throwing `JUNCTION_FILL_RANGE`, so it dies before it
## can lift a mid-block pool. It adds no pole, so it cannot put a standard in a
## traffic lane - the full measured clearance is in the report.
func _junction_fill() -> void:
	var count := 0
	# `for n in graph.nodes` yields the node Dictionary itself, NOT an index -
	# `graph.nodes[n]` with a Dictionary key is how the first attempt of this
	# function died. Same shape as `_blocked_by_junction`.
	for node_v in graph.nodes:
		var node: Dictionary = node_v
		if int(node["edges"].size()) < 3:
			continue
		var p: Vector2 = node["pos"]
		var l := OmniLight3D.new()
		l.light_color = Look.JUNCTION_FILL_COLOUR
		l.light_energy = Look.JUNCTION_FILL_ENERGY
		l.omni_range = Look.JUNCTION_FILL_RANGE
		# Gentler falloff than a sodium standard on purpose: this is meant to be
		# an even lift over the whole box, not a pool with a hot centre.
		l.omni_attenuation = 1.1
		l.light_volumetric_fog_energy = 0.0
		l.position = Vector3(p.x, Look.JUNCTION_FILL_HEIGHT, p.y)
		l.shadow_enabled = false
		l.set_meta("night_role", "junction")
		add_child(l)
		count += 1
	print("[World] %d junction fills" % count)


func _power_lines() -> void:
	## Timber poles and sagging catenary wires. Nothing says "outer suburban
	## Australia" faster than power lines over a street.
	var pole := _tapered_cylinder_mesh(0.14, 0.19, 1.0, 6)
	_materials["pole_wood"] = MatLib.wall(Color(0.19, 0.16, 0.13))
	_materials["wire"] = MatLib.wall(Color(0.05, 0.05, 0.05))

	var pole_positions: Array = []
	for e in graph.edges:
		var a: Vector2 = graph.node_pos(int(e["a"]))
		var b: Vector2 = graph.node_pos(int(e["b"]))
		var seg := b - a
		var length := seg.length()
		if length < 30.0:
			continue
		var dir := seg / length
		var nrm := Vector2(-dir.y, dir.x)
		var count := maxi(int(length / 45.0), 1)
		for i in count:
			var mid := a.lerp(b, (float(i) + 0.5) / float(count))
			var side: float = 1.0 if i % 2 == 0 else -1.0
			var p := mid + nrm * (float(e["width"]) * 0.5 + 2.6) * side
			if _blocked_by_junction(Vector3(p.x, 0, p.y)):
				continue
			var h := 9.5
			_add("poles_wood", pole, Transform3D(Basis(), Vector3(p.x, 0, p.y)).scaled_local(Vector3(1.0, h, 1.0)), "pole_wood")
			pole_positions.append(Vector3(p.x, h - 0.8, p.y))
			_solid_post(_solid_prop, p, 0.2, h * 0.5)
	_connect_wires(pole_positions)


func _connect_wires(points: Array) -> void:
	# Join each pole to its nearest neighbour on roughly the same street, then
	# sag the span. Crude, but overhead wires only ever need to read as wires.
	if points.size() < 2:
		return
	var used := {}
	for i in points.size():
		var best := -1
		var best_d := 1e9
		for j in points.size():
			if i == j:
				continue
			var d: float = (points[i] as Vector3).distance_to(points[j] as Vector3)
			if d < best_d and d > 8.0 and d < 52.0:
				best_d = d
				best = j
		if best < 0:
			continue
		var key := "%d_%d" % [mini(i, best), maxi(i, best)]
		if used.has(key):
			continue
		used[key] = true
		_sag_wire(points[i], points[best])


func _sag_wire(a: Vector3, b: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var segs := 8
	var sag: float = a.distance_to(b) * 0.06
	var prev := a
	for i in range(1, segs + 1):
		var t := float(i) / segs
		var p: Vector3 = a.lerp(b, t)
		p.y -= sin(t * PI) * sag
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(prev)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(p)
		prev = p
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _materials["wire"]
	add_child(mi)


func _car_meet() -> void:
	## The hub. A vacant lot off the arterial with a handful of parked cars,
	## floodlights and a crowd - the place the whole game loops back to.
	car_meet = Node3D.new()
	car_meet.name = "CarMeet"
	car_meet.position = OSMLayout.car_meet_position()
	add_child(car_meet)

	# Kept on a short leash on purpose. The lot sits `car_meet_position()` =
	# 70 m back from the arterial, so a 45 m flood still reached the carriageway:
	# measured on the `street` pose it put a pure-white vertical down the middle
	# of frame (the solid centre line lit head-on off `wet_asphalt`) and was
	# responsible for most of the road band's clipping. A car-park flood lights
	# its own lot, not the main road it is reached from - 24 m and 5.0 put the
	# light back on the cars and off the arterial.
	var m := OmniLight3D.new()
	m.light_color = MatLib.MERCURY
	m.light_energy = 5.0
	m.omni_range = 24.0
	m.position = Vector3(0, 9, 0)
	car_meet.add_child(m)

	var m2 := OmniLight3D.new()
	m2.light_color = MatLib.SODIUM
	m2.light_energy = 4.0
	m2.omni_range = 20.0
	m2.position = Vector3(9, 5, 6)
	car_meet.add_child(m2)


# ------------------------------------------------------------------- primitives
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := _tri_normal(a, b, c)
	for v in [a, b, c]:
		st.set_normal(n)
		st.set_uv(Vector2(v.x, v.z) * 0.3)
		st.add_vertex(v)


## `_tri` with the normal and UVs supplied, for the surfaces that cannot use the
## world-X/Z projection. UVs default to zero for materials that do not sample a
## texture at all, which is most of them.
static func _tri_n(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3,
		uva := Vector2.ZERO, uvb := Vector2.ZERO, uvc := Vector2.ZERO) -> void:
	var verts := [a, b, c]
	var uvs := [uva, uvb, uvc]
	for i in 3:
		st.set_normal(n)
		st.set_uv(uvs[i])
		st.add_vertex(verts[i])


## Where a palm trunk is thickest, as a fraction of its base radius, bottom to
## top. A coconut palm is not a cone: the base flares out into buttress roots,
## the shaft runs near-parallel for most of its height, and it swells again
## right at the crown where the fronds carry the load out.
##
## A table rather than a formula because the shape is the art and a formula would
## be a worse way to say it. Read here as "how much radius is left at 0%, 20%,
## 45%, 72% and 100% of the trunk" - the last row dipping back up is the crown
## swelling, which is what stops the top of the trunk reading as a cut pipe.
const PALM_TRUNK_PROFILE := [1.0, 0.78, 0.62, 0.55, 0.60]
const PALM_TRUNK_SIDES := 8
const PALM_RING_BANDS := 14.0


## A palm shaft: segmented along its height so the taper above is real geometry,
## ringed with UVs that carry the leaf-scar banding.
##
## It cannot go through `_tri`, which projects every vertex's UV from world X/Z.
## That is right for a road surface lying flat and useless here - a trunk needs
## `u` to run around its circumference and `v` up its length, or the ring
## texture lands as stripes across it instead of bands around it.
static func _palm_trunk_mesh(r_base: float, h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var last := PALM_TRUNK_PROFILE.size() - 1
	var dy := h / float(last)
	for ri in last:
		var t0f := float(ri) / float(last)
		var t1f := float(ri + 1) / float(last)
		var r0 := r_base * float(PALM_TRUNK_PROFILE[ri])
		var r1 := r_base * float(PALM_TRUNK_PROFILE[ri + 1])
		var y0 := -h * 0.5 + t0f * h
		var y1 := y0 + dy
		# The ring texture repeats PALM_RING_BANDS times up the shaft, and once
		# per side around it, so both axes tile on a seamless texture.
		var v0 := t0f * PALM_RING_BANDS
		var v1 := t1f * PALM_RING_BANDS
		for s in PALM_TRUNK_SIDES:
			var a0 := TAU * float(s) / float(PALM_TRUNK_SIDES)
			var a1 := TAU * float(s + 1) / float(PALM_TRUNK_SIDES)
			var u0 := float(s)
			var u1 := float(s + 1)
			var lo0 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var lo1 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var hi0 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			var hi1 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			# Normals point straight out from the axis so the shaft reads round
			# at 8 sides instead of faceted.
			var n0 := Vector3(cos(a0), 0.0, sin(a0))
			var n1 := Vector3(cos(a1), 0.0, sin(a1))
			_tri_n(st, lo0, lo1, hi0, n0, Vector2(u0, v0), Vector2(u1, v0), Vector2(u0, v1))
			_tri_n(st, lo1, hi1, hi0, n1, Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1))
	return st.commit()


static func _tapered_cylinder_mesh(r_bottom: float, r_top: float, h: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in sides:
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var b0 := Vector3(cos(a0) * r_bottom, -h * 0.5, sin(a0) * r_bottom)
		var b1 := Vector3(cos(a1) * r_bottom, -h * 0.5, sin(a1) * r_bottom)
		var t0 := Vector3(cos(a0) * r_top, h * 0.5, sin(a0) * r_top)
		var t1 := Vector3(cos(a1) * r_top, h * 0.5, sin(a1) * r_top)
		_tri(st, b0, b1, t0)
		_tri(st, b1, t1, t0)
	var mesh := st.commit()
	return mesh


## One palm frond, as a frond rather than a blade: a rachis that arcs up off the
## crown and droops at the tip, with leaflets hung off both sides of it.
##
## The old version was a single tapered strip in one plane - five quads, ten
## triangles, one normal for all of them. That is the flat-card read from every
## angle, and no material can fix it: a plane either faces the streetlight or it
## does not, and from most of the circle around the tree it does not.
##
## The fix is geometry. Each leaflet is its own surface with its own normal,
## angled off the rachis and swept along it, so the crown presents a different
## angle to the lamp at every point and picks up light in patches the way real
## foliage does. It is deliberately still 48 triangles: a full coconut frond
## carries over a hundred leaflets, and this mesh is drawn 14,562 times.
static func _frond_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length := 3.2
	var leafs := 12

	for i in leafs:
		# Leaflets crowd toward the tip on a real frond, so the spacing is
		# stepped rather than even.
		var t := pow((float(i) + 0.4) / float(leafs), 0.86)
		var side := 1.0 if i % 2 == 0 else -1.0
		var base := _frond_rachis(t, length)
		# Each leaflet leans out and back off the rachis, and the lean widens
		# toward the tip. That spread is what gives the frond volume.
		var spread := 0.55 + t * 0.75
		var drop := 0.18 + t * 0.5
		var reach := 0.46 + (1.0 - t) * 0.52
		var out := Vector3(side * spread, -drop, 0.35).normalized()
		# Normal to this leaflet's own plane, so it catches the lamp separately
		# from its neighbours rather than sharing one flat facing.
		var across := Vector3.UP.cross(out).normalized()
		var normal := across.cross(out).normalized()
		if normal.y < 0.0:
			normal = -normal
		# A blade, not a spike: narrow where it leaves the rachis, widest a third
		# of the way along, tapering to the point.
		var mid := base + out * reach * 0.55
		var tip := base + out * reach
		var w1 := 0.075 + t * 0.045
		var blade_lo := base - across * 0.03
		var blade_hi := base + across * 0.03
		var mid_out := mid + across * w1
		var mid_in := mid - across * w1
		var tip_out := tip + across * 0.012
		var tip_in := tip - across * 0.012
		_tri_n(st, blade_lo, blade_hi, mid_out, normal)
		_tri_n(st, blade_lo, mid_out, mid_in, normal)
		_tri_n(st, mid_in, mid_out, tip_out, normal)
		_tri_n(st, mid_in, tip_out, tip_in, normal)
	return st.commit()


## The rachis: up off the crown, over, and down at the tip. `t` is 0 at the
## crown and 1 at the point, and the same curve is used by the whole frond so the
## leaflets sit on the spine rather than near it.
static func _frond_rachis(t: float, length: float) -> Vector3:
	var rise := 0.95 * sin(t * PI * 0.55)
	var droop := 1.65 * pow(t, 2.4)
	return Vector3(0.0, rise - droop, t * length)


static func _icosphere(radius: float, subdiv: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 4
	var segs := 6
	for r in rings:
		var v0 := PI * float(r) / rings
		var v1 := PI * float(r + 1) / rings
		for s in segs:
			var u0 := TAU * float(s) / segs
			var u1 := TAU * float(s + 1) / segs
			var p := func(v: float, u: float) -> Vector3:
				return Vector3(sin(v) * cos(u), cos(v), sin(v) * sin(u)) * radius
			_tri(st, p.call(v0, u0), p.call(v1, u0), p.call(v1, u1))
			_tri(st, p.call(v0, u0), p.call(v1, u1), p.call(v0, u1))
	return st.commit()

