class_name ManundaLayout
extends RefCounted
## The authored road layout for the first playable block.
##
## ORIGINAL GAME CONTENT. No map data, imagery, coordinates or geometry was taken
## from Google or any other mapping service. What this borrows from the real
## Manunda is only its *character*, which anyone can see from the street:
##
##   - flat, low-lying, flood-prone ground with open drainage channels
##   - a long north-south commercial strip with shops and a supermarket
##   - a wide arterial crossing it
##   - a low-rise residential grid of narrow streets and cul-de-sacs
##   - a workshop / light-industrial pocket
##   - the mountain ranges standing to the west
##   - power lines and palms over everything
##
## Street names are invented. Block sizes, bend geometry and every building are
## original. The point is that a player who knows the area should feel the
## *layout rhythm* without it being a copy of anything.
##
## Axes: +X east, +Z south, origin at the middle of the commercial intersection.
## Playable block is about 1400 x 1400 m (~2 km^2 with the outlying edges).

const HALF := 700.0


static func corridors() -> Array:
	var c: Array = []

	# --- the main commercial spine, running north-south -----------------------
	c.append({
		"name": "MOODY PARADE", "class": RoadGraph.RoadClass.ARTERIAL,
		"points": _line(Vector2(0, -680), Vector2(0, 690)),
	})
	# --- the arterial, running east-west ---------------------------------------
	c.append({
		"name": "BRUCE ROAD", "class": RoadGraph.RoadClass.ARTERIAL,
		"points": _line(Vector2(-690, 40), Vector2(690, 40)),
	})
	# --- the highway, up on the northern edge ----------------------------------
	c.append({
		"name": "MULGRAVE ROAD", "class": RoadGraph.RoadClass.HIGHWAY,
		"points": _line(Vector2(-690, -560), Vector2(690, -560)),
	})

	# --- residential grid -----------------------------------------------------
	# Cross streets, evenly spaced but deliberately not a perfect lattice: real
	# suburbs have a couple of streets that drift, and the drift is what makes a
	# place feel real rather than generated.
	var cross_z := [-430.0, -300.0, -170.0, -80.0, 160.0, 280.0, 400.0, 520.0, 630.0]
	var n := 0
	for z in cross_z:
		n += 1
		var drift: float = 0.0
		# Streets east of the spine drift gently south as they run out to the east.
		if z > -500.0:
			drift = 14.0 * sin(z * 0.01)
		c.append({
			"name": _street_name(n), "class": RoadGraph.RoadClass.STREET,
			"points": _line(Vector2(-680, z), Vector2(680, z + drift)),
		})

	# North-south residential streets.
	var spine_x := [-560.0, -440.0, -320.0, -200.0, 200.0, 320.0, 440.0, 560.0]
	for x in spine_x:
		n += 1
		# The streets just out from the shops are shorter - the older, tighter part
		# of the suburb, where the commercial strip has eaten the grid.
		var y0: float = -520.0
		var y1: float = 620.0
		if absf(x) < 400.0:
			y0 = -300.0
		c.append({
			"name": _street_name(n), "class": RoadGraph.RoadClass.STREET,
			"points": _line(Vector2(x, y0), Vector2(x, y1)),
		})

	# --- cul-de-sacs: where the suburb runs into the flood plain -------------
	c.append({
		"name": "SANKEY CLOSE", "class": RoadGraph.RoadClass.LANE,
		"points": [Vector2(320, 400), Vector2(430, 412), Vector2(505, 448), Vector2(548, 500)],
	})
	c.append({
		"name": "DINA STREET", "class": RoadGraph.RoadClass.STREET,
		"points": [Vector2(-680, 520), Vector2(-520, 516), Vector2(-392, 500)],
	})

	# --- the workshop / light-industrial pocket in the south-west --------------
	c.append({
		"name": "BOUNDER STREET", "class": RoadGraph.RoadClass.STREET,
		"points": [Vector2(-680, 280), Vector2(-520, 284), Vector2(-360, 290), Vector2(-240, 296)],
	})
	c.append({
		"name": "MELALEUCA ROAD", "class": RoadGraph.RoadClass.ARTERIAL,
		"points": [Vector2(-440, 280), Vector2(-436, 400), Vector2(-430, 630)],
	})

	# --- the riverside road, out beyond the drain, to the west ----------------
	c.append({
		"name": "SILVER CREEK ROAD", "class": RoadGraph.RoadClass.STREET,
		"points": [Vector2(-660, -430), Vector2(-648, -170), Vector2(-640, 160), Vector2(-630, 400), Vector2(-622, 660)],
	})

	# --- a pair of lanes for tight, technical racing ---------------------------
	c.append({
		"name": "PEASE LANE", "class": RoadGraph.RoadClass.LANE,
		"points": [Vector2(200, -80), Vector2(320, -70), Vector2(440, -52), Vector2(540, -30)],
	})

	return c


## Subdivides a straight run into short segments so that crossings are found
## per-segment and long edges do not have to be intersected against everything.
static func _line(a: Vector2, b: Vector2) -> Array:
	var out: Array = []
	var steps := 6
	for i in steps + 1:
		out.append(a.lerp(b, float(i) / steps))
	return out


static func _street_name(seed: float) -> String:
	var pool := [
		"YOOUNGBAH PLACE", "TILLET STREET", "BUSHRA PLACE", "PEASE COURT",
		"ELIZABETH STREET", "KINGFISHER CLOSE", "RAFAEL DRIVE", "MCILWRAITH STREET",
		"THOMAS STREET", "GARDENIA CLOSE", "WALLACE STREET", "PANDANUS WAY",
		"FLAMINGO CLOSE", "HORIZON STREET", "BANANA COURT", "JACKSON STREET",
		"LEICHARDT STREET", "NURSERY CLOSE", "ORCHID STREET", "BRISBANE STREET",
	]
	var i: int = int(abs(seed)) % pool.size()
	return pool[i]


## Where the player starts and where the car meet sits.
static func car_meet_position() -> Vector3:
	return Vector3(-84.0, 0.0, 118.0)


static func start_grid_position(slot: int) -> Vector3:
	# Behind the Bruce Road / Moody Parade intersection, on the arterial.
	var row := slot / 2
	var col := slot % 2
	return Vector3(-18.0 - float(row) * 9.0, 0.0, 40.0 + float(col) * 4.0)


static func finish_line() -> Dictionary:
	return {"position": Vector3(0.0, 0.0, 40.0), "direction": Vector3(1, 0, 0), "width": 13.0}
