class_name ArtKitProps
extends RefCounted
## Street furniture and vegetation for a tropical Queensland suburb at night.
##
## ## What this replaces
##
## `World/world_builder.gd` builds its props with a handful of private mesh
## helpers and exactly one palm: a tapered cylinder for every trunk, one frond
## mesh for every frond, an icosphere for every bush - cloned 1621 times with
## only a random yaw and a random height. That is the "orange polygons" look. The
## reason it reads as procedural is not the polygon count, it is that *the same
## object appears 1621 times and the eye counts them*.
##
## So variation here is structural, not cosmetic:
##   - **Four palm species**, because a north Queensland street genuinely mixes
##     them and because one species at 1621 clones is the worst single thing in
##     the world today. Coco, Alexandrine, areca (clumping) and the fan palm
##     (Livistona) are all in Cairns street planting, and they are visibly
##     different from across a street.
##   - **`VARIANTS` mesh variants per species**, deterministic from a seed, with
##     different bend, frond count, lean and height. Three is the budget in
##     `standards.md`: past three, draw calls climb faster than the variety.
##   - **Beyond the variant table, vary by uniform scale and yaw only**, which is
##     free and adds no draw call.
##
## ## Every generator returns `Array[ArtKitPart]`
##
## Never a bare ArrayMesh, even for a prop that is one material. Two reasons:
## `ArtKitBatch` groups by (mesh, material) and a uniform return type means a
## caller never branches, and it makes it impossible to return a mesh whose
## material nobody set - which is an untextured white box in a dark scene.
##
## ## Registry
##
## `registry()` lists every generator in this file, and `artkit_check.gd` fails
## if a generator exists that is not in it. That is the mechanism that stops the
## kit rotting quietly: a prop added on a Friday gets checked on a Friday.

## Mesh variants per prop. See the note above on why this is 3.
const VARIANTS := 3


# =============================================================================
# REGISTRY
# =============================================================================

## Every generator: what it is, what it wears, and what it is for. The check
## reads this; consumers can ignore it.
static func registry() -> Dictionary:
	return {
		# --- vegetation ---
		"palm_coco": {
			"kind": "vegetation", "mat": "bark",
			"use": "tall smooth-trunked street palm, 9.5-13 m, heavy crown, fruit bunch",
		},
		"palm_alexandrine": {
			"kind": "vegetation", "mat": "bark",
			"use": "Alexandra palm: stout, near-plumb, tight upright crown. The classic Manunda street tree",
		},
		"palm_areca": {
			"kind": "vegetation", "mat": "bark",
			"use": "betel nut palm. Clumps of thin stems, no fruit. The cheap mass filler that does not look like a clone",
		},
		"palm_fan": {
			"kind": "vegetation", "mat": "bark",
			"use": "Livistona: stump trunk, frond-base skirt, round fans. Reads subtropical in one glance",
		},
		"tree_rain_tree": {
			"kind": "vegetation", "mat": "bark",
			"use": "melaleuca: paperbark trunk, dense rounded canopy. The footpath shade tree",
		},
		"tree_cedar": {
			"kind": "vegetation", "mat": "bark",
			"use": "tropical cedar with a buttressed base. The vertical that breaks a flat roofline",
		},
		"tree_paperbark": {
			"kind": "vegetation", "mat": "bark",
			"use": "street paperbark, 15-20 m, real trunk, canopy wider than the crown so it overhangs the carriageway",
		},
		"tree_fern": {
			"sink": true,
			"kind": "vegetation", "mat": "bark",
			"use": "cyathea: rosette of fronds on a short trunk. Says Wet Tropics without saying it",
		},
		"bush_scrub": {
			"sink": true,
			"kind": "vegetation", "mat": "surface_foliage_d",
			"use": "low verge scrub in three silhouettes, so a bank is not a hedge",
		},
		"grass_tuft": {
			"sink": true,
			"kind": "vegetation", "mat": "grass",
			"use": "verge grass. 24 triangles and the cheapest ground cover in the kit",
		},

		# --- utility ---
		"contact_shadow": {
			"decal": true, "kind": "utility", "mat": "contact_shadow",
			"use": "a multiply decal under anything that must not float. One quad, "
				+ "no light of its own, works with the scene's shadows switched off",
		},

		# --- infrastructure ---
		"power_pole": {
			"kind": "infrastructure", "mat": "timber",
			"use": "9.5 m timber pole, two crossarms, insulators, a transformer can",
		},
		"wire_span": {
			"sink": true,
			"kind": "infrastructure", "mat": "wire",
			"use": "one unit catenary sag, instanced along a span. Every wire in the city is one draw call",
		},
		"streetlight": {
			"kind": "infrastructure", "mat": "steel_galv",
			"use": "sodium luminaire on a 7.2 m column with a 1.5 m outreach arm over the kerb",
		},
		"streetlight_wall": {
			"mounted": true,
			"kind": "infrastructure", "mat": "steel_galv",
			"use": "wall-mount bracket for narrow streets where a column would land in a driveway",
		},
		"sign_post": {
			"kind": "infrastructure", "mat": "sign_face",
			"use": "regulatory sign on a post. Unlit retroreflective plate, read by catching a headlight",
		},
		"sign_illuminated": {
			"mounted": true,
			"kind": "infrastructure", "mat": "sign_face",
			"use": "a shop's illuminated sign box. The cheapest thing that makes a street read as a city",
		},
		"drain_channel": {
			"sink": true,
			"kind": "infrastructure", "mat": "concrete_a",
			"use": "4 m open concrete drainage channel with standing water. The reason Manunda floods",
		},
		"drain_grate": {
			"sink": true,
			"kind": "infrastructure", "mat": "rust",
			"use": "silt trap with a rusted steel grate. The only rusted steel in the streets, so it reads as a landmark",
		},

		# --- furniture ---
		"bin": {
			"kind": "furniture", "mat": "steel_galv",
			"use": "240 L wheelie bin, lid ajar, two lid materials. A Queensland kerb in one prop",
		},
		"fence_paling": {
			"kind": "furniture", "mat": "timber",
			"use": "4 m hardwood paling fence module, gapped, with posts and a capping rail",
		},
		"fence_mesh": {
			"kind": "furniture", "mat": "steel_galv",
			"use": "4 m galvanised pool fence module. Back lots and the industrial blocks",
		},
		"bus_shelter": {
			"kind": "furniture", "mat": "steel_galv",
			"use": "shelter with posts, a roof with a real overhang, a bench and a lit route panel",
		},
		"bollard": {
			"kind": "furniture", "mat": "steel_galv",
			"use": "1.1 m bollard. 18 triangles and the cheapest depth cue on a footpath",
		},
	}


## True if `name` is a generator in this file.
static func has(name: String) -> bool:
	return registry().has(name)


## Generated arrays, cached by recipe.
##
## This exists because of the single worst footgun in a procedural kit: a
## consumer writes
##
##     for i in 1600: batch.add_array(ArtKitProps.palm_coco(i % 3), xform)
##
## and gets 1600 *different* ArrayMesh resources, so every signature is unique and
## `ArtKitBatch` emits 1600 draw calls instead of 3. Nothing errors. The frame
## rate is the only symptom, and by then the batching code looks fine.
##
## So every generator is memoised: same recipe in, same mesh resource out, which
## is what makes the signature match. `ArtKitProps.variant()` is the name-dispatch
## front door to this.
static var _shared: Dictionary = {}


static func _memo(key: String, make: Callable) -> Array:
	if not _shared.has(key):
		_shared[key] = make.call()
	return _shared[key]


## The shared, memoised parts for a prop by name and variant. **This is what a
## scatter loop should call.** Height variation is uniform instance scale via
## `ArtKitBatch.place(pos, yaw, scale)`, not a baked parameter, because a baked
## height is a different mesh and a different draw call.
static func variant(name: String, variant_index: int = 0) -> Array:
	match name:
		"palm_coco": return palm_coco(variant_index)
		"palm_alexandrine": return palm_alexandrine(variant_index)
		"palm_areca": return palm_areca(variant_index)
		"palm_fan": return palm_fan(variant_index)
		"tree_rain_tree": return tree_rain_tree(variant_index)
		"tree_cedar": return tree_cedar(variant_index)
		"tree_fern": return tree_fern(variant_index)
		"bush_scrub": return bush_scrub(variant_index)
		"grass_tuft": return grass_tuft(variant_index)
		"power_pole": return power_pole(variant_index)
		"wire_span": return wire_span(variant_index)
		"streetlight": return streetlight(variant_index)
		"streetlight_wall": return streetlight_wall(variant_index)
		"sign_post": return sign_post(variant_index)
		"sign_illuminated": return sign_illuminated(variant_index)
		"drain_channel": return drain_channel(variant_index)
		"drain_grate": return drain_grate(variant_index)
		"bin": return bin(variant_index)
		"fence_paling": return fence_paling(variant_index)
		"fence_mesh": return fence_mesh(variant_index)
		"bus_shelter": return bus_shelter(variant_index)
		"bollard": return bollard(variant_index)
		"contact_shadow": return contact_shadow(variant_index)
	push_error("ArtKitProps: unknown prop '%s'" % name)
	return []


## The four palm species, in the order a consumer should mix them.
const PALM_SPECIES: PackedStringArray = [
	"palm_coco", "palm_alexandrine", "palm_areca", "palm_fan",
]


## Build a palm by species name, so a scatter loop can pick a species without a
## match statement of its own.
static func palm(species: String, variant: int, height_scale: float = 1.0) -> Array:
	match species:
		"palm_coco": return palm_coco(variant, height_scale)
		"palm_alexandrine": return palm_alexandrine(variant, height_scale)
		"palm_areca": return palm_areca(variant, height_scale)
		"palm_fan": return palm_fan(variant, height_scale)
		_: push_error("ArtKitProps: unknown palm species '%s'" % species); return []


## Pick a palm the way a real street does: mostly the one species the suburb was
## planted with, a few of another. Purely a helper so four consumers do not each
## invent a weighting; deterministic on `seed_value`.
static func palm_for(seed_value: int) -> Array:
	var r := _rng(seed_value, 4242)
	var roll := r.randf()
	var species: String = PALM_SPECIES[0] if roll < 0.55 else (
			PALM_SPECIES[1] if roll < 0.85 else (
			PALM_SPECIES[2] if roll < 0.95 else PALM_SPECIES[3]))
	return palm(species, r.randi() % VARIANTS, r.randf_range(0.9, 1.15))


# =============================================================================
# PALMS
# =============================================================================

## Frond blade half-width as a fraction of frond length.
##
## Source: *Cocos nucifera* fronds run 4-6 m and the leaflets of a mature frond
## spread about 0.5-1 m to a side, so blade width is 1.0-2.0 m on a 4-6 m frond -
## a full-width ratio of 0.17-0.33, i.e. a half-width ratio of 0.08-0.17. The
## narrow end of that band is the safe one: over-widening is what closed the
## canopy into a disc last time. Alexandra palm (*Ptychosperma alexandrae*) fronds
## are 1.5-2.5 m with a ~0.3 m blade, ratio ~0.12 half-width, same band.
##
## This was 0.30 - a full blade width of 0.60 x length, roughly four times the
## widest the botany allows. That is the measurement behind "the canopies read as
## floating green rhombus grids": at 11 fronds those spokes overlap about twice
## over and the crown closes into one solid faceted disc.
##
## 0.075 is inside the botany band and was picked by looking, not by arithmetic:
## at 0.05 the blades were so narrow they read as straps with no canopy mass,
## which is the opposite failure. See `docs/decisions/0001-art-director.md`
## §"Frond outline" for the render that settled it.
const FROND_HALF_WIDTH := 0.075

## Spine segments per frond, for the palms that can afford them. Seven spans put
## a new vertex roughly every 12% of the frond's arc, which is what turns the
## three visible chords of the old spine into a smooth arch under flat shading.
## `palm_areca` uses FROND_SEGMENTS_SMALL because it carries a crown per stem.
const FROND_SEGMENTS := 7
const FROND_SEGMENTS_SMALL := 6

## Coconut palm. The tall one: a smooth, slightly curved grey trunk with the
## leaf-scar rings implied by a radius wobble, a heavy crown of 11 arching
## fronds, and a fruit bunch tucked under the crown. The fruit is 40 triangles
## and invisible from 30 m, and it is the difference between a palm and a pole.
static func _build_palm_coco(variant: int = 0, height_scale: float = 1.0) -> Array:
	var s := _rng(variant, 101)
	var h := s.randf_range(9.5, 13.0) * height_scale
	var bend := Vector3(s.randf_range(-0.9, 0.9), 0.0, s.randf_range(-0.9, 0.9))
	var parts: Array = []
	parts.append(ArtKitPart.of(ArtKitMesh.curved_tube(0.26, 0.19, h, 7,
			bend.x, bend.z, 4), "bark"))
	# The crown rides the top of the curve, not the top of the bounding box.
	var crown := bend + Vector3(0.0, h, 0.0)
	parts.append(_palm_crown(crown, 11, s.randf_range(3.0, 3.9),
			s.randf_range(0.5, 0.85), s, "surface_foliage_a", 0.10, FROND_SEGMENTS))
	parts.append(ArtKitPart.of(_fruit_bunch(crown, s), "surface_foliage_c"))
	# A skirt of dead frond bases just under the crown. 14 triangles of nothing,
	# and it hides the joint where the trunk meets the crown.
	parts.append(ArtKitPart.of(ArtKitMesh.tube(0.20, 0.29, 0.55, 7,
			crown + Vector3(0, -0.62, 0)), "surface_foliage_c"))
	return ArtKitPart.weld(parts)


## Alexandra palm - the actual Cairns street palm. Near-plumb and stouter, with a
## tight upright crown of stiff fronds, so it reads as *engineered planting*
## rather than jungle. The contrast against the coco palms on the same street is
## the entire reason to ship two species.

static func palm_coco(variant: int = 0, height_scale: float = 1.0) -> Array:
	return _memo("palm_coco:%d:%d" % [variant, roundi(height_scale * 20.0)],
			func() -> Array: return _build_palm_coco(variant, height_scale))


static func _build_palm_alexandrine(variant: int = 0, height_scale: float = 1.0) -> Array:
	var s := _rng(variant, 202)
	var h := s.randf_range(7.5, 10.5) * height_scale
	var parts: Array = []
	parts.append(ArtKitPart.of(ArtKitMesh.curved_tube(0.30, 0.24, h, 7,
			s.randf_range(-0.35, 0.35), s.randf_range(-0.2, 0.2), 3), "bark"))
	var crown := Vector3(0.0, h, 0.0)
	parts.append(_palm_crown(crown, 9, s.randf_range(1.9, 2.5),
			s.randf_range(0.15, 0.35), s, "surface_foliage_a", 0.22, FROND_SEGMENTS))
	return ArtKitPart.weld(parts)


## Betel nut palm. A clump of thin stems off one root ball, each a different
## height, no fruit. This is the budget palm: it fills a block boundary for the
## cost of a third of a coco palm and it looks nothing like one.

static func palm_alexandrine(variant: int = 0, height_scale: float = 1.0) -> Array:
	return _memo("palm_alexandrine:%d:%d" % [variant, roundi(height_scale * 20.0)],
			func() -> Array: return _build_palm_alexandrine(variant, height_scale))


static func _build_palm_areca(variant: int = 0, height_scale: float = 1.0) -> Array:
	var s := _rng(variant, 303)
	var parts: Array = []
	var stems := 3 + (variant % VARIANTS)
	for i in stems:
		var a := TAU * float(i) / float(stems) + s.randf_range(-0.3, 0.3)
		var lean := s.randf_range(0.25, 0.6)
		var h := s.randf_range(4.0, 6.5) * height_scale
		var dir := Vector3(cos(a), 0, sin(a))
		parts.append(ArtKitPart.of(ArtKitMesh.curved_tube(0.10, 0.07, h, 5,
				dir.x * lean, dir.z * lean, 3, dir * 0.18), "bark"))
		parts.append(_palm_crown(dir * (lean * 1.1) + Vector3(0, h, 0), 6,
				s.randf_range(1.3, 1.8), s.randf_range(0.4, 0.7), s,
				"surface_foliage_a", 0.16, FROND_SEGMENTS_SMALL))
	return ArtKitPart.weld(parts)


## Fan palm. A short stump with a skirt of old frond bases, then round fans
## hanging off it. The fans are the reason this exists: a fan palm rendered with
## feather fronds is recognisably wrong to anyone who has seen one, and it is the
## clearest single difference between a subtropical and a tropical street.

static func palm_areca(variant: int = 0, height_scale: float = 1.0) -> Array:
	return _memo("palm_areca:%d:%d" % [variant, roundi(height_scale * 20.0)],
			func() -> Array: return _build_palm_areca(variant, height_scale))


static func _build_palm_fan(variant: int = 0, height_scale: float = 1.0) -> Array:
	var s := _rng(variant, 404)
	var h := s.randf_range(3.4, 5.2) * height_scale
	var parts: Array = []
	parts.append(ArtKitPart.of(ArtKitMesh.tube(0.34, 0.27, h * 0.8, 8), "bark"))
	# Old frond bases: a ring of short stubs around the stump. A healthy fan palm
	# with a clean trunk is the computer-game version; real ones wear a skirt.
	for i in 4:
		var a := TAU * float(i) / 4.0
		parts.append(ArtKitPart.of(ArtKitMesh.tube(0.10, 0.06, 0.62, 4,
				Vector3(cos(a) * 0.28, h * 0.42, sin(a) * 0.28)), "bark"))
	var base := Vector3(0, h * 0.8, 0)
	var leaves := 7 + (variant % VARIANTS)
	for i in leaves:
		var a := TAU * float(i) / float(leaves) + s.randf_range(-0.2, 0.2)
		var tilt := s.randf_range(0.35, 0.75)
		parts.append(ArtKitPart.of(_oriented_fan(a, tilt, s.randf_range(1.5, 2.2), base),
				"surface_foliage_a"))
	# Two dead fans hanging down. Their job is to break the symmetry of the
	# crown, which is the thing that makes a fan palm look drawn rather than grown.
	for i in 2:
		var a := TAU * (float(i) / 2.0) + 1.1
		parts.append(ArtKitPart.of(_oriented_fan(a, 1.35, s.randf_range(1.1, 1.5),
				base - Vector3(0, 0.1, 0)), "surface_foliage_c"))
	return ArtKitPart.weld(parts)


## A fan leaf already oriented in the world frame, so a fan palm needs no
## per-leaf basis. Six tapering spans, doubled, 24 triangles.

static func palm_fan(variant: int = 0, height_scale: float = 1.0) -> Array:
	return _memo("palm_fan:%d:%d" % [variant, roundi(height_scale * 20.0)],
			func() -> Array: return _build_palm_fan(variant, height_scale))


static func _oriented_fan(yaw: float, tilt: float, radius: float, base: Vector3) -> ArrayMesh:
	var dir := Vector3(cos(yaw) * sin(tilt), cos(tilt), sin(yaw) * sin(tilt))
	var flat := Vector3(cos(yaw), 0.0, sin(yaw))
	var side := flat.cross(Vector3.UP).normalized()
	var st := ArtKitMesh.begin()
	for i in 6:
		var t0 := float(i) / 6.0
		var t1 := float(i + 1) / 6.0
		var w0 := radius * (0.20 * sin(t0 * PI * 0.92) + 0.04)
		var w1 := radius * (0.20 * sin(t1 * PI * 0.92) + 0.04)
		var c0 := base + flat * (t0 * radius * sin(tilt)) - Vector3.UP * (t0 * t0 * radius * 0.5)
		var c1 := base + flat * (t1 * radius * sin(tilt)) - Vector3.UP * (t1 * t1 * radius * 0.5)
		_strip(st, c0, c1, w0, w1, side)
	return ArtKitMesh.commit(st)


## A crown of drooping fronds fanning around `centre`. Shared by three of the four
## palms, which is the honest overlap: a frond is a frond, and what changes
## between species is the count, the length, the droop and the stiffness.
##
## `segments` is the spine resolution and it is a *per-species* number, not a
## constant, for one reason: `palm_areca` carries a crown per stem across up to
## five stems, so it cannot afford the same resolution inside its 560-triangle
## budget. Everything else about a frond is identical between species.
static func _palm_crown(centre: Vector3, count: int, length: float, droop: float,
		s: RandomNumberGenerator, mat: String, stiffness: float,
		segments: int) -> ArtKitPart:
	var st := ArtKitMesh.begin()
	for i in count:
		var yaw := TAU * float(i) / float(count) + s.randf_range(-0.18, 0.18)
		var tilt := s.randf_range(0.30, 0.62) * (1.0 - stiffness * 0.5)
		var ln := length * s.randf_range(0.82, 1.15)
		var horiz := Vector3(cos(yaw), 0.0, sin(yaw))
		# `reach` and `tip_drop` keep the crown's footprint and hang identical to
		# the three-chord version this replaced, so the change is confined to how
		# the frond is *shaped* and not to where the crown sits in the frame.
		var reach := ln * 0.94
		var lift := ln * sin(tilt)
		var tip_drop := ln * droop - lift * 0.18
		# Per-frond roll, signed, so a crown's blades face opposite ways and the
		# canopy does not read as one fan of identical facets.
		ArtKitMesh.frond(st, centre, horiz, reach, lift, maxf(tip_drop, 0.0),
				ln * FROND_HALF_WIDTH, segments, s.randf_range(-0.55, 0.55))
	return ArtKitPart.of(ArtKitMesh.commit(st), mat)


## A tapering two-sided strip between two spine points. Foliage is two-sided in
## the material, so the doubling is only there for the ones that read as paper
## thin; the strip itself is 4 triangles.
static func _strip(st: SurfaceTool, a: Vector3, b: Vector3, w0: float, w1: float,
		side: Vector3) -> void:
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	side = side.normalized()
	ArtKitMesh.quad(st, a - side * w0, b - side * w1, b + side * w1, a + side * w0)
	ArtKitMesh.quad_flip(st, a - side * w0, a + side * w0, b + side * w1, b - side * w1)


## A coconut fruit bunch: five nuts in a cluster under the crown, each a stubby
## two-sided lens, so the whole bunch is 40 triangles.
static func _fruit_bunch(crown: Vector3, s: RandomNumberGenerator) -> ArrayMesh:
	var st := ArtKitMesh.begin()
	var centre := crown + Vector3(0, -0.30, 0.42)
	for i in 5:
		var a := TAU * float(i) / 5.0
		var side := Vector3(cos(a + PI * 0.5), 0, sin(a + PI * 0.5))
		var hang := s.randf_range(0.14, 0.26)
		var nut_top := centre + side * 0.06 - Vector3.UP * 0.06
		var nut_bot := centre + side * 0.10 - Vector3.UP * (0.06 + hang)
		_strip(st, centre, nut_top, 0.02, 0.02, side)
		# The nut itself: a lens from the top to the bottom of the nut.
		ArtKitMesh.quad(st, nut_top - side * 0.055, nut_bot - side * 0.045,
				nut_bot + side * 0.045, nut_top + side * 0.055)
		ArtKitMesh.quad_flip(st, nut_top - side * 0.055, nut_top + side * 0.055,
				nut_bot + side * 0.045, nut_bot - side * 0.045)
	return ArtKitMesh.commit(st)


## Deterministic per-(family, variant) RNG, so variant 1 is always variant 1 and a
## cached mesh stays valid for the life of the process.
static func _rng(variant: int, family: int) -> RandomNumberGenerator:
	var s := RandomNumberGenerator.new()
	s.seed = family * 7919 + variant * 104729
	return s


# =============================================================================
# OTHER VEGETATION
# =============================================================================

## Melaleuca / paperbark: the shade tree over a suburban footpath. A pale trunk
## and a rounded, slightly irregular canopy. Three overlapping blobs, because one
## blob reads as a lollipop and a lollipop in a tropical street reads as a
## mushroom.
static func _build_tree_rain_tree(variant: int = 0) -> Array:
	var s := _rng(variant, 505)
	var h := s.randf_range(7.0, 11.0)
	var parts: Array = []
	parts.append(ArtKitPart.of(ArtKitMesh.curved_tube(0.34, 0.20, h * 0.62, 7,
			s.randf_range(-0.3, 0.3), s.randf_range(-0.3, 0.3), 3), "bark"))
	var crown_y := h * 0.62
	# Two limbs reaching up into the canopy. 48 triangles that break a silhouette.
	for i in 2:
		var a := s.randf_range(0.0, TAU)
		parts.append(ArtKitPart.of(ArtKitMesh.tube(0.09, 0.05, h * 0.34, 4,
				Vector3(cos(a) * 0.14, h * 0.5, sin(a) * 0.14)), "bark"))
	for i in 3:
		var a := TAU * float(i) / 3.0 + s.randf_range(-0.4, 0.4)
		var r := s.randf_range(1.5, 2.4)
		parts.append(ArtKitPart.of(ArtKitMesh.blob(r, 4, 7, r * 0.28, variant * 3 + i + 7,
				Vector3(cos(a) * r * 0.45, crown_y + r * 0.35, sin(a) * r * 0.45)),
				"surface_foliage_b"))
	return ArtKitPart.weld(parts)


## Tropical cedar: tall, straight, buttressed, with a high thin crown. The point
## of it is vertical. A suburb of one-storey roofs needs the occasional tall thin
## mass, or the roofline is one flat band across the whole frame.

static func tree_rain_tree(variant: int = 0) -> Array:
	return _memo("tree_rain_tree:%d" % variant, func() -> Array: return _build_tree_rain_tree(variant))


static func _build_tree_cedar(variant: int = 0) -> Array:
	var s := _rng(variant, 606)
	var h := s.randf_range(11.0, 16.0)
	var parts: Array = []
	parts.append(ArtKitPart.of(ArtKitMesh.curved_tube(0.55, 0.16, h, 7,
			s.randf_range(-0.2, 0.2), s.randf_range(-0.2, 0.2), 4), "bark"))
	for i in 4:
		var a := TAU * float(i) / 4.0 + 0.4
		parts.append(ArtKitPart.of(ArtKitMesh.tube(0.30, 0.10, 1.5, 4,
				Vector3(cos(a) * 0.34, 0.0, sin(a) * 0.34)), "bark"))
	var top := Vector3(0.0, h, 0.0)
	for i in 3:
		var r := s.randf_range(1.3, 2.0)
		parts.append(ArtKitPart.of(ArtKitMesh.blob(r, 3, 6, r * 0.30, variant * 5 + i + 3,
				Vector3(cos(TAU * float(i) / 3.0) * r * 0.4, h - r * 0.3,
						sin(TAU * float(i) / 3.0) * r * 0.4)),
				"surface_foliage_b"))
	return ArtKitPart.weld(parts)


## Tree fern: a rosette of big fronds on a 1.2 m trunk, with the dead frond skirt
## every cyathea carries. 200-odd triangles and it says "Wet Tropics" without a
## word.

static func tree_cedar(variant: int = 0) -> Array:
	return _memo("tree_cedar:%d" % variant, func() -> Array: return _build_tree_cedar(variant))


static func _build_tree_fern(variant: int = 0) -> Array:
	var s := _rng(variant, 707)
	var h := s.randf_range(0.9, 1.7)
	var parts: Array = []
	parts.append(ArtKitPart.of(ArtKitMesh.tube(0.26, 0.22, h, 7), "bark"))
	for i in 3:
		var a := TAU * float(i) / 3.0 + s.randf_range(-0.4, 0.4)
		parts.append(ArtKitPart.of(ArtKitMesh.tube(0.11, 0.05, 0.55, 4,
				Vector3(cos(a) * 0.22, h * 0.30, sin(a) * 0.22)), "surface_foliage_c"))
	parts.append(_palm_crown(Vector3(0, h, 0), 6, s.randf_range(1.4, 2.1),
			s.randf_range(0.5, 0.8), s, "surface_foliage_b", 0.05, FROND_SEGMENTS))
	return ArtKitPart.weld(parts)


## Low verge scrub, three silhouettes chosen by `variant`: a low wide mound, a
## loose three-part clump, and a spiky upright. One blob scattered 1234 times is
## a hedge with the fence knocked out of it.

static func tree_fern(variant: int = 0) -> Array:
	return _memo("tree_fern:%d" % variant, func() -> Array: return _build_tree_fern(variant))


## Street paperbark, 15-20 m. The measured gap on the anchor arterial: the kerb
## had low icosphere domes and a 9.5 m rain tree, so nothing in frame was tall
## enough to be a canopy and the road read as a corridor of equal-height boxes.
##
## Two things this has to get right, both learned from the before frames:
##   1. A real trunk. `h * 0.55` of clean stem before the first branch, so from
##      a 2.4 m eye height the trunk is a vertical in the frame and the crown
##      is above the roofline instead of sitting on it.
##   2. A crown WIDER than the stem is tall. The canopy blobs are pushed out to
##      `reach` (2.6-4.1 m) and lifted to `h * 0.78`, so a tree planted 3 m
##      back from the kerb overhangs the carriageway. That overhang is the whole
##      reason for the class - a shade tree you cannot see the edge of.
static func _build_tree_paperbark(variant: int = 0) -> Array:
	var s := _rng(variant, 909)
	var h := s.randf_range(15.0, 20.0)
	var reach := s.randf_range(2.6, 4.1)
	var parts: Array = []
	# Trunk, leaning slightly off plumb so 1600 of them are not a fence of posts.
	parts.append(ArtKitPart.of(ArtKitMesh.curved_tube(0.46, 0.21, h * 0.62, 8,
			s.randf_range(-0.22, 0.22), s.randf_range(-0.22, 0.22), 4), "bark"))
	# Two limbs reaching out to hold the canopy off the stem. Without them the
	# crown reads as a lollipop stuck on a stick.
	for i in 2:
		var a := s.randf_range(0.0, TAU)
		parts.append(ArtKitPart.of(ArtKitMesh.tube(0.13, 0.06, h * 0.30, 4,
				Vector3(cos(a) * reach * 0.5, h * 0.50, sin(a) * reach * 0.5)), "bark"))
	# Five canopy blobs on a ring, not a stack: the outer ones carry the width
	# that makes it overhang, the inner one fills the centre so you do not see
	# daylight through the middle of a solid-looking crown.
	for i in 5:
		var a := TAU * float(i) / 5.0 + s.randf_range(-0.25, 0.25)
		var r := s.randf_range(2.2, 3.1)
		var rr: float = reach if i < 3 else reach * 0.55
		parts.append(ArtKitPart.of(ArtKitMesh.blob(r, 4, 8, r * 0.26, variant * 7 + i + 11,
				Vector3(cos(a) * rr, h * 0.78 + s.randf_range(-0.4, 0.5),
						sin(a) * rr)), "surface_foliage_b"))
	parts.append(ArtKitPart.of(ArtKitMesh.blob(s.randf_range(2.0, 2.6), 4, 7, 2.6 * 0.26,
			variant * 3 + 29, Vector3(0.0, h * 0.80, 0.0)), "surface_foliage_b"))
	return ArtKitPart.weld(parts)


static func tree_paperbark(variant: int = 0) -> Array:
	return _memo("tree_paperbark:%d" % variant, func() -> Array: return _build_tree_paperbark(variant))


static func _build_bush_scrub(variant: int = 0) -> Array:
	var s := _rng(variant, 808)
	var parts: Array = []
	match variant % VARIANTS:
		0:
			var r := s.randf_range(0.8, 1.5)
			parts.append(ArtKitPart.of(ArtKitMesh.blob(r, 3, 7, r * 0.34, 11),
					"surface_foliage_d"))
		1:
			for i in 3:
				var r := s.randf_range(0.5, 0.95)
				var a := TAU * float(i) / 3.0
				parts.append(ArtKitPart.of(ArtKitMesh.blob(r, 3, 6, r * 0.40, 20 + i),
						"surface_foliage_d"))
		_:
			for i in 5:
				var r := s.randf_range(0.35, 0.7)
				var a := TAU * float(i) / 5.0 + s.randf_range(-0.3, 0.3)
				parts.append(ArtKitPart.of(ArtKitMesh.tube(0.16, 0.05, r * 2.2, 4,
						Vector3(cos(a) * 0.35, 0.0, sin(a) * 0.35)), "surface_foliage_d"))
	return ArtKitPart.weld(parts)


## Verge grass. Three crossed quads at three yaws - 24 triangles, and a footpath
## verge without it looks like a swept concrete shoulder.

static func bush_scrub(variant: int = 0) -> Array:
	return _memo("bush_scrub:%d" % variant, func() -> Array: return _build_bush_scrub(variant))


static func _build_grass_tuft(variant: int = 0) -> Array:
	var s := _rng(variant, 909)
	var st := ArtKitMesh.begin()
	for i in 3:
		var a := TAU * float(i) / 3.0
		var m := ArtKitMesh.cross(s.randf_range(0.30, 0.55), s.randf_range(0.22, 0.34))
		ArtKitMesh.blit(st, m, Transform3D(Basis.from_euler(Vector3(0, a, 0)), Vector3.ZERO))
	return [ArtKitPart.of(ArtKitMesh.commit(st), "grass")]


# =============================================================================
# INFRASTRUCTURE
# =============================================================================

## A timber power pole: two crossarms, four insulators, a transformer can.
## 9.5 m, which is the height the existing world already uses, so wire and pole
## stay consistent when the map agent adopts both.

static func grass_tuft(variant: int = 0) -> Array:
	return _memo("grass_tuft:%d" % variant, func() -> Array: return _build_grass_tuft(variant))


static func _build_power_pole(variant: int = 0) -> Array:
	var h := 9.5
	var wood: Array = [
		ArtKitMesh.tube(0.19, 0.14, h, 6),
		ArtKitMesh.box_from(Vector3(2.4, 0.16, 0.14), Vector3(-1.2, h - 0.9, -0.07)),
		ArtKitMesh.box_from(Vector3(1.7, 0.13, 0.12), Vector3(-0.85, h - 1.9, -0.06)),
	]
	var steel: Array = []
	for i in 4:
		steel.append(ArtKitMesh.tube(0.055, 0.055, 0.16, 5,
				Vector3(-1.0 + float(i) * 0.66, h - 0.74, 0.0)))
	steel.append(ArtKitMesh.tube(0.24, 0.24, 0.72, 7, Vector3(0.36, h - 2.7, 0.22)))
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.merge(wood, []), "timber"),
		ArtKitPart.of(ArtKitMesh.merge(steel, []), "steel_galv"),
	])


## One unit of catenary sag, authored as a span from (0,0,0) to (1,0,0) with a
## 6% sag. A consumer instances this 6-8 times along a span using
## `wire_transforms()`, so every overhead wire in the city is one draw call
## instead of one per span. Building a unique mesh per span is the most expensive
## mistake available when scattering wire over a suburb, and it is invisible in a
## screenshot - it just costs 10 fps.

static func power_pole(variant: int = 0) -> Array:
	return _memo("power_pole:%d" % variant, func() -> Array: return _build_power_pole(variant))


static func _build_wire_span(variant: int = 0) -> Array:
	var pts := PackedVector3Array()
	var segs := 6
	for i in segs + 1:
		var t := float(i) / float(segs)
		pts.append(Vector3(t, -sin(t * PI) * 0.06, 0.0))
	return [ArtKitPart.of(ArtKitMesh.strand(pts, 0.022), "wire")]


## Transforms that lay `wire_span()` between two points. Empty if the span is too
## short to be a span. `sag_scale` exaggerates the droop: a physically correct
## catenary over 45 m is 0.7 m of sag and reads as a straight line from a car.

static func wire_span(variant: int = 0) -> Array:
	return _memo("wire_span:%d" % variant, func() -> Array: return _build_wire_span(variant))


static func wire_transforms(from: Vector3, to: Vector3, segments: int = 7,
		sag_scale: float = 1.6) -> Array:
	var out: Array = []
	var d := to - from
	var length := d.length()
	if length < 2.0 or segments < 1:
		return out
	var seg := length / float(segments)
	for i in segments:
		var t0 := float(i) / float(segments)
		# Drop the segment start by the catenary value at that end of the span.
		var sag: float = sin(t0 * PI) * 0.06 * length * sag_scale
		var start := from + d * t0 - Vector3.UP * sag
		out.append(ArtKitMesh.along(start, start + d / float(segments), seg))
	return out


## Sodium luminaire on a 7.2 m column with a 1.5 m outreach over the kerb. The
## lens is a *separate part* with its own emissive material, so the whole
## street's lamps are one MultiMesh of steel and one of lens: two draw calls for
## 1121 streetlights, and the lens still glows.
static func _build_streetlight(variant: int = 0) -> Array:
	var h := 7.2
	var reach := 1.5
	var steel: Array = [
		ArtKitMesh.tube(0.14, 0.10, h, 7),
		# Base flange: 14 triangles and the pole stops looking pushed into the mud.
		ArtKitMesh.tube(0.22, 0.18, 0.35, 7),
		# The outreach. A box rather than a tube, because a galvanised outreach arm
		# is a folded plate - 12 triangles instead of 16 and a better silhouette.
		ArtKitMesh.box_from(Vector3(0.10, 0.10, reach), Vector3(-0.05, h - 0.10, 0.0)),
		ArtKitMesh.box_from(Vector3(0.09, 0.34, 0.09), Vector3(-0.045, h - 0.02, reach - 0.09)),
	]
	var lens := ArtKitMesh.box_from(Vector3(0.34, 0.13, 0.62),
			Vector3(-0.17, h - 0.34, reach - 0.31))
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.merge(steel, []), "steel_galv"),
		ArtKitPart.of(lens, "lamp_lens"),
	])


## Wall-mounted luminaire for a narrow street. Same lens material, so a street
## with both types still batches all its lenses into one draw call.

static func streetlight(variant: int = 0) -> Array:
	return _memo("streetlight:%d" % variant, func() -> Array: return _build_streetlight(variant))


static func _build_streetlight_wall(variant: int = 0) -> Array:
	var steel: Array = [
		ArtKitMesh.box_from(Vector3(0.36, 0.12, 0.12), Vector3(-0.06, 3.0, 0.0)),
		ArtKitMesh.box_from(Vector3(0.10, 0.28, 0.70), Vector3(-0.05, 2.86, 0.05)),
	]
	var lens := ArtKitMesh.box_from(Vector3(0.30, 0.10, 0.56), Vector3(-0.15, 2.84, 0.10))
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.merge(steel, []), "steel_galv"),
		ArtKitPart.of(lens, "lamp_lens"),
	])


## Regulatory sign on a post. The plate is a different material from the post and
## is deliberately *unlit*: a sign that glows is a lie about the world. A
## retroreflective plate is read by catching a headlight, which is a different and
## much better effect than emitting - and it is why the plate material is
## `sign_face` and not a neon.

static func streetlight_wall(variant: int = 0) -> Array:
	return _memo("streetlight_wall:%d" % variant, func() -> Array: return _build_streetlight_wall(variant))


static func _build_sign_post(variant: int = 0) -> Array:
	var h := 2.4
	var steel: Array = [ArtKitMesh.tube(0.045, 0.040, h, 5)]
	var plates: Array = [
		ArtKitMesh.panel(0.62, 0.62, Vector3(0, h - 0.5, 0.03)),
		# A supplementary plate under the main one, which is what makes it read as
		# a real sign rather than a floating rectangle.
		ArtKitMesh.panel(0.60, 0.18, Vector3(0, h - 1.15, 0.03)),
	]
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.merge(steel, []), "steel_galv"),
		ArtKitPart.of(ArtKitMesh.merge(plates, []), "sign_face"),
	])


## An illuminated sign box on a bracket. The face is a *light source* material
## (a neon role), the frame and bracket are not. The art direction's rule is only
## meaningful if those are two different materials, which is why this returns two
## parts and not one.

static func sign_post(variant: int = 0) -> Array:
	return _memo("sign_post:%d" % variant, func() -> Array: return _build_sign_post(variant))


static func _build_sign_illuminated(variant: int = 0) -> Array:
	var w := 0.6
	var hh := 3.4
	var y := 4.2
	var frame: Array = [
		ArtKitMesh.box_from(Vector3(0.12, 0.12, 0.55), Vector3(-0.06, y + hh * 0.5, -0.55)),
		ArtKitMesh.box_from(Vector3(0.12, 0.12, 0.55), Vector3(-0.06, y - hh * 0.5, -0.55)),
		ArtKitMesh.box_from(Vector3(w + 0.14, 0.09, 0.30),
				Vector3(-(w + 0.14) * 0.5, y + hh * 0.5, 0.0)),
		ArtKitMesh.box_from(Vector3(w + 0.14, 0.09, 0.30),
				Vector3(-(w + 0.14) * 0.5, y - hh * 0.5 - 0.09, 0.0)),
		ArtKitMesh.box_from(Vector3(0.07, hh, 0.30), Vector3(-(w * 0.5) - 0.07, y - hh * 0.5, 0.0)),
		ArtKitMesh.box_from(Vector3(0.07, hh, 0.30), Vector3(w * 0.5, y - hh * 0.5, 0.0)),
	]
	var face := ArtKitMesh.panel(w, hh, Vector3(0, y, 0.16))
	var col: String = ["neon_magenta", "neon_cyan", "neon_red"][variant % 3]
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.merge(frame, []), "sign_face"),
		ArtKitPart.of(face, col),
	])


## A 4 m open concrete drainage channel: two side walls, a floor, and end lips so
## consecutive modules do not show daylight between them. The standing water is a
## separate part with its own material, because a dry channel and a full one are
## two different scenes and the Wet Tropics only ever gives you the second.

static func sign_illuminated(variant: int = 0) -> Array:
	return _memo("sign_illuminated:%d" % variant, func() -> Array: return _build_sign_illuminated(variant))


static func _build_drain_channel(variant: int = 0) -> Array:
	var st := ArtKitMesh.begin()
	var w := 1.6
	var d := 4.0
	for sx in [-1.0, 1.0]:
		ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(0.18, 0.30, d),
				Vector3(sx * w * 0.5 - 0.09, 0.0, -d * 0.5)), Transform3D())
	ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(w - 0.36, 0.06, d),
			Vector3(-(w - 0.36) * 0.5, -0.26, -d * 0.5)), Transform3D())
	for sz in [-1.0, 1.0]:
		ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(w, 0.08, 0.12),
				Vector3(-w * 0.5, -0.02, sz * (d * 0.5 - 0.12))), Transform3D())
	var water := ArtKitMesh.box_from(Vector3(w - 0.40, 0.02, d - 0.08),
			Vector3(-(w - 0.40) * 0.5, -0.20, -(d - 0.08) * 0.5))
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.commit(st), "concrete_a"),
		ArtKitPart.of(water, "water"),
	])


## A silt trap: a concrete pit with a rusted steel grate over it. It goes on
## every gutter low point, and the rust is the only rusted steel in the streets,
## so it reads as a landmark rather than as more kerb.

static func drain_channel(variant: int = 0) -> Array:
	return _memo("drain_channel:%d" % variant, func() -> Array: return _build_drain_channel(variant))


static func _build_drain_grate(variant: int = 0) -> Array:
	var pit := ArtKitMesh.box_from(Vector3(0.9, 0.22, 0.9), Vector3(-0.45, -0.22, -0.45))
	var bars := ArtKitMesh.begin()
	for i in 5:
		var z := -0.36 + float(i) * 0.18
		ArtKitMesh.blit(bars, ArtKitMesh.box_from(Vector3(0.84, 0.04, 0.06),
				Vector3(-0.42, 0.0, z - 0.03)), Transform3D())
	ArtKitMesh.blit(bars, ArtKitMesh.box_from(Vector3(0.90, 0.05, 0.90),
			Vector3(-0.45, -0.05, -0.45)), Transform3D())
	return ArtKitPart.weld([
		ArtKitPart.of(pit, "concrete_a"),
		ArtKitPart.of(ArtKitMesh.commit(bars), "rust"),
	])


## Bus shelter: four posts, a mono roof with a real 0.5 m overhang, a bench, a
## back panel and a lit route panel. The lit panel is why a shelter reads at 200 m
## and the roof overhang is why it reads as a *shelter* rather than as a sign.

static func drain_grate(variant: int = 0) -> Array:
	return _memo("drain_grate:%d" % variant, func() -> Array: return _build_drain_grate(variant))


static func _build_bus_shelter(variant: int = 0) -> Array:
	var w := 3.6
	var d := 1.4
	var h := 2.5
	var steel: Array = []
	for px in [-w * 0.5, w * 0.5 - 0.08]:
		for pz in [-d * 0.5, d * 0.5 - 0.08]:
			steel.append(ArtKitMesh.box_from(Vector3(0.08, h, 0.08), Vector3(px, 0.0, pz)))
	# Bench: two legs and a seat at the back of the shelter.
	steel.append(ArtKitMesh.box_from(Vector3(0.10, 0.42, 0.42),
			Vector3(-w * 0.5 + 0.4, 0.0, -d * 0.5 + 0.16)))
	steel.append(ArtKitMesh.box_from(Vector3(0.10, 0.42, 0.42),
			Vector3(w * 0.5 - 0.5, 0.0, -d * 0.5 + 0.16)))
	steel.append(ArtKitMesh.box_from(Vector3(w - 0.8, 0.06, 0.42),
			Vector3(-(w - 0.8) * 0.5 - 0.05, 0.42, -d * 0.5 + 0.16)))
	steel.append(ArtKitMesh.mono_roof(w, d, 0.25, 0.5, h, 0.08))
	var back := ArtKitMesh.panel(w - 0.16, h - 0.35, Vector3(0.0, h * 0.5 + 0.1, -d * 0.5 + 0.04))
	var route := ArtKitMesh.panel(0.34, 0.90, Vector3(w * 0.5 - 0.5, 1.65, d * 0.5 - 0.05))
	return ArtKitPart.weld([
		ArtKitPart.of(ArtKitMesh.merge(steel, []), "steel_galv"),
		ArtKitPart.of(back, "sign_face"),
		ArtKitPart.of(route, "glass_shop"),
	])


## A bollard: 18 triangles, and the cheapest depth cue on a footpath. A line of
## them at the kerb tells you how long the block is when the geometry is dark.

static func bus_shelter(variant: int = 0) -> Array:
	return _memo("bus_shelter:%d" % variant, func() -> Array: return _build_bus_shelter(variant))


static func _build_bollard(variant: int = 0) -> Array:
	return [ArtKitPart.of(ArtKitMesh.tube(0.07, 0.065, 1.1, 6), "steel_galv")]


## A 240 L wheelie bin, lid ajar. `variant` picks the lid material, and that is
## the detail that makes a Queensland kerb read as Australia: general waste is
## dark, the recycling bin is the one saturated thing on the footpath that is not
## a light source.

static func bollard(variant: int = 0) -> Array:
	return _memo("bollard:%d" % variant, func() -> Array: return _build_bollard(variant))


static func _build_bin(variant: int = 0) -> Array:
	var body := ArtKitMesh.frustum(Vector2(0.58, 0.98), Vector2(0.62, 1.04), 0.95)
	var lid := ArtKitMesh.box_from(Vector3(0.64, 0.05, 1.08), Vector3(-0.32, 0.95, -0.56))
	var lid_mat := "rust" if variant % 2 == 0 else "surface_foliage_d"
	return ArtKitPart.weld([
		ArtKitPart.of(body, "steel_galv"),
		ArtKitPart.of(lid, lid_mat),
	])


## A 4 m hardwood paling fence module: nine 130 mm boards with a gap, two posts
## and a capping rail. The gaps are the point - a solid panel is a wall, and a
## wall on a suburban boundary is a wall with no depth in it at night.

static func bin(variant: int = 0) -> Array:
	return _memo("bin:%d" % variant, func() -> Array: return _build_bin(variant))


static func _build_fence_paling(variant: int = 0) -> Array:
	var h := 1.5
	var st := ArtKitMesh.begin()
	var boards := 9
	for i in boards:
		var x := -2.0 + float(i) * (4.0 / float(boards))
		ArtKitMesh.quad(st,
			Vector3(x, 0, 0), Vector3(x + 0.13, 0, 0),
			Vector3(x + 0.13, h, 0), Vector3(x, h, 0))
		ArtKitMesh.quad_flip(st,
			Vector3(x, 0, 0), Vector3(x, h, 0),
			Vector3(x + 0.13, h, 0), Vector3(x + 0.13, 0, 0))
	for px in [-2.0, 2.0]:
		ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(0.12, h + 0.2, 0.12),
				Vector3(px - 0.06, 0.0, -0.06)), Transform3D())
	ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(4.0, 0.07, 0.20),
			Vector3(-2.0, h, -0.10)), Transform3D())
	return [ArtKitPart.of(ArtKitMesh.commit(st), "timber")]


## A 4 m galvanised pool-fence module: a frame plus five verticals. Back lots and
## the industrial blocks, where a paling fence would be wrong.

static func fence_paling(variant: int = 0) -> Array:
	return _memo("fence_paling:%d" % variant, func() -> Array: return _build_fence_paling(variant))


static func _build_fence_mesh(variant: int = 0) -> Array:
	var h := 1.8
	var st := ArtKitMesh.begin()
	ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(4.0, 0.06, 0.05),
			Vector3(-2.0, 0.0, -0.025)), Transform3D())
	ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(4.0, 0.06, 0.05),
			Vector3(-2.0, h - 0.06, -0.025)), Transform3D())
	for px in [-2.0, 2.0]:
		ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(0.07, h, 0.07),
				Vector3(px - 0.035, 0.0, -0.035)), Transform3D())
	for i in 5:
		ArtKitMesh.blit(st, ArtKitMesh.box_from(Vector3(0.05, h, 0.04),
				Vector3(-1.6 + float(i) * 0.8, 0.0, -0.02)), Transform3D())
	return [ArtKitPart.of(ArtKitMesh.commit(st), "steel_galv")]


static func fence_mesh(variant: int = 0) -> Array:
	return _memo("fence_mesh:%d" % variant, func() -> Array: return _build_fence_mesh(variant))


## A contact shadow: one horizontal quad at `y = 0.012`, multiplied into the road.
##
## This is the cheapest thing in the kit and the one that most changes how a night
## render reads. The lead's frame of the hero car came back as a car "floating in a
## near pitch-black void" that "lacks realistic shadows, ambient occlusion, or
## reflections that would integrate it naturally into a night environment". The
## geometry and the bodywork were judged good. What was missing is exactly this:
## a dark contact where the tyres meet the tarmac, which is what tells the eye the
## car is resting on the road instead of hovering over it.
##
## `radius` is the half-width of the decal. Rule of thumb: a car's shadow patch is
## a little wider than the car and about 1.4x its length, because the falloff that
## reads as contact is tight while the body of the shadow is soft. `strength` is
## baked into the material's radial gradient - the core value - and there is
## deliberately no per-instance version, because a per-instance colour would
## defeat the MultiMesh batching this whole kit depends on. Two or three fixed
## strengths is the right amount of variety.
##
## The three variants are 2.0 m (car), 2.6 m (van) and 3.4 m (truck) half-widths.
## Yaw it with `ArtKitBatch.facing()` if the object it sits under is not square to
## the road. The 12 mm lift is not cosmetic: coplanar with the road it z-fights,
## and a shadow that shimmers is worse than no shadow.
static func contact_shadow(variant: int = 0, radius: float = -1.0) -> Array:
	# Memoised like every other generator, because `variant()` hands this out in a
	# scatter loop and an unmemoised generator is 1600 draw calls instead of 3.
	return _memo("contact_shadow:%d:%.2f" % [variant, radius],
			func() -> Array: return _build_contact_shadow(variant, radius))


static func _build_contact_shadow(variant: int = 0, radius: float = -1.0) -> Array:
	# Three fixed sizes rather than a continuous parameter: car, van, truck. A
	# per-instance scale would be the other way to vary this, and that is a
	# uniform instance scale which is already allowed - so a consumer who wants a
	# fifth size scales the instance, they do not generate a new mesh.
	var sizes := [2.0, 2.6, 3.4]
	var hw: float = maxf(radius, 0.2) if radius > 0.0 else float(sizes[posmod(variant, 3)])
	var hd := hw * 1.4
	var st := ArtKitMesh.begin()
	ArtKitMesh.quad(st,
			Vector3(-hw, 0.012, -hd), Vector3(hw, 0.012, -hd),
			Vector3(hw, 0.012, hd), Vector3(-hw, 0.012, hd), 1.0)
	ArtKitMesh.quad_flip(st,
			Vector3(-hw, 0.012, -hd), Vector3(-hw, 0.012, hd),
			Vector3(hw, 0.012, hd), Vector3(hw, 0.012, -hd), 1.0)
	return [ArtKitPart.of(ArtKitMesh.commit(st), "contact_shadow")]
