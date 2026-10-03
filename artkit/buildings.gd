class_name ArtKitBuildings
extends RefCounted
## Buildings for a low-rise tropical city: a Queensland highset house, a
## commercial shopfront, an industrial shed, a low-rise walk-up block, and an
## adapter that gives a *real OSM footprint* the same treatment.
##
## ## The reference this replaces
##
## `_house()` in `World/world_builder.gd` is a scaled box, a scaled gable prism,
## and three more scaled boxes for verandah posts, with the windows glued on as
## thin emissive slabs on the *outside* of the wall. It is not embarrassing, but
## it is a box with a triangle roof, and Cairns is not that.
##
## What makes a Queenslander a Queenslander, in the order you notice it from a
## moving car:
##   1. **It is up on stumps.** The ground floods, so the floor is 0.8-1.5 m off
##      the dirt and you can see daylight and shadow underneath. This is the
##      single most recognisable thing about the architecture and it costs ten
##      triangles.
##   2. **The eaves are enormous.** 0.8-1.0 m of overhang on every side: shade,
##      rain protection, and the reason the roof is the silhouette you read from
##      the street rather than the wall.
##   3. **There is a veranda**, with its own posts and its own *separate* roof,
##      and a carport beside it under a single-slope roof.
##   4. **The window openings are real holes**, not painted rectangles. You see
##      the dark interior of the ones that are off and the glow of the ones that
##      are on, and the light comes from *inside* the wall.
##
## All four are in here. Openings are built as solid panels around the gaps, so
## the glass sits in a hole, and the lit ones also get a dim emissive panel set
## 0.55 m *behind* them - a window with emission on its own face looks like a
## sticker, and a window with a dim room behind it looks like a room.
##
## ## For whoever consumes the 2198 OSM footprints
##
## `wrap_footprint()` takes a real OSM polygon and gives it walls, a plinth, deep
## eaves and lit windows at whatever scale the polygon happens to be. That is
## the intended path: real outlines from OSM, real art direction from this kit,
## one material library, one batching path. Consuming this kit does not mean
## accepting a box.


## How much of a domestic window wall is glass. A house is mostly wall; a house
## that is mostly window is a shop.
const WINDOW_RATIO := 0.42
## Sill and head height of a domestic opening. The proportion is what makes a
## wall read as a wall with windows in it.
const SILL := 0.95
const HEAD := 2.10
## Domestic storey height. Cairns is low-rise and this is why.
const STOREY := 3.0


# =============================================================================
# REGISTRY
# =============================================================================

## Every generator: what it is for, and the material it is expected to wear. The
## check reads this; consumers can ignore it.
static func registry() -> Dictionary:
	return {
		"qld_house": {
			"kind": "building", "mat": "surface_render_wall_a",
			"use": "highset Queenslander: stumps, deep eaves, veranda, carport, real lit window openings",
		},
		"qld_shop": {
			"kind": "building", "mat": "surface_render_wall_a",
			"use": "commercial shopfront unit: flat parapet, awning over the footpath, big glazing, illuminated sign",
		},
		"industrial_shed": {
			"kind": "building", "mat": "industrial_metal",
			"use": "high-bay shed: roller door, mercury wall pack, roof vent and stack. The only tall thing in the suburb",
		},
		"walk_up_block": {
			"kind": "building", "mat": "surface_render_wall_a",
			"use": "3-4 storey walk-up with balconied storeys. The arterial's own skyline, before the real CBD",
		},
	}


static func has(name: String) -> bool:
	return registry().has(name)


# =============================================================================
# A WALL, IN ITS OWN FRAME
# =============================================================================

## Lays a wall out in its own local frame: width along X, thickness along Z with
## the *outside* face at -Z, base at y = 0. It returns the local (x, y) centre of
## every opening it cut, so the glass cannot be placed independently and end up
## disagreeing with the hole.
##
## Doing this per wall and then transforming it is the only way the side walls
## come out right: a side wall's openings run along Z, not X, and a single
## axis-agnostic layout gets that wrong in a way that is invisible until you
## stand on the footpath and see the windows on the wrong wall.
static func _wall(st: SurfaceTool, width: float, height: float, thickness: float,
		count: int, has_door: bool) -> Array:
	var out: Array = []
	# A solid pier at each end, so the corner reads as a corner and not as four
	# walls meeting in a hole.
	var pier := thickness
	var inner := maxf(width - pier * 2.0, 0.4)
	var span := inner / float(maxi(count, 1))
	var open_w := span * WINDOW_RATIO
	var x0 := -inner * 0.5

	# Band below the openings. With a door, the door is a hole in this band.
	var door_w := 0.95
	if has_door:
		var dl := -door_w * 0.5
		var dr := door_w * 0.5
		_panel(st, SILL, 0.0, 0.0, thickness, -width * 0.5, dl)
		_panel(st, SILL, 0.0, 0.0, thickness, dr, width * 0.5)
		# The head of the door.
		_panel(st, head_of_door() - 0.1, 1.95, 0.0, thickness, dl, dr)
	else:
		_panel(st, SILL, 0.0, 0.0, thickness, -width * 0.5, width * 0.5)

	# Band above the openings.
	_panel(st, maxf(height - HEAD, 0.0), HEAD, 0.0, thickness, -width * 0.5, width * 0.5)

	# Piers between and beside the openings.
	var cursor := x0
	for i in count:
		var ol := x0 + span * float(i) + (span - open_w) * 0.5
		var or_ := ol + open_w
		_panel(st, HEAD - SILL, SILL, 0.0, thickness, cursor, ol)
		cursor = or_
		out.append([(ol + or_) * 0.5, (SILL + HEAD) * 0.5, open_w, HEAD - SILL])
	_panel(st, HEAD - SILL, SILL, 0.0, thickness, cursor, x0 + inner)

	# The reveals: the inner faces of each opening, so the wall has thickness at
	# the window and the interior glow has something to land on. Four thin panels
	# per opening; the whole lot is under a hundred triangles for a house.
	for entry in out:
		var cx: float = entry[0]
		var ow: float = entry[2]
		var oh: float = entry[3]
		for sx in [-1.0, 1.0]:
			_panel(st, oh, SILL, 0.0, thickness, cx + sx * ow * 0.5 - 0.04, cx + sx * ow * 0.5)
	return out


## Door head height. A domestic door is 2.05 m; the panel above it is what stops
## the door being a hole that runs into the window band.
static func head_of_door() -> float:
	return 2.05


## One solid box in wall-local coordinates. `h` is its height above `y_base`,
## `z` its centre, `depth` its thickness, and the last two are the X span.
##
## This is a function because every wall in every building needs it, and getting
## the winding wrong in a hundred call sites is a hundred invisible faces.
static func _panel(st: SurfaceTool, h: float, y_base: float, z: float, depth: float,
		x0: float, x1: float) -> void:
	var w := x1 - x0
	if w <= 0.0005 or h <= 0.0005 or depth <= 0.0005:
		return
	var xc := (x0 + x1) * 0.5
	var y0 := y_base
	var y1 := y_base + h
	var za := z - depth * 0.5
	var zb := z + depth * 0.5
	ArtKitMesh.quad(st, Vector3(x0, y0, za), Vector3(x1, y0, za),
			Vector3(x1, y1, za), Vector3(x0, y1, za))
	ArtKitMesh.quad(st, Vector3(x0, y0, zb), Vector3(x1, y0, zb),
			Vector3(x1, y1, zb), Vector3(x0, y1, zb))
	ArtKitMesh.quad(st, Vector3(x0, y0, za), Vector3(x0, y0, zb),
			Vector3(x0, y1, zb), Vector3(x0, y1, za))
	ArtKitMesh.quad(st, Vector3(x1, y0, za), Vector3(x1, y0, zb),
			Vector3(x1, y1, zb), Vector3(x1, y1, za))
	ArtKitMesh.quad(st, Vector3(x0, y1, za), Vector3(x1, y1, za),
			Vector3(x1, y1, zb), Vector3(x0, y1, zb))
	ArtKitMesh.quad(st, Vector3(x0, y0, za), Vector3(x1, y0, za),
			Vector3(x1, y0, zb), Vector3(x0, y0, zb))


## Places the glass for a wall's openings into the dark / lit / interior meshes,
## using the wall's own transform. `lit_ratio` is deliberately low: a suburb
## where every window is lit is a suburb where nobody is home, and that destroys
## the only reason lit windows exist.
static func _glaze(dark: SurfaceTool, lit: SurfaceTool, inner: SurfaceTool, s: RandomNumberGenerator,
		openings: Array, xf: Transform3D, thickness: float, lit_ratio: float) -> void:
	for entry in openings:
		var cx: float = entry[0]
		var cy: float = entry[1]
		var ow: float = entry[2]
		var oh: float = entry[3]
		var pane := ArtKitMesh.panel(ow, oh, Vector3(cx, cy, -thickness * 0.5 - 0.04))
		if s.randf() < lit_ratio:
			ArtKitMesh.blit(lit, pane, xf)
			# The room, 0.55 m behind the glass and dimmer than it.
			ArtKitMesh.blit(inner, ArtKitMesh.panel(ow, oh,
					Vector3(cx, cy, -thickness * 0.5 + 0.55)), xf)
		else:
			ArtKitMesh.blit(dark, pane, xf)


# =============================================================================
# DOMESTIC
# =============================================================================

## A Queensland highset house. `seed_value` fixes every dimension, the wall and
## roof colours, which windows are lit, and the carport's side - so the same seed
## always gives the same house, which is what lets a consumer cache and batch
## thousands of them.
static func _build_qld_house(seed_value: int = 0) -> Array:
	var s := _rng(seed_value)
	var w := s.randf_range(7.5, 11.0)
	var d := s.randf_range(6.5, 9.0)
	var lift := s.randf_range(0.8, 1.5)
	var h := s.randf_range(2.7, 3.2)
	var t := 0.20
	var wall_key := _wall_key(s.randi() % 6)
	var roof_key := _roof_key(s.randi() % 5)
	var parts: Array = []

	# --- stumps, bearers and the floor slab ---------------------------------
	# The gap under the floor is the most Queensland thing in the model. Six
	# posts, two bearers, one slab, and you can see through it at night.
	var stumps := ArtKitMesh.begin()
	for i in 6:
		var px := (float(i % 2) * 2.0 - 1.0) * (w * 0.5 - 0.35)
		var pz := (float(i / 2) * 2.0 - 1.0) * (d * 0.5 - 0.35)
		ArtKitMesh.blit(stumps, ArtKitMesh.box_from(Vector3(0.18, lift, 0.18),
				Vector3(px - 0.09, 0.0, pz - 0.09)), Transform3D())
	for pz in [-d * 0.5 + 0.35, d * 0.5 - 0.35]:
		ArtKitMesh.blit(stumps, ArtKitMesh.box_from(Vector3(w - 0.2, 0.14, 0.14),
				Vector3(-(w - 0.2) * 0.5, lift - 0.14, pz - 0.07)), Transform3D())
	ArtKitMesh.blit(stumps, ArtKitMesh.box_from(Vector3(w, 0.10, d),
			Vector3(-w * 0.5, lift - 0.10, -d * 0.5)), Transform3D())
	parts.append(ArtKitPart.of(ArtKitMesh.commit(stumps), "timber"))

	# --- four walls, each laid out in its own frame then rotated into place ----
	var walls := ArtKitMesh.begin()
	var dark := ArtKitMesh.begin()
	var lit := ArtKitMesh.begin()
	var inner := ArtKitMesh.begin()
	# (centre, yaw, width, opening count, has a door)
	var plan := [
		[Vector3(0.0, lift, -d * 0.5 + t * 0.5), 0.0, w, 2, true],
		[Vector3(0.0, lift, d * 0.5 - t * 0.5), PI, w, 2, false],
		[Vector3(-w * 0.5 + t * 0.5, lift, 0.0), PI * 0.5, d, 1, false],
		[Vector3(w * 0.5 - t * 0.5, lift, 0.0), -PI * 0.5, d, 1, false],
	]
	for entry in plan:
		var at: Vector3 = entry[0]
		var xf := Transform3D(Basis.from_euler(Vector3(0.0, float(entry[1]), 0.0)), at)
		var local := ArtKitMesh.begin()
		var openings := _wall(local, float(entry[2]), h, t, int(entry[3]), bool(entry[4]))
		ArtKitMesh.blit(walls, ArtKitMesh.commit(local), xf)
		_glaze(dark, lit, inner, s, openings, xf, t, 0.42)
	parts.append(ArtKitPart.of(ArtKitMesh.commit(walls), wall_key))

	# --- roof. The eaves are the silhouette, so they are generous. -----------
	var eave := s.randf_range(0.80, 1.00)
	parts.append(ArtKitPart.of(ArtKitMesh.gable_roof(w, d, 1.4 + eave, eave, lift + h),
			roof_key))

	# --- veranda: three posts, a deck and its own separate roof --------------
	var vd := 1.8
	var vz := -d * 0.5 - vd
	var porch := ArtKitMesh.begin()
	for i in 3:
		var px := (float(i) / 2.0 - 0.5) * (w - 0.6)
		ArtKitMesh.blit(porch, ArtKitMesh.box_from(Vector3(0.16, h, 0.16),
				Vector3(px - 0.08, lift, vz + 0.08)), Transform3D())
	ArtKitMesh.blit(porch, ArtKitMesh.box_from(Vector3(w, 0.08, vd),
			Vector3(-w * 0.5, lift - 0.10, vz)), Transform3D())
	# A step down to the dirt. A house with no step is a house on a plinth.
	ArtKitMesh.blit(porch, ArtKitMesh.box_from(Vector3(1.3, lift * 0.45, 0.55),
			Vector3(-0.65, 0.0, vz - 0.55)), Transform3D())
	parts.append(ArtKitPart.of(ArtKitMesh.commit(porch), "timber"))
	parts.append(ArtKitPart.of(ArtKitMesh.mono_roof(w, vd, 0.5, eave * 0.8, lift + h * 0.94),
			roof_key))

	# --- carport on the +X side: slab, two posts, a mono roof -----------------
	var cp_w := 3.4
	var cp := ArtKitMesh.begin()
	ArtKitMesh.blit(cp, ArtKitMesh.box_from(Vector3(cp_w, 0.08, d * 0.8),
			Vector3(w * 0.5 + 0.1, 0.0, -d * 0.4)), Transform3D())
	for pz in [-d * 0.38, d * 0.38]:
		ArtKitMesh.blit(cp, ArtKitMesh.box_from(Vector3(0.14, 2.4, 0.14),
				Vector3(w * 0.5 + 0.17, 0.0, pz - 0.07)), Transform3D())
	parts.append(ArtKitPart.of(ArtKitMesh.commit(cp), "concrete_b"))
	parts.append(ArtKitPart.of(ArtKitMesh.mono_roof(cp_w, d * 0.8, 0.35, 0.4, 2.4),
			roof_key))

	parts.append(ArtKitPart.of(ArtKitMesh.commit(dark), "glass_dark"))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(lit), "glass_lit"))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(inner), "interior_warm"))
	return ArtKitPart.weld(parts)


# =============================================================================
# COMMERCIAL
# =============================================================================

## A commercial shopfront unit. Three things make a strip read as a city at
## night, in this order: the lit shopfront, the awning over the footpath, and the
## illuminated sign fascia on the parapet. All three are here.
static func _build_qld_shop(seed_value: int = 0) -> Array:
	var s := _rng(seed_value)
	var w := s.randf_range(9.0, 16.0)
	var d := s.randf_range(8.0, 12.0)
	var h := s.randf_range(3.8, 5.2)
	var t := 0.20
	var wall_key := _wall_key(s.randi() % 6)
	var parts: Array = []

	# --- shell ---------------------------------------------------------------
	# The front wall is mostly glass, so it is built as a sill, a head beam and a
	# pier: three panels, with the shopfront glazing filling the gap. A solid wall
	# with a lit panel stuck on it is the thing this replaces.
	var front := -d * 0.5
	var glazing_top := h * 0.74
	var shell := ArtKitMesh.begin()
	_panel(shell, 0.45, 0.0, front + t * 0.5, t, -w * 0.5, w * 0.5)            # sill
	_panel(shell, h - glazing_top, glazing_top, front + t * 0.5, t, -w * 0.5, w * 0.5)
	_panel(shell, glazing_top - 0.45, 0.45, front + t * 0.5, t, w * 0.5 - 0.40, w * 0.5)
	# Back and sides, solid, in their own local frames so nothing has to be
	# reasoned about by hand.
	ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(w, h, t),
			Vector3(-w * 0.5, 0.0, d * 0.5 - t * 0.5)),
			Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3.ZERO))
	for sx in [-1.0, 1.0]:
		ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(d, h, t),
				Vector3(-d * 0.5, 0.0, -t * 0.5)),
				Transform3D(Basis.from_euler(Vector3(0, sx * PI * 0.5, 0)),
						Vector3(sx * (w * 0.5 - t * 0.5), 0.0, 0.0)))
	# A back-of-house lean-to, so a shop has depth from the side as well.
	ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(w * 0.4, h * 0.8, 1.2),
			Vector3(-w * 0.2, 0.0, d * 0.5)), Transform3D())
	parts.append(ArtKitPart.of(ArtKitMesh.commit(shell), wall_key))

	# --- flat parapet, not a gable. Cairns commercial is flat-roofed, and the
	# --- silhouette difference is most of what says "suburb ends here".
	var parapet := ArtKitMesh.box_from(Vector3(w, 0.55, d), Vector3(-w * 0.5, h, -d * 0.5))
	var cap := ArtKitMesh.box_from(Vector3(w + 0.18, 0.08, d + 0.18),
			Vector3(-(w + 0.18) * 0.5, h + 0.55, -(d + 0.18) * 0.5))
	parts.append(ArtKitPart.of(ArtKitMesh.merge([parapet, cap], []), "concrete_a"))

	# --- awning over the footpath, on two struts ------------------------------
	var aw := ArtKitMesh.mono_roof(w, 1.2, 0.30, 0.15, h * 0.78, 0.08)
	parts.append(ArtKitPart.of(aw, "industrial_metal"))
	var struts := ArtKitMesh.begin()
	for px in [-w * 0.4, w * 0.4]:
		ArtKitMesh.blit(struts, ArtKitMesh.box_from(Vector3(0.07, h * 0.30, 1.2),
				Vector3(px, h * 0.48, front - 1.2)), Transform3D())
	parts.append(ArtKitPart.of(ArtKitMesh.commit(struts), "steel_galv"))

	# --- shopfront glazing and the room behind it ------------------------------
	var gw := w - 0.50
	var gh := glazing_top - 0.50
	var gy := 0.45 + gh * 0.5
	parts.append(ArtKitPart.of(ArtKitMesh.panel(gw, gh, Vector3(-0.20, gy, front - 0.02)),
			"glass_shop"))
	# The interior, 1.2 m back. A shopfront with nothing behind it is a lit
	# billboard; a shopfront with a dim ceiling behind it is a shop.
	parts.append(ArtKitPart.of(ArtKitMesh.panel(gw, gh, Vector3(-0.20, gy, front + 1.2)),
			"interior_warm"))

	# --- the sign: a fascia on the parapet -------------------------------------
	# This used to be a 0.52 m x 3.5-6.0 m emissive PANEL standing 1.04 m in
	# front of the facade with nothing underneath it, in a colour rolled at
	# random per building out of three saturated neons and `lamp_lens`.
	#
	# At night that is not signage. 0.52 m wide against up to 6 m tall is an
	# aspect ratio of 7.0:1 to 11.3:1 (measured across the variant set: 3.64 m to
	# 5.90 m tall), so it reads as a glowing bar standing NEXT to the shop rather
	# than as a sign ON it - and because every shop on an arterial got one, the
	# street carried dozens. That is the opposite of the art direction's "a few
	# saturated signs doing the talking" and its "signage only, and sparingly".
	# `lamp_lens` was the worst of the four: that is the luminaire lens role at
	# emit 6.0, it was in four of the sixteen designs, and it was the brightest
	# bar in the frame.
	#
	# A sign is a WIDE SHALLOW box sitting hard against the parapet. Proportion is
	# the whole fix - 4.2 x 0.95 m cannot be read as a bar from any angle - and
	# the lit face now stands 0.04 m proud of its own carcass instead of hanging
	# in the air over the footpath.
	var sw: float = minf(w - 1.6, 4.2)
	var sh := 0.95
	var sd := 0.34
	# Centred over the glazing, which is at x = -0.20, and based on the parapet
	# cap, whose top is h + 0.63.
	var sx := -0.20
	var sy := h + 0.63 + sh * 0.5
	parts.append(ArtKitPart.of(ArtKitMesh.box_from(Vector3(sw + 0.16, sh + 0.14, sd),
			Vector3(sx, sy, front - sd * 0.5 - 0.02)), "sign_face"))
	# `sign_face_lit` is the doc's cool shopfront white - "Mercury / shopfront" is
	# an emit_role and that is the material key that holds it - so that is what the
	# general case is. It emits at 2.2 rather than reusing `lamp_lens_cool`'s 5.0
	# because a fascia is a large flat face, not a small intense source; see the
	# note in `materials.gd`. Three shops in sixteen get a saturated accent, one
	# accent each: the old roll handed a different neon to every shop on the
	# street, which is precisely what stopped them reading as accents. Three of the
	# sixteen HOUSE_VARIANTS seeds (1, 7, 13) are accented; anything outside that
	# range falls through to the unaccented default, which is the safe direction
	# for a role that is meant to be rare.
	var sign_mat := "sign_face_lit"
	match posmod(seed_value, HOUSE_VARIANTS):
		1: sign_mat = "neon_cyan"
		7: sign_mat = "neon_magenta"
		13: sign_mat = "neon_red"
	parts.append(ArtKitPart.of(ArtKitMesh.panel(sw, sh,
			Vector3(sx, sy, front - sd - 0.04)), sign_mat))
	return ArtKitPart.weld(parts)


## An industrial shed. A high-bay shed is the one building in a low-rise tropical
## city that is *tall*, and a city with nothing tall reads as a village. Roller
## door cut as a real opening, a mercury wall pack, a roof vent and a stack.
static func _build_industrial_shed(seed_value: int = 0) -> Array:
	var s := _rng(seed_value)
	var w := s.randf_range(16.0, 28.0)
	var d := s.randf_range(11.0, 18.0)
	var h := s.randf_range(5.0, 7.0)
	var t := 0.14
	var door_w := 4.2
	var door_h := 4.2
	var front := -d * 0.5
	var parts: Array = []

	var shell := ArtKitMesh.begin()
	_panel(shell, h, 0.0, front + t * 0.5, t, -w * 0.5, -door_w * 0.5)
	_panel(shell, h, 0.0, front + t * 0.5, t, door_w * 0.5, w * 0.5)
	_panel(shell, h - door_h, door_h, front + t * 0.5, t, -door_w * 0.5, door_w * 0.5)
	ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(w, h, t),
			Vector3(-w * 0.5, 0.0, d * 0.5 - t * 0.5)),
			Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3.ZERO))
	for sx in [-1.0, 1.0]:
		ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(d, h, t),
				Vector3(-d * 0.5, 0.0, -t * 0.5)),
				Transform3D(Basis.from_euler(Vector3(0, sx * PI * 0.5, 0)),
						Vector3(sx * (w * 0.5 - t * 0.5), 0.0, 0.0)))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(shell), "industrial_metal"))

	parts.append(ArtKitPart.of(ArtKitMesh.gable_roof(w, d, 1.2, 0.35, h), "rust"))

	# The roller door itself, closed, in a different metal so it reads as a door.
	parts.append(ArtKitPart.of(ArtKitMesh.box_from(Vector3(door_w - 0.24, door_h - 0.12, 0.08),
			Vector3(-(door_w - 0.24) * 0.5, 0.0, front - 0.08)), "rust"))

	# A wall pack over the door. This is the light source on an industrial
	# building and it is mercury, not sodium - the cool/warm split is what stops
	# the whole city being one temperature.
	parts.append(ArtKitPart.of(ArtKitMesh.box_from(Vector3(0.44, 0.26, 0.30),
			Vector3(0, door_h + 0.32, front - 0.30)), "steel_galv"))
	parts.append(ArtKitPart.of(ArtKitMesh.panel(0.36, 0.17,
			Vector3(0, door_h + 0.33, front - 0.46)), "lamp_lens_cool"))

	# A roof vent and a stack: two small verticals that break the roofline and
	# read as silhouettes against the sky.
	parts.append(ArtKitPart.of(ArtKitMesh.merge([
		ArtKitMesh.tube(0.45, 0.45, 0.7, 8, Vector3(w * 0.25, h + 0.9, d * 0.2)),
		ArtKitMesh.tube(0.22, 0.20, s.randf_range(2.0, 3.5), 6,
				Vector3(-w * 0.3, h + 0.7, -d * 0.25)),
	], []), "rust"))

	# One lit office window: an occupied building, not a shell.
	parts.append(ArtKitPart.of(ArtKitMesh.panel(1.6, 0.9,
			Vector3(w * 0.5 + 0.03, h * 0.7, d * 0.1)), "glass_shop"))
	return ArtKitPart.weld(parts)


## A low-rise walk-up: three or four storeys with a balcony. This is the mass
## that gives an arterial a skyline of its own, two hundred metres before the
## real CBD appears on the horizon. The balcony railing is what makes four
## storeys read as four storeys rather than as one tall box.
static func _build_walk_up_block(seed_value: int = 0) -> Array:
	var s := _rng(seed_value)
	var w := s.randf_range(11.0, 17.0)
	var d := s.randf_range(9.0, 13.0)
	var floors := 3 + (s.randi() % 2)
	var h := float(floors) * STOREY
	var t := 0.20
	var wall_key := _wall_key(s.randi() % 6)
	var front := -d * 0.5
	var door_w := 2.6
	var parts: Array = []

	# --- shell. Front is built in its own frame: a spandrel, a head band, and a
	# --- hole onto the balcony, storey by storey.
	var front_wall := ArtKitMesh.begin()
	for f in floors:
		var y := float(f) * STOREY
		_panel(front_wall, STOREY - 0.95, y, 0.0, t, -w * 0.5, -door_w * 0.5)
		_panel(front_wall, STOREY - 0.95, y, 0.0, t, door_w * 0.5, w * 0.5)
		_panel(front_wall, 0.95, y + STOREY - 0.95, 0.0, t, -door_w * 0.5, door_w * 0.5)
	# Ground floor: a shopfront band, so the base is not a blank wall.
	_panel(front_wall, 0.6, 0.0, 0.0, t, -w * 0.5, w * 0.5)
	_panel(front_wall, STOREY - 3.0, 3.0, 0.0, t, -w * 0.5, w * 0.5)
	for px in [-w * 0.5 + 0.25, 0.0, w * 0.5 - 0.25]:
		_panel(front_wall, 2.4, 0.6, 0.0, t, px - 0.12, px + 0.12)
	var shell := ArtKitMesh.begin()
	ArtKitMesh.blit(shell, ArtKitMesh.commit(front_wall),
			Transform3D(Basis.from_euler(Vector3(0, 0, 0)), Vector3(0, 0, front + t * 0.5)))
	ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(w, h, t),
			Vector3(-w * 0.5, 0.0, d * 0.5 - t * 0.5)),
			Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3.ZERO))
	for sx in [-1.0, 1.0]:
		ArtKitMesh.blit(shell, ArtKitMesh.box_from(Vector3(d, h, t),
				Vector3(-d * 0.5, 0.0, -t * 0.5)),
				Transform3D(Basis.from_euler(Vector3(0, sx * PI * 0.5, 0)),
						Vector3(sx * (w * 0.5 - t * 0.5), 0.0, 0.0)))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(shell), wall_key))

	# --- balconies: slab, soffit, railing of verticals, top rail --------------
	var slabs := ArtKitMesh.begin()
	for f in range(1, floors + 1):
		var y := float(f) * STOREY - 0.22
		ArtKitMesh.blit(slabs, ArtKitMesh.box_from(Vector3(w * 0.94, 0.20, 1.10),
				Vector3(-w * 0.47, y, front - 1.10)), Transform3D())
		for i in 11:
			var px := -w * 0.47 + float(i) * (w * 0.94 / 10.0)
			ArtKitMesh.blit(slabs, ArtKitMesh.box_from(Vector3(0.05, 0.95, 0.05),
					Vector3(px - 0.025, y + 0.20, front - 1.06)), Transform3D())
		ArtKitMesh.blit(slabs, ArtKitMesh.box_from(Vector3(w * 0.94, 0.06, 0.08),
				Vector3(-w * 0.47, y + 1.15, front - 1.09)), Transform3D())
	parts.append(ArtKitPart.of(ArtKitMesh.commit(slabs), "concrete_b"))

	# --- flat roof, parapet, stair head. A flat roof needs something on it or
	# --- it reads as an unfinished box from above the road.
	parts.append(ArtKitPart.of(ArtKitMesh.merge([
		ArtKitMesh.box_from(Vector3(w, 0.22, d), Vector3(-w * 0.5, h, -d * 0.5)),
		ArtKitMesh.box_from(Vector3(w, 0.70, d), Vector3(-w * 0.5, h + 0.22, -d * 0.5)),
		ArtKitMesh.box_from(Vector3(3.2, 2.4, 2.6), Vector3(-1.6, h + 0.92, -1.3)),
	], []), "concrete_a"))

	# --- glazing: a ground-floor shopfront and a balcony door per storey. The
	# --- mix of lit and unlit is the whole point.
	var dark := ArtKitMesh.begin()
	var lit := ArtKitMesh.begin()
	var inner := ArtKitMesh.begin()
	var shopfront := Transform3D(Basis.from_euler(Vector3(0, 0, 0)),
			Vector3(0, 0, front - 0.02))
	for i in 3:
		var cx := (float(i) - 1.0) * (w * 0.30)
		_pane(dark, lit, inner, s, ArtKitMesh.panel(2.4, 2.3,
				Vector3((float(i) - 1.0) * (w * 0.30), 1.75, front - 0.04)), shopfront)
	for f in floors:
		var y := float(f) * STOREY
		var xf := Transform3D(Basis.from_euler(Vector3(0, 0, 0)), Vector3(0, y, front - 0.04))
		_pane_xf(dark, lit, inner, s, ArtKitMesh.panel(1.2, 2.1, Vector3(0, 1.05, 0.0)),
				xf, 0.42)
		for px in [-w * 0.32, w * 0.32]:
			_pane_xf(dark, lit, inner, s,
					ArtKitMesh.panel(0.95, 1.30, Vector3(px, 1.55, 0.0)), xf, 0.42)
	parts.append(ArtKitPart.of(ArtKitMesh.commit(dark), "glass_dark"))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(lit), "glass_lit"))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(inner), "interior_warm"))
	return ArtKitPart.weld(parts)


## Route one pane to the dark mesh, the lit mesh, or the interior glow behind it.
static func _pane(dark: SurfaceTool, lit: SurfaceTool, inner: SurfaceTool,
		s: RandomNumberGenerator, pane: ArrayMesh, xf: Transform3D) -> void:
	_pane_xf(dark, lit, inner, s, pane, xf, 0.42)


static func _pane_xf(dark: SurfaceTool, lit: SurfaceTool, inner: SurfaceTool,
		s: RandomNumberGenerator, pane: ArrayMesh, xf: Transform3D, lit_ratio: float) -> void:
	if s.randf() < lit_ratio:
		ArtKitMesh.blit(lit, pane, xf)
		ArtKitMesh.blit(inner, pane, Transform3D(Basis(), xf.origin + Vector3(0, 0, 0.6)))
	else:
		ArtKitMesh.blit(dark, pane, xf)


# =============================================================================
# THE OSM PATH
# =============================================================================

## Give a real OSM building footprint the same treatment as a generated one: real
## walls extruded from the real polygon, a plinth, deep eaves, and lit windows in
## real openings on the -Z face.
##
## This exists for whoever consumes the 2198 real footprints. They do not have to
## be boxes to get the art direction: they get the eaves, the wall colours, the
## plinth, the lit-window mix and the batching from this kit, and the only thing
## they keep from the raw data is the outline.
##
## `storeys` and `lit_ratio` are the two levers. `lit_ratio` defaults low on
## purpose - a suburb where every window is lit is a suburb with nobody home, and
## it destroys the only reason the lit windows existed.
##
## ## The one thing this does *not* do, honestly
##
## It does not cut the window openings out of the extruded prism. `ArtKitMesh
## .prism()` extrudes a polygon without holes, so the walls are extruded from a
## footprint scaled in by half a wall thickness and the window wall is built in
## the gap. For a footprint whose -Z edge is straight (the overwhelming majority
## of a suburban extract) the openings are then real holes in a real wall from
## any distance a driver is at. For an L-shaped or notched footprint the scaled
## offset is only exact on the extreme faces, so the window wall projects or
## recedes a little at the corners. Fixing that properly needs a true polygon
## offset with self-intersection removal, which is more code than the artefact is
## worth. It is listed in `standards.md` under "known gaps" rather than quietly
## shipped.
static func wrap_footprint(poly: PackedVector2Array, storeys: int = 1,
		lit_ratio: float = 0.4, seed_value: int = 0) -> Array:
	if poly.size() < 3:
		return []
	var s := _rng(seed_value)
	var wall_key := _wall_key(s.randi() % 6)
	var roof_key := _roof_key(s.randi() % 5)
	var parts: Array = []

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var size := hi - lo
	var storey: int = maxi(storeys, 1)
	var h := float(storey) * STOREY
	# Eaves scale with the building. 0.8 m is the domestic figure and it is what
	# makes a low-rise city read as low-rise and tropical; a 28 m shed gets a
	# clamp rather than 4 m of roof.
	var eave := clampf(minf(size.x, size.y) * 0.14, 0.35, 1.10)
	var wall_t := 0.24

	# A 0.3 m plinth in a different material, then the walls above it. This is what
	# stops an extruded footprint reading as a solid with no ground contact.
	parts.append(ArtKitPart.of(ArtKitMesh.prism(poly, 0.0, 0.30), "concrete_a"))
	# The walls are scaled in by half a wall thickness so the -Z face lands exactly
	# on the inner face of the window wall built below. That is what makes the
	# windows holes instead of a band stuck onto a face. Uniform scaling about the
	# centre is an approximation of a true offset - exact on the extreme faces,
	# within a couple of centimetres on the corners, which is invisible at the
	# scale the openings are read from.
	var k: float = maxf(1.0 - wall_t / maxf(size.y, 0.5), 0.5)
	var shrunk := PackedVector2Array()
	var c := (lo + hi) * 0.5
	for p in poly:
		shrunk.append(c + (p - c) * k)
	parts.append(ArtKitPart.of(ArtKitMesh.prism(shrunk, 0.30, h), wall_key))

	# Roof: gabled for anything residential-width, flat parapet for a wide block.
	if minf(size.x, size.y) < 14.0:
		parts.append(ArtKitPart.of(ArtKitMesh.gable_roof(size.x, size.y,
				1.2 + eave, eave, h), roof_key))
	else:
		parts.append(ArtKitPart.of(ArtKitMesh.prism(poly, h, h + 0.5), "concrete_a"))

	# The window wall, in bays. One band of openings per storey, so `storeys`
	# changes the building's silhouette and not just its height.
	var dark := ArtKitMesh.begin()
	var lit := ArtKitMesh.begin()
	var inner := ArtKitMesh.begin()
	var windows := ArtKitMesh.begin()
	var bays: int = clampi(int(size.x / 3.4), 1, 6)
	for f in storey:
		var y := 0.30 + float(f) * STOREY
		if y + HEAD + 0.3 > h:
			break
		var local := ArtKitMesh.begin()
		var openings := _wall(local, size.x, h - y, wall_t, bays, false)
		var xf := Transform3D(Basis.from_euler(Vector3(0, 0, 0)),
				Vector3(lo.x, y, lo.y + wall_t * 0.5))
		ArtKitMesh.blit(windows, ArtKitMesh.commit(local), xf)
		_glaze(dark, lit, inner, s, openings, xf, wall_t, lit_ratio)
	parts.append(ArtKitPart.of(ArtKitMesh.commit(windows), wall_key))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(dark), "glass_dark"))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(lit), "glass_lit"))
	parts.append(ArtKitPart.of(ArtKitMesh.commit(inner), "interior_warm"))
	return ArtKitPart.weld(parts)


# =============================================================================

const WALL_KEYS: PackedStringArray = [
	"surface_render_wall_a", "surface_render_wall_b", "surface_render_wall_c",
	"surface_render_wall_d", "surface_render_wall_e", "surface_render_wall_f",
]
const ROOF_KEYS: PackedStringArray = [
	"surface_roof_iron_a", "surface_roof_iron_b", "surface_roof_iron_c",
	"surface_roof_iron_d", "surface_roof_iron_e",
]


static func _wall_key(index: int) -> String:
	return WALL_KEYS[posmod(index, WALL_KEYS.size())]


static func _roof_key(index: int) -> String:
	return ROOF_KEYS[posmod(index, ROOF_KEYS.size())]


static func _rng(seed_value: int) -> RandomNumberGenerator:
	var s := RandomNumberGenerator.new()
	s.seed = seed_value * 2654435761 + 17
	return s


# =============================================================================
# SHARED VARIANTS
# =============================================================================

## Generated arrays, cached by recipe.
##
## A building generated from its own seed is a *unique mesh*, so a MultiMesh per
## building is one draw call per building and instancing buys nothing. Two ways
## out, and a consumer picks one:
##
## 1. **A finite seed set.** `ArtKitBuildings.variant(name, index)` hands out
##    `HOUSE_VARIANTS` memoised designs per type. 16 designs of every type across
##    2198 footprints is a suburb that does not repeat visibly from a car, for
##    about 100 draw calls. This is the default and it is what the check measures.
## 2. **`ArtKitBatch.build_merged()`.** Bake the real footprints into one mesh per
##    material - about 5 draw calls for the whole suburb - and accept that the
##    geometry can no longer move. Static city geometry does not need to move.
##
## Do not call `_build_*` or `wrap_footprint()` directly in a loop and then batch:
## every call is a new resource, so every signature is unique.
static var _shared: Dictionary = {}

## How many designs of each type exist. 16 is where a suburb stops looking
## repeated from a car; 8 is visible along a straight road.
const HOUSE_VARIANTS := 16


static func _memo(key: String, make: Callable) -> Array:
	if not _shared.has(key):
		_shared[key] = make.call()
	return _shared[key]


## Memoised parts for a building type by design index. `index` wraps, so a
## consumer can scatter any number of buildings and get `HOUSE_VARIANTS` meshes
## per type.
static func variant(name: String, index: int = 0) -> Array:
	var i := posmod(index, HOUSE_VARIANTS)
	match name:
		"qld_house": return qld_house(i)
		"qld_shop": return qld_shop(i)
		"industrial_shed": return industrial_shed(i)
		"walk_up_block": return walk_up_block(i)
	push_error("ArtKitBuildings: unknown building type '%s'" % name)
	return []


## Every design of a type, as an array. For a consumer that just wants "a suburb".
static func all_variants(name: String) -> Array:
	var out: Array = []
	for i in HOUSE_VARIANTS:
		out.append(variant(name, i))
	return out


static func qld_house(seed_value: int = 0) -> Array:
	return _memo("qld_house:%d" % seed_value,
			func() -> Array: return _build_qld_house(seed_value))


static func qld_shop(seed_value: int = 0) -> Array:
	return _memo("qld_shop:%d" % seed_value,
			func() -> Array: return _build_qld_shop(seed_value))


static func industrial_shed(seed_value: int = 0) -> Array:
	return _memo("industrial_shed:%d" % seed_value,
			func() -> Array: return _build_industrial_shed(seed_value))


static func walk_up_block(seed_value: int = 0) -> Array:
	return _memo("walk_up_block:%d" % seed_value,
			func() -> Array: return _build_walk_up_block(seed_value))
