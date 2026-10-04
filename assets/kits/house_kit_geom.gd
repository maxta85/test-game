# =============================================================================
# house_kit_geom.gd - the one mesh builder the house kit pieces are made of
# =============================================================================
#
# WHY THIS EXISTS INSTEAD OF USING artkit/mesh_kit.gd
#
#   Two reasons, both measured rather than assumed:
#
#   1. Godot 4.3's GLTFDocument has NO save_to_file. Probed with
#      ClassDB.class_has_method(): append_from_scene = true, save_to_file =
#      false, and calling it raised "Nonexistent function 'save_to_file' in
#      base 'GLTFDocument'". save_to_file landed in 4.4. So the .glb files this
#      kit ships have to be packed by hand (glb_pack.py), which needs raw
#      vertex/normal/index/uv arrays rather than a committed ArrayMesh.
#   2. artkit/ belongs to another agent and is being edited right now. A shared
#      vocabulary that has to be re-derived whenever someone renames a constant
#      is not a vocabulary, it is a coupling.
#
# WINDING - MEASURED, NOT REMEMBERED
#
#   Two quads in the same plane with the same stored normal, differing only in
#   triangle order, rendered from +Z (probe: assets/kits/_probe_winding.gd):
#
#     winding normal +Z (pointing AT the camera)    mean luma 0.0000  n=10000
#     winding normal -Z (pointing AWAY from it)     mean luma 0.0169  n=10000
#
#   So on Godot 4.3 / Compatibility / OpenGL3, a face is drawn when the
#   right-hand-rule winding normal points AWAY from the camera. Therefore:
#
#     STORED VERTEX NORMAL = the OUTWARD direction, so it lights correctly.
#     TRIANGLE WINDING     = the OPPOSITE direction, so it survives culling.
#
#   Two independent decisions. push_quad() takes the caller's OUTWARD direction
#   and derives the winding from it, so they cannot be made inconsistent.
#
# SCALE AND CONVENTION (matches artkit/mesh_kit.gd:11-31)
#
#   1 unit = 1 metre. +Y up. +Z is out of the wall a piece fixes to. UVs are in
#   metres so one material tiles the same on a fence rail and a warehouse wall.

class_name HouseKitGeom
extends RefCounted

var verts := PackedVector3Array()
var norms := PackedVector3Array()
var uvs := PackedVector2Array()
var idx := PackedInt32Array()
var uv_scale := 1.0


## One quad as two triangles. `a b c d` may be in ANY order; `facing` is the
## direction the face is meant to be seen from. Stored normal is `facing` on all
## four corners; winding is its opposite.
func push_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, facing: Vector3) -> void:
	var n := facing.normalized()
	if n.length_squared() < 0.5:
		return
	var wind := (b - a).cross(c - a)
	if wind.length_squared() < 1e-9:
		return
	var bb := b
	var dd := d
	if wind.normalized().dot(n) < 0.0:
		bb = d
		dd = b
	var base := verts.size()
	for p in [a, bb, c, dd]:
		verts.append(p)
		norms.append(n)
		uvs.append(Vector2(p.x, p.z) * uv_scale)
	idx.append(base + 0)
	idx.append(base + 2)
	idx.append(base + 1)
	idx.append(base + 0)
	idx.append(base + 3)
	idx.append(base + 2)


## One triangle with an explicit outward direction (spear points, ridge ends).
func push_tri(a: Vector3, b: Vector3, c: Vector3, facing: Vector3) -> void:
	var n := facing.normalized()
	var wind := (b - a).cross(c - a)
	if wind.length_squared() < 1e-9 or n.length_squared() < 0.5:
		return
	var base := verts.size()
	for p in [a, b, c]:
		verts.append(p)
		norms.append(n)
		uvs.append(Vector2(p.x, p.z) * uv_scale)
	idx.append(base + 0)
	idx.append(base + 2)
	idx.append(base + 1)


## Axis-aligned box from its minimum corner. All six faces facing out, so the
## box is closed and solid from every angle - the closure property the kit is
## judged on. A piece with a hole in its shell is culled, not lit.
func push_box(from: Vector3, size: Vector3) -> void:
	var x0 := from.x
	var y0 := from.y
	var z0 := from.z
	var x1 := from.x + size.x
	var y1 := from.y + size.y
	var z1 := from.z + size.z
	push_quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(0, 0, 1))
	push_quad(Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0), Vector3(0, 0, -1))
	push_quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3(0, -1, 0))
	push_quad(Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(0, 1, 0))
	push_quad(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(-1, 0, 0))
	push_quad(Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3(1, 0, 0))


## A vertical tube between two heights - a downpipe, a gateling stile, a spear.
## `cap_top` false gives the pointed top that makes a gateling a gateling.
func push_tube(centre: Vector2, r: float, y0: float, y1: float, sides: int,
		cap_top: bool = true) -> void:
	var base_y0 := Vector3(centre.x, y0, centre.y)
	var base_y1 := Vector3(centre.x, y1, centre.y)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		push_quad(base_y0 + d0 * r, base_y0 + d1 * r,
			base_y1 + d1 * r, base_y1 + d0 * r, (d0 + d1) * 0.5)
	if cap_top:
		var up := Vector3(0, 1, 0)
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			push_tri(base_y1 + Vector3(cos(a0), 0, sin(a0)) * r,
				base_y1 + Vector3(cos(a1), 0, sin(a1)) * r, base_y1, up)
	else:
		var tip := base_y1 + Vector3(0, r * 2.4, 0)
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			push_tri(base_y1 + Vector3(cos(a0), 0, sin(a0)) * r,
				base_y1 + Vector3(cos(a1), 0, sin(a1)) * r, tip, Vector3(0, 1, 0))


## A quarter-turn swept in the XZ plane: the downpipe elbow, which is the whole
## reason a downpipe reads as plumbing and not as a pole stuck on a wall.
## The pipe arrives travelling straight DOWN at `entry`, leaves travelling
## horizontally along `dir`, and the whole thing is the arc of radius r.
func push_elbow(entry: Vector3, r: float, dir: Vector3, sides: int, segs: int = 5) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	var centre := entry + flat * r
	var axis := Vector3(0, 1, 0)
	var prev := entry
	var prev_rad := Vector3(0, 0, 0)
	for s in range(1, segs + 1):
		var th := PI * 0.5 * float(s) / float(segs)
		# radius rotates from -flat (entry, pipe travelling straight down) to
		# -UP (outlet, pipe travelling along +flat). Getting these two the wrong
		# way round makes the arc a full circle that returns to its own start.
		var rad := flat * (-cos(th)) + axis * (-sin(th))
		var cur := centre + rad * r
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var d0 := Vector3(cos(a0), 0.0, sin(a0))
			var d1 := Vector3(cos(a1), 0.0, sin(a1))
			var face := rad
			if s == 1:
				face = (rad + prev_rad).normalized() if prev_rad.length_squared() > 0.0 else rad
			push_quad(prev + d0 * r, prev + d1 * r, cur + d1 * r, cur + d0 * r, face)
		prev_rad = rad
		prev = cur
	# Outlet: a short stub along `dir`, capped so you cannot see up the pipe.
	var tip := prev + flat * r * 1.1
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		push_quad(prev + d0 * r, prev + d1 * r, tip + d1 * r, tip + d0 * r, flat)
		push_tri(tip + d0 * r, tip + d1 * r, tip, flat)


## A half-round gutter trough: the LOWER half of a circle, so the opening faces
## up and the shadow inside it is half the reason a Queenslander eave line
## reads at all. Tips sit at y = 0, which is the fixing line - that is the
## origin of the piece.
##   back_z : the fascia plane. The back tip sits on it.
##   dia    : outside diameter. wall thickness is taken off the inner arc.
func push_gutter(x0: float, x1: float, back_z: float, dia: float, wall: float, segs: int) -> void:
	var r := dia * 0.5
	var ri := r - wall
	var cz := back_z + r
	# beta sweeps -PI/2 -> +PI/2 from the back tip, through the belly, to the
	# front lip. Both tips land on y = 0, which is the gutter's fixing line and
	# therefore the origin of this piece.
	#   beta = -PI/2 -> (0, 0, back_z)        back tip, on the fascia
	#   beta =  0     -> (0, -r, back_z + r)  belly
	#   beta = +PI/2 -> (0, 0, back_z + 2r)   front lip
	var back_o := Vector3(0.0, 0.0, back_z)
	var back_i := Vector3(0.0, 0.0, back_z + wall)
	# Rear rim faces up: it is the top edge of the back of the trough.
	push_quad(Vector3(x0, back_o.y, back_o.z), Vector3(x0, back_i.y, back_i.z),
		Vector3(x1, back_i.y, back_i.z), Vector3(x1, back_o.y, back_o.z), Vector3(0, 1, 0))
	var prev_o := back_o
	var prev_i := back_i
	for s in range(1, segs + 1):
		var beta := -PI * 0.5 + PI * float(s) / float(segs)
		var rad := Vector3(0.0, -cos(beta), sin(beta))
		var po := rad * r + Vector3(0.0, 0.0, cz)
		var pin := rad * ri + Vector3(0.0, 0.0, cz)
		# Outer skin, normal radially out; inner skin, normal radially in. The
		# inner skin is what catches the shadow, and the shadow is the read.
		push_quad(Vector3(x0, prev_o.y, prev_o.z), Vector3(x0, po.y, po.z),
			Vector3(x1, po.y, po.z), Vector3(x1, prev_o.y, prev_o.z), rad)
		push_quad(Vector3(x0, prev_i.y, prev_i.z), Vector3(x0, pin.y, pin.z),
			Vector3(x1, pin.y, pin.z), Vector3(x1, prev_i.y, prev_i.z), -rad)
		prev_o = po
		prev_i = pin
	# Front lip rim faces down.
	push_quad(Vector3(x0, prev_o.y, prev_o.z), Vector3(x0, prev_i.y, prev_i.z),
		Vector3(x1, prev_i.y, prev_i.z), Vector3(x1, prev_o.y, prev_o.z), Vector3(0, -1, 0))
	# Back plate against the fascia, facing into the trough, closing the rear.
	push_quad(Vector3(x0, -dia, back_z), Vector3(x1, -dia, back_z),
		Vector3(x1, 0.0, back_z), Vector3(x0, 0.0, back_z), Vector3(0, 0, 1))
	# End plates, so the trough is a closed solid from every angle.
	for sx in [x0, x1]:
		var s := float(sx)
		var out := Vector3(-1, 0, 0) if s < 0.0 else Vector3(1, 0, 0)
		push_quad(Vector3(s, -dia, back_z), Vector3(s, 0.0, back_z),
			Vector3(s, 0.0, back_z + dia), Vector3(s, -dia, back_z + dia), out)


func bounds() -> AABB:
	if verts.is_empty():
		return AABB()
	var lo := verts[0]
	var hi := verts[0]
	for v in verts:
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	return AABB(lo, hi - lo)


func tri_count() -> int:
	return idx.size() / 3


func vert_count() -> int:
	return verts.size()


## The JSON payload glb_pack.py consumes. Plain arrays, so the Python side does
## not have to know how Godot encodes packed arrays.
func to_payload() -> Dictionary:
	var pv := PackedFloat32Array()
	pv.resize(verts.size() * 3)
	for i in verts.size():
		pv[i * 3 + 0] = verts[i].x
		pv[i * 3 + 1] = verts[i].y
		pv[i * 3 + 2] = verts[i].z
	var pn := PackedFloat32Array()
	pn.resize(norms.size() * 3)
	for i in norms.size():
		pn[i * 3 + 0] = norms[i].x
		pn[i * 3 + 1] = norms[i].y
		pn[i * 3 + 2] = norms[i].z
	var pu := PackedFloat32Array()
	pu.resize(uvs.size() * 2)
	for i in uvs.size():
		pu[i * 2 + 0] = uvs[i].x
		pu[i * 2 + 1] = uvs[i].y
	var bb := bounds()
	return {
		"position": Array(pv),
		"normal": Array(pn),
		"uv": Array(pu),
		"index": Array(idx),
		"bounds_min": [bb.position.x, bb.position.y, bb.position.z],
		"bounds_max": [bb.end.x, bb.end.y, bb.end.z],
	}