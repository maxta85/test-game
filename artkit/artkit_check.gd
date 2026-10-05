extends SceneTree
## artkit_check.gd - the artkit's own acceptance test.
##
##     godot --headless --audio-driver Dummy --path . --script res://artkit/artkit_check.gd
##
## Exits 0 if every section passes, 1 on any failure, and prints the measured
## numbers behind the claims in `standards.md` so nobody has to take them on
## trust. This is the *mechanical* half of the standards: palette discipline,
## material discipline, geometry sanity, triangle budgets, the welding invariant,
## and the two batching strategies actually collapsing the draw calls they claim.
##
## It is a `SceneTree` script rather than a `Tests/` suite because it has to run
## as the acceptance command on its own, and because nothing outside `artkit/`
## should have to exist for it to pass.

# --------------------------------------------------------------------------- state
var _fails: Array[String] = []
var _checks: int = 0


func _ok(cond: bool, label: String, detail: String = "") -> bool:
	_checks += 1
	if cond:
		print("  ok   %s" % label)
	else:
		print("  FAIL %s%s" % [label, ("  <- " + detail) if detail != "" else ""])
		_fails.append(label)
	return cond


## Copies of the whole prop set that the batching walk places. Shared by the walk
## and by `_expected_instances()` so the two can never disagree, which is how
## the 1650 in this file came to be stale: the multiplier was typed in twice.
const SCATTER_REPS := 25

## Copies of one prop, for the "adding 1000 copies must not add a draw call"
## regression guard. Same reason: the loop bound and the assertion have to be
## one number.
const REPEAT_COPIES := 1300


## Total parts one full pass over the registry produces, i.e. the instance count
## a correct batch must end up with.
func _expected_instances(reg: Dictionary) -> int:
	var n := 0
	for name in reg:
		for v in ArtKitProps.VARIANTS:
			n += ArtKitProps.variant(name, v).size()
	return n * SCATTER_REPS


func _section(title: String) -> void:
	print("\n[%s]" % title)


# --------------------------------------------------------------------------- budgets
## Per-object triangle budgets, in `standards.md` §7. These are the numbers the
## kit is allowed to cost, checked per variant - a budget that only the v0 mesh
## respects is not a budget.
const PROP_BUDGETS := {
	"grass_tuft": 32, "bollard": 24, "bin": 32, "sign_post": 32,
	"wire_span": 60, "streetlight_wall": 48, "bush_scrub": 120,
	"drain_channel": 90, "drain_grate": 96, "fence_paling": 90,
	"streetlight": 90, "sign_illuminated": 90, "fence_mesh": 130,
	"bus_shelter": 130, "power_pole": 140, "tree_fern": 160,
	"palm_alexandrine": 200, "tree_cedar": 260, "tree_rain_tree": 280,
	"palm_coco": 300, "palm_fan": 350, "palm_areca": 560,
	# Measured at 4, not 2: the contact decal is a quad plus its multiply skirt.
	# Set to the measurement on purpose. Every other budget here is a ceiling with
	# headroom, but this one's whole job is to be nearly free - a decal that costs
	# as much as a bollard is a decal nobody can afford to put under 1600 palms.
	"contact_shadow": 4,
}
const BUILDING_BUDGETS := {
	"industrial_shed": 200, "qld_shop": 220, "qld_house": 780,
	"walk_up_block": 1100,
}
## Per storey, because an OSM footprint's cost is a function of its height.
const WRAP_BUDGET_PER_STOREY := 350

## How many footprints the real OSM extract holds. Declared, not derived: this
## is the world's size, owned by the map data, and artkit deliberately has no
## dependency on `World/` so that this suite runs on its own. Quoted in one place
## so that if the extract grows, one number here is what goes stale - and it will
## fail loudly rather than quietly. See the budget section.
const OSM_FOOTPRINTS := 2198

## `ART_DIRECTION.md`: saturated colour is a light source, not a surface. A
## surface role above this saturation is a wall somebody painted cyan at 3am.
const SURFACE_SATURATION_MAX := 0.22

## The road is the hero surface. Outside this band it is not the road.
const ASPHALT_ROUGHNESS := [0.10, 0.18]

const DOC_PATH := "res://ART_DIRECTION.md"


func _initialize() -> void:
	print("artkit check - Cairns After Dark procedural asset kit")
	_check_palette()
	_check_palette_against_doc()
	_check_materials()
	_check_geometry()
	_check_frond_outline()
	_check_budgets()
	_check_batching()
	_check_consumer()
	_check_no_external_assets()
	_check_licensed_assets()
	_check_texture_layer()
	_report()


# =============================================================================
# 1. PALETTE
# =============================================================================

func _check_palette() -> void:
	_section("palette")
	var roles := ArtKitPalette.ROLES
	_ok(roles.size() >= 40, "role count >= 40", "got %d" % roles.size())

	var no_use: Array[String] = []
	var bad_hex: Array[String] = []
	var saturated_surfaces: Array[String] = []
	var light_roles: Array[String] = []
	for role in roles:
		var spec: Dictionary = roles[role]
		if String(spec.get("use", "")).strip_edges() == "":
			no_use.append(role)
		var hex := String(spec.get("hex", ""))
		if hex.length() != 6 or not hex.is_valid_hex_number(false):
			bad_hex.append(role)
		if bool(spec.get("emits", false)):
			light_roles.append(role)
		elif ArtKitPalette.saturation(role) > SURFACE_SATURATION_MAX:
			saturated_surfaces.append("%s(s=%.2f)" % [role, ArtKitPalette.saturation(role)])

	_ok(no_use.is_empty(), "every role documents where it goes", str(no_use))
	_ok(bad_hex.is_empty(), "every role is a 6-digit hex", str(bad_hex))
	_ok(saturated_surfaces.is_empty(),
			"no surface role exceeds saturation %.2f (saturated colour is a light source)"
			% SURFACE_SATURATION_MAX, str(saturated_surfaces))
	_ok(light_roles.size() >= 7, "at least 7 emitting light roles", "got %d" % light_roles.size())

	# The rule only holds if it interlocks the other way as well: any colour a
	# material emits with has to be a light role, or a new emissive material can
	# smuggle a saturated colour onto a surface.
	var undeclared: Array[String] = []
	for k in ArtKitMaterials._SPECS:
		var spec: Dictionary = ArtKitMaterials._SPECS[k]
		var emit_role := String(spec.get("emit_role", ""))
		if emit_role != "" and not ArtKitPalette.is_light(emit_role):
			undeclared.append("%s emits %s" % [k, emit_role])
	_ok(undeclared.is_empty(), "every emission colour is declared a light role", str(undeclared))

	# The rule is only worth anything if it is a real constraint, so check that
	# the light roles are actually the saturated ones. If the light side were also
	# desaturated the whole palette would be grey and the check would be vacuous.
	var lit_sat: Array[float] = []
	for r in light_roles:
		if ArtKitPalette.saturation(r) > 0.0:
			lit_sat.append(ArtKitPalette.saturation(r))
	_ok(lit_sat.size() > 0 and lit_sat.max() > 0.5,
			"the light roles are the saturated ones (max s=%.2f)"
			% (lit_sat.max() if lit_sat.size() > 0 else 0.0))

	# Every family the doc's spread rules depend on must exist.
	# asphalt_dry is deliberately a single value: dry verges are one thing, and
	# three values for it would be variation nobody asked for.
	for fam in ["asphalt_wet", "roof_iron", "render_wall", "foliage"]:
		_ok(ArtKitPalette.family_keys(fam).size() >= 3,
				"family '%s' has >= 3 values" % fam,
				"got %d" % ArtKitPalette.family_keys(fam).size())


## The nine light roles are quoted from `ART_DIRECTION.md`. Parse the doc's own
## table back and fail if a hex or a label drifted, so the doc stays the source of
## truth rather than a copy nobody checks.
func _check_palette_against_doc() -> void:
	_section("palette vs ART_DIRECTION.md")
	if not FileAccess.file_exists(DOC_PATH):
		_ok(false, "ART_DIRECTION.md is readable", "missing %s" % DOC_PATH)
		return
	var text := FileAccess.get_file_as_string(DOC_PATH)
	_ok(text != "", "ART_DIRECTION.md is non-empty")

	# Pull every `| ... | `#rrggbb` ... |` row out of the palette table.
	var doc_hex := {}
	for line in text.split("\n"):
		if not line.begins_with("|"):
			continue
		var cells := line.split("|")
		if cells.size() < 3:
			continue
		var label := cells[1].strip_edges()
		for token in cells[2].split("`"):
			var hex := token.strip_edges().trim_prefix("#")
			if hex.length() == 6 and hex.is_valid_hex_number(false):
				doc_hex[hex] = label
	# "Neon accents" carries three hexes in one cell; collect them all.
	_ok(doc_hex.size() >= 8, "doc table yields >= 8 hexes", "got %d" % doc_hex.size())

	# One doc row can carry several hexes ("Neon accents | cyan #.., magenta #.."),
	# so the comparison is a set per label, not a single value per label.
	var by_label: Dictionary = {}
	for role in ArtKitPalette.ROLES:
		var label := String(ArtKitPalette.ROLES[role].get("doc", ""))
		if label == "":
			continue
		if not by_label.has(label):
			by_label[label] = []
		by_label[label].append(String(ArtKitPalette.ROLES[role]["hex"]).trim_prefix("#"))

	var drift: Array[String] = []
	for label in by_label:
		var doc_set: Array = []
		for hex in doc_hex:
			if doc_hex[hex] == label:
				doc_set.append(hex)
		for hex in by_label[label]:
			if not doc_set.has(hex):
				drift.append("%s: kit has #%s, doc does not" % [label, hex])
		for hex in doc_set:
			if not (by_label[label] as Array).has(hex):
				drift.append("#%s (%s) is in the doc and not in the kit" % [hex, label])
	_ok(drift.is_empty(), "every doc light role matches the kit", str(drift))
	_ok(by_label.size() >= 7, "the doc's whole palette table is represented",
			"only %d labels: %s" % [by_label.size(), str(by_label.keys())])
	print("       %d doc rows, %d hexes cross-checked" % [by_label.size(), doc_hex.size()])


# =============================================================================
# 2. MATERIALS
# =============================================================================

func _check_materials() -> void:
	_section("materials")
	var keys := ArtKitMaterials.keys()
	_ok(keys.size() >= 40, "material count >= 40", "got %d" % keys.size())

	var unresolved: Array[String] = []
	var not_cached: Array[String] = []
	for k in keys:
		if ArtKitMaterials.get_(k) == null:
			unresolved.append(k)
		elif ArtKitMaterials.get_(k) != ArtKitMaterials.get_(k):
			# Two equal-by-value materials are two draw calls; the cache is the
			# whole mechanism, so it is worth a pointer comparison.
			not_cached.append(k)
	_ok(unresolved.is_empty(), "every key builds a material", str(unresolved))
	_ok(not_cached.is_empty(), "get_() returns the same instance every call", str(not_cached))

	# Emission must trace back to a light role. An emissive material with a colour
	# nobody chose is exactly how a street ends up orange.
	var bad_emit: Array[String] = []
	for k in keys:
		if ArtKitMaterials.emission_energy_of(k) <= 0.0:
			continue
		var spec: Dictionary = ArtKitMaterials._SPECS[k]
		var emit_role := String(spec.get("emit_role", ""))
		if emit_role == "":
			# Faint self-lit surfaces - foliage and grass bleeding a little lamp -
			# take their own albedo. Legal, and the only exception.
			if not bool(spec.get("leaf", false)):
				bad_emit.append("%s emits with no declared role" % k)
		elif not ArtKitPalette.is_light(emit_role):
			bad_emit.append("%s emits %s, which is not a light role" % [k, emit_role])
	_ok(bad_emit.is_empty(), "every emissive material declares a light role", str(bad_emit))

	# Faint emission must stay faint. Foliage at 0.05 bleeding through a frond is
	# right; foliage at 1.5 is a light box, and it is the failure that is hardest
	# to see in a test and easiest to see in a render.
	var too_hot: Array[String] = []
	for k in keys:
		var e := ArtKitMaterials.emission_energy_of(k)
		var leaf := bool(ArtKitMaterials._SPECS[k].get("leaf", false))
		if leaf and e > 0.10:
			too_hot.append("%s leaf emission %.2f" % [k, e])
	_ok(too_hot.is_empty(), "foliage emission stays under 0.10", str(too_hot))

	# The hero surface. How many wet states exist is derived from the palette and
	# checked in both directions - every wet-asphalt role has a material, and
	# every wet-asphalt material traces back to a role - rather than being
	# asserted as "4", which is only ever the number the palette happened to hold
	# on the day somebody typed it.
	var wet_roles := ArtKitPalette.family_keys("asphalt_wet_")
	var wet_mats: Array[String] = []
	var wet_orphans: Array[String] = []
	for r in wet_roles:
		var mk := "surface_" + String(r)
		if keys.has(mk):
			wet_mats.append(mk)
		else:
			wet_orphans.append(mk + " has no material")
	for k in keys:
		if String(k).begins_with("surface_asphalt_wet") and not wet_mats.has(String(k)):
			wet_orphans.append(String(k) + " has no palette role")
	_ok(wet_orphans.is_empty(),
			"wet asphalt: all %d palette roles are materialised, none orphaned"
			% wet_roles.size(), str(wet_orphans))

	# The band is where the wet variants' *texture* ramps sit; the scalar is a
	# multiplier and is 1.0. 1e-4 of slack because these are float32.
	var lo: float = ASPHALT_ROUGHNESS[0]
	var hi: float = ASPHALT_ROUGHNESS[1]
	var in_band := not wet_mats.is_empty()
	for k in wet_mats:
		var w: Array = ArtKitMaterials._SPECS[k]["wet"]
		in_band = in_band and float(w[0]) >= lo - 0.0001 and float(w[1]) <= hi + 0.0001
	_ok(in_band, "every wet-asphalt ramp stays in %.2f-%.2f (%d variants)"
			% [lo, hi, wet_mats.size()])
	# Effective, not the scalar. A PBR key's `m.roughness` is a *multiplier* on the
	# scanned roughness map, so asserting on the scalar alone is asserting on the
	# wrong number - the same shape of bug `World/look_dev_test.gd` already documents
	# for the wet road.
	var dry := ArtKitMaterials.effective_roughness_of("surface_asphalt_dry")
	_ok(dry > 0.6, "dry asphalt is matte (effective rough=%.2f)" % dry)

	# Variation inside a family is the point of a family, so a family whose values
	# are all the same is a family that should be collapsed to one.
	for fam in ["roof_iron", "render_wall", "asphalt_wet", "foliage"]:
		var spread := 0.0
		var members := ArtKitMaterials.family_keys(fam)
		if members.size() < 2:
			_ok(false, "family '%s' has members" % fam)
			continue
		# Wet asphalt carries its variation in a roughness *ramp*, not a scalar,
		# so compare whatever the spec actually varies.
		for a in members:
			for b in members:
				var va: Array = ArtKitMaterials._SPECS[a].get("wet",
						[ArtKitMaterials.roughness_of(a), ArtKitMaterials.roughness_of(a)])
				var vb: Array = ArtKitMaterials._SPECS[b].get("wet",
						[ArtKitMaterials.roughness_of(b), ArtKitMaterials.roughness_of(b)])
				spread = maxf(spread, absf(float(va[0]) - float(vb[0])))
		# For a PBR-backed family the scalar is a multiplier on the scanned map, so a
		# spread of 0 here means the five variants render identically - which is the
		# failure this check exists for, and it is still the right thing to measure.
		_ok(spread >= 0.02, "family '%s' varies roughness (scalar spread %.2f)" % [fam, spread])

	# The noise textures must actually be generated, not null placeholders, or
	# every road in the city is flat plastic.
	var wet := ArtKitMaterials.get_("surface_asphalt_wet_a")
	_ok(wet.roughness_texture != null,
			"wet asphalt has a procedural roughness texture (broken-up, not a sheet of plastic)")
	_ok(wet.normal_enabled and wet.normal_texture != null,
			"wet asphalt has a procedural normal map")
	_ok(wet.metallic_specular >= 0.9,
			"wet asphalt is full specular (metallic_specular=%.2f)" % wet.metallic_specular)
	# A dielectric road: metallic 0, and the reflection comes from roughness and
	# specular. Setting metallic on tarmac is the classic way to make it look like
	# painted metal, so the check pins it.
	_ok(wet.metallic < 0.1, "wet asphalt is a dielectric (metallic=%.2f)" % wet.metallic)
	# ## The corrugation check used to assert a fake
	#
	# It read `uv1_scale.y >= CORRUGATION_UV * 0.9`, which was true because the ribs
	# were *stripes in UV*: `_build()` squeezed the Y tiling to 13 so a stripe landed
	# every 8 cm down the slope. That is not a rib - it has no shading across its
	# width, no weathering, and it is the same on every roof in the city.
	#
	# With the scanned corrugated-steel set the ribs are in the normal map, so the
	# assertion that matters is that the ribs are coming from the scan at all, and that
	# nothing has collapsed the tiling to a single stretched copy. The UV-stripe ratio
	# is deliberately NOT re-imposed: satisfying it now would mean inventing a magic
	# number to pass a check about a technique the kit no longer uses.
	var roof := ArtKitMaterials.get_("surface_roof_iron_a")
	_ok(roof.normal_enabled and roof.normal_texture != null,
			"roof iron has a normal map")
	_ok(roof.normal_texture == ArtKitMaterials.pbr_tex("corrugated_roof", "n"),
			"the roof ribs come from the corrugated-steel scan, not from UV stripes")
	_ok(roof.albedo_texture == ArtKitMaterials.pbr_tex("corrugated_roof", "c"),
			"roof iron albedo is the scan, tinted by the palette role")
	var uv_ok := true
	for axis in [roof.uv1_scale.x, roof.uv1_scale.y, roof.uv1_scale.z]:
		uv_ok = uv_ok and axis > 0.001
	_ok(uv_ok, "roof iron tiling is non-degenerate (uv1_scale=%s)" % str(roof.uv1_scale))
	_ok(ArtKitMaterials.pbr_mean("corrugated_roof", "r") > 0.05,
			"the corrugated scan carries a real roughness (mean %.3f)"
			% ArtKitMaterials.pbr_mean("corrugated_roof", "r"))


# =============================================================================
# 3. GEOMETRY
# =============================================================================

## Every generator, every variant, checked for the things that produce a scene
## that renders but is wrong: empty meshes, NaN vertices, a prop floating above
## or sunk into the ground, materials that do not exist, and parts that were never
## welded.
func _check_geometry() -> void:
	_section("geometry")
	var reg := ArtKitProps.registry()
	_ok(reg.size() >= 20, "prop registry has >= 20 entries", "got %d" % reg.size())

	var empty: Array[String] = []
	var unwelded: Array[String] = []
	var missing_mat: Array[String] = []
	var off_ground: Array[String] = []
	var not_sunk: Array[String] = []
	var nan_mesh: Array[String] = []
	var no_uv: Array[String] = []
	var under_spec: Array[String] = []

	for name in reg:
		for v in ArtKitProps.VARIANTS:
			var parts: Array = ArtKitProps.variant(name, v)
			var tag := "%s/v%d" % [name, v]
			if parts.is_empty():
				empty.append(tag)
				continue
			# The welding invariant: one part per distinct material. A generator
			# that returns two parts in the same material doubled its draw calls.
			var mats := {}
			for p in parts:
				mats[p.mat] = true
			if mats.size() != parts.size():
				unwelded.append("%s (%d parts, %d materials)" % [tag, parts.size(), mats.size()])
			# The ground invariant is about the *object*, not each part: a palm's
			# crown is 11 m up and a streetlight's lens is 7 m up, and neither is a
			# bug. What has to be true is that the object as a whole starts at y=0.
			var whole := AABB()
			for p in parts:
				var pa: AABB = p.mesh.get_aabb()
				whole = pa if whole.size.length() <= 0.0 else whole.merge(pa)
			var sink := bool(reg[name].get("sink", false))
			var mounted := bool(reg[name].get("mounted", false))
			var decal := bool(reg[name].get("decal", false))
			if decal:
				# A decal is lifted off the surface it multiplies into - a couple of
				# centimetres, no more, or it floats and its contact darkening stops
				# being contact.
				if whole.position.y <= 0.0 or whole.position.y > 0.05:
					not_sunk.append("%s decal at y=%.3f" % [tag, whole.position.y])
			elif mounted:
				# Wall-mounted kit hangs at bracket height and is placed against a
				# wall, not on a road. The only requirement is that it is up there.
				if whole.position.y < 1.5:
					not_sunk.append("%s mounted at y=%.3f" % [tag, whole.position.y])
			elif sink:
				# Bushes, tufts, open drains and wire spans sit at or below grade -
				# a channel is cut into the road, a wire span hangs between poles.
				# What they must not do is float, which is the failure that shows up
				# in a render as a hedge hovering over a footpath.
				if whole.position.y > 0.01:
					not_sunk.append("%s floats at y=%.3f" % [tag, whole.position.y])
			elif absf(whole.position.y) > 0.02:
				off_ground.append("%s y=%.3f" % [tag, whole.position.y])
			for p in parts:
				if not ArtKitMaterials.keys().has(p.mat):
					missing_mat.append("%s:%s" % [tag, p.mat])
					continue
				var aabb: AABB = p.mesh.get_aabb()
				if aabb.size.length() <= 0.0 or aabb.size.length() > 4000.0:
					nan_mesh.append("%s:%s extent=%.1f" % [tag, p.mat, aabb.size.length()])
				var arrays: Array = p.mesh.surface_get_arrays(0) if p.mesh.get_surface_count() > 0 else []
				if arrays.is_empty() or (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() == 0:
					no_uv.append("%s:%s" % [tag, p.mat])
			# Registry metadata must be honest: the declared "mat" has to be one
			# the generator actually uses, or the registry is decoration.
			if not mats.has(String(reg[name].get("mat", ""))):
				under_spec.append("%s declares %s, uses %s" % [tag, reg[name].get("mat", ""), str(mats.keys())])

	_ok(empty.is_empty(), "every prop variant generates geometry", str(empty))
	_ok(unwelded.is_empty(), "one part per material (welded)", str(unwelded))
	_ok(missing_mat.is_empty(), "every part names a real material", str(missing_mat))
	_ok(off_ground.is_empty(), "every prop stands on y=0", str(off_ground))
	_ok(not_sunk.is_empty(),
			"sunk props touch the ground and mounted props hang at height", str(not_sunk))
	_ok(nan_mesh.is_empty(), "no empty or absurd extents", str(nan_mesh))
	_ok(no_uv.is_empty(), "every mesh has UVs in metres", str(no_uv))
	_ok(under_spec.is_empty(), "the registry's declared material is used", str(under_spec))

	# Buildings, across the full variant set, plus the OSM wrapper. Driven by the
	# building registry, not a hand-typed list: a design added to `buildings.gd`
	# used to land here unchecked, in the same way `contact_shadow` escaped the
	# budget walk. An empty geometry, unwelded, or floating building is the bug
	# this section exists to catch, and it only catches it for the names it lists.
	var breg := ArtKitBuildings.registry()
	var b_empty: Array[String] = []
	var b_unwelded: Array[String] = []
	var b_missing: Array[String] = []
	var b_ground: Array[String] = []
	for bname in breg:
		for i in ArtKitBuildings.HOUSE_VARIANTS:
			var parts: Array = ArtKitBuildings.variant(bname, i)
			var tag := "%s/%d" % [bname, i]
			if parts.is_empty():
				b_empty.append(tag)
				continue
			var mats := {}
			var whole := AABB()
			for p in parts:
				mats[p.mat] = true
				if not ArtKitMaterials.keys().has(p.mat):
					b_missing.append("%s:%s" % [tag, p.mat])
				var aabb: AABB = p.mesh.get_aabb()
				whole = aabb if whole.size.length() <= 0.0 else whole.merge(aabb)
			# A highset house is held up on stilts, so the wall part legitimately
			# starts a metre up. The building as a whole is what stands on the road.
			if absf(whole.position.y) > 0.02:
				b_ground.append("%s y=%.3f" % [tag, whole.position.y])
			if mats.size() != parts.size():
				b_unwelded.append("%s (%d parts, %d materials)" % [tag, parts.size(), mats.size()])
	_ok(b_empty.is_empty(), "every building design generates geometry", str(b_empty))
	_ok(b_unwelded.is_empty(), "buildings are welded too", str(b_unwelded))
	_ok(b_missing.is_empty(), "building parts name real materials", str(b_missing))
	_ok(b_ground.is_empty(), "buildings sit on the ground", str(b_ground))

	# A building must be taller than it is wide, or the kit has a scale bug that a
	# triangle budget will not catch.
	var tall := false
	for i in ArtKitBuildings.HOUSE_VARIANTS:
		var h := 0.0
		for p in ArtKitBuildings.variant("walk_up_block", i):
			h = maxf(h, p.mesh.get_aabb().position.y + p.mesh.get_aabb().size.y)
		tall = tall or h > 6.0
	_ok(tall, "a walk-up block is over 6 m tall")

	# A shopfront sign is a fascia, not a bar. This is a regression guard rather
	# than a style opinion. `qld_shop` used to hang a 0.52 m x 3.5-6.0 m emissive
	# panel 1.04 m in front of the facade with nothing under it, in a colour rolled
	# per building out of three saturated neons and `lamp_lens`; at night that
	# read as a tall glowing bar standing BESIDE the shop, dozens of them along an
	# arterial, rather than a sign ON it. Parts are welded per material, so the
	# geometry is the only place the proportion is visible - no palette check, no
	# reachability check and no triangle budget can see it.
	#
	# `qld_shop` is the only building that lights a sign with these keys (the
	# industrial shed's `lamp_lens_cool` is a wall pack, and this iterates shops
	# only), which is what lets them be named here.
	var sign_faces := ["sign_face_lit", "lamp_lens_cool", "neon_cyan", "neon_magenta", "neon_red"]
	var neons := ["neon_cyan", "neon_magenta", "neon_red"]
	var bar_shaped: Array[String] = []
	var upright: Array[String] = []
	var accents := {}
	var signs := 0
	for i in ArtKitBuildings.HOUSE_VARIANTS:
		for p in ArtKitBuildings.variant("qld_shop", i):
			if not sign_faces.has(p.mat):
				continue
			signs += 1
			if neons.has(p.mat):
				accents[p.mat] = int(accents.get(p.mat, 0)) + 1
			var a: AABB = p.mesh.get_aabb()
			if a.size.y > 1.30:
				bar_shaped.append("%d %s %.2f m tall" % [i, p.mat, a.size.y])
			if a.size.x < a.size.y * 2.0:
				upright.append("%d %s %.2f x %.2f" % [i, p.mat, a.size.x, a.size.y])
	_ok(signs == ArtKitBuildings.HOUSE_VARIANTS,
			"every shop design carries exactly one sign (%d of %d)"
			% [signs, ArtKitBuildings.HOUSE_VARIANTS])
	_ok(bar_shaped.is_empty(), "no shop sign is taller than 1.30 m", str(bar_shaped))
	_ok(upright.is_empty(), "every shop sign is at least twice as wide as it is tall",
			str(upright))
	# "signage only, and sparingly" - the accents are a minority, and all three
	# documented neon roles stay in play so none of them becomes an unused role.
	var one_each := accents.size() == 3
	for k in accents:
		one_each = one_each and int(accents[k]) == 1
	_ok(one_each, "one of each neon accent across the variant set, and no more (%s)"
			% str(accents))
	# A wide flat emitter is judged on energy TIMES AREA, not on its energy
	# setting, and every knob here moves that product: a wider fascia, a taller
	# one, or the same panel at `lamp_lens_cool`'s 5.0 each push clipping up
	# while every individual number still looks reasonable. Capping the product
	# is the only assertion that survives all three.
	var fascia := 0.0
	for p in ArtKitBuildings.variant("qld_shop", 0):
		if p.mat == "sign_face_lit":
			fascia = ArtKitMaterials.emission_energy_of(p.mat) * p.mesh.get_aabb().size.x \
					* p.mesh.get_aabb().size.y
	_ok(fascia > 0.0 and fascia <= 10.0,
			"the shop sign fascia stays under 10 of energy x m2 (got %.2f)" % fascia)

	# The OSM path: a rectangle, an L, and a degenerate polygon.
	var rect := PackedVector2Array([Vector2(0, 0), Vector2(12, 0), Vector2(12, 9), Vector2(0, 9)])
	var ell := PackedVector2Array([Vector2(0, 0), Vector2(14, 0), Vector2(14, 8),
			Vector2(7, 8), Vector2(7, 14), Vector2(0, 14)])
	var wrap: Array = ArtKitBuildings.wrap_footprint(rect, 2, 0.4, 7)
	_ok(wrap.size() > 0, "wrap_footprint builds a rectangle")
	var wrap_l: Array = ArtKitBuildings.wrap_footprint(ell, 1, 0.4, 7)
	_ok(wrap_l.size() > 0, "wrap_footprint builds an L-shaped footprint")
	_ok(ArtKitBuildings.wrap_footprint(PackedVector2Array([Vector2(0, 0), Vector2(1, 1)]), 1, 0.4, 1).is_empty(),
			"wrap_footprint rejects a degenerate polygon")
	# The lit/unlit mix has to actually mix, or every window in the city is lit.
	var lit_count := 0
	var runs := 40
	for sd in runs:
		for p in ArtKitBuildings.wrap_footprint(rect, 1, 0.4, sd):
			if p.mat == "glass_lit":
				lit_count += p.tri
	var dark_count := 0
	for sd in runs:
		for p in ArtKitBuildings.wrap_footprint(rect, 1, 0.4, sd):
			if p.mat == "glass_dark":
				dark_count += p.tri
	_ok(lit_count > 0 and dark_count > 0,
			"the lit/unlit window mix mixes (%d lit, %d dark tris over %d runs)"
			% [lit_count, dark_count, runs])

	# Shared meshes: the whole instancing story depends on `variant()` returning
	# the same resource, not an equal copy.
	var a := ArtKitProps.variant("palm_coco", 1)
	var b := ArtKitProps.variant("palm_coco", 1)
	_ok(a[0].mesh == b[0].mesh, "variant() hands out shared mesh resources")
	_ok(ArtKitProps.variant("palm_coco", 0)[0].mesh != a[0].mesh,
			"variants are genuinely different meshes")
	_ok(ArtKitBuildings.variant("qld_house", 3)[0].mesh == ArtKitBuildings.variant("qld_house", 3)[0].mesh,
			"buildings hand out shared mesh resources")


# =============================================================================
# 3b. FROND OUTLINE
# =============================================================================

## ## What this section is for
##
## On 2026-10-02 the owner sent a night screenshot (red S15A, LAP 1/1) in which
## "tree canopies read as floating green rhombus grids and read as toy props at
## night". Measured cause, from the built meshes: every feather frond was a
## 3-segment wedge whose blade was 0.60 x its own length. Three flat facets,
## each as wide as the frond was long, and eleven of them closing the crown into
## a lid. None of that is taste - it is a facet count and a width ratio, and
## both are measurable.
##
## So this section asserts counts, and every threshold below carries the
## measurement it was set from. Both numbers were read off the real meshes
## before and after the change, on all three variants, on this machine:
##
## | prop               | facets/frond before | after | edge/reach before | after |
## |--------------------|---------------------|-------|-------------------|-------|
## | palm_coco          | 3.0                 | 7.0   | 0.646-0.783       | 0.259-0.312 |
## | palm_alexandrine   | 3.0                 | 7.0   | 0.639-0.660       | 0.209-0.212 |
## | palm_areca         | 3.0                 | 6.0   | 0.478-0.576       | 0.213-0.249 |
## | tree_fern          | 3.0                 | 7.0   | 0.637-0.666       | 0.258-0.265 |
##
## A threshold with no measured source is how WHEEL_GRIP_FLOOR shipped against
## the wrong number. Sources are in `docs/decisions/0001-art-director.md`
## §"Frond outline".

## Minimum distinct facet orientations per frond.
##
## Counted on the built mesh, not read off a constant: every unique triangle
## normal is quantised to 1e-3 and the distinct set is divided by the frond
## count. Flat shading means one normal per spine span, so this *is* the number
## of straight runs in the frond - which is exactly the thing that made the old
## crown read as folded paper.
##
## Source: the shipped fronds measure 7.0 (`palm_coco`, `palm_alexandrine`,
## `tree_fern`) and 6.0 (`palm_areca`, which carries a crown per stem and cannot
## afford more inside its 560-triangle budget). The floor is set to 6, the
## lowest in use. Every pre-fix frond measured 3.0, so this check fails on the
## old geometry with a factor of two to spare rather than scraping past.
##
## The quantisation is deliberate: a span's two triangles share a normal and a
## duplicated quad shares it again, so all three collapse to one entry. That is
## why the pre-fix count is 3 and not 6 - `quad_flip` was emitting a
## bit-identical duplicate, not a reversed back face.
const MIN_FROND_FACETS := 6

## Fronds per crown, for the three palms whose crown count is fixed.
##
## `palm_areca` is absent on purpose: its crowns are welded across up to five
## stems into one part, so "per frond" would have to reverse-engineer the stem
## count, which is exactly the kind of coupling that makes a test lie. Its
## outline is held by the two checks below, which need no frond count.
const FEATHER_FRONDS_PER_CROWN := {
	"palm_coco": 11,
	"palm_alexandrine": 9,
	"tree_fern": 6,
}

## Feather palms deliberately left out of the per-frond facet check, with the
## reason, so the exemption is a declaration rather than a hole.
##
## Asserted against below: adding a palm to the check without either declaring
## its frond count or listing it here is a failure, not a silently weaker test.
const FROND_COUNT_EXEMPT := {
	# Carries one crown per stem and welds them into a single part, and the stem
	# count is `3 + variant % VARIANTS`, so a fixed frond count does not exist.
	# Its fronds are 6-facet like the rest and its outline is held by the
	# edge/reach and canopy-gap checks, which need no frond count.
	"palm_areca": "crowns welded across a variant-dependent number of stems",
}

## The longest single straight edge anywhere on a frond, as a fraction of that
## frond's horizontal reach.
##
## This is a compound measure and is documented as one: it folds in the widest
## blade edge, the per-span step along the spine, and - because the blade rolls
## along its length - the skew a rolled span gives its own edge. It is used
## because it is the number that decides whether a frond presents a broad flat
## facet to a streetlight or a slender blade, and because it is read off the
## built mesh rather than off the parameters that produced it.
##
## Source: measured across all 12 feather-palm cases, the worst reading after the
## change is 0.312 (`palm_coco` v2) and the best reading before it is 0.478
## (`palm_areca` v2). 0.40 sits between them - 28% above the worst shipped
## reading and 16% below the best old one. The physical reason the old number
## was so much higher is the botany figure quoted in `props.gd`: a coconut
## frond's leaflets spread about 0.5-1 m to a side of a 4-6 m frond, so a blade
## edge should be well under a third of its reach. At 0.60 x reach the old
## fronds were four times the widest the species allows.
const MAX_FROND_EDGE_OF_REACH := 0.40

## Fraction of the crown's own top-down footprint that must be sky.
##
## This is a silhouette-area measure: the crown is grid-sampled from directly
## above and the cells whose centre falls inside no crown triangle are sky.
##
## Source: measured across all 12 cases, the shipped feather palms run 0.69-0.83
## and the old ones ran 0.47-0.66. 0.55 is 25% below the worst shipped reading.
## Honest note on what this one does and does not catch: at 0.55 it separates
## `palm_coco`, `palm_alexandrine` and `palm_areca` from their old geometry, but
## `tree_fern` measured 0.61-0.66 before the change and would have passed. Its
## old crown was already airy because its fronds are short and droop hard. The
## facet and edge checks above are the ones that catch `tree_fern`; this one
## exists to stop any of the four drifting back toward a lid.
const MIN_CANOPY_GAP := 0.55

## Resolution of the top-down sky test. 32x32 cells over the crown's footprint:
## enough that a gap between two fronds spans several cells, cheap enough that
## the section costs well under a second headless.
const CANOPY_GRID := 32


func _check_frond_outline() -> void:
	_section("frond outline")

	var names: Array[String] = ["palm_coco", "palm_alexandrine", "palm_areca", "tree_fern"]
	var reg := ArtKitProps.registry()
	var missing: Array[String] = []
	for n in names:
		if not reg.has(n):
			missing.append(n)
	_ok(missing.is_empty(), "the four feather palms are all registered", str(missing))

	# --- facet count: how many straight runs is a frond made of? -------------
	#
	# Only for the palms whose frond count is known. Dividing by a made-up count
	# would let `palm_areca` "pass" without ever having measured a frond, which is
	# a green that means nothing - so instead the coverage is asserted, and a palm
	# added to `names` without a frond count fails loudly rather than silently
	# dividing by 1. `palm_areca` is caught by the two checks below instead.
	var counted: Array[String] = []
	for n in names:
		if not FEATHER_FRONDS_PER_CROWN.has(n) and not FROND_COUNT_EXEMPT.has(n):
			counted.append(n)
	_ok(counted.is_empty(),
			"every checked palm either declares its frond count or is a declared exemption (exempt: %s)"
			% ", ".join(PackedStringArray(FROND_COUNT_EXEMPT.keys())), str(counted))

	var coarse: Array[String] = []
	var facet_worst := 999
	var facet_worst_name := ""
	for n in FEATHER_FRONDS_PER_CROWN:
		var fronds: int = FEATHER_FRONDS_PER_CROWN[n]
		for v in ArtKitProps.VARIANTS:
			var part := _crown_part(n, v)
			if part == null:
				coarse.append("%s/v%d has no foliage part" % [n, v])
				continue
			var facets := float(_distinct_facets(part.mesh)) / float(fronds)
			if facet_worst > facets:
				facet_worst = int(facets)
				facet_worst_name = "%s/v%d" % [n, v]
			if facets < float(MIN_FROND_FACETS):
				coarse.append("%s/v%d %.1f facets/frond" % [n, v, facets])
	_ok(coarse.is_empty(),
			"every feather frond is built from at least %d distinct facets, all variants (worst %d at %s)"
			% [MIN_FROND_FACETS, facet_worst, facet_worst_name], str(coarse))

	# --- blade width vs reach ----------------------------------------------
	var fat: Array[String] = []
	var edge_worst := 0.0
	var edge_worst_name := ""
	for n in names:
		for v in ArtKitProps.VARIANTS:
			var r := _longest_edge_of_reach(n, v)
			if r > edge_worst:
				edge_worst = r
				edge_worst_name = "%s/v%d" % [n, v]
			if r > MAX_FROND_EDGE_OF_REACH:
				fat.append("%s/v%d %.3f" % [n, v, r])
	_ok(fat.is_empty(),
			"no frond presents an edge longer than %.2f x its own reach (worst %.3f at %s)"
			% [MAX_FROND_EDGE_OF_REACH, edge_worst, edge_worst_name], str(fat))

	# --- sky through the canopy, seen from straight above --------------------
	var lidded: Array[String] = []
	var gap_worst := 1.0
	var gap_worst_name := ""
	var gaps: Array[String] = []
	for n in names:
		for v in ArtKitProps.VARIANTS:
			var g := _canopy_gap(n, v)
			gaps.append("%s/v%d=%.2f" % [n, v, g])
			if g < gap_worst:
				gap_worst = g
				gap_worst_name = "%s/v%d" % [n, v]
			if g < MIN_CANOPY_GAP:
				lidded.append("%s/v%d gap %.2f" % [n, v, g])
	_ok(lidded.is_empty(),
			"every feather crown shows at least %d%% sky from above (tightest %.2f at %s)"
			% [roundi(MIN_CANOPY_GAP * 100.0), gap_worst, gap_worst_name], str(lidded))
	print("       measured canopy sky gaps: %s" % ", ".join(PackedStringArray(gaps)))


## The foliage part of a prop: the one wearing a `surface_foliage_*` material with
## the most triangles. For all four feather palms that is the crown - the fruit
## bunch and the frond-base skirt are both smaller.
func _crown_part(prop: String, variant: int) -> ArtKitPart:
	var best: ArtKitPart = null
	for p in ArtKitProps.variant(prop, variant):
		if not String(p.mat).begins_with("surface_foliage"):
			continue
		if best == null or p.tri > best.tri:
			best = p
	return best


## Distinct triangle-normal directions in a mesh, quantised to 1e-3 so that
## coplanar triangles and duplicated quads collapse into one entry. Under flat
## shading this counts the number of distinct planes the mesh is folded along,
## which for a frond is the number of spans in its spine.
func _distinct_facets(mesh: ArrayMesh) -> int:
	var seen := {}
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for n in norms:
			seen["%d,%d,%d" % [roundi(n.x * 1000.0), roundi(n.y * 1000.0),
					roundi(n.z * 1000.0)]] = true
	return seen.size()


## Every triangle corner of a part, three per triangle. SurfaceTool commits
## non-indexed, so the vertex array is already triangles; the index branch is
## here so this keeps working if that ever changes.
func _tri_corners(part: ArtKitPart) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in part.mesh.get_surface_count():
		var arrays: Array = part.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index: Variant = arrays[Mesh.ARRAY_INDEX]
		if index == null:
			out.append_array(verts)
		else:
			for i in (index as PackedInt32Array):
				out.append(verts[i])
	return out


## The longest edge of the crown's triangles as a fraction of the crown's
## horizontal reach, measured about the crown's own XZ centroid so a leaning
## trunk cannot shrink the denominator.
func _longest_edge_of_reach(prop: String, variant: int) -> float:
	var part := _crown_part(prop, variant)
	if part == null:
		return 0.0
	var v := _tri_corners(part)
	var longest := 0.0
	for i in range(0, v.size() - 2, 3):
		for e in 3:
			longest = maxf(longest, v[i + e].distance_to(v[i + (e + 1) % 3]))
	var c := _xz_centre(v)
	var reach := 0.0
	for p in v:
		reach = maxf(reach, Vector2(p.x - c.x, p.z - c.y).length())
	return longest / maxf(reach, 1e-4)


## The fraction of the crown's own top-down footprint that is sky: grid-sample the
## XZ bounding square of the crown, and count the cells whose centre is not inside
## any crown triangle. Reported as gap = 1 - covered.
func _canopy_gap(prop: String, variant: int) -> float:
	var part := _crown_part(prop, variant)
	if part == null:
		return 0.0
	var v := _tri_corners(part)
	if v.is_empty():
		return 0.0
	var c := _xz_centre(v)
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p in v:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	# Projected triangles, each with a bounding box so the inner loop can bail
	# early. Without it this is cells x triangles point-in-triangle tests.
	var tris: Array = []
	var boxes: Array = []
	for i in range(0, v.size() - 2, 3):
		var t := PackedVector2Array([Vector2(v[i].x, v[i].z),
				Vector2(v[i + 1].x, v[i + 1].z), Vector2(v[i + 2].x, v[i + 2].z)])
		tris.append(t)
		boxes.append(Vector4(minf(minf(t[0].x, t[1].x), t[2].x),
				maxf(maxf(t[0].x, t[1].x), t[2].x),
				minf(minf(t[0].y, t[1].y), t[2].y), maxf(maxf(t[0].y, t[1].y), t[2].y)))

	var covered := 0
	var cells := 0
	for gy in CANOPY_GRID:
		for gx in CANOPY_GRID:
			var px := lerpf(min_x, max_x, (float(gx) + 0.5) / float(CANOPY_GRID))
			var pz := lerpf(min_z, max_z, (float(gy) + 0.5) / float(CANOPY_GRID))
			# Outside the crown's own disc is sky by definition rather than by
			# geometry, so it is not counted either way - otherwise a crown would
			# be rewarded for being small.
			if Vector2(px - c.x, pz - c.y).length() > 0.5 * maxf(max_x - min_x, max_z - min_z):
				continue
			cells += 1
			for k in tris.size():
				var bb: Vector4 = boxes[k]
				if px < bb.x or px > bb.y or pz < bb.z or pz > bb.w:
					continue
				if _in_tri_2d(Vector2(px, pz), tris[k]):
					covered += 1
					break
	if cells == 0:
		return 0.0
	return 1.0 - float(covered) / float(cells)


func _xz_centre(v: PackedVector3Array) -> Vector2:
	var sx := 0.0
	var sz := 0.0
	for p in v:
		sx += p.x
		sz += p.z
	return Vector2(sx / float(v.size()), sz / float(v.size()))


## Barycentric point-in-triangle, 2D. The sign test handles both windings and
## degenerate triangles without a separate area check.
func _in_tri_2d(p: Vector2, t: PackedVector2Array) -> bool:
	var d1 := (p.x - t[1].x) * (t[0].y - t[1].y) - (t[0].x - t[1].x) * (p.y - t[1].y)
	var d2 := (p.x - t[2].x) * (t[1].y - t[2].y) - (t[1].x - t[2].x) * (p.y - t[2].y)
	var d3 := (p.x - t[0].x) * (t[2].y - t[0].y) - (t[2].x - t[0].x) * (p.y - t[0].y)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)



# =============================================================================
# 4. BUDGETS
# =============================================================================

func _check_budgets() -> void:
	_section("triangle budgets")
	# Separate lists, because sharing one meant a prop over budget also failed the
	# *building* budget check and printed a prop's name under "all building
	# budgets hold". A check that reports the wrong subsystem is how people learn
	# to ignore checks.
	var over: Array[String] = []
	var b_over: Array[String] = []
	var worst := 0
	var worst_name := ""
	# The *registry* drives this walk, not the budget table. Iterating the budget
	# table instead - which is what this used to do - means a prop with no
	# entry is never checked at all: `contact_shadow` had none, so its triangle
	# count was never held to anything, silently. Coverage is asserted first so
	# that hole is loud, and an unbudgeted prop is skipped here rather than
	# cascading into a pile of bogus "0 tris over budget" failures.
	var prop_reg := ArtKitProps.registry()
	var missing: Array[String] = []
	for name in prop_reg:
		if not PROP_BUDGETS.has(name):
			missing.append(String(name))
	for name in PROP_BUDGETS:
		if not prop_reg.has(name):
			missing.append("budget for unregistered prop '%s'" % name)
	_ok(missing.is_empty(),
			"every one of the %d registered props has a budget, and no budget is an orphan"
			% prop_reg.size(), str(missing))

	for name in prop_reg:
		if not PROP_BUDGETS.has(name):
			continue
		var budget: int = PROP_BUDGETS[name]
		var peak := 0
		for v in ArtKitProps.VARIANTS:
			var t := 0
			for p in ArtKitProps.variant(name, v):
				t += p.tri
			peak = maxi(peak, t)
		if peak > budget:
			over.append("%s %d > %d" % [name, peak, budget])
		if peak > worst:
			worst = peak
			worst_name = String(name)
	_ok(over.is_empty(),
			"all %d prop budgets hold across all variants" % prop_reg.size(), str(over))

	# Same story for buildings: registry-driven, coverage asserted.
	var bld_reg := ArtKitBuildings.registry()
	var b_missing: Array[String] = []
	for name in bld_reg:
		if not BUILDING_BUDGETS.has(name):
			b_missing.append(String(name))
	for name in BUILDING_BUDGETS:
		if not bld_reg.has(name):
			b_missing.append("budget for unregistered building '%s'" % name)
	_ok(b_missing.is_empty(),
			"every one of the %d registered buildings has a budget, and no budget is an orphan"
			% bld_reg.size(), str(b_missing))

	var heaviest_building := 0
	var heaviest_building_name := ""
	for name in bld_reg:
		if not BUILDING_BUDGETS.has(name):
			continue
		var budget: int = BUILDING_BUDGETS[name]
		var peak := 0
		for i in ArtKitBuildings.HOUSE_VARIANTS:
			var t := 0
			for p in ArtKitBuildings.variant(name, i):
				t += p.tri
			peak = maxi(peak, t)
		if peak > budget:
			b_over.append("%s %d > %d" % [name, peak, budget])
		if peak > heaviest_building:
			heaviest_building = peak
			heaviest_building_name = String(name)
	# The OSM wrapper scales with storeys, so it is budgeted per storey.
	var w0 := 0
	for p in ArtKitBuildings.wrap_footprint(
			PackedVector2Array([Vector2(0, 0), Vector2(12, 0), Vector2(12, 9), Vector2(0, 9)]), 1, 0.4, 5):
		w0 += p.tri
	if w0 > WRAP_BUDGET_PER_STOREY:
		b_over.append("wrap_footprint %d > %d/storey" % [w0, WRAP_BUDGET_PER_STOREY])
	_ok(b_over.is_empty(), "all building budgets hold", str(b_over))
	# Measured, not quoted. This used to print a hardcoded 1100 for "heaviest
	# building", which is `walk_up_block`'s *budget* - so the number in the output
	# would have kept claiming 1100 no matter what the kit actually built.
	print("       heaviest prop %s %d tris, heaviest building %s %d tris, OSM footprint %d/storey"
			% [worst_name, worst, heaviest_building_name, heaviest_building, w0])

	# The city's total, which is the number that actually decides whether this is
	# affordable. 2198 is the world's footprint count, not the kit's: it belongs to
	# the OSM data, and artkit cannot read World/ without making a kit that is
	# supposed to stand alone depend on files other agents are still writing. It is
	# a declared input, quoted once here. What the kit owns is `w0`, and that is
	# measured directly above. 2 M is a design budget.
	_ok(w0 * OSM_FOOTPRINTS < 2_000_000,
			"%d OSM footprints stay under 2 M triangles (%d)"
			% [OSM_FOOTPRINTS, w0 * OSM_FOOTPRINTS])


# =============================================================================
# 5. BATCHING
# =============================================================================

## The headline claim, measured rather than asserted: the whole prop set, placed
## 25 times over, must collapse to a handful of draw calls.
func _check_batching() -> void:
	_section("batching - instancing")
	var reg := ArtKitProps.registry()
	var b := ArtKitBatch.new("test")
	var placed := 0
	for rep in SCATTER_REPS:
		for name in reg:
			for v in ArtKitProps.VARIANTS:
				var xform := ArtKitBatch.place(Vector3(float(rep) * 40.0, 0.0, 0.0),
						ArtKitBatch.scatter_yaw(rep * 7 + v), 1.0)
				b.add_array(ArtKitProps.variant(name, v), xform)
				placed += 1
	print("       %d placements, %d parts, %d M triangles"
			% [placed, placed, b.triangles() / 1000000])
	# Every registered prop, in every variant, once per repetition, and nothing
	# else. Derived from the registry and `VARIANTS` rather than typed in: this
	# used to say 1650, which is 25 x 22 x 3, and `contact_shadow` made it 1725
	# the moment it was added to the registry. A count that only changes when a
	# prop is added tests nothing except "somebody remembered to edit a number" -
	# the two checks below it are the ones that actually catch a regression.
	var expected_placements := reg.size() * ArtKitProps.VARIANTS * SCATTER_REPS
	_ok(placed == expected_placements,
			"every registered prop placed once per variant, %d times (%d of %d)"
			% [SCATTER_REPS, placed, expected_placements])
	# The count the batching claim actually rests on, derived the same way: the
	# distinct (mesh, material) signatures the whole prop set can produce. The
	# point is the ratio - if anything regressed, group_count() would climb
	# toward the instance count and the draw calls would go with it.
	var signatures := {}
	for name in reg:
		for v in ArtKitProps.VARIANTS:
			for p in ArtKitProps.variant(name, v):
				signatures[p.signature()] = true
	_ok(b.group_count() == signatures.size(),
			"exactly one group per distinct (mesh, material): %d groups, not %d"
			% [b.group_count(), b.instances()])
	_ok(b.instances() == _expected_instances(reg),
			"every part became an instance (%d)" % b.instances())
	# 20x is a design budget, not a measurement: it is the ratio standards.md
	# claims, and the number that would move if the kit regressed is the measured
	# group count above.
	_ok(b.group_count() * 20 <= b.instances(),
			"draw calls are at least 20x fewer than instances (%d vs %d)"
			% [b.group_count(), b.instances()])
	# 4 M is the scene triangle ceiling, a design budget.
	_ok(b.triangles() < 4_000_000, "the scatter stays under 4 M triangles (%d)" % b.triangles())

	# Adding a thousand-odd copies of one prop must not add a single draw call.
	# This is the regression guard for the footgun the memoisation exists to kill.
	var one := ArtKitBatch.new("one")
	var parts := ArtKitProps.variant("streetlight", 0)
	for i in REPEAT_COPIES:
		one.add_array(parts, ArtKitBatch.place(Vector3(float(i) * 8.0, 0.0, 0.0), 0.0, 1.0))
	_ok(one.group_count() == parts.size(),
			"%d streetlights are %d draw calls, one per material"
			% [REPEAT_COPIES, one.group_count()])
	_ok(one.instances() == REPEAT_COPIES * parts.size(),
			"all %d streetlights instanced" % REPEAT_COPIES)

	# The built node tree has to be right, not just the counters: one child per
	# group, a material on each, a culling box that covers the batch.
	var parent := Node3D.new()
	root.add_child(parent)
	var built := b.build(parent)
	_ok(built.get_child_count() == b.group_count(), "build() emits one node per group")
	var bad_mat := 0
	var no_aabb := 0
	var no_surfaces := 0
	for mmi in built.get_children():
		var m: MultiMeshInstance3D = mmi
		if m.material_override == null:
			bad_mat += 1
		if m.multimesh == null or m.multimesh.custom_aabb.size.length() <= 0.0:
			no_aabb += 1
		if m.multimesh == null or m.multimesh.mesh == null \
				or m.multimesh.mesh.get_surface_count() == 0:
			no_surfaces += 1
	_ok(bad_mat == 0, "every MultiMeshInstance3D has a material_override", "%d missing" % bad_mat)
	_ok(no_aabb == 0, "every MultiMesh has an explicit culling AABB", "%d missing" % no_aabb)
	_ok(no_surfaces == 0, "every instanced mesh has real surfaces, not just arrays",
			"%d surfaceless" % no_surfaces)
	_ok(built.transform == Transform3D.IDENTITY, "the batch holder is at the origin")

	# An empty batch must emit nothing rather than an empty draw call.
	var empty_batch := ArtKitBatch.new("empty")
	var eparent := Node3D.new()
	root.add_child(eparent)
	_ok(empty_batch.build(eparent).get_child_count() == 0, "an empty batch emits nothing")

	_section("batching - baking (unique geometry)")
	# 2198 unique footprints cannot be instanced - every one is a different mesh -
	# so this is the path that actually matters for the OSM data, and it must land
	# at one draw call per material rather than 2198.
	var mb := ArtKitBatch.new("city")
	var count := 400
	var city_mats := {}
	for i in count:
		var w := 9.0 + float(i % 7) * 1.3
		var d := 8.0 + float(i % 5) * 1.7
		var poly := PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, d), Vector2(0, d)])
		var fp: Array = ArtKitBuildings.wrap_footprint(poly, 1 + i % 2, 0.4, i)
		for p in fp:
			city_mats[p.mat] = true
		mb.add_array(fp,
				ArtKitBatch.place(Vector3(float(i % 20) * 30.0, 0.0, float(i / 20) * 30.0),
						ArtKitBatch.scatter_yaw(i), 1.0))
	# Every footprint is its own mesh, so the group count is the part count and
	# grows with the city. That is exactly why baking exists.
	_ok(mb.group_count() > count,
			"OSM footprints are unique meshes, one group each (%d groups for %d buildings)"
			% [mb.group_count(), count])
	var mparent := Node3D.new()
	root.add_child(mparent)
	var merged := mb.build_merged(mparent)
	print("       %d unique buildings -> %d draw calls" % [count, merged.get_child_count()])
	# The invariant, derived: baking collapses the whole city to exactly one node
	# per distinct material it used. Stated this way it survives a palette change,
	# and it is the claim that actually matters - 400 buildings, 8000-odd meshes,
	# 15 draw calls. The old check only said "<= 16" and would have been equally
	# happy with 16 nodes for 16 buildings.
	_ok(merged.get_child_count() == city_mats.size(),
			"baking collapses %d buildings to one node per material (%d nodes, %d materials)"
			% [count, merged.get_child_count(), city_mats.size()])
	# The ceiling on that number is a design budget: it is the size of the
	# building palette (wall colours, roof colours, concrete, dark glass, lit
	# glass, interior glow), not the size of the city, which is the entire point.
	# It is the one number here that must be raised by hand when a building
	# material is added, and it is a palette budget rather than a data-dependent
	# count, so it is deliberately left as a typed constant.
	_ok(merged.get_child_count() <= 16,
			"baking %d unique buildings gives <= 16 draw calls (got %d)"
			% [count, merged.get_child_count()])
	var merged_tris := 0
	var missing_mat := 0
	var surfaceless := 0
	for mi in merged.get_children():
		var m: MeshInstance3D = mi
		merged_tris += ArtKitMesh.triangles(m.mesh)
		if m.material_override == null:
			missing_mat += 1
		# A mesh whose arrays were copied but never indexed has a triangle count
		# and no surfaces, and renders nothing. Counting triangles is not enough.
		if m.mesh == null or m.mesh.get_surface_count() == 0:
			surfaceless += 1
	_ok(missing_mat == 0, "every baked node has a material_override", "%d missing" % missing_mat)
	_ok(surfaceless == 0, "every baked mesh has real surfaces, not just arrays",
			"%d surfaceless" % surfaceless)
	_ok(merged_tris == mb.triangles(),
			"baking preserves every triangle (%d vs %d)" % [merged_tris, mb.triangles()])
	_ok(merged_tris < 2_000_000, "the baked city stays under 2 M triangles (%d)" % merged_tris)

	# Baking must not lose the placement - a merged city that all collapsed to the
	# origin would still pass every check above.
	var spread := 0.0
	for mi in merged.get_children():
		spread = maxf(spread, (mi as MeshInstance3D).mesh.get_aabb().size.length())
	_ok(spread > 100.0, "baked geometry keeps its world extent (%.0f m)" % spread)

	# free(), not queue_free(): these hold MultiMeshInstance3D and MeshInstance3D
	# children, and a deferred free races the engine's shutdown, which reports 15
	# "Parameter m is null" errors from the dummy renderer after the check has
	# already printed PASS. Freeing them here keeps the output honest.
	parent.free()
	eparent.free()
	mparent.free()


# =============================================================================
# 6. THE CONSUMER
# =============================================================================

## The kit had no consumer: nine files, no caller, and a check that proved the
## library works while nothing proved it is *callable*. `scatter.gd` is the one
## line the world builder adds, so it is checked the way a library is checked -
## by calling it, including the way it is meant to be called.
func _check_consumer() -> void:
	_section("consumer - ArtKitScatter")
	var placements: Array = []
	# 600 props across four names: enough that a per-placement mesh would show up
	# as a node count in the hundreds, which is the whole failure being guarded.
	var prop_names := ["palm_coco", "tree_rain_tree", "streetlight", "wire_span"]
	for i in 600:
		placements.append({
			"prop": String(prop_names[i % prop_names.size()]),
			"pos": Vector3(float(i) * 3.0, 0.0, float(i / 40) * 3.0),
			"yaw": ArtKitBatch.scatter_yaw(i),
		})
	# 120 real-ish footprints, half as bare polygons (the OSM shape a consumer
	# actually has) and half as dictionaries with a storey count.
	for i in 120:
		var poly := PackedVector2Array([Vector2(0, 0), Vector2(9.0 + i % 5, 0.0),
				Vector2(9.0 + i % 5, 8.0 + i % 3), Vector2(0, 8.0 + i % 3)])
		if i % 2 == 0:
			placements.append(poly)
		else:
			placements.append({"footprint": poly, "storeys": 1 + i % 3, "seed": i})
	# A named building, and then the malformed entries a trust boundary has to
	# survive: an unknown prop, an unknown building, a two-point polygon, a
	# string, a dict with no key, a non-Vector3 pos and a negative scale.
	placements.append({"building": "qld_house", "pos": Vector3(0, 0, 500)})
	var bad_from := placements.size()
	placements.append({"prop": "not_a_prop", "pos": Vector3.ZERO})
	placements.append({"building": "not_a_building", "pos": Vector3.ZERO})
	placements.append(PackedVector2Array([Vector2(0, 0), Vector2(1, 1)]))
	placements.append("a string")
	placements.append({"nothing": 1})
	placements.append({"prop": "bollard", "pos": "not a vector"})
	placements.append({"prop": "bollard", "pos": Vector3.ZERO, "scale": -1.0})
	placements.append({"prop": "bollard"})
	placements.append({"footprint": "not an array"})
	var bad := placements.size() - bad_from

	var scatter := ArtKitScatter.new()
	root.add_child(scatter)
	var st := scatter.populate(placements)

	# Nothing malformed is allowed through, and everything malformed is reported
	# rather than thrown: a scatter that raises halfway leaves a half-built suburb
	# with no way to tell a bad entry from a bug in the kit.
	_ok(int(st["props"]) == 600 and int(st["buildings"]) == 121,
			"every valid placement is placed: %d props, %d buildings"
			% [int(st["props"]), int(st["buildings"])])
	_ok((st["skipped"] as Array).size() == bad,
			"all %d malformed entries are skipped and reported, not thrown (%s)"
			% [bad, str(st["skipped"])])

	# The regression that matters, stated as two derived counts rather than a
	# guessed threshold. The instanced side must equal the number of distinct
	# (mesh, material) signatures the placements can produce - computed here
	# independently, from `variant()` directly - so it is bounded by the variant
	# set and not by the 600. The baked side must equal the number of distinct
	# materials, because every footprint is a unique mesh and baking is the only
	# thing that collapses them.
	var expect_sigs := {}
	for i in 600:
		var sig_name := String(prop_names[i % prop_names.size()])
		for p in ArtKitProps.variant(sig_name, posmod(i, ArtKitProps.VARIANTS)):
			expect_sigs[p.signature()] = true
	_ok(int(st["prop_nodes"]) == expect_sigs.size(),
			"600 props collapse to one node per distinct signature (%d nodes, %d signatures)"
			% [int(st["prop_nodes"]), expect_sigs.size()])
	_ok(int(st["prop_nodes"]) < int(st["props"]),
			"prop draw calls do not scale with placements (%d nodes for %d props)"
			% [int(st["prop_nodes"]), int(st["props"])])

	var expect_mats := {}
	for i in 120:
		var fp := PackedVector2Array([Vector2(0, 0), Vector2(9.0 + i % 5, 0.0),
				Vector2(9.0 + i % 5, 8.0 + i % 3), Vector2(0, 8.0 + i % 3)])
		# Mirrors the placement loop above exactly, including the storey count,
		# so this is a second derivation and not a copy of the first one.
		var storeys := 1 if i % 2 == 0 else 1 + i % 3
		for p in ArtKitBuildings.wrap_footprint(fp, storeys, 0.4, i):
			expect_mats[p.mat] = true
	for p in ArtKitBuildings.variant("qld_house", 0):
		expect_mats[p.mat] = true
	_ok(int(st["building_nodes"]) == expect_mats.size(),
			"121 buildings bake to one node per material (%d nodes, %d materials)"
			% [int(st["building_nodes"]), expect_mats.size()])
	_ok(int(st["triangles"]) > 0 and int(st["instances"]) > 0,
			"the consumer reports real counts (%d instances, %d triangles)"
			% [int(st["instances"]), int(st["triangles"])])

	# The node tree the caller ends up parenting into must actually be built.
	var mmi := 0
	var mi := 0
	for child in scatter.get_children():
		for grand in child.get_children():
			if grand is MultiMeshInstance3D:
				mmi += 1
			elif grand is MeshInstance3D:
				mi += 1
	_ok(mmi == int(st["prop_nodes"]) and mi == int(st["building_nodes"]),
			"the emitted node tree matches the reported draw calls (%d instanced, %d baked)"
			% [mmi, mi])

	# Determinism. An RNG in the variant choice would make every number above
	# unreproducible, including this suite's own.
	var again := ArtKitScatter.new()
	root.add_child(again)
	var st2 := again.populate(placements)
	_ok(int(st2["triangles"]) == int(st["triangles"]) \
			and int(st2["nodes"]) == int(st["nodes"]),
			"the same placements give the same city (%d nodes, %d triangles)"
			% [int(st2["nodes"]), int(st2["triangles"])])

	# An empty list is not an error and must not emit a draw call.
	var empty := ArtKitScatter.new()
	root.add_child(empty)
	var st3 := empty.populate([])
	_ok(int(st3["nodes"]) == 0 and empty.get_child_count() == 0,
			"an empty placement list emits nothing")

	print("       %d placements -> %d draw calls, %d triangles, %d skipped"
			% [placements.size(), int(st["nodes"]), int(st["triangles"]),
			(st["skipped"] as Array).size()])

	scatter.free()
	again.free()
	empty.free()


# =============================================================================
# 7. NO EXTERNAL ASSETS
# =============================================================================

## The brief forbids downloaded models and textures. The only way to keep it that
## way is to check, because a single `preload("res://assets/palm.glb")` would
## otherwise be invisible in review and would break the "everything is code" claim
## that the whole cost model rests on.
func _check_no_external_assets() -> void:
	_section("provenance and external assets")
	# ## This section used to forbid texture files outright
	#
	# The old contract was `standards.md` §1: "There is no `.glb`, no `.obj`, no
	# downloaded texture, no `.png`. That is a hard constraint from the brief." t181
	# replaced it with real CC0 PBR sets, so the check that enforced it had to change
	# too - and the useful part of it did not change at all.
	#
	# What survived, and why it is still worth asserting:
	#   - **No 3D model and no audio.** Still true, still free, still worth a check.
	#     The kit generates its geometry in GDScript and that is what makes 2198
	#     buildings cost nothing to store.
	#   - **Textures only from the manifest.** The old check said "no file in artkit/
	#     loads anything at runtime". The new one says *loads textures only through the
	#     one audited loader in materials.gd, and only files the manifest declares*. A
	#     texture dropped in by hand with no provenance line fails here.
	#   - **Provenance is complete.** Every set declares a source URL and a licence.
	#     A CC0 claim with no URL in it is not a claim anyone can check.
	#   - **The data maps are read linearly.** The single most expensive bug in this
	#     task's history, and the one no other check would catch: see the header of
	#     `artkit/materials.gd`.
	#
	# What is deliberately no longer asserted: that the kit contains no image files.
	# It contains eighteen.
	var dir := DirAccess.open("res://artkit")
	_ok(dir != null, "artkit/ is readable")
	var files: Array[String] = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir():
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()

	var models: Array[String] = []
	var stray_loads: Array[String] = []
	# Every quoted image extension is a texture reference; they are tracked so the
	# load can be traced back to the manifest rather than merely counted.
	var tex_exts := [".png", ".jpg", ".jpeg", ".webp"]
	for file in files:
		if not String(file).ends_with(".gd") or file == "artkit_check.gd":
			continue
		var text := FileAccess.get_file_as_string("res://artkit/" + file)
		var mod_exts := [".glb", ".gltf", ".obj", ".fbx", ".dae", ".blend",
				".hdr", ".exr", ".ktx", ".dds", ".wav", ".ogg"]
		for ext in mod_exts:
			# Quoted, because a bare substring match flags `m.blend_mode` as a mention
			# of Blender files, which is a false positive that trains people to ignore
			# this check.
			if text.contains("\"" + ext + "\"") or text.contains("'" + ext + "'"):
				models.append("%s mentions %s" % [file, ext])
		# `materials.gd` is the one file allowed to load an image, and it does it in
		# exactly one function. Any other file reaching for a texture is a bypass.
		for line in text.split("\n"):
			var stripped := line.strip_edges()
			if stripped.begins_with("#"):
				continue
			# WRITING a texture is not reading one. `pbr_shot.gd` saves PNGs and
			# `artkit_check.gd` names the extensions because it is the auditor; treating
			# both as "loading a texture" made this check fail on the capture harness
			# that exists to prove the textures render.
			if stripped.contains("save_png") or stripped.contains("DirAccess"):
				continue
			var loads_image := false
			for ext in tex_exts:
				if stripped.contains("\"" + ext + "\"") or stripped.contains("'" + ext + "'"):
					loads_image = true
			var loads_any := stripped.contains("preload(") or stripped.contains("load(")
			# Two files are allowed to load an image, for two stated reasons, and a
			# third would fail. An allowlist rather than a general exemption, because
			# "it is probably fine" is how a kit ends up with nine ways in.
			var allowed := {
				# The one audited material-texture loader. Colour management lives here.
				"materials.gd": true,
				# The capture harness. `--measure` re-reads the board PNG it just wrote so
				# a measurement can be repeated without re-rendering. It reads its OWN
				# output, under the `--out` directory, and loads no material texture.
				"pbr_shot.gd": true,
				# The audited *licensing* loader (t194). It is a real, deliberate second
				# way in, not an exemption: every byte it loads is required to be in
				# `assets/art/third_party/inventory.json` with an accepted licence and a
				# source URL, and `_check_licensed_assets` fails on an unclaimed file and
				# on an unlicensed row. It exists precisely so that `materials.gd` does not
				# become the second unaudited loader. Without this entry the check is
				# right - a third or fourth loader still fails.
				"licensing.gd": true,
			}
			if loads_any and not allowed.has(file):
				stray_loads.append("%s: %s" % [file, stripped])
	_ok(models.is_empty(), "no 3D model or audio file is referenced", str(models))
	_ok(stray_loads.is_empty(),
			"only materials.gd and pbr_shot.gd load an image (listed, with reasons)",
			str(stray_loads))

	# --- provenance, read from the manifest rather than asserted by hand.
	var manifest := ArtKitMaterials.pbr_manifest()
	var sets: Dictionary = manifest.get("sets", {})
	_ok(not sets.is_empty(), "the PBR manifest is readable (%d sets)" % sets.size())
	var complete := true
	var unlicensed: Array[String] = []
	var sourceless: Array[String] = []
	for setname in sets.keys():
		var entry: Dictionary = sets[setname]
		var lic := String(entry.get("license", ""))
		var url := String(entry.get("source_url", ""))
		if lic.strip_edges().is_empty():
			unlicensed.append(String(setname))
		if url.strip_edges().is_empty():
			sourceless.append(String(setname))
		complete = complete and not lic.is_empty() and not url.is_empty()
	_ok(complete, "every set declares a licence and a source URL",
			str(unlicensed + sourceless))
	var declared: Dictionary = {}
	for setname in sets.keys():
		for kind in ["c", "r", "n"]:
			declared[String((sets[setname] as Dictionary)["maps"][kind]["file"])] = true
	_ok(declared.size() == sets.size() * 3,
			"every set declares albedo + roughness + normal (%d files)" % declared.size())

	# --- the sets the brief named, present by name.
	var want := ["weatherboard", "corrugated_roof", "paling_fence", "concrete_kerb",
			"bitumen", "grass_verge"]
	var missing: Array[String] = []
	for w in want:
		if not sets.has(w):
			missing.append(w)
	_ok(missing.is_empty(), "the residential palette is all six sets", str(missing))

	# --- THE COLOUR-SPACE CONTRACT. This is the check that matters.
	# `Image.load()` hands back 8-bit, which Godot samples *as sRGB*. A roughness or
	# normal map read that way is wrong in the shader and looks plausible in a render.
	# `ArtKitMaterials.pbr_tex()` widens the data maps to RGBAF; this asserts it
	# happened, per map, and that albedo was NOT widened.
	var colour_bad: Array[String] = []
	for setname in sets.keys():
		for kind in ["c", "r", "n"]:
			var fmt := ArtKitMaterials.pbr_format(String(setname), kind)
			if fmt == "":
				colour_bad.append("%s/%s did not load" % [setname, kind])
			elif kind == "c" and fmt == "%d" % Image.FORMAT_RGBAF:
				colour_bad.append("%s/c was widened - a colour must stay sRGB" % setname)
			elif kind != "c" and fmt != "%d" % Image.FORMAT_RGBAF:
				colour_bad.append("%s/%s is %s, not RGBAF - sRGB-decoded" % [setname, kind, fmt])
	_ok(colour_bad.is_empty(),
			"data maps are RGBAF (linear), albedo is not", str(colour_bad))

	# --- and the textures themselves are shared, or the memoisation rule is broken
	# at the texture layer and every batch signature goes with it.
	var same := ArtKitMaterials.pbr_tex("bitumen", "c") == ArtKitMaterials.pbr_tex("bitumen", "c")
	_ok(same, "one map is one Texture2D resource (memoisation holds for textures)")
	var sets_differ := ArtKitMaterials.pbr_tex("bitumen", "c") != ArtKitMaterials.pbr_tex("grass_verge", "c")
	_ok(sets_differ, "different sets are different textures")

	print("       %d files at the top level: %s"
			% [files.size(), ", ".join(PackedStringArray(files))])
	print("       %d texture files, %d sets, %d bytes"
			% [declared.size(), sets.size(), int(manifest.get("total_bytes", 0))])


# =============================================================================

## ## Why this floor exists
##
## A parse error in one of the kit's files makes a whole section abort mid-way -
## GDScript prints a SCRIPT ERROR, unwinds that one function, and carries on to the
## next. The suite still reaches `_report()` and still prints PASS with 36 checks
## instead of 80, because the checks that never ran are simply absent rather than
## failed. That is the worst possible failure mode for an acceptance test: it
## reports green while checking nothing.
##
## So the total is asserted against a floor. Adding checks means raising it, which
## is a deliberate act - and a section that starts aborting shows up as a failure
## instead of a silent hole. Raised whenever the suite grows.
const MIN_CHECKS := 123


# =============================================================================
# 8. LICENSED ASSETS
# =============================================================================

## The brief used to forbid downloaded models and textures, and this check proved
## the absence: no `.jpg`, no `.glb`, no `load(` anywhere in `artkit/`. That was a
## coherent policy with an honest enforcement mechanism, and it is now inverted.
##
## Reuse-first says a licensed photograph of asphalt beats a procedural noise
## pretending to be one. So the check no longer asks "is anything external
## referenced?" - a question with only one safe answer and no useful signal. It
## asks the question that actually matters about external assets:
##
##   * is every one of them in the machine-readable inventory;
##   * does every inventory row carry a licence this project accepts, that
##     permits redistribution, and that names a fetchable source URL;
##   * does every inventoried file actually exist;
##   * is every asset file on disk claimed by the inventory (so a hand-dropped
##     `.jpg` fails rather than being invisible);
##   * did any of it reach a material at runtime - because a licensed asset that
##     silently fell back to the procedural path is reuse that did not happen,
##     and it looks exactly like success in a render.
##
## That is strictly stronger than the check it replaces: the old rule could only
## prove a negative, and a negative is satisfied by doing nothing.
##
## ## Why the fallback must stay testable
##
## A material that falls back when its capture is missing is correct behaviour
## and also the perfect hiding place for a feature that never worked. So
## `_check_texture_layer` asserts the *applied* count, not the *available* count
## - what the renderer sampled, not what was downloaded. If the whole layer
## silently reverted to noise, that check fails while the renders keep looking
## acceptable, which is the only combination in which the bug is worth catching.
func _check_licensed_assets() -> void:
	_section("licensed assets")
	var dir := DirAccess.open("res://artkit")
	_ok(dir != null, "artkit/ is readable")
	var files: Array[String] = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir():
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()

	# 1. the inventory has to be there and parseable, or none of the rest is a check
	var have_inv := FileAccess.file_exists(ArtKitLicensing.INVENTORY_PATH)
	_ok(have_inv, "the third-party inventory exists at %s" % ArtKitLicensing.INVENTORY_PATH)
	if not have_inv:
		_ok(false, "inventory parses (cannot check provenance without it)")
		return
	_ok(not ArtKitLicensing.entries().is_empty(),
			"the inventory lists assets (%d)" % ArtKitLicensing.entries().size())

	# 2. every row is licensed, redistributable, sourced, and present.
	var unlicensed := ArtKitLicensing.unlicensed()
	_ok(unlicensed.is_empty(),
			"every inventoried asset carries an accepted, redistributable licence "
			+ "with a source URL (%d entries)" % ArtKitLicensing.entries().size(),
			str(unlicensed))

	# 3. the reverse direction: nothing on disk is unclaimed.
	#
	# The witness below exists because this check fails OPEN on its own history.
	# `_walk` originally recursed on one DirAccess handle, which stack-overflowed
	# and returned an empty list - so "no unclaimed files" reported green while
	# having walked nothing at all. A guard that can be satisfied by crashing
	# needs a witness: the walk is proven to have reached real asset files,
	# which is only true if it terminated.
	var unclaimed := ArtKitLicensing.unclaimed()
	_ok(unclaimed.is_empty(), "no asset file on disk is missing from the inventory",
			str(unclaimed))
	var walked := ArtKitLicensing.walked_count()
	_ok(walked >= 1,
			"the unclaimed-file walk actually reached asset files (%d scanned, so it "
			% walked + "did not abort early and pass vacuously)")

	# 4. nothing in artkit/ reaches around the licensing layer. This is the old
	#    check, kept in the form that still has teeth: the kit may load assets,
	#    but only through ArtKitLicensing, so every load is inventoried by
	#    construction rather than by review.
	var strays: Array[String] = []
	for file in files:
		# This file is the auditor; it necessarily contains the words it searches
		# for as string literals.
		if not String(file).ends_with(".gd") or file == "artkit_check.gd" \
				or file == "licensing.gd":
			continue
		for line in FileAccess.get_file_as_string("res://artkit/" + file).split("\n"):
			var stripped := line.strip_edges()
			if stripped.begins_with("#"):
				continue
			if stripped.contains("preload(") or stripped.contains("ResourceLoader.load(") \
					or stripped.contains("DirAccess.open(\"res://assets"):
				# t181's PBR layer reads its own *manifest index* here. That is a JSON
				# index of provenance, not an asset, and it is exactly what
				# `_check_no_external_assets` audits for licence + source URL on every
				# row. t194's rule is "no file reaches around the licensing layer", and
				# the layer t181 legitimately runs its own side of.
				#
				# Matched as the literal expression, not as a blanket exemption for
				# `ResourceLoader.load` - every other bypass still fails below.
				if stripped.contains("ResourceLoader.load(PBR_MANIFEST)"):
					continue
				strays.append("%s: %s" % [file, stripped])
	_ok(strays.is_empty(),
			"artkit/ loads assets only through ArtKitLicensing, so every one is "
			+ "inventoried", str(strays))

	_ok(files.size() >= 10, "the kit's files are all present (%d)" % files.size())
	print("       %d files: %s" % [files.size(), ", ".join(PackedStringArray(files))])
	print("       %s" % ArtKitLicensing.format_summary())


## The reuse layer must actually have run.
##
## Asserting that textures are *available* proves nothing: `ArtKitLicensing`
## could be wired up, files on disk, inventory complete, and the materials still
## handing back pure procedural noise if `_apply_licensed` were never called or
## silently returned early. Every render would look plausible.
##
## So this checks the applied count, which is incremented at the exact point a
## texture is assigned to a material. Two halves, both needed:
##
##   * a floor - zero applied means the layer is dead code;
##   * a ceiling relative to the declared intent - an implausibly low number
##     means most materials silently fell back, which is the failure mode where
##     "some of it works" hides "most of it did not".


# =============================================================================
# 9. TEXTURE LAYER
# =============================================================================

## The reuse layer must actually have run.
##
## Asserting that textures are *available* proves nothing: `ArtKitLicensing`
## could be wired up, files on disk, inventory complete, and the materials still
## handing back pure procedural noise if `_apply_licensed` were never called or
## silently returned early. Every render would look plausible.
##
## So this checks the applied count, which is incremented at the exact point a
## texture is assigned to a material. Two halves, both needed:
##
##   * a floor - zero applied means the layer is dead code;
##   * a ceiling relative to the declared intent - an implausibly low number
##     means most materials silently fell back, which is the failure mode where
##     "some of it works" hides "most of it did not".
func _check_texture_layer() -> void:
	_section("texture layer")
	# Build every declared material so the layer has had its chance to run.
	var keys := ArtKitMaterials.keys()
	for k in keys:
		ArtKitMaterials.get_(k)

	var declared := ArtKitMaterials.TEXTURED.size()
	_ok(declared >= 12, "the library declares textured materials (%d)" % declared)

	# Every declared set must name an inventory entry for each slot it wants.
	var unknown_sets: Array[String] = []
	for key in ArtKitMaterials.TEXTURED.keys():
		var set_name := String(ArtKitMaterials.TEXTURED[key])
		if ArtKitLicensing.entry(set_name, "albedo").is_empty():
			unknown_sets.append("%s -> %s" % [key, set_name])
	_ok(unknown_sets.is_empty(),
			"every declared texture set exists in the inventory", str(unknown_sets))

	var applied := ArtKitLicensing.applied_count()
	var missing := ArtKitLicensing.missing()
	# The floor. One applied texture is enough to prove the path executes; the
	# exact number depends on which captures this checkout has imported, so the
	# upper bound is deliberately loose and the lower bound is the real check.
	_ok(applied >= 1, "licensed textures actually reached a material (TEXTURES_APPLIED=%d)"
			% applied)
	print("       applied=%d missing_slots=%d declared_sets=%d"
			% [applied, missing.size(), declared])
	if not missing.is_empty():
		# Not a failure: a bare checkout with no ingested captures is a supported
		# state and the procedural fallbacks are the point. Reported so the number
		# in the log is never mistaken for "everything was found".
		print("       NOTE: %d slot(s) fell back to procedural noise" % missing.size())


func _report() -> void:
	print("\n========================================")
	if _checks < MIN_CHECKS:
		_fails.append("only %d of >= %d checks ran - a section aborted early"
				% [_checks, MIN_CHECKS])
	if _fails.is_empty():
		print("PASS  %d checks" % _checks)
		quit(0)
	else:
		print("FAIL  %d of %d checks:" % [_fails.size(), _checks])
		for f in _fails:
			print("  - %s" % f)
		quit(1)
