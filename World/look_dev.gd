class_name LookDev
extends RefCounted
## The look vocabulary for the road edge, and the numbers that hold it to standard.
##
## `artkit/` is the Art Director's path and this is not: this is the map's own
## answer to "the roads and kerbs look bad", and `docs/decisions/0001-art-director.md`
## is where the brief comes from. Two things out of that document shape everything
## here:
##
##   1. It names a **seven-point rubric** - asphalt, markings, buildings,
##      vegetation, lighting, atmosphere, material variation - and a vision-model
##      gate that "does not auto-pass". This file is the machine-checkable half of
##      four of those seven points (asphalt, markings, lighting, material
##      variation). A rubric the model scores and nobody asserts is how the
##      original pass shipped: 1354 green assertions, none of them about a pixel.
##   2. It calls "a library of N identical materials ... looks like a library and
##      behaves like a bug", and its context section names the failure this file
##      exists to fix: 24 primitive-construction call sites with flat single-colour
##      materials that read as "orange polygons in darkness".
##
## So the thresholds are all *measurements of the image*, not of the code.
## Anything here that could be satisfied by deleting geometry is deliberately not
## written: `KERB_TOP_W` and `PAINT_FLUSH_LIFT` are measured in the frame.
##
## The gate that matters, from the same document: **"No agent is authorised to
## expand the world until the beauty shot is acceptable"** and "the map agent must
## make one good 500 m stretch first". `LookMeasure.COVERAGE_M` is that 500 m.
##
## The thresholds are not here. They are in `World/look_measure.gd`, with the code
## that measures the frames, because they are assertions about an image and this
## file is a description of the road.

# --------------------------------------------------------------------- geometry
## Height of the kerb face. Not tunable: `Systems/traffic/pedestrians.gd` stands
## people on `WorldBuilder.KERB_HEIGHT` and that is a gameplay surface, not a look.
const KERB_HEIGHT := 0.14

## Width of the flat top of the kerb, excluding the channel. Australian kerb-and-
## channel: a 300 mm kerb is the standard section, and the old build drew a
## **1000 mm** top, which is why every street in the render reads as a low concrete
## wall with a ledge rather than as a road edge. Measured off the before shot: the
## pale band flanking the carriageway is 3x what a kerb should be and its outer
## half is a bench nobody stands on.
const KERB_TOP_W := 0.30

## Chamfer on the top edge of the kerb face. 25 mm. Small, and it is the whole
## reason the kerb has a highlight: a razor edge between two flat-shaded faces
## either catches the lamp or it does not, and a chamfer makes it always do.
const KERB_CHAMFER := 0.025

## Width of the concrete channel on the road side of the kerb, and how deep its
## dish is. This is the single biggest read in the frame: a continuous pale line
## running down both sides of a wet street is what separates "tarmac" from
## "ground". The old build had no channel at all - the kerb plinth butted straight
## onto the carriageway.
const CHANNEL_W := 0.45
const CHANNEL_DEPTH := 0.035

## How far behind the kerb the footpath starts, and how wide it is. The old build
## put the footpath at carriageway-edge + 0.5 while the plinth ran to +1.0, so the
## footpath sat *on top of* the outer half of its own kerb and the remaining 0.5 m
## stuck out as an unexplained ledge.
const FOOTPATH_W := 1.6

## Where the open drain trench goes. Cairns puts it in the nature strip, behind
## the footpath, not in the carriageway: the old build put a 1.6 m x 0.30 m trench
## at carriageway-edge + 0.15, which is *underneath* both the kerb plinth and the
## footpath - three surfaces fighting over the same metre of ground, which is what
## the dark slots along the kerb in the before shot actually are.
const DRAIN_W := 1.6
const DRAIN_DEPTH := 0.30
const DRAIN_RAIL_W := 0.30
## Distance from the back of the footpath to the centre of the trench.
const DRAIN_OFF := 0.95

## Lateral budget of one side of a street, kerb-side inward to outward. Derived,
## so a change to any one section cannot silently eat the next one's ground.
static func kerb_to_footpath_gap() -> float:
	return KERB_TOP_W


static func channel_to_back_of_footpath() -> float:
	return CHANNEL_W + KERB_TOP_W + FOOTPATH_W


static func back_of_footpath_to_drain_centre() -> float:
	return channel_to_back_of_footpath() + DRAIN_OFF


# ------------------------------------------------------------------- road paint
## Line width. Was 0.12 m and stays 0.12 m: that is the real dimension of an
## Australian lane line and there is nothing to gain by making it wider.
const LINE_W := 0.12

## The vertical budget of the road edge, in metres above y=0, in one place.
##
## These three were previously three separate literals in two different functions
## of `WorldBuilder` (0.015 for the carriageway mesh, 0.020 for the junction
## patch, 0.028 for the markings) which is why the paint could be *below* the
## junction tarmac it crosses and neither file could see it.
const TARMAC_Y := 0.015
const JUNCTION_Y := 0.020
## How far the paint film sits above the carriageway mesh. 12 mm: enough to beat
## the junction patch's extra 5 mm and the float depth at street level, small
## enough to be a decal. The old build used a 12 mm **box** instead, which is the
## same number doing the same job as a slab of plastic - you could see the side of
## every dash in profile, and the camera's own rim light caught it.
const PAINT_LIFT := 0.012
const PAINT_Y := TARMAC_Y + PAINT_LIFT

## Line width, again, for the only caller that draws a bar rather than a stripe.
## Real stop bars and edge lines in this state are 150 mm; the old code reused
## LINE_W for the edge lines and a hardcoded 0.4 m depth for the bar, and neither
## was a real dimension.
const BAR_W := 0.15

# ------------------------------------------------------------------- thresholds
## Seven-point rubric, `docs/decisions/0001-art-director.md`: "asphalt, markings,
## buildings, vegetation, lighting, atmosphere, material variation".
##
## Only four are this file's business - the other three belong to `artkit/` and
## `Systems/` - and each threshold below names the point it defends.

## MATERIAL VARIATION. The document's own words: "a library of N identical
## materials looks like a library and behaves like a bug", and the whole context
## section is about surfaces that are flat and single-coloured. The road edge is
## five distinct surfaces - carriageway, channel, kerb top, kerb face, footpath -
## and it is drawn from four. Five is the count the geometry above actually
## creates; four is what a single shared `concrete` gives you.
const MIN_SURFACE_FAMILIES := 5
# ------------------------------------------------------------------- materials
## The road-edge material set, keyed by the batch material key `WorldBuilder`
## uses. Every entry is a *different* material with its own roughness, because the
## whole point is that a kerb does not return the same light as the footpath next
## to it - they differ by a metre and a half of height, and at a grazing angle
## that is the entire difference between "concrete" and "street".
##
## Order matters for readability only. Roughness, not albedo, is what separates
## these at night: the frame is lit by sodium lamps at a grazing angle, so a wet
## surface returns a long specular smear and a dry one returns almost nothing.
static func kerb_top_mat() -> StandardMaterial3D:
	var m := MatLib.concrete(Color(0.235, 0.230, 0.222))
	# The kerb top is the one part of a kerb a tyre never touches and rain never
	# washes. Wet at the face, drier and grimier on top.
	m.roughness = 0.42
	m.uv1_scale = Vector3(0.30, 0.30, 0.30)
	return m


static func kerb_face_mat() -> StandardMaterial3D:
	var m := MatLib.concrete(Color(0.150, 0.148, 0.146))
	# A vertical face at night is lit by nothing: no lamp is above it, and the
	# moon is 52 degrees off the horizontal. It has to be *dark*, or the kerb
	# reads as a pale wall and the channel above it stops being a line.
	m.roughness = 0.88
	m.uv1_scale = Vector3(0.45, 0.45, 0.45)
	return m


static func channel_mat() -> StandardMaterial3D:
	var m := MatLib.concrete(Color(0.170, 0.170, 0.175))
	# Standing water in a channel. This is what turns the edge of the frame into a
	# line of reflected sodium, and it is the reason the kerb is worth drawing.
	m.roughness = 0.16
	m.metallic_specular = 0.9
	m.uv1_scale = Vector3(0.22, 0.22, 0.22)
	return m


static func footpath_mat() -> StandardMaterial3D:
	var m := MatLib.concrete(Color(0.300, 0.294, 0.278))
	# Dry, pale, and *higher* than the kerb top: it is the brightest thing at
	# ground level in a night frame and that is what it is in life - a slab under
	# a streetlight is the closest thing to daylight you get at ground level.
	m.roughness = 0.86
	m.uv1_scale = Vector3(0.55, 0.55, 0.55)
	return m


## Every surface family the road edge is drawn from, for the assertion that counts
## them. Keyed the same way `WorldBuilder._mat` keys them, so the count is of
## materials that are actually instanced and not of functions nobody calls.
const SURFACE_KEYS := [
	"asphalt", "channel", "kerb_top", "kerb_face", "footpath", "concrete",
]

# --------------------------------------------------------------------- profiles
## The kerb, split into two meshes so its two surfaces can be two materials.
##
## A `MultiMeshInstance3D` carries one `material_override` and `WorldBuilder._add`
## keys one mesh per material key, so a single mesh with a dark face and a lighter
## top would force both to share one material. Splitting costs one extra draw call
## for the whole map and buys the only thing that matters at night: a kerb whose
## top catches the lamp and whose face does not.
##
## Local frame for both: +X points *away* from the carriageway, +Y up, +Z along
## the kerb. Length is 1 in Z so one mesh serves every piece and the instance
## scales it. Both meshes are authored in the *same* frame - the face mesh starts
## at x=0 because the top does - so a single transform places both.
static func kerb_face_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := KERB_HEIGHT
	var c := KERB_CHAMFER
	# The vertical face, stopping short of the top so the chamfer can take the edge.
	_profile_quad(st, Vector2(0.0, 0.0), Vector2(0.0, h - c), Vector2(-1.0, 0.0))
	# The 25 mm chamfer. Small, and it is the entire reason the kerb has a
	# highlight at all: between two flat faces meeting at a right angle, whether
	# the edge catches light is a coin flip, and a chamfer makes it always.
	_profile_quad(st, Vector2(0.0, h - c), Vector2(c, h), Vector2(-0.7071, 0.7071))
	return st.commit()


static func kerb_top_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := KERB_HEIGHT
	var c := KERB_CHAMFER
	var w := KERB_TOP_W
	# Top face. 300 mm, which is what makes it a kerb and not a ledge.
	_profile_quad(st, Vector2(c, h), Vector2(w, h), Vector2(0.0, 1.0))
	# Back, down to ground, so the kerb is a solid and not a floating lid. The
	# footpath covers it in a normal street; it is here so the kerb reads as a
	# solid from a grazing angle, which is the only angle anyone looks at a kerb
	# from.
	_profile_quad(st, Vector2(w, h), Vector2(w, 0.0), Vector2(1.0, 0.0))
	return st.commit()


## The channel: a dished concrete gutter on the road side of the kerb, flush with
## the carriageway at the near lip, 35 mm low across the floor, and back up to
## flush at the kerb. Three quads, six triangles.
##
## The floor is the point. A continuous 0.45 m line of wet concrete down both
## sides of a street, carrying the reflection of every sodium lamp above it, is
## the single element that turns "a dark strip between two buildings" into a
## road. It is also the cheapest thing in this file: six triangles a side.
static func channel_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := CHANNEL_W
	var d := CHANNEL_DEPTH
	var a := w * 0.34
	var b := w * 0.66
	var up := Vector2(0.0, 1.0)
	_profile_quad(st, Vector2(0.0, 0.0), Vector2(a, -d), up)
	_profile_quad(st, Vector2(a, -d), Vector2(b, -d), up)
	_profile_quad(st, Vector2(b, -d), Vector2(w, 0.0), up)
	return st.commit()


## One quad in the profile plane, extruded the full unit length in Z.
##
## `p` and `q` are the two ends of the cross-section edge and `n` is the normal
## the surface is meant to have. Which of `p`/`q` comes first is decided here by
## the sign of the normal rather than left to the caller, because getting it
## backwards is invisible in code review and catastrophic in a render: the face
## is culled, or lit from underneath. `WorldBuilder._quad` documents the same
## contract from the other side - it says "walk the corners counter-clockwise seen
## from above so the right-hand rule reads the outward normal" - and this is that
## rule with the caller protected from it.
static func _profile_quad(st: SurfaceTool, p: Vector2, q: Vector2, n: Vector2) -> void:
	var a2 := p
	var b2 := q
	# Right-hand-rule normal of (a, b, b-at-plus-Z) is (e.y, -e.x) with e = b - a.
	var e := b2 - a2
	var rh := Vector2(e.y, -e.x)
	if rh.dot(n) < 0.0:
		a2 = q
		b2 = p
	var nn := Vector3(n.x, n.y, 0.0)
	var a := Vector3(a2.x, a2.y, -0.5)
	var b := Vector3(b2.x, b2.y, -0.5)
	var c2 := Vector3(b2.x, b2.y, 0.5)
	var d2 := Vector3(a2.x, a2.y, 0.5)
	# Reversed winding: emitted (a, c, b) and (a, d, c), which is what
	# `WorldBuilder._quad` does and why that file is legible about normals.
	for v in [a, c2, b, a, d2, c2]:
		st.set_normal(nn)
		st.set_uv(Vector2(v.x, v.z))
		st.add_vertex(v)


## A flat strip of paint on the tarmac, lying in the XZ plane with +Y up.
##
## Unit: 1 x 1 in X/Z, at y = 0, so one mesh serves every dash, edge line and stop
## bar in the map and the instance scale is the only thing that differs. Same
## reason `_box_mesh(Vector3.ONE, ...)` was used for the old markings.
##
## Flat, and flat is the whole point. The old box had two visible faces - the top
## and a 12 mm side - and at a street-level camera that side is a specular edge
## running the length of every dash in frame. Two triangles instead of twelve.
##
## Winding is `(a, b, c)`, which puts the right-hand-rule normal at **-Y**: into
## the tarmac, exactly as `WorldBuilder._road_quad` does it. Godot draws a face
## whose right-hand-rule normal points away from the camera, so -Y is the
## convention that makes a road surface visible from a camera above it - and a
## marking wound the other way is a decal you cannot see. `winding_normal` exists
## so this is asserted rather than remembered.
static func paint_quad() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-0.5, 0.0, -0.5)
	var b := Vector3(0.5, 0.0, -0.5)
	var c := Vector3(0.5, 0.0, 0.5)
	var d := Vector3(-0.5, 0.0, 0.5)
	for v in [a, b, c, a, c, d]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x + 0.5, v.z + 0.5))
		st.add_vertex(v)
	return st.commit()


## Area-weighted mean right-hand-rule winding normal of a triangle mesh.
##
## This is the one number that decides whether a surface exists. Godot culls by
## winding, not by the normal attribute, so a mesh can carry a perfect upward
## normal and still be invisible from above - and `WorldBuilder` has exactly that
## disagreement between `_road_quad` (wound to -Y, visible, and therefore the
## reference) and `_junction_fan` (wound to +Y, from the same file, written
## later). Measured rather than read, because the disagreement is invisible in
## every screenshot taken from a car.
static func winding_normal(mesh: ArrayMesh) -> Vector3:
	if mesh == null:
		return Vector3.ZERO
	var acc := Vector3.ZERO
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for t in range(0, verts.size() - 2, 3):
			var a: Vector3 = verts[t]
			var b: Vector3 = verts[t + 1]
			var c: Vector3 = verts[t + 2]
			# Cross product magnitude is twice the triangle's area, so summing
			# the un-normalised crosses weights by area - a 12-triangle plinth and
			# a 2-triangle dash cannot average each other out by triangle count.
			acc += (b - a).cross(c - a)
	return acc.normalized() if acc.length_squared() > 0.000001 else Vector3.ZERO
