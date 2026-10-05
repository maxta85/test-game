class_name ArtKitLicensing
extends RefCounted
## Provenance for every third-party byte the kit uses, and the only door to it.
##
## ## Why this file exists
##
## Until t194, `artkit/artkit_check.gd` asserted the *absence* of external
## assets: no `.jpg`, no `.glb`, no `load(` anywhere in `artkit/`. That was a
## coherent policy - "everything is code" - and it was enforced honestly.
##
## The brief changed. Reuse-first means a licensed photograph of asphalt is
## worth more than a procedural noise pretending to be one: the hero surface gets
## its aggregate, its chipping and its patching from a real capture rather than
## from `FastNoiseLite`. Deleting assets to satisfy a check that forbids them is
## not an option, and neither is waving the check through.
##
## So the check is replaced by a stronger one. The old rule could only prove the
## negative. This one proves a positive: **every** external asset is named in a
## machine-readable inventory, carries an accepted licence with a fetchable
## source, hashes to the bytes the inventory recorded, and degrades to a
## procedural stand-in when it is absent. A new `.jpg` dropped into `assets/art/`
## with no inventory row fails the audit - the same way an unlisted download
## would have failed review, except now it fails automatically.
##
## ## The fallback is not a courtesy, it is the design
##
## `ArtKitMaterials` is built and consumed in a headless suite, on a CI box with
## no network, and on a fresh clone before the first import. If a missing texture
## were a hard error the whole suite would be unreachable. So every accessor here
## returns null on absence and the material layer keeps its procedural noise. A
## run with no third-party assets installed renders the city exactly as it did
## before this file existed. That property is what makes reuse safe to adopt: it
## can only ever add detail, never take the game away.
##
## ## Read the inventory, do not duplicate it
##
## `assets/art/third_party/inventory.json` is written by `ingest.py` and
## verified by `ingest.py --verify`. Nothing here re-states a licence, a URL or a
## hash: a second copy of one fact always drifts, and a drifted licence record is
## worse than none because it still looks authoritative.

const INVENTORY_PATH := "res://assets/art/third_party/inventory.json"
const ROOT := "res://assets/art/third_party/"
const STATS_PATH := "res://assets/art/third_party/albedo_stats.json"

## Licences this project will accept, with the one bit that actually matters:
## can the bytes be redistributed in a shipped build. An inventory entry whose
## licence is absent from this table is treated as unlicensed, not as "probably
## fine" - the default has to be the safe one.
const ACCEPTED := {
	"CC0-1.0": {"redistribute": true, "attribute_required": false},
}

## Albedo maps are normalised against this instead of replacing the palette.
## ART_DIRECTION.md's rule is that neighbouring surfaces must differ in *value*,
## and that is decided by `ArtKitPalette`. A photograph's own mean luminance is
## not a value anybody chose for a wet road at 1am, so the map is divided by its
## own mean and keeps only the detail around it.
const NORMALISE_ALBEDO_TO_UNIT_MEAN := true

## Cached textures, keyed set/role. A texture is expensive to decode and
## immutable once loaded, so this one *is* cached - with the caveat that a
## checkout which imports its captures after the first material request will not
## pick them up in the same process. That is a real limitation, stated rather
## than hidden: it is why `MISSING_SLOTS` is reported instead of being treated as
## success.
static var _tex_cache: Dictionary = {}
## Counters the report and the audit read. `_applied` counts material slots that
## actually received a real texture, which is the only number that answers "did
## reuse actually happen" - counting downloaded files answers a different and
## much easier question.
static var _applied := 0
static var _missing: Array[String] = []
static var _unlicensed: Array[String] = []
## How many asset files `unclaimed()`'s walk actually looked at. Exists so a
## caller can tell "found nothing wrong" from "walked nothing"; see `_walk`.
static var _walked := 0


# ------------------------------------------------------------------ inventory

## The parsed inventory, or an empty dict when it cannot be read.
##
## ## Deliberately not cached
##
## The first version memoised this behind a `_loaded` flag, next to the texture
## cache where memoising is obviously right. That made the audit blind: mutating
## `inventory.json` on disk - setting a licence to CC-BY-NC, blanking a source
## URL, pointing a row at a file that does not exist - changed nothing, because
## the process kept serving the copy it read at startup. All three of those
## mutations passed the check.
##
## So the asymmetry is now explicit. **Textures** are cached: decoding a 1k PNG
## costs real milliseconds and the bytes cannot change under us. **The inventory**
## is re-read on every call: it is small, it is the thing being audited, and an
## audit that cannot observe a change to its own subject is not auditing.
static func doc() -> Dictionary:
	if not FileAccess.file_exists(INVENTORY_PATH):
		return {}
	var text := FileAccess.get_file_as_string(INVENTORY_PATH)
	var parsed: Variant = JSON.parse_string(text)
	# A malformed inventory reads as an absent one, which makes every row look
	# unlicensed. Silently accepting a parse failure would let a truncated file
	# disable the audit without failing anything.
	if parsed is Dictionary:
		return parsed
	return {}


static func entries() -> Array:
	var out: Array = []
	var d := doc()
	if d.is_empty():
		return out
	for a in (d.get("assets") as Array):
		if a is Dictionary:
			out.append(a)
	return out


## The inventory row for `set_name`/`role`, or an empty dict.
static func entry(set_name: String, role: String) -> Dictionary:
	for a in entries():
		if String(a.get("set", "")) == set_name and String(a.get("role", "")) == role:
			return a
	return {}


## Every asset in the inventory, checked against this project's accepted
## licences. This is the function `UNLICENSED_ASSETS` is read from, so it has to
## be a real check rather than a count of rows that happen to look fine:
##
##   * a licence that is not in `ACCEPTED`;
##   * a licence accepted but not marked redistributable;
##   * a row with no source URL, which is an asset nobody can attribute;
##   * a row whose file is not actually on disk, which is a claim of provenance
##     for bytes that are not in the tree.
static func unlicensed() -> Array[String]:
	var bad: Array[String] = []
	for a in entries():
		var rel := String(a.get("path", ""))
		# ## Not `a.get("license") or {}`
		#
		# GDScript 4's `or` coerces both operands to bool, so the expression's
		# static type is bool and assigning it to a typed `Dictionary` is a parse
		# error. `{"spdx_id": "CC0-1.0"} or {}` reads like an obvious "default if
		# absent" and is not one. The guarded form is what actually works, and it
		# is also honest about a malformed row: a `license` key holding a string
		# is a corrupt inventory, not an absent licence, and it must not silently
		# become `{}` and pass as "no licence claimed".
		var lic: Dictionary = {}
		var raw_lic: Variant = a.get("license")
		if raw_lic is Dictionary:
			lic = raw_lic
		var spdx := String(lic.get("spdx_id", ""))
		var rule: Dictionary = {}
		if ACCEPTED.has(spdx):
			rule = ACCEPTED[spdx]
		if rule.is_empty():
			bad.append("%s: licence %s is not accepted" % [rel, spdx])
			continue
		if not bool(rule.get("redistribute", false)):
			bad.append("%s: %s is not redistributable" % [rel, spdx])
			continue
		if not String(lic.get("url", "")).begins_with("http"):
			bad.append("%s: licence text has no URL" % rel)
			continue
		var src: Dictionary = {}
		var raw_src: Variant = a.get("source")
		if raw_src is Dictionary:
			src = raw_src
		if not String(src.get("file_url", "")).begins_with("http"):
			bad.append("%s: no source URL" % rel)
			continue
		if not FileAccess.file_exists(ROOT + rel):
			bad.append("%s: inventoried but not on disk" % rel)
	if FileAccess.file_exists(INVENTORY_PATH) and not doc().has("assets"):
		bad.append("%s: present but unparseable" % INVENTORY_PATH)
	return bad


## Files sitting in `assets/art/third_party/` that the inventory does not claim.
## The reverse direction, and the one that catches a hand-dropped file.
static func unclaimed() -> Array[String]:
	var claimed := {}
	for a in entries():
		claimed[String(a.get("path", ""))] = true
	var found: Array[String] = []
	_walked = 0
	_walk(ROOT, "", found, claimed)
	return found


## Asset files the last `unclaimed()` walk examined. Zero means the walk aborted,
## which makes `unclaimed()`'s empty result meaningless.
static func walked_count() -> int:
	return _walked


## Recurse with a path, opening a **fresh** `DirAccess` per directory.
##
## The first version took a `DirAccess` and recursed on that same handle. That is
## infinite: `list_dir_begin()` resets the cursor to the top of the directory, so
## the recursive call re-reads the parent's entries, sees the same subdirectory,
## and recurses again. It surfaces as `Stack overflow` from `_walk` and - this is
## the part that matters - as a **passing** `no asset file on disk is missing from
## the inventory` check, because the overflow aborts the walk partway and returns
## an empty `found`.
##
## So a walking bug here fails *open*, and the check it guards reads as green.
## The signature below takes a `res://` path and opens its own handle, which is
## the only shape that terminates.
static func _walk(path: String, prefix: String, found: Array[String],
		claimed: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	# Snapshot first: `get_next()` is invalidated by the recursive open below, and
	# reading a stale cursor mid-walk is how a directory gets skipped silently.
	var names: Array[String] = []
	while f != "":
		names.append(f)
		f = dir.get_next()
	dir.list_dir_end()

	for name in names:
		var rel := prefix + name
		if dir.dir_exists(name):
			if name.begins_with("."):
				continue
			_walk(path.path_join(name), rel + "/", found, claimed)
			continue
		if not name.contains("."):
			continue
		var ext := name.get_extension().to_lower()
		if ext in ["png", "jpg", "jpeg", "hdr", "exr", "ktx", "dds", "webp",
				"svg", "glb", "gltf", "obj", "fbx", "dae", "blend", "wav",
				"ogg", "mp3", "tga", "basis"]:
			_walked += 1
			if not claimed.has(rel):
				found.append(rel)


# --------------------------------------------------------------------- assets

## The measured mean luma of an albedo map, from `albedo_stats.json`. Used to
## normalise the map so it contributes detail rather than brightness.
static func albedo_mean(set_name: String) -> float:
	if not FileAccess.file_exists(STATS_PATH):
		return 0.0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATS_PATH))
	if not (parsed is Dictionary):
		return 0.0
	var sets: Dictionary = {}
	if (parsed as Dictionary).has("sets") and (parsed as Dictionary)["sets"] is Dictionary:
		sets = (parsed as Dictionary)["sets"]
	var entry_v: Variant = sets.get(set_name)
	if not (entry_v is Dictionary):
		return 0.0
	var a: Dictionary = {}
	if (entry_v as Dictionary).has("albedo") and (entry_v as Dictionary)["albedo"] is Dictionary:
		a = (entry_v as Dictionary)["albedo"]
	# Stored 0..255 on purpose: it is what Pillow measured, and converting it at
	# write time would mean the file disagrees with the tool that produced it.
	var luma := float(a.get("luma_mean", 0.0))
	return luma / 255.0


## A licensed texture as a `Texture2D`, or null.
##
## Null is a normal return value and callers must handle it. Three separate
## things make null correct here: the asset was never ingested, the file is not
## in this checkout, or the import produced nothing yet. All three mean the same
## thing to a material - carry on with the procedural texture.
static func texture(set_name: String, role: String) -> Texture2D:
	var key := "%s/%s" % [set_name, role]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var e := entry(set_name, role)
	if e.is_empty():
		_missing.append(key)
		_tex_cache[key] = null
		return null
	var rel := String(e.get("path", ""))
	var path := ROOT + rel
	if not FileAccess.file_exists(path):
		_missing.append(key)
		_tex_cache[key] = null
		return null
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = ResourceLoader.load(path) as Texture2D
	if tex == null and role == "albedo" and NORMALISE_ALBEDO_TO_UNIT_MEAN:
		tex = _normalised(path, albedo_mean(set_name))
	elif tex != null and role == "albedo" and NORMALISE_ALBEDO_TO_UNIT_MEAN:
		tex = _normalised_resource(tex, albedo_mean(set_name))
	_tex_cache[key] = tex
	return tex


## Load the raw image and divide out its own mean.
##
## Doing this in the engine rather than baking a normalised copy into the tree
## keeps the repository holding the provider's bytes: the file on disk still
## hashes to what the inventory recorded, so `--verify` keeps meaning something
## about provenance instead of about our own post-processing.
static func _normalised(path: String, mean: float) -> Texture2D:
	var img := Image.new()
	var err := img.load(ProjectSettings.globalize_path(path))
	if err != OK or img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	if mean > 0.001 and NORMALISE_ALBEDO_TO_UNIT_MEAN:
		var scale := 0.5 / mean
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(
						clampf(c.r * scale, 0.0, 1.0),
						clampf(c.g * scale, 0.0, 1.0),
						clampf(c.b * scale, 0.0, 1.0),
						c.a))
	return ImageTexture.create_from_image(img)


static func _normalised_resource(tex: Texture2D, mean: float) -> Texture2D:
	if mean <= 0.001 or not NORMALISE_ALBEDO_TO_UNIT_MEAN:
		return tex
	var img := tex.get_image()
	if img == null:
		return tex
	return _normalised_from_image(img, mean)


static func _normalised_from_image(img: Image, mean: float) -> Texture2D:
	img.convert(Image.FORMAT_RGBA8)
	var scale := 0.5 / mean
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(
					clampf(c.r * scale, 0.0, 1.0),
					clampf(c.g * scale, 0.0, 1.0),
					clampf(c.b * scale, 0.0, 1.0),
					c.a))
	return ImageTexture.create_from_image(img)


## The sky HDRI as a texture, or null. Kept separate from `texture()` because an
## HDRI is a radiance map, not a surface: it drives ambient light and must never
## be handed to a material as an albedo.
static func hdri(set_name: String) -> Texture2D:
	return texture(set_name, "sky_ibl")


# ----------------------------------------------------------------- accounting

## Material slots that received a real licensed texture. Read by the report as
## `TEXTURES_APPLIED`.
static func applied_count() -> int:
	return _applied


## Slots whose texture was requested but is not installed. Expected to be
## non-empty on a bare checkout, and that is why the fallbacks exist.
static func missing() -> Array[String]:
	return _missing


## Record that a texture reached a material. Called by `ArtKitMaterials` at the
## point of assignment, so the count reflects what the renderer will actually
## sample rather than what was downloaded.
static func note_applied(set_name: String, role: String) -> void:
	_applied += 1
	var key := "%s/%s" % [set_name, role]
	_missing.erase(key)


## A one-block summary for a report or a log line. Every number here is read from
## live state, never written by hand.
static func summary() -> Dictionary:
	var d := doc()
	return {
		"inventory_present": not d.is_empty(),
		"assets_in_inventory": entries().size(),
		"unlicensed": unlicensed().size(),
		"unclaimed_on_disk": unclaimed().size(),
		"textures_applied": applied_count(),
		"slots_missing_texture": missing().size(),
	}


static func format_summary() -> String:
	var s := summary()
	return ("inventory=%s assets=%d UNLICENSED_ASSETS=%d UNCLAIMED_ON_DISK=%d "
			+ "TEXTURES_APPLIED=%d MISSING_SLOTS=%d") % [
		str(s["inventory_present"]), int(s["assets_in_inventory"]),
		int(s["unlicensed"]), int(s["unclaimed_on_disk"]),
		int(s["textures_applied"]), int(s["slots_missing_texture"]),
	]