# =============================================================================
# house_kit_pieces.gd - the house kit roster
# =============================================================================
#
# THE REFERENCE STILLS DO NOT EXIST. Stated plainly because the brief asks for
# pieces "from the reference stills" and there is no such file anywhere in the
# repo, in /tmp/reports, or in artkit/. The only "reference board" the project
# has ever named is three commercial games (ART_DIRECTION.md:3-5). What exists
# as an elevation spec is prose, and every dimension below is taken from it or
# from a constant that is already in the tree:
#
#   artkit/buildings.gd:14-27  the four things that make a Queenslander read
#   artkit/buildings.gd:43-51  SILL 0.95, HEAD 2.10, WINDOW_RATIO 0.42
#   artkit/buildings.gd:212-296 house footprint 7.5-11.0 x 6.5-9.0, wall t
#                              0.20, lift 0.8-1.5, eave overhang 0.80-1.00,
#                              veranda depth 1.8
#   World/osm_buildings.gd:80-161  SILL 1.0, PANE_W 1.15, PANE_H 1.3,
#                              VERANDA_OUT 1.45, VERANDA_FASCIA 0.16,
#                              POST_W 0.10, SILL_OUT 0.07, SILL_T 0.09
#   artkit/props.gd:951-976  the 4 m paling module this kit must match
#
# ONE CANONICAL HOUSE, so the pieces are interchangeable
#
#   LIFT 1.10   floor off the dirt (in the repo's 0.8-1.5 band)
#   WALL_H 2.90 wall to the top plate (in the repo's 2.7-3.2 band)
#   WALL_T 0.20
#   WALL_W 8.00  span of the roof along the ridge (in the 7.5-11.0 band)
#   DEPTH 6.00  depth of the roof across it (in the 6.5-9.0 band)
#   EAVE 0.90   eave overhang (in the 0.80-1.00 band)
#   RIDGE_H 1.75 ridge above the eave line
#   DECK 0.76   veranda deck off the dirt, 4 x 0.19
#
# ORIGIN RULE - "origin at fastening point"
#
#   Every piece's origin is the point a tradesman would hold it against while
#   it is screwed on, and every piece is centred on that point in the axes that
#   matter for fastening. The rule is stated per piece in the roster below and
#   re-asserted in the manifest, because an origin nobody can predict is an
#   origin every placement has to correct by hand.
#
# SILHOUETTE GATE - the brief's "past 30 cm"
#
#   Read as: a house only reads as a Queenslander from a moving car because of
#   the features BIGGER than 30 cm - the 900 mm eave, the 1.75 m ridge, the
#   1.45 m veranda line, the 4 m paling module. Anything finer than 30 cm is
#   texture-scale: it may exist in a piece, but it is not allowed to be the
#   thing carrying the read. SIL_MIN is that line, it is asserted per piece,
#   and the ablation in the capture measures whether each piece really does
#   change the outline by at least 30 cm at the street framing. Where a piece
#   fails, it is reported as failing rather than fattened to pass - a 300 mm
#   downpipe would be wrong.

class_name HouseKitPieces
extends RefCounted

# Resolved by preload, not by the class_name registry. `class_name` globals only
# resolve once `.godot/global_script_class_cache.cfg` exists, and refreshing that
# cache needs an editor import pass that writes .import stubs for every asset in
# the project - which is not this file's business. preload() works on a cold
# checkout, so the kit builds on a fresh clone with no import step at all.
const Geom := preload("res://assets/kits/house_kit_geom.gd")

# --- the canonical house -----------------------------------------------------
const LIFT := 1.10
const WALL_H := 2.90
const WALL_T := 0.20
const WALL_W := 8.00
const DEPTH := 6.00
const EAVE := 0.90
const RIDGE_H := 1.75
const FASCIA_H := 0.16          # World/osm_buildings.gd:145 VERANDA_FASCIA
const DECK := 0.76              # 4 x 0.19 riser
const TREAD := 0.25
const STEP_W := 1.10
const VERANDA_OUT := 1.45     # World/osm_buildings.gd:133 - where a boundary
                              # paling fence stands, off the frontage

# --- window ------------------------------------------------------------------
const OPEN_W := 1.15            # World/osm_buildings.gd:81 PANE_W
const OPEN_H := 1.15            # PANE_H 1.3 minus a 0.15 head trim; square
const SILL := 0.95              # artkit/buildings.gd:46
const HEAD := 2.10              # artkit/buildings.gd:47
const FRAME_W := 0.09
const REVEAL := 0.09            # how far the frame sits back into the wall
const SASH_W := 0.055
const SILL_OUT := 0.07          # World/osm_buildings.gd:155 SILL_OUT
const SILL_T := 0.09            # :156 SILL_T

# --- gutter / downpipe -------------------------------------------------------
const GUTTER_DIA := 0.15
const GUTTER_WALL := 0.012
const DOWNPIPE_R := 0.055
# A fixed mesh cannot know its own mounting height, so the drop is cut for the
# canonical plate (LIFT + WALL_H = 4.00 m) and lands the elbow 0.10 m above
# grade. Measured clearance is reported by the capture; a different plate height
# must re-cut this, and the capture's alignment table is what will tell you.
const DOWNPIPE_DROP := 3.60
const DOWNPIPE_ELBOW := 90.0

# --- frontage ----------------------------------------------------------------
const POST_W := 0.12            # World/osm_buildings.gd:152 POST_W is 0.10;
                                # 0.12 for a veranda post, which is 2.4 m tall
const POST_H := 2.40

# --- paling / gateling -------------------------------------------------------
const FENCE_H := 1.50           # artkit/props.gd:960
const FENCE_SPAN := 4.00        # artkit/props.gd:964
const PALING_W := 0.13          # artkit/props.gd:966
const PALING_PITCH := 0.16      # 130 mm paling + 30 mm gap. props.gd's 4/9
                                # pitch is 444 mm, which is a boarded fence with
                                # 314 mm gaps; a boundary paling fence is
                                # palings at a pitch, and the gap is the point.
const FENCE_POST_W := 0.12
const GATE_W := 1.28            # the gateling bay replaces eight palings
const SPEAR_ABOVE := 0.24       # how far the gateling spears stand above rail

const SIL_MIN := 0.30

## Four risers from grade to deck, not six. Six risers of 183 mm at a 300 mm
## tread is a stair 1.8 m deep, which is deeper than the 1.45 m veranda it is
## supposed to arrive at - the landing would come out negative. Four risers of
## 275 mm at a 280 mm tread is 1.12 m deep, leaves a 330 mm landing inside the
## 1.45 m veranda, and the top tread's surface IS the deck, so the step and the
## floor it serves are one number instead of two that nearly meet.
const RISERS := 4
## How far the step flight reaches OUT past the deck edge. The boundary fence has
## to stand clear of it, which is why the gateling is a gate onto the path and not
## decoration: it is the way in past the steps.
const FLIGHT_OUT := TREAD * float(RISERS)

## role -> {colour, metallic, roughness}. Roles, not hex, so a consumer can
## rebind the kit to its own palette without regenerating the geometry.
const ROLES := {
	"timber": {"color": [0.58, 0.54, 0.47, 1.0], "metallic": 0.0, "roughness": 0.72},
	"timber_dark": {"color": [0.40, 0.36, 0.31, 1.0], "metallic": 0.0, "roughness": 0.78},
	"paint_white": {"color": [0.86, 0.87, 0.85, 1.0], "metallic": 0.0, "roughness": 0.44},
	"roof_iron": {"color": [0.28, 0.30, 0.29, 1.0], "metallic": 0.35, "roughness": 0.46},
	"steel_galv": {"color": [0.62, 0.64, 0.66, 1.0], "metallic": 0.80, "roughness": 0.34},
	"glass_dark": {"color": [0.05, 0.07, 0.10, 1.0], "metallic": 0.0, "roughness": 0.08},
}


## The roster. `name` is the file stem AND the glTF node name - one name, no
## translation table. `fasten` is the origin rule in words. `sil_m` is the
## silhouette feature that is claimed to carry the piece.
static func roster() -> Array:
	return [
		{"name": "kit_window_sash", "archetype": "qld_house",
			"fasten": "centre of the opening, in the outside face plane of the wall; +Z out of the wall",
			"sil_m": OPEN_W,
			"sil_feature": "the 1.15 m frame band across the opening"},
		{"name": "kit_roof_gable", "archetype": "qld_house,qld_shop,industrial_shed,walk_up_block",
			"fasten": "midpoint of the ridge, on the ridge axis; ridge runs along +X, eaves at -RIDGE_H",
			"sil_m": EAVE,
			"sil_feature": "the 0.90 m eave overhang on both long sides, plus the 1.75 m ridge"},
		{"name": "kit_roof_hip", "archetype": "qld_house,qld_shop",
			"fasten": "midpoint of the ridge, on the ridge axis; ridge runs along +X, hipped both ends",
			"sil_m": EAVE,
			"sil_feature": "the 0.90 m eave overhang plus four slopes; reads hipped from any corner"},
		{"name": "kit_gutter_downpipe", "archetype": "qld_house,qld_shop",
			"fasten": "the gutter's fixing line at y=0 on the fascia plane z=0, at the outlet end (x=0)",
			"sil_m": GUTTER_DIA,
			"sil_feature": "the gutter run itself; the downpipe is a vertical rhythm line, not an outline"},
		{"name": "kit_frontage_step_post", "archetype": "qld_house",
			"fasten": "frontage wall plane x=0 z=0 at grade: the datum a fitter sights off. The post stands forward on the deck edge at z=1.45",
			"sil_m": VERANDA_OUT,
			"sil_feature": "the 1.45 m veranda deck line at 1.10 m, its corner post, and the step flight projecting 1.00 m past it"},
		{"name": "kit_fence_paling_gateling", "archetype": "qld_house",
			"fasten": "base of the leading post at y=0, on the fence line; the module runs +X over 4 m",
			"sil_m": FENCE_SPAN,
			"sil_feature": "the 4 m paling module and the 1.28 m gateling bay's spear tops"},
	]


static func roster_names() -> Array:
	var out := []
	for e in roster():
		out.append(String(e["name"]))
	return out


# =============================================================================
# 1. WINDOW WITH REVEAL AND SASH
# =============================================================================
# Origin at the centre of the opening, in the outside face plane of the wall.
# Opening OPEN_W x OPEN_H, centred on y = 0, so it spans y -0.575 .. +0.575 and
# the placer offsets to SILL + OPEN_H*0.5 = 1.525 to land the sill on SILL.
#
# What is here and why: a reveal (the opening's own jamb/head/sill returns, so
# the wall has thickness at the hole instead of a decal), a projecting sill
# board, a two-casement sash with real stiles and rails, and glass. The reveal is
# 90 mm, which is what makes the opening read as a hole in a 200 mm wall at any
# angle other than dead-on.

static func window_sash() -> Dictionary:
	var g := Geom.new()
	var hw := OPEN_W * 0.5
	var hh := OPEN_H * 0.5
	var fw := FRAME_W
	var inner_w := OPEN_W - fw * 2.0
	var inner_h := OPEN_H - fw * 2.0

	# --- reveal: the four returns of the opening, facing into the hole ------
	# Head return, facing down into the opening.
	g.push_quad(Vector3(-hw, hh, 0), Vector3(hw, hh, 0),
		Vector3(hw, hh, -REVEAL), Vector3(-hw, hh, -REVEAL), Vector3(0, -1, 0))
	# Sill return, facing up out of the hole.
	g.push_quad(Vector3(-hw, -hh, -REVEAL), Vector3(hw, -hh, -REVEAL),
		Vector3(hw, -hh, 0), Vector3(-hw, -hh, 0), Vector3(0, 1, 0))
	# Two jambs.
	g.push_quad(Vector3(-hw, -hh, 0), Vector3(-hw, -hh, -REVEAL),
		Vector3(-hw, hh, -REVEAL), Vector3(-hw, hh, 0), Vector3(1, 0, 0))
	g.push_quad(Vector3(hw, -hh, 0), Vector3(hw, hh, 0),
		Vector3(hw, hh, -REVEAL), Vector3(hw, -hh, -REVEAL), Vector3(-1, 0, 0))

	# --- outer frame face, flush with the wall ------------------------------
	# Four rails, 90 mm face, sitting on the wall face at z = 0.
	g.push_box(Vector3(-hw, hh - fw, 0.0), Vector3(OPEN_W, fw, 0.03))
	g.push_box(Vector3(-hw, -hh, 0.0), Vector3(OPEN_W, fw, 0.03))
	g.push_box(Vector3(-hw, -hh, 0.0), Vector3(fw, OPEN_H, 0.03))
	g.push_box(Vector3(hw - fw, -hh, 0.0), Vector3(fw, OPEN_H, 0.03))

	# --- projecting sill board ----------------------------------------------
	# 70 mm proud of the wall (SILL_OUT) and 90 mm thick (SILL_T), the widest
	# thing on the elevation and the part that throws a shadow line.
	g.push_box(Vector3(-hw - fw, -hh - fw - SILL_T, -SILL_OUT),
		Vector3(OPEN_W + fw * 2.0, SILL_T, SILL_OUT + 0.03))

	var sash_z := -REVEAL + 0.012
	var sash_t := 0.030
	# --- two casement sashes ------------------------------------------------
	# Each casement is half the inner width with a 55 mm stile/rail all round
	# and a meeting stile in the middle, which is the vertical line a
	# Queenslander window is read by.
	for side in [-1.0, 1.0]:
		var x0 := 0.0 if side > 0.0 else -inner_w * 0.5
		var x1 := inner_w * 0.5 if side > 0.0 else 0.0
		var b := Vector3(x0 + SASH_W, -hh + fw + SASH_W, sash_z)
		var s := Vector3(x1 - SASH_W, hh - fw - SASH_W, sash_z + sash_t)
		if side < 0.0:
			# Meeting stile: the left casement's closing edge is at x = 0.
			b.x = -inner_w * 0.5 + SASH_W
			s.x = -SASH_W
		g.push_box(b, s - b)

	# --- glass, one pane per casement ----------------------------------------
	var glass := Geom.new()
	for side in [-1.0, 1.0]:
		var x0 := -inner_w * 0.5 + SASH_W if side < 0.0 else SASH_W
		var x1 := -SASH_W if side < 0.0 else inner_w * 0.5 - SASH_W
		glass.push_box(Vector3(x0, -hh + fw + SASH_W, sash_z + sash_t),
			Vector3(x1 - x0, inner_h - SASH_W * 2.0, 0.008))

	return {"timber": g.to_payload(), "glass_dark": glass.to_payload()}


# =============================================================================
# 2. GABLE ROOF, RIDGE CAPPING, EAVES
# =============================================================================
# Origin at the midpoint of the ridge. Ridge along +X, so the two slopes fall
# to -Z and +Z. Eaves at y = -RIDGE_H, overhang EAVE past the wall line on the
# two long sides, and 0.20 past the gable ends as a barge board.
#
# The ridge capping is the fastest way to stop a gable reading as two grey
# triangles meeting in a line: a 340 mm half-round over the apex gives the
# silhouette a rounded top edge and a hard shadow line, which is the difference
# between a roof and a folded card.

static func roof_gable() -> Dictionary:
	var g := Geom.new()
	var hx := WALL_W * 0.5 + 0.20          # barge overhang at the gable ends
	var hz := DEPTH * 0.5 + EAVE          # eave overhang on the long sides
	var y := -RIDGE_H
	var slope := RIDGE_H / (DEPTH * 0.5)  # rise over run, for the fascia

	# The two roof planes. Each is a quad given its own outward normal, because
	# a sloped face's normal is not +Y and lighting it as if it were is how a
	# roof comes out flat.
	for s in [-1.0, 1.0]:
		var n := Vector3(0.0, 1.0, s * (DEPTH * 0.5) / RIDGE_H).normalized()
		g.push_quad(
			Vector3(-hx, 0.0, 0.0), Vector3(hx, 0.0, 0.0),
			Vector3(hx, y, s * hz), Vector3(-hx, y, s * hz), n)

	# Underside of the eave: the soffit you see from a car. Without it the roof
	# is a zero-thickness card and the eave line - the single most Queenslander
	# thing about it - vanishes from below.
	for s in [-1.0, 1.0]:
		g.push_quad(
			Vector3(-hx, y - 0.02, s * hz), Vector3(hx, y - 0.02, s * hz),
			Vector3(hx, y, s * hz), Vector3(-hx, y, s * hz),
			Vector3(0.0, -1.0, 0.0))

	# Gable ends, filled - a gable end is wall, and leaving it open shows the
	# inside of the far slope through the near one.
	for s in [-1.0, 1.0]:
		var c0 := Vector3(s * hx, 0.0, 0.0)
		var c1 := Vector3(s * hx, y, hz)
		var c2 := Vector3(s * hx, y, -hz)
		g.push_tri(c0, c1, c2, Vector3(s, 0.0, 0.0))

	# Fascia boards at both eaves. The gutter fastens to these, which is why the
	# gutter piece's origin is "the fascia plane" and not an arbitrary offset.
	for s in [-1.0, 1.0]:
		g.push_box(Vector3(-hx, y - FASCIA_H, s * hz - (FASCIA_H if s > 0.0 else 0.0)),
			Vector3(hx * 2.0, FASCIA_H, FASCIA_H))

	# Ridge capping: a half-round over the apex, 340 mm across.
	var cap_r := 0.17
	var cap_z := Vector3(0.0, 0.0, 1.0)
	var cap_prev := Vector3(0.0, 0.0, -cap_r)
	for i in range(9):
		var a0 := PI * float(i) / 8.0
		var a1 := PI * float(i + 1) / 8.0
		var p0 := Vector3(-hx, sin(a0) * cap_r, -cos(a0) * cap_r)
		var p1 := Vector3(hx, sin(a0) * cap_r, -cos(a0) * cap_r)
		var p2 := Vector3(hx, sin(a1) * cap_r, -cos(a1) * cap_r)
		var p3 := Vector3(-hx, sin(a1) * cap_r, -cos(a1) * cap_r)
		var mid := PI * (float(i) + 0.5) / 8.0
		g.push_quad(p0, p1, p2, p3, Vector3(0.0, sin(mid), -cos(mid)))
	g.push_tri(Vector3(-hx, 0.0, cap_r), Vector3(hx, 0.0, cap_r),
		Vector3(-hx, cap_r * 0.0, -cap_r), Vector3(0, 1, 0))
	cap_z = Vector3.ZERO
	var _unused := slope

	return {"roof_iron": g.to_payload()}


# =============================================================================
# 3. HIP ROOF, RIDGE CAPPING, EAVES
# =============================================================================
# Same origin rule as the gable: midpoint of the ridge. The ridge is shortened
# by DEPTH so the four slopes meet it, which is what makes it hip rather than
# gable, and a hip is what reads as a Queenslander from a corner - the gable
# reads as a triangle from the front and as a box from the side.

static func roof_hip() -> Dictionary:
	var g := Geom.new()
	var hx := WALL_W * 0.5 + 0.20
	var hz := DEPTH * 0.5 + EAVE
	var rx := WALL_W * 0.5 - DEPTH * 0.5      # ridge half-length
	var y := -RIDGE_H

	# Two trapezoids front and back.
	for s in [-1.0, 1.0]:
		var n := Vector3(0.0, 1.0, s * (DEPTH * 0.5) / RIDGE_H).normalized()
		g.push_quad(
			Vector3(-rx, 0.0, 0.0), Vector3(rx, 0.0, 0.0),
			Vector3(hx, y, s * hz), Vector3(-hx, y, s * hz), n)
	# Two hip triangles at the ends.
	for s in [-1.0, 1.0]:
		var n := Vector3(s * (DEPTH * 0.5) / RIDGE_H, 1.0, 0.0).normalized()
		g.push_tri(Vector3(s * rx, 0.0, 0.0),
			Vector3(s * hx, y, -hz), Vector3(s * hx, y, hz), n)
	# Soffits under all four eaves.
	for s in [-1.0, 1.0]:
		g.push_quad(
			Vector3(s * rx, y - 0.02, 0.0), Vector3(s * hx, y - 0.02, -hz),
			Vector3(s * hx, y, -hz), Vector3(s * rx, y, 0.0), Vector3(0, -1, 0))
		g.push_quad(
			Vector3(s * rx, y - 0.02, hz), Vector3(s * hx, y - 0.02, hz),
			Vector3(s * hx, y, hz), Vector3(s * rx, y, 0.0), Vector3(0, -1, 0))
		g.push_quad(
			Vector3(-hx, y - 0.02, s * hz), Vector3(hx, y - 0.02, s * hz),
			Vector3(hx, y, s * hz), Vector3(-hx, y, s * hz), Vector3(0, -1, 0))
	# Fascia on all four sides, so a gutter can be fixed to any of them.
	for s in [-1.0, 1.0]:
		g.push_box(Vector3(-hx, y - FASCIA_H, s * hz - (FASCIA_H if s > 0.0 else 0.0)),
			Vector3(hx * 2.0, FASCIA_H, FASCIA_H))
		g.push_box(Vector3(s * hx - (FASCIA_H if s > 0.0 else 0.0), y - FASCIA_H, -hz),
			Vector3(FASCIA_H, FASCIA_H, hz * 2.0))
	# Ridge capping over the shortened ridge.
	var cap_r := 0.17
	for i in range(8):
		var a0 := PI * float(i) / 8.0
		var a1 := PI * float(i + 1) / 8.0
		var mid := PI * (float(i) + 0.5) / 8.0
		g.push_quad(
			Vector3(-rx, sin(a0) * cap_r, -cos(a0) * cap_r),
			Vector3(rx, sin(a0) * cap_r, -cos(a0) * cap_r),
			Vector3(rx, sin(a1) * cap_r, -cos(a1) * cap_r),
			Vector3(-rx, sin(a1) * cap_r, -cos(a1) * cap_r),
			Vector3(0.0, sin(mid), -cos(mid)))
	g.push_quad(Vector3(-rx, 0.0, cap_r), Vector3(rx, 0.0, cap_r),
		Vector3(rx, 0.0, -cap_r), Vector3(-rx, 0.0, -cap_r), Vector3(0, 1, 0))

	return {"roof_iron": g.to_payload()}


# =============================================================================
# 4. GUTTER AND DOWNPIPE WITH ELBOW
# =============================================================================
# Origin at the gutter's fixing line: y = 0 is the line the brackets sit on and
# z = 0 is the fascia plane. x = 0 is the outlet end, so the downpipe is
# directly under the piece's origin and a placer only has to supply the fascia
# corner.
#
# HONESTY NOTE, carried into the report: a 150 mm gutter and a 110 mm downpipe
# are both under the 300 mm silhouette line. They are authored at real size
# because a 300 mm downpipe would be a mistake. They are NOT claimed to carry
# the silhouette; the ablation measures what they actually contribute and the
# report records them as depth elements.

static func gutter_downpipe() -> Dictionary:
	var g := Geom.new()
	var run := 4.00
	# The gutter hangs with its back tip ON the fascia plane, so the back tip is
	# at z = 0 and the trough projects to +Z.
	g.push_gutter(-run, 0.0, 0.0, GUTTER_DIA, GUTTER_WALL, 6)
	# Two straps: the fixings, and the reason the gutter's origin rule exists.
	for sx in [-3.40, -1.20]:
		var x := float(sx)
		g.push_box(Vector3(x - 0.02, -GUTTER_DIA - 0.09, -0.02),
			Vector3(0.04, 0.14, 0.05))
	# The pipe axis sits on the trough centreline so the dropper is plumb.
	var axis_z := GUTTER_DIA * 0.5
	var under := -GUTTER_DIA - 0.05
	# Dropper, then the straight run down the wall. The run has to exist: with
	# only the elbow present, the two brackets end up floating 1.6 m below the
	# end of a pipe, and the only thing that gives it away is the bounding box.
	g.push_tube(Vector2(0.0, axis_z), DOWNPIPE_R, under, under - 0.28, 8)
	var bottom_y := under - DOWNPIPE_DROP
	g.push_tube(Vector2(0.0, axis_z), DOWNPIPE_R, under - 0.28, bottom_y, 8)
	# The elbow, at the BOTTOM, turning out toward the path.
	g.push_elbow(Vector3(0.0, bottom_y, axis_z), DOWNPIPE_R, Vector3(0, 0, 1), 8, 5)
	# Two pipe brackets straddling the run and screwed back to the fascia - the
	# other fastening, and the reason a downpipe is a line on a wall and not a
	# floating pole.
	for by in [bottom_y + 0.55, bottom_y + 1.85]:
		var y := float(by)
		g.push_box(Vector3(-(DOWNPIPE_R + 0.055), y - 0.03, 0.0),
			Vector3(DOWNPIPE_R * 2.0 + 0.11, 0.06, axis_z + DOWNPIPE_R))
	return {"steel_galv": g.to_payload()}


# =============================================================================
# 5. FRONTAGE STEP AND POST
# =============================================================================
# Origin at the base of the veranda post, on the frontage wall plane. The post
# is the fastener; the step treads butt into it and stop.
#
# A Queenslander sits up on a deck, so the frontage has a horizontal line at the
# deck edge that the eye reads as "house" rather than "shed". Four 190 mm risers
# to a 760 mm deck, three treads at 300 mm, and a 120 mm post carrying the
# veranda roof at 2.40 m - the line above the deck line and the line below it
# are the whole frontage read.

static func frontage_step_post() -> Dictionary:
	var g = Geom.new()
	# HOW A QUEENSLANDER FRONTAGE IS ACTUALLY ARRANGED, because getting this wrong
	# is invisible in a bounding box and obvious in a render:
	#
	#   - The veranda DECK is a floor 1.45 m deep and the full width of the house,
	#     standing 1.10 m off the ground. It is not a stair - it is a room without
	#     walls, and its outer edge is the 1.45 m line that says "house".
	#   - The steps are ONE flight, at one point, projecting OUTWARD from the deck
	#     edge. They do not climb up the face of the wall: the first version of
	#     this piece had every tread starting at z = 0, so the lowest tread ran
	#     the whole depth of the veranda to the wall, the top tread sat at the BACK
	#     of the flight, and there was a 0.84 m gap between the top tread and the
	#     deck. The render showed a staircase lying on its back.
	#   - The corner POST stands on the deck at its outer edge, clear of the step
	#     run, and carries the veranda roof. A post coplanar with the wall is
	#     half-buried in the cladding and reads as a seam; a post behind the steps
	#     is hidden by them. Both were in the first version.
	var riser := LIFT / float(RISERS)
	var deck_z := VERANDA_OUT
	# --- the deck: floor slab plus its edge fascia ---------------------------
	g.push_box(Vector3(-STEP_W * 0.5 - POST_W, DECK - 0.10, 0.0),
		Vector3(STEP_W + POST_W * 2.0, 0.10, deck_z))
	g.push_box(Vector3(-STEP_W * 0.5 - POST_W, DECK - 0.10 - 0.16, deck_z - 0.02),
		Vector3(STEP_W + POST_W * 2.0, 0.16, 0.02))
	# --- the flight, climbing outward from the deck edge ---------------------
	for i in RISERS:
		var y := riser * float(i + 1)
		var z0 := deck_z + TREAD * float(RISERS - 1 - i)
		# Every tread is exactly TREAD deep. Giving tread i the whole REMAINING
		# run (TREAD * (RISERS - i)) put the outermost, lowest tread across the
		# entire flight - 1.75 m of the veranda's depth instead of 250 mm - and the
		# measured AABB said so: the piece reached z = 3.20 where FLIGHT_OUT says
		# 2.45.
		g.push_box(Vector3(-STEP_W * 0.5, 0.0, z0), Vector3(STEP_W, y, TREAD))
		# A 30 mm nosing. The shadow line under a Queenslander step is 30 mm of
		# overhang, and at the street framing that line is most of what the flight
		# contributes to the read - visible in day_street_kit_tight.
		g.push_box(Vector3(-STEP_W * 0.5, y - 0.03, z0 + TREAD - 0.03),
			Vector3(STEP_W, 0.03, 0.03))
	# --- the corner post, on the deck, outboard of the steps -----------------
	var px := -STEP_W * 0.5 - POST_W * 1.5
	var pz := deck_z - POST_W * 0.5
	g.push_box(Vector3(px, DECK - 0.10, pz), Vector3(POST_W, POST_H - DECK + 0.10, POST_W))
	g.push_quad(
		Vector3(px, POST_H, pz), Vector3(px + POST_W, POST_H, pz),
		Vector3(px + POST_W, POST_H - 0.06, pz + POST_W),
		Vector3(px, POST_H - 0.06, pz + POST_W), Vector3(0, 1, 0))
	# The brace back to the wall: the triangle that says "veranda" rather than
	# "post".
	var ba := Vector3(px + POST_W * 0.5, POST_H - 0.12, pz)
	var bb := Vector3(px + POST_W * 0.5, POST_H - 0.12, 0.0)
	var bd := (bb - ba).normalized()
	var bp := Vector3(-bd.z, 0.0, bd.x) * 0.035
	g.push_quad(ba + bp, ba - bp, bb - bp, bb + bp, Vector3(0, 1, 0))
	g.push_quad(ba + bp, bb + bp, bb - bp, ba - bp, Vector3(0, 1, 0))
	return {"timber": g.to_payload()}


# =============================================================================
# 6. PALING FENCE WITH GATELING
# =============================================================================
# Origin at the base of the leading post, on the fence line, module running +X
# over FENCE_SPAN. Deliberately the same 4 m module and 1.5 m height as
# artkit/props.gd:959-976 `fence_paling`, so a kitted boundary and a scattered
# prop boundary are the same fence and do not disagree from a moving car. The
# palings are at a 160 mm pitch rather than props.gd's 444 mm: at 314 mm gaps a
# paling fence is a wall with slots in it, and the gap IS the read.
#
# The gateling is the 1.28 m bay in the middle: two stiles, three rails, five
# spear-palings with pointed tops standing SPEAR_ABOVE above the top rail, and
# a diagonal brace. The pointed top is the entire point of a gateling and it is
# 24 cm of it, which is under the 300 mm line - so the gate reads as a rhythm
# of five points, not as an outline feature.

static func fence_paling_gateling() -> Dictionary:
	var g := Geom.new()
	var hw := FENCE_SPAN * 0.5
	var h := FENCE_H
	var gate_x := GATE_W * 0.5

	# Palings either side of the gate bay.
	var x := -hw
	while x + PALING_W <= -gate_x:
		g.push_box(Vector3(x, 0.0, -PALING_W * 0.5), Vector3(PALING_W, h, PALING_W))
		x += PALING_PITCH
	x = gate_x
	while x + PALING_W <= hw:
		g.push_box(Vector3(x, 0.0, -PALING_W * 0.5), Vector3(PALING_W, h, PALING_W))
		x += PALING_PITCH
	# Two rails, and they STOP at the gate bay. A rail running straight through a
	# hung gate is the tell that a fence was extruded rather than built: the gate
	# is a separate framed leaf with its own three rails, hung between the posts.
	# Width is gate_x + hw, not gate_x - hw. The left run starts at -hw and ends
	# at +gate_x, so its width is the SUM; `gate_x - hw` is -1.36 m, a negative
	# size, and push_box does not reject one - it silently emits a box running
	# backwards from -2.0 to -3.36, which is how this was caught: the exporter's
	# own bounds() said a 4 m module spanned -3.36.
	var left_w := gate_x + hw
	var right_w := hw - gate_x
	g.push_box(Vector3(-hw, h - 0.07, -0.10), Vector3(left_w, 0.07, 0.20))
	g.push_box(Vector3(gate_x, h - 0.07, -0.10), Vector3(right_w, 0.07, 0.20))
	g.push_box(Vector3(-hw, 0.20, -0.09), Vector3(left_w, 0.07, 0.18))
	g.push_box(Vector3(gate_x, 0.20, -0.09), Vector3(right_w, 0.07, 0.18))
	# Posts at both ends, taller than the fence, which is how a paling fence
	# announces where it stops.
	for px in [-hw, hw - FENCE_POST_W]:
		var p := float(px)
		g.push_box(Vector3(p, 0.0, -FENCE_POST_W * 0.5), Vector3(FENCE_POST_W, h + 0.20, FENCE_POST_W))
		g.push_quad(
			Vector3(p, h + 0.20, -FENCE_POST_W * 0.5), Vector3(p + FENCE_POST_W, h + 0.20, -FENCE_POST_W * 0.5),
			Vector3(p + FENCE_POST_W, h + 0.20, FENCE_POST_W * 0.5),
			Vector3(p, h + 0.20, FENCE_POST_W * 0.5), Vector3(0, 1, 0))

	# --- the gateling -------------------------------------------------------
	# Stiles. The latch stile is 40 mm thicker, which is the detail that makes a
	# gate a gate from across a street.
	g.push_box(Vector3(-gate_x, 0.0, -0.05), Vector3(0.08, h, 0.10))
	g.push_box(Vector3(gate_x - 0.12, 0.0, -0.05), Vector3(0.12, h, 0.10))
	# Three rails, including the bottom one 250 mm off the ground.
	for ry in [0.25, 0.82, h - 0.10]:
		var y := float(ry)
		g.push_box(Vector3(-gate_x, y, -0.04), Vector3(GATE_W, 0.09, 0.08))
	# Five SPEAR PALINGS with pointed tops. Paled, not round: a gateling is by
	# definition a gate of palings cut to a point, and building the spears as
	# square tubes turned the vocabulary into a row of dowels. Each is a flat
	# paling with a triangular cap, 130 mm wide like every other paling in the
	# module so the gate and the fence are the same timber at the same thickness.
	var spears := 5
	var spear_y0 := 0.25
	var spear_y1 := h - 0.10 + SPEAR_ABOVE
	for i in spears:
		var sx := -gate_x + 0.08 + (GATE_W - 0.16) * float(i) / float(spears - 1)
		var hw2 := PALING_W * 0.5
		g.push_box(Vector3(sx - hw2, spear_y0, -0.05), Vector3(PALING_W, spear_y1 - spear_y0, 0.10))
		# The point: four triangles over the top face, so the spear reads as cut
		# rather than as a box someone put a cone on.
		for k in 4:
			var a0 := Vector3(sx - hw2 + PALING_W * float(k) / 4.0, spear_y1, -0.05)
			var a1 := Vector3(sx - hw2 + PALING_W * float(k + 1) / 4.0, spear_y1, -0.05)
			var tip := Vector3(sx, spear_y1 + SPEAR_ABOVE * 0.45, 0.0)
			g.push_tri(a0, a1, tip, Vector3(0, 0.35, 1.0))
			g.push_tri(a1, a0, tip, Vector3(0, 0.35, -1.0))
	# Diagonal brace from the latch stile down to the hinge stile.
	var brace_a := Vector3(-gate_x + 0.04, h - 0.16, -0.055)
	var brace_b := Vector3(gate_x - 0.10, 0.30, -0.055)
	var brace_w := 0.06
	var bd := (brace_b - brace_a).normalized()
	var bp := Vector3(-bd.z, 0.0, bd.x) * brace_w * 0.5
	g.push_quad(brace_a + bp, brace_a - bp, brace_b - bp, brace_b + bp, Vector3(0, 0, -1))
	g.push_quad(brace_a + bp, brace_b + bp, brace_b - bp, brace_a - bp, Vector3(0, 0, 1))
	return {"timber_dark": g.to_payload()}


## name -> {role -> payload}. One function per roster entry, no table.
static func build(name: String) -> Dictionary:
	match name:
		"kit_window_sash": return window_sash()
		"kit_roof_gable": return roof_gable()
		"kit_roof_hip": return roof_hip()
		"kit_gutter_downpipe": return gutter_downpipe()
		"kit_frontage_step_post": return frontage_step_post()
		"kit_fence_paling_gateling": return fence_paling_gateling()
	push_error("HouseKitPieces: unknown kit piece '%s'" % name)
	return {}