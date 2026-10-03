class_name ArtKitMesh
extends RefCounted
## The procedural mesh vocabulary every artkit generator is built from.
##
## Nobody in this project can model or paint, so geometry is code. The only way
## that stays maintainable is if there is exactly one box, one tapered cylinder
## and one swept strand in the project - otherwise four agents write four
## slightly different boxes and the world is subtly incoherent at the millimetre
## level, which is exactly the "procedural" smell the art direction is fighting.
##
## ## Scale and origin - the whole kit obeys this, so get it right
##
##   - **1 unit = 1 metre.** No decimetres, no "about a metre". The world is
##     2.6 km across and a 10% scale error is a 260 m error in the city.
##   - **+Y is up. +Z is the front** of whatever the primitive is (a building
##     faces +Z, a palm's fronds fan toward +Z). Consumers only ever need a yaw.
##   - **Origin is the footprint centre on the ground: x = 0 is the centre line,
##     z = 0 is the centre line, y = 0 is the bottom.** Every builder below takes
##     an explicit `at` / `base` / `from` so nothing is implicit. A prop dropped
##     at a world position is standing on the road, not half-buried in it, and
##     the normal case needs no correction vector.
##   - **Meshes are baked at real size; instances scale uniformly only.** A
##     non-uniform instance scale shears normals and stretches a corrugation
##     pattern. Uniform 0.85-1.2 is safe and is how height variation is done.
##   - Every mesh is committed with **flat normals** unless the primitive is
##     genuinely curved, because flat is what a road, a kerb and a wall panel
##     need. Curved primitives (tube, strand, blob, revolved fan) get smooth
##     normals from `generate_normals()`.
##   - **UVs are in metres, not normalised**, so one material tiles the same on a
##     kerb and a warehouse. Triplanar materials in the library ignore them;
##     the corrugation stripes and the road paint do not.

## Corners of a unit box, in the winding the face table below expects.
static func _box_corners(s: Vector3) -> Array:
	var h := s * 0.5
	return [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
const _BOX_FACES := [
	[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
	[3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5],
]


# ----------------------------------------------------------------- surface tool

## Adds one quad as two triangles, flat-shaded. `uv_scale` is in metres, so a
## world-sized quad and a 4 m module get the same texel density.
static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uv_scale: float = 1.0) -> void:
	var n := tri_normal(a, b, c)
	_add(st, a, n, uv_scale)
	_add(st, b, n, uv_scale)
	_add(st, c, n, uv_scale)
	_add(st, a, n, uv_scale)
	_add(st, c, n, uv_scale)
	_add(st, d, n, uv_scale)


static func tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, uv_scale: float = 1.0) -> void:
	var n := tri_normal(a, b, c)
	_add(st, a, n, uv_scale)
	_add(st, b, n, uv_scale)
	_add(st, c, n, uv_scale)


## A quad with the winding of `a b c d` reversed, for the inside of a shell.
static func quad_flip(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uv_scale: float = 1.0) -> void:
	quad(st, a, d, c, b, uv_scale)


static func _add(st: SurfaceTool, v: Vector3, n: Vector3, uv_scale: float) -> void:
	st.set_normal(n)
	st.set_uv(Vector2(v.x, v.z) * uv_scale)
	st.add_vertex(v)


static func tri_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	return n.normalized() if n.length_squared() > 0.000001 else Vector3.UP


## Commits a SurfaceTool, optionally replacing the flat normals with averaged
## ones. A degenerate surface (zero vertices) still returns a real ArrayMesh with
## zero surfaces rather than null, so a caller never has to null-check.
static func commit(st: SurfaceTool, smooth: bool = false) -> ArrayMesh:
	if smooth:
		st.generate_normals()
	return st.commit()


static func begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


# -------------------------------------------------------------------- primitives

## An axis-aligned box. 12 triangles. `at` is the centre.
static func box(size: Vector3, at: Vector3 = Vector3.ZERO, uv_scale: float = 1.0) -> ArrayMesh:
	var st := begin()
	var corners := _box_corners(size)
	for f in _BOX_FACES:
		quad(st,
			(corners[int(f[0])] as Vector3) + at,
			(corners[int(f[1])] as Vector3) + at,
			(corners[int(f[2])] as Vector3) + at,
			(corners[int(f[3])] as Vector3) + at, uv_scale)
	return commit(st)


## A box specified by its minimum corner, which is how a house is actually laid
## out: "the wall panel from x=-5 y=1.1 to x=5 y=4.2".
static func box_from(size: Vector3, from: Vector3, uv_scale: float = 1.0) -> ArrayMesh:
	return box(size, from + size * 0.5, uv_scale)


## A tapered tube standing on the ground: `r0` at y=0, `r1` at y=h. Smooth
## shaded, so a pole does not read as an octagon. Capped, because an open top on
## a streetlight column shows the sky through it at a shallow angle.
static func tube(r0: float, r1: float, h: float, sides: int, base: Vector3 = Vector3.ZERO,
		cap: bool = true) -> ArrayMesh:
	var st := begin()
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := base + Vector3(cos(a0) * r0, 0.0, sin(a0) * r0)
		var b1 := base + Vector3(cos(a1) * r0, 0.0, sin(a1) * r0)
		var t0 := base + Vector3(cos(a0) * r1, h, sin(a0) * r1)
		var t1 := base + Vector3(cos(a1) * r1, h, sin(a1) * r1)
		quad(st, b0, b1, t1, t0)
	if cap:
		var top := base + Vector3(0, h, 0)
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			tri(st, top,
				base + Vector3(cos(a0) * r1, h, sin(a0) * r1),
				base + Vector3(cos(a1) * r1, h, sin(a1) * r1))
	return commit(st, true)


## A tube whose axis *leans*, and optionally *curves*, in the XZ plane.
## Coconut palms are not plumb: the sweep is most of what makes one read as a
## palm instead of a pole with leaves on it. `bend` is the horizontal offset at
## the crown, in metres; `sway` is a second-order term so the trunk is a curve
## rather than a straight diagonal.
static func curved_tube(r0: float, r1: float, h: float, sides: int, bend: float,
		sway: float, rings: int = 4, base: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var st := begin()
	var prev: Array = []
	for ring in rings + 1:
		var t := float(ring) / float(rings)
		var centre := base + Vector3(bend * t * t + sway * t * t * t, h * t, 0.0)
		var r: float = lerpf(r0, r1, t)
		var ring_pts: Array = []
		for i in sides:
			var a := TAU * float(i) / float(sides)
			ring_pts.append(centre + Vector3(cos(a) * r, 0.0, sin(a) * r))
		if ring > 0:
			for i in sides:
				var j := (i + 1) % sides
				quad(st, prev[i], prev[j], ring_pts[j], ring_pts[i])
		prev = ring_pts
	var crown: Vector3 = base + Vector3(bend + sway, h, 0.0)
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		tri(st, crown,
			base + Vector3(bend + sway + cos(a0) * r1, h, sin(a0) * r1),
			base + Vector3(bend + sway + cos(a1) * r1, h, sin(a1) * r1))
	return commit(st, true)


## A gabled roof solid, ridge running along +X, sitting on `eave_y` with the
## ridge `h` above it and overhanging the walls by `overhang` on all four sides.
## A closed solid rather than two planes, because an open roof shows its own
## interior through the gable ends from a low camera.
static func gable_roof(w: float, d: float, h: float, overhang: float, eave_y: float,
		thickness: float = 0.12) -> ArrayMesh:
	var hw := w * 0.5 + overhang
	var hd := d * 0.5 + overhang
	var ridge := h
	# Cross-section in the YZ plane, traced anticlockwise seen from +X.
	var prof := [
		Vector3(0, ridge, -hd), Vector3(0, ridge, hd),
		Vector3(0, -thickness, hd), Vector3(0, -thickness, -hd),
	]
	var st := begin()
	for i in prof.size():
		var a: Vector3 = prof[i]
		var b: Vector3 = prof[(i + 1) % prof.size()]
		quad(st, Vector3(-hw, a.y + eave_y, a.z), Vector3(hw, a.y + eave_y, a.z),
			Vector3(hw, b.y + eave_y, b.z), Vector3(-hw, b.y + eave_y, b.z))
	# Gable ends, which close the triangle at each end of the ridge.
	for sx in [-1.0, 1.0]:
		var x: float = hw * sx
		var t0 := Vector3(x, eave_y, -hd)
		var t1 := Vector3(x, eave_y, hd)
		var r := Vector3(x, eave_y + ridge, 0.0)
		var b0 := Vector3(x, eave_y - thickness, -hd)
		var b1 := Vector3(x, eave_y - thickness, hd)
		if sx < 0.0:
			tri(st, t0, r, t1)
			tri(st, t0, t1, b1)
			tri(st, t0, b1, b0)
			tri(st, t1, r, t0)
		else:
			tri(st, t0, t1, r)
			tri(st, t0, b1, t1)
			tri(st, t0, b0, b1)
			tri(st, t0, r, t1)
	return commit(st)


## A single-slope roof: high at -Z, low at +Z (i.e. it drains toward the front),
## which is how a carport or a shed lean-to is actually built.
static func mono_roof(w: float, d: float, rise: float, overhang: float, eave_y: float,
		thickness: float = 0.1) -> ArrayMesh:
	var hw := w * 0.5 + overhang
	var hd := d * 0.5 + overhang
	var hi := eave_y + rise
	var lo := eave_y
	var st := begin()
	# Slope.
	quad(st, Vector3(-hw, hi, -hd), Vector3(hw, hi, -hd), Vector3(hw, lo, hd), Vector3(-hw, lo, hd))
	# Underside, so a carport seen from the road has a ceiling.
	quad(st, Vector3(-hw, hi - thickness, -hd), Vector3(-hw, lo - thickness, hd),
		Vector3(hw, lo - thickness, hd), Vector3(hw, hi - thickness, -hd))
	# The two raking edges and the front fascia.
	quad(st, Vector3(-hw, hi, -hd), Vector3(-hw, lo, hd), Vector3(-hw, lo - thickness, hd),
		Vector3(-hw, hi - thickness, -hd))
	quad(st, Vector3(hw, hi, -hd), Vector3(hw, hi - thickness, -hd), Vector3(hw, lo - thickness, hd),
		Vector3(hw, lo, hd))
	quad(st, Vector3(-hw, lo, hd), Vector3(hw, lo, hd), Vector3(hw, lo - thickness, hd),
		Vector3(-hw, lo - thickness, hd))
	return commit(st)


## Extrudes a closed XZ polygon between two heights, with caps. This is the
## workhorse, and the reason the buildings agent can extrude 2198 *real* OSM
## footprints instead of boxes: same material library, same batching, no boxes.
## `poly` is in metres, anticlockwise seen from above. Concave polygons are fine
## - the cap is a fan from vertex 0, which is valid for a star-shaped polygon and
## every building outline in a 2.5 km suburban extract is.
static func prism(poly: PackedVector2Array, y0: float, y1: float, uv_scale: float = 1.0) -> ArrayMesh:
	var n := poly.size()
	if n < 3 or y1 <= y0:
		return commit(begin())
	var st := begin()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		quad(st,
			Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y),
			Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y), uv_scale)
	for i in range(1, n - 1):
		tri(st, Vector3(poly[0].x, y1, poly[0].y),
			Vector3(poly[i].x, y1, poly[i].y),
			Vector3(poly[i + 1].x, y1, poly[i + 1].y), uv_scale)
		tri(st, Vector3(poly[0].x, y0, poly[0].y),
			Vector3(poly[i + 1].x, y0, poly[i + 1].y),
			Vector3(poly[i].x, y0, poly[i].y), uv_scale)
	return commit(st)


## A flat polygon in one plane - a window pane, a sign face, a road patch.
static func slab(poly: PackedVector2Array, y: float, uv_scale: float = 1.0) -> ArrayMesh:
	return prism(poly, y, y + 0.001, uv_scale)


## A tapered blade lying along +Z from the origin, drooping under its own weight.
## `width_fn` and `drop_fn` take t in 0..1. This is the palm frond, the fern
## frond, the grass blade and the roadside weed: one shape, four uses, which is
## why 1600 palms are not 1600 identical objects.
static func blade(length: float, segments: int, width_fn: Callable, drop_fn: Callable,
		twist: float = 0.0) -> ArrayMesh:
	var st := begin()
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for i in segments + 1:
		var t := float(i) / float(segments)
		var w: float = maxf(float(width_fn.call(t)), 0.008)
		var y: float = float(drop_fn.call(t))
		var roll := twist * t
		var dir := Vector3(cos(roll), 0.0, sin(roll))
		var centre := Vector3(0, y, t * length)
		var l := centre - dir * w
		var r := centre + dir * w
		if i > 0:
			quad(st, prev_l, l, r, prev_r)
			quad(st, prev_r, r, l, prev_l)
		prev_l = l
		prev_r = r
	return commit(st)


## A fan palm leaf: `ribs` tapered blades radiating through `spread` radians in
## the XZ plane from `base`, each drooping. A Livistona is not a feather, and
## using a feather for it is the single most common way a procedural tropical
## street reads as a video-game tree.
static func fan(radius: float, ribs: int, spread: float, droop: float,
		base: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var st := begin()
	for i in ribs:
		var a := -spread * 0.5 + spread * (float(i) / maxf(float(ribs - 1), 1.0))
		var dir := Vector3(sin(a), 0.0, cos(a))
		var tip := base + Vector3(dir.x * radius, -droop, dir.z * radius)
		var side := Vector3(cos(a), 0.0, -sin(a)) * (radius * 0.17)
		var mid := base.lerp(tip, 0.45) - Vector3(0, droop * 0.12, 0)
		# Two triangles per rib, doubled, because foliage is two-sided in the
		# material and a back face costs nothing next to a hole in the canopy.
		tri(st, base, mid - side, tip)
		tri(st, base, tip, mid + side)
		tri(st, base, tip, mid - side)
		tri(st, base, mid + side, tip)
	return commit(st)


## ## Why a frond is not a blade
##
## `blade()` is a straight tapering strip. That is right for a grass blade and a
## fern pinna and wrong for a palm frond, because a frond's *outline* is the
## entire read. A frond leaves the crown on a narrow petiole, is widest at about
## a third of its length, arcs over, and finishes in a fine point. Built from
## `blade()`'s straight spine with a monotonic taper, that outline is a wedge -
## and a ring of wedges is exactly the "floating green rhombus grid" the owner
## photographed on 2026-10-02, where eleven fronds closed into a solid faceted
## disc that read as a toy prop.
##
## Three things change here and all three are free or cheaper than what they
## replace:
##
## 1. The spine is a real curve. A quadratic bezier through (base, apex, tip),
##    sampled at `segments` spans, so the arch is smooth instead of three
##    straight chords.
## 2. The width profile is lanceolate (see `frond_half_width`), widest at t=0.33
##    instead of at the base. Narrow at the base is what leaves sky between
##    fronds, which is what makes a canopy read as leaves rather than as a lid.
## 3. The blade *rolls* along its length. A perfectly planar blade presents one
##    flat facet to a streetlight; rolling it means each span catches the key at
##    a different angle, which is most of the difference between "lit" and
##    "shaped".
##
## ## One quad per span, not two
##
## Every foliage material is `CULL_DISABLED` (see `materials.gd`), so a span
## needs no back face to be visible from behind. The span this replaced emitted
## the front quad and then `quad_flip`ped *the same four vertices in the same
## order* - a bit-identical duplicate, which z-fights and costs 50% of the
## crown's triangles for nothing. Dropping it is what pays for the extra
## segments: 7 spans single-sided costs 14 triangles against 12 for 3 spans
## doubled, so the crown gains resolution for two triangles per frond.
static func frond(st: SurfaceTool, base: Vector3, horiz: Vector3, reach: float,
		lift: float, tip_drop: float, half_width: float, segments: int,
		roll: float = 0.0) -> void:
	if segments < 1 or reach <= 0.0:
		return
	# Quadratic bezier: base, an apex up-and-out, then the tip. The tangents at
	# both ends are horizontal-ish and down-ish respectively, which is what makes
	# a palm frond leave the crown rising and end hanging.
	var apex := base + horiz * (reach * 0.46) + Vector3.UP * (lift * 0.58)
	var tip := base + horiz * reach - Vector3.UP * tip_drop
	var axis := horiz.cross(Vector3.UP).normalized()
	if axis.length_squared() < 0.001:
		axis = Vector3.RIGHT
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var have_prev := false
	for i in segments + 1:
		var t := float(i) / float(segments)
		var centre := _bezier2(base, apex, tip, t)
		# Roll the width axis about the spine tangent. Rolling about `horiz`
		# rather than the true tangent is a small approximation and costs no
		# extra maths; at these segment counts it is not visible.
		var w := frond_half_width(t, half_width)
		var dir := axis.rotated(horiz, roll * (t - 0.5) * 2.0)
		var l := centre - dir * w
		var r := centre + dir * w
		if have_prev:
			quad(st, prev_l, l, r, prev_r)
		prev_l = l
		prev_r = r
		have_prev = true


## The lanceolate half-width of a frond at `t` in 0..1, as a multiple of
## `half_width` (which is the *maximum*, not the base width).
##
## The three factors, and why each exists:
##   - `sin(pi * t^0.55)` is zero at the base and at the tip and peaks where
##     `t^0.55 = 0.5`, i.e. t = 0.327. That is the widest point, and it is the
##     whole difference between a leaf and a dart.
##   - the `root` term fills the first 18% of the length in from the petiole, so
##     the base is a narrow stalk rather than a degenerate zero-width vertex.
##   - the `tip` term runs the last third down to a fine point, so the frond ends
##     in a tip instead of a chopped-off edge.
##
## 0.03 of the maximum is the floor. Without it the first and last spans collapse
## to zero-area triangles, which still rasterise and still cost a triangle.
static func frond_half_width(t: float, half_width: float) -> float:
	var u := clampf(t, 0.0, 1.0)
	var blade := pow(maxf(sin(PI * pow(u, 0.55)), 0.0), 0.75)
	var root := 0.34 + 0.66 * clampf(u / 0.18, 0.0, 1.0)
	var tip := 1.0 - 0.94 * pow(clampf((u - 0.66) / 0.34, 0.0, 1.0), 1.5)
	return half_width * maxf(blade * root * tip, 0.03)


static func _bezier2(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * (u * u) + b * (2.0 * u * t) + c * (t * t)



## A thin square strand swept along a polyline. The overhead wires: 3000 spans as
## one batched mesh, which is why this exists instead of drawing lines.
static func strand(points: PackedVector3Array, radius: float) -> ArrayMesh:
	var st := begin()
	if points.size() < 2:
		return commit(st)
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var dir := (b - a).normalized()
		if dir.length_squared() < 0.5:
			continue
		var side := dir.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		side = side.normalized() * radius
		var up := side.cross(dir).normalized() * radius
		quad(st, a - side, b - side, b + up, a + up)
		quad(st, a + up, b + up, b - side, a - side)
		quad(st, a - side, a + up, b + up, b - side)
		quad(st, a + up, a - side, b - side, b + up)
	return commit(st, true)


## A closed blob: a UV sphere pushed around by cheap integer-hash noise. Bushes,
## tree canopies and the odd termite mound. `lump` is how far the radius moves;
## a value of 0 gives a sphere, which is a legitimate answer for a clipped hedge.
##
## `at` is explicit like every other builder here, and a blob is a sphere so the
## distinction is not cosmetic: without it a tree canopy is centred on the origin,
## which puts half the crown 2.5 m underground. Bushes pass a low `at` on purpose,
## because a bush that sits *on* a bank looks pasted on.
static func blob(radius: float, rings: int, segs: int, lump: float, seed_value: int,
		at: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var st := begin()
	for r in rings:
		var v0 := PI * float(r) / float(rings)
		var v1 := PI * float(r + 1) / float(rings)
		for s in segs:
			var u0 := TAU * float(s) / float(segs)
			var u1 := TAU * float(s + 1) / float(segs)
			var a := _blob_point(v0, u0, radius, lump, seed_value)
			var b := _blob_point(v1, u0, radius, lump, seed_value)
			var c := _blob_point(v1, u1, radius, lump, seed_value)
			var d := _blob_point(v0, u1, radius, lump, seed_value)
			quad(st, a + at, b + at, c + at, d + at)
	return commit(st, true)


static func _blob_point(v: float, u: float, radius: float, lump: float, seed_value: int) -> Vector3:
	var d := Vector3(sin(v) * cos(u), cos(v), sin(v) * sin(u))
	var h := 0.0
	if lump > 0.0:
		# Three sine terms at incommensurate frequencies: deterministic, no
		# RNG state, and no visible grid the way a per-vertex RNG would give.
		h = lump * (sin(u * 3.0 + float(seed_value)) * 0.5
				+ sin(v * 4.0 - u * 2.0 + float(seed_value) * 1.7) * 0.3
				+ sin(u * 7.0 + v * 3.0 + float(seed_value) * 0.6) * 0.2)
	return d * (radius + h)


## A flat quad standing in the XY plane facing +Z. Window panes, sign faces, the
## back of a shopfront.
static func panel(w: float, h: float, centre: Vector3 = Vector3.ZERO, uv_scale: float = 1.0) -> ArrayMesh:
	var st := begin()
	var hw := w * 0.5
	var hh := h * 0.5
	quad(st, centre + Vector3(-hw, -hh, 0), centre + Vector3(hw, -hh, 0),
		centre + Vector3(hw, hh, 0), centre + Vector3(-hw, hh, 0), uv_scale)
	quad_flip(st, centre + Vector3(-hw, -hh, 0), centre + Vector3(-hw, hh, 0),
		centre + Vector3(hw, hh, 0), centre + Vector3(hw, -hh, 0), uv_scale)
	return commit(st)


## Two crossed quads. Grass tufts and weeds: 4 triangles for a plant that is
## 0.4 m tall and mostly seen from 8 m away.
static func cross(height: float, width: float, centre: Vector3 = Vector3.ZERO) -> ArrayMesh:
	var st := begin()
	var hw := width * 0.5
	panel_quads(st, centre + Vector3(-hw, height * 0.5, 0), Vector3(0, 1, 0), width, height)
	panel_quads(st, centre + Vector3(0, height * 0.5, -hw), Vector3(1, 0, 0), width, height)
	return commit(st)


static func panel_quads(st: SurfaceTool, centre: Vector3, up: Vector3, w: float, h: float) -> void:
	var side := up.cross(Vector3.FORWARD)
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	side = side.normalized() * (w * 0.5)
	var upn := up.normalized() * (h * 0.5)
	quad(st, centre - upn - side, centre + upn - side, centre + upn + side, centre - upn + side)
	quad_flip(st, centre - upn - side, centre - upn + side, centre + upn + side, centre + upn - side)


## A box whose top face is a different size from its bottom: wheelie bins, bin
## bodies, tapered shed walls, anything that is a prism rather than a cube.
## 20 triangles.
static func frustum(bottom: Vector2, top: Vector2, h: float, at: Vector3 = Vector3.ZERO,
		uv_scale: float = 1.0) -> ArrayMesh:
	var st := begin()
	var b0 := at + Vector3(-bottom.x * 0.5, 0.0, -bottom.y * 0.5)
	var b1 := at + Vector3(bottom.x * 0.5, 0.0, -bottom.y * 0.5)
	var b2 := at + Vector3(bottom.x * 0.5, 0.0, bottom.y * 0.5)
	var b3 := at + Vector3(-bottom.x * 0.5, 0.0, bottom.y * 0.5)
	var t0 := at + Vector3(-top.x * 0.5, h, -top.y * 0.5)
	var t1 := at + Vector3(top.x * 0.5, h, -top.y * 0.5)
	var t2 := at + Vector3(top.x * 0.5, h, top.y * 0.5)
	var t3 := at + Vector3(-top.x * 0.5, h, top.y * 0.5)
	quad(st, b0, b1, t1, t0, uv_scale)
	quad(st, b1, b2, t2, t1, uv_scale)
	quad(st, b2, b3, t3, t2, uv_scale)
	quad(st, b3, b0, t0, t3, uv_scale)
	quad(st, t0, t1, t2, t3, uv_scale)
	quad(st, b3, b2, b1, b0, uv_scale)
	return commit(st)


## Copies an already-built mesh into `st` under a transform, keeping its normals
## and re-deriving its UVs in world metres. This is how a generator builds a
## prop out of pieces without paying for a mesh merge: build the pieces, blit
## them into one SurfaceTool, commit once, and the whole prop is one mesh and
## one draw call.
static func blit(st: SurfaceTool, mesh: ArrayMesh, xform: Transform3D = Transform3D.IDENTITY,
		uv_scale: float = 0.25) -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var index: Variant = arrays[Mesh.ARRAY_INDEX]
	var count: int = (index as PackedInt32Array).size() if index != null else verts.size()
	for v in count:
		var p := xform * verts[v]
		st.set_normal((xform.basis * (norms[v] if norms.size() > v else Vector3.UP)).normalized())
		st.set_uv(Vector2(p.x, p.z) * uv_scale)
		st.add_vertex(p)


## The transform for a unit-length piece laid along `from -> to`, with local +X
## following the direction. Wire spans, kerb runs and fence lines all need this
## and all need the same basis construction, which is why it lives here.
static func along(from: Vector3, to: Vector3, length_scale: float = 1.0) -> Transform3D:
	var d := to - from
	if d.length_squared() < 0.000001:
		return Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * length_scale), from)
	var fwd := d.normalized()
	var z_axis := Vector3.UP.cross(fwd)
	z_axis = z_axis.normalized() if z_axis.length_squared() > 0.000001 else Vector3.FORWARD
	var y_axis := fwd.cross(z_axis).normalized()
	return Transform3D(Basis(fwd, y_axis, z_axis).scaled(Vector3.ONE * length_scale), from)


## Merges several meshes into one, offsetting each by `xforms`. Used when a
## generator wants one draw call out of pieces it built separately.
static func merge(meshes: Array, xforms: Array) -> ArrayMesh:
	var st := begin()
	for i in meshes.size():
		var xf: Transform3D = xforms[i] if i < xforms.size() else Transform3D.IDENTITY
		blit(st, meshes[i], xf)
	return commit(st)


## Triangle count of a mesh, across all surfaces. The number the budgets in
## `standards.md` are written against.
static func triangles(mesh: ArrayMesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var index: Variant = arrays[Mesh.ARRAY_INDEX]
		if index != null:
			total += (index as PackedInt32Array).size() / 3
		else:
			total += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total
