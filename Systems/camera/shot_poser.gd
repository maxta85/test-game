class_name ShotPoser
extends Node3D
## Moves the camera to fixed vantage points so renders can be compared like for
## like between passes. Without this, "it looks better" is unmeasurable because
## every screenshot frames something different.
##
## ./run.sh --shot NAME [PRESET]

const PRESETS := {
	# name: [cam_pos, cam_look_at, fov]
	"start":      [Vector3(-30, 6, 58), Vector3(10, 1.2, 40), 55.0],
	"street":     [Vector3(0, 3.2, -60), Vector3(0, 1.0, 30), 50.0],
	"downtown":   [Vector3(-70, 14, -40), Vector3(10, 2, 60), 60.0],
	"kerb":       [Vector3(14, 1.1, 62), Vector3(-6, 0.6, 20), 45.0],
	"carmeet":    [Vector3(-60, 8, 100), Vector3(-84, 1.5, 118), 55.0],
	"aerial":     [Vector3(0, 420, 340), Vector3(0, 0, 0), 60.0],
	"motorway":   [Vector3(0, 12, -420), Vector3(30, 2, -300), 55.0],
	# A residential frontage with a veranda on it, on the far side of the city
	# from every preset above: all of those frame the anchor street, which is a
	# shopfront strip, so nothing here had ever seen a Queenslander.
	#
	# These two numbers are a *copy* of what `World/look_dev_capture.gd --only
	# resi` computes, and the copy is deliberate - this is the `./render.sh
	# residential` path a human uses, and it cannot ask for a graph. The source is
	# the longest street-facing wall on a raised house in
	# `assets/maps/cairns_buildings.json`: osm 311035040, a 26.1 m frontage 5.1 m
	# off the kerb on a class-1 street, deck at 0.85 m, wall at 3.35 m. Re-run the
	# capture after `python3 Tools/osm_cairns.py` and take the numbers from its
	# `[LookDev] resi pose:` line rather than trusting these.
	"residential": [Vector3(136.89, 1.65, -60.76), Vector3(148.73, 2.25, -53.65), 55.0],
	# The same veranda from the opposite footpath: the only sightline on that
	# street with nothing in it, because the near lane is parked cars and the near
	# footpath is trees.
	"resi_detail": [Vector3(139.31, 1.65, -47.12), Vector3(148.96, 2.30, -53.84), 50.0],
}

## Shots framed on the player's car rather than on a fixed point in the world,
## so they still work after the start grid moves. `[offset_from_car, look_at, fov]`
const CAR_SHOTS := {
	# Straight behind and a little up: the shot the player actually sees, so any
	# change to the chase camera shows up here. A coupe is 4.7 m long, so 5.2 m
	# of standoff put the tail deck across the whole frame; 7.6 m frames the car
	# with road either side of it.
	"carhero":    [Vector3(0.0, 2.1, -7.6), Vector3(0, 0.70, 0.0), 46.0],
	# Low three-quarter front: headlights, paint and stance in one frame.
	"carfront":   [Vector3(4.6, 1.2, -6.4), Vector3(0, 0.6, 0.0), 42.0],
	# High three-quarter rear: roofline, wheels, and how much the car is lit.
	"carhigh":    [Vector3(-5.0, 3.4, 7.2), Vector3(0, 0.7, 0.0), 44.0],
}


## Wide street view with the car in it. Same frame character as the layout
## preset below - up the street, not across it - but anchored on the car.
## "street" used to frame `OSMLayout.start_line()`, and that point is not where
## a race puts its cars: `RaceDirector._grid_slot` builds the grid from the
## ROUTE's start line, which on the default race is 1096 m from the layout's, so
## the shot contained a street with no car in it while the HUD read POS 1/2.
const STREET_SHOT := [Vector3(0.0, 3.2, -17.0), Vector3(0, 1.0, 0.0), 50.0]

static func apply(node: Node, preset_name: String) -> bool:
	if preset_name == "street":
		# Car first, layout second: in a running race the car is the subject, and
		# only a scene with no car at all needs the map-derived fallback.
		if _apply_to_car(node, STREET_SHOT):
			return true
		return _apply_to_start_line(node)
	if CAR_SHOTS.has(preset_name):
		return _apply_to_car(node, CAR_SHOTS[preset_name])
	if not PRESETS.has(preset_name):
		return false
	var p: Array = PRESETS[preset_name]
	var cam := _camera_of(node)
	if cam == null:
		return false
	cam.global_position = p[0]
	cam.look_at(Vector3(p[1]), Vector3.UP)
	cam.fov = float(p[2])
	return true


## The "street" preset follows the map instead of hardcoding Manunda's origin.
## Every other preset in PRESETS is an absolute point in the world, so they all
## went stale the moment the layout became real OSM data. This one is derived
## from the layout, so it keeps framing the start line whatever the map is - and
## it looks *along* the street, not at a fixed compass bearing, which matters
## now that the anchor street can run any direction.
static func _apply_to_start_line(node: Node) -> bool:
	var cam := _camera_of(node)
	if cam == null:
		return false
	var s: Dictionary = OSMLayout.start_line()
	var at: Vector3 = s["pos"]
	var d: Vector2 = s["dir"]
	var fwd := Vector3(d.x, 0.0, d.y)
	var side := Vector3(-d.y, 0.0, d.x)
	cam.global_position = at - fwd * 26.0 + side * 7.0 + Vector3(0.0, 2.6, 0.0)
	cam.look_at(at + fwd * 30.0, Vector3.UP)
	cam.fov = 52.0
	return true


## Car-relative shot. The camera is put where the car is *now*, so a preset does
## not go stale when the start grid or the route changes.
static func _apply_to_car(node: Node, p: Array) -> bool:
	var cam := _camera_of(node)
	if cam == null:
		return false
	var car: CarBody = null
	if node is ChaseCamera:
		car = (node as ChaseCamera).car()
	if car == null:
		return false
	# In the car's own frame: +Z is backwards, so -Z is behind its nose.
	var back: Vector3 = car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	var up: Vector3 = car.car_up()
	var anchor: Vector3 = car.global_position + back * p[0].z + up * p[0].y + right * p[0].x
	cam.global_position = anchor
	cam.look_at(car.global_position + up * float(p[1].y) - back * float(p[1].z), up)
	cam.fov = float(p[2])
	return true


static func _camera_of(node: Node) -> Camera3D:
	for c in node.get_children():
		if c is Camera3D:
			return c
	return null
