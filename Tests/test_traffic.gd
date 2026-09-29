extends RefCounted
## Civilian traffic. Run with: ./test.sh traffic
##
## Everything here is pure logic against a real RoadGraph - no CarBody, no
## physics, no scene tree. A test car is a TrafficCar, which is a route and a
## number, so a whole city of them costs milliseconds to set up and nothing at
## all to tear down.

var g: RoadGraph
var lights: TrafficLights
var rng := RandomNumberGenerator.new()


func run(t: TestHarness) -> void:
	rng.seed = 4242
	g = RoadGraph.new()
	g.build(ManundaLayout.corridors())
	lights = TrafficLights.new()
	lights.setup(g)

	_advances_on_road(t)
	_right_hand_traffic(t)
	_follows_and_brakes_early(t)
	_signals(t)
	_compliance(t)
	_junction_choices(t)
	_density(t)
	_forward_query(t)
	_parked_cars(t)
	_roster(t)


# ---------------------------------------------------------------------- cases

## A car drives. It must cover real ground and it must be sitting on the tarmac
## the whole way - position is derived from the route, never integrated, so it
## cannot drift off the road.
func _advances_on_road(t: TestHarness) -> void:
	var eid := _longest_edge(g)
	var c := _car(g, lights, eid, 4.0, "wandoo_sedan", 0)
	var width := float(g.edges[eid]["width"])
	var moved := 0.0
	var last := c.position()
	var off_surface := 0.0
	for i in 600:
		c.tick(1.0 / 60.0, -1.0)
		var p := c.position()
		moved += p.distance_to(last)
		last = p
		# Two invariants, checked every frame: the car is exactly its lane offset
		# from the centreline it claims to be on, and that offset is on the road.
		var centre: Vector3 = g.point_on_edge(c.edge(), c.along, c.from_a)
		off_surface = maxf(off_surface, absf(p.distance_to(centre) - c.lateral))
		if c.lateral > width * 0.5 or c.lateral < 0.0:
			off_surface += 10.0
	t.gt(moved, 60.0, "car covers real ground over 10 s (%.0f m)" % moved)
	t.between(off_surface, 0.0, 0.01, "car never leaves the road surface (worst error %.4f m)" % off_surface)
	t.gt(c.speed, 1.0, "and it is still driving at the end of it")


## Australia drives on the left, so the car sits on the RIGHT of the centreline
## with the kerb on its right hand. The sign convention is the whole test, so it
## is checked in both directions of travel.
func _right_hand_traffic(t: TestHarness) -> void:
	var eid := _longest_edge(g)
	for lane in _car(g, lights, eid, 12.0, "wandoo_sedan", 0).lane_count():
		var c := _car(g, lights, eid, 12.0, "wandoo_sedan", lane)
		var centre: Vector3 = g.point_on_edge(c.edge(), c.along, c.from_a)
		var side: float = (c.position() - centre).dot(c.heading().cross(Vector3.UP))
		t.gt(side, 0.5, "lane %d sits right of the centreline (%.2f m out)" % [lane, side])
		t.between(c.lateral, 0.0, float(g.edges[c.edge()]["width"]) * 0.5,
			"lane %d is inside the road surface" % lane)
		if lane > 0:
			t.gt(c.target_lateral, float(lane - 1) * c.lane_width(),
				"lane %d is outboard of the one inboard of it" % lane)

	# Lanes are counted per direction. Manunda's 9 m street is one lane each
	# side of a centreline, so a car sitting in "lane 1" of a four-lane reading
	# would be parked on the footpath.
	var street := _car(g, lights, eid, 12.0, "wandoo_sedan", 0)
	t.eq(street.lane_count(), 1, "a two-lane street is one lane in our direction")
	t.near(street.lane_width(), float(g.edges[eid]["width"]) * 0.5, 0.01,
		"and that lane is half the road wide")
	var highway := 0
	for e in g.edges:
		if int(e["class"]) == RoadGraph.RoadClass.HIGHWAY:
			highway = int(e["id"])
			break
	if highway >= 0:
		t.eq(_car(g, lights, highway, 12.0, "wandoo_sedan", 0).lane_count(), 2,
			"the three-lane highway is two lanes in our direction, so overtaking exists")

	var fwd := _car(g, lights, eid, 12.0, "wandoo_sedan", 0)
	var back := _car(g, lights, eid, 12.0, "wandoo_sedan", 0)
	back.from_a = not fwd.from_a
	t.ok(fwd.heading().dot(back.heading()) < -0.9, "reversing the route really does reverse the car")
	for c in [fwd, back]:
		var centre: Vector3 = g.point_on_edge(c.edge(), c.along, c.from_a)
		t.gt((c.position() - centre).dot(c.heading().cross(Vector3.UP)), 0.5,
			"%s is right of ITS centreline, not the graph's" % ("a->b car" if c == fwd else "b->a car"))


## Car following. The car behind must slow down, must not touch, and must have
## started braking while it still had room - an assertion on the final gap
## alone would not catch a car that brakes at the last moment.
func _follows_and_brakes_early(t: TestHarness) -> void:
	var m := _empty_manager()
	var eid := _longest_edge(g)
	var length: float = g.edge_length(eid)
	# A loaded truck up front, a light hatchback behind it: the gap closes and
	# the follower has to sort it out. Close enough that the follower can see
	# it - its lookahead scales with its own braking distance, not with the map.
	var lead := _car(g, lights, eid, length * 0.66, "barra_truck", 0)
	var follower := _car(g, lights, eid, length * 0.40, "corvo_hatch", 0)
	follower.speed = follower.cruise_speed()
	m.cars = [lead, follower]
	t.gt(lead.cruise_speed(), 0.0, "the truck has a cruise speed")
	t.ok(follower.cruise_speed() > lead.cruise_speed() * 1.1,
		"the hatchback wants to go faster than the truck (%.1f vs %.1f m/s)"
			% [follower.cruise_speed(), lead.cruise_speed()])

	var closest := 1e9
	var braked_early := false
	var gap_at_first_brake := 0.0
	var slowest := 99.0
	var worst_demand := 0.0
	for i in 600:
		m.tick(1.0 / 60.0)
		var gap := follower.position().distance_to(lead.position())
		closest = minf(closest, gap)
		# "Early" means already off the throttle while still far enough away to
		# stop comfortably - measured in seconds of headway, because 20 m means
		# something completely different at 8 m/s than at 16.
		if follower.speed < follower.cruise_speed() * 0.9 and gap / maxf(follower.speed, 0.1) > 1.5:
			braked_early = true
			gap_at_first_brake = maxf(gap_at_first_brake, gap)
		if i > 60:
			slowest = minf(slowest, follower.speed)
			# The deceleration the follower would have needed to avoid the
			# leader entirely, against the deceleration it actually has. Under 1
			# means it was never in trouble, at any point, in the whole run.
			if gap > 1.0:
				worst_demand = maxf(worst_demand,
					(follower.speed * follower.speed - lead.speed * lead.speed) / (2.0 * gap))
	t.ok(braked_early, "follower eases off with %.0f m (%.1f s of headway) still clear"
		% [gap_at_first_brake, gap_at_first_brake / maxf(follower.speed, 0.1)])
	t.ok(worst_demand < follower.decel,
		"follower never needed more than it has (peak demand %.2f vs %.2f m/s2)"
			% [worst_demand, follower.decel])
	t.gt(closest, lead.half_length() + follower.half_length(),
		"follower never closes inside the leader's bodywork (closest %.2f m bumper to bumper)" % closest)
	t.between(closest, TrafficCar.MIN_GAP * 0.5, 40.0, "and keeps a sane gap while doing it")
	t.between(slowest, 0.0, lead.cruise_speed() * 1.1, "follower settles to the leader's pace, not to zero")
	t.gt(lead.speed, 1.0, "the leader kept moving")


## Red means stop, green means go, and the minority who ignore the light do so
## without anybody's permission.
func _signals(t: TestHarness) -> void:
	t.gt(lights.junction_nodes.size(), 10, "the network has real signals (%d junctions)" % lights.junction_nodes.size())

	# A signalled approach with a long enough run-up to actually have to brake.
	var node := -1
	var eid := -1
	for n in lights.junction_nodes:
		for cand in g.nodes[n]["edges"]:
			if g.edge_length(cand) > 110.0:
				node = n
				eid = cand
				break
		if node >= 0:
			break
	t.gt(node, -1, "found a signalled approach with room to approach it")

	var c := _car(g, lights, eid, 0.0, "wandoo_sedan", 0)
	c.from_a = int(g.edges[eid]["b"]) == node    # drive at the junction
	c.along = g.edge_length(eid) - 70.0
	c.obedience = 1.0
	c.speed = c.cruise_speed()
	# Force the phase that this approach is NOT on, so the light is red for it
	# however the cycle happens to be sitting.
	lights._timer = 0.0
	lights._active = 1 - lights.phase_of(node, eid)
	t.eq(lights.state_for(node, eid), TrafficLights.State.RED, "the approach is red")
	t.gt(c.signal_gap(), 0.0, "an obedient driver is told about the stop line")

	for i in 600:
		var sig := c.signal_gap()
		c.tick(1.0 / 60.0, sig, 0.0)
	t.between(c.speed, 0.0, 0.2, "car is stopped at a red light")
	t.between(c.along + c.half_length(), 0.0, g.edge_length(eid) - TrafficCar.STOP_SETBACK + 0.05,
		"car's nose stopped short of the stop line (%.1f m clear)"
			% (g.edge_length(eid) - c.along - c.half_length()))
	t.eq(c.blocked, true, "and it knows it is blocked, not merely slow")

	# A light with no car on it still cycles.
	var guard := 0
	while lights.state_for(node, eid) != TrafficLights.State.GREEN and guard < 3000:
		lights.tick(1.0 / 60.0)
		guard += 1
	t.eq(lights.state_for(node, eid), TrafficLights.State.GREEN, "the approach turns green")
	for i in 600:
		var sig := c.signal_gap()
		c.tick(1.0 / 60.0, sig, 0.0)
	t.gt(c.edge_i, 0, "car crossed the junction on green")
	t.gt(c.speed, 1.0, "and is moving again")


## The brief asks for a minority who run reds. Not none of them, and not chaos.
func _compliance(t: TestHarness) -> void:
	var m := TrafficManager.spawn(null, g, 240)
	var runners := 0
	for c in m.cars:
		if c.obedience < 1.0:
			runners += 1
	var frac := float(runners) / float(maxi(m.cars.size(), 1))
	t.gt(runners, 0, "some drivers run red lights (%d of %d)" % [runners, m.cars.size()])
	t.between(frac, 0.02, 0.25, "and they are a minority of the traffic (%.1f%%)" % (frac * 100.0))

	# A runner does not even slow down for the junction.
	var c := _car(g, lights, _longest_edge(g), 0.0, "wandoo_sedan", 0)
	c.obedience = 0.0
	c.speed = c.cruise_speed()
	t.eq(c.signal_gap(), -1.0, "a non-compliant driver is never told to stop")
	for i in 300:
		c.tick(1.0 / 60.0, c.signal_gap(), 0.0)
	t.gt(c.speed, 1.0, "and keeps rolling straight through the red")


## Junctions are where a traffic system turns into a traffic accident. Every
## choice has to be a real edge out of the right node, never a U-turn, and never
## the wrong way down a one-way.
func _junction_choices(t: TestHarness) -> void:
	var og := _oneway_graph()
	var illegal := 0
	var choices := 0
	for n in og.nodes:
		for from_edge in n["edges"]:
			# Arriving at either end of the edge is a legitimate approach.
			for arrive in [int(og.edges[from_edge]["a"]), int(og.edges[from_edge]["b"])]:
				for k in 12:
					var c := TrafficCar.new()
					c.graph = og
					var pick: int = c.choose_next_edge(arrive, from_edge, _rng(k * 31 + int(n["id"])))
					if pick < 0:
						continue
					choices += 1
					if not (og.nodes[arrive]["edges"] as Array).has(pick):
						illegal += 1
					elif og.nodes[arrive]["edges"].size() > 1 and pick == from_edge:
						illegal += 1
					elif bool(og.edges[pick].get("oneway", false)) and int(og.edges[pick]["a"]) != arrive:
						illegal += 1
	t.gt(choices, 30, "junctions produced plenty of routes to check (%d)" % choices)
	t.eq(illegal, 0, "every choice is a real edge out of that node, never a U-turn, never against a one-way")

	# One-way data really is in the graph, or the test above proves nothing.
	var oneway_edges := 0
	for e in og.edges:
		if bool(e.get("oneway", false)):
			oneway_edges += 1
	t.gt(oneway_edges, 1, "the test network has a genuine one-way in it (%d edges)" % oneway_edges)

	# A dead end is the one place reversing is correct.
	for n in og.nodes:
		if n["edges"].size() == 1:
			var only: int = int(n["edges"][0])
			var car := TrafficCar.new()
			car.graph = og
			t.eq(car.choose_next_edge(int(n["id"]), only, _rng(1)), only,
				"a dead end may be turned around in")
			break

	# Live traffic on the real network obeys the same rules.
	var live := TrafficManager.spawn(null, g, 30)
	var reversed := 0
	var off_route := 0
	for c in live.cars:
		if c.finished():
			continue
		var nxt: int = c.choose_next_edge(c.exit_node(), c.edge(), rng)
		if nxt < 0:
			continue
		if nxt != c.edge() and not (g.nodes[c.exit_node()]["edges"] as Array).has(nxt):
			off_route += 1
		if nxt == c.edge() and g.nodes[c.exit_node()]["edges"].size() > 1:
			reversed += 1
		if bool(g.edges[nxt].get("oneway", false)) and int(g.edges[nxt]["a"]) != c.exit_node():
			reversed += 1
	t.eq(reversed, 0, "live traffic never turns around or reverses down a one-way")
	t.eq(off_route, 0, "and never picks an edge that is not at the junction")


## Density management, and the rule that matters most: no two cars in the same
## place, or the player meets a wall instead of a queue.
func _density(t: TestHarness) -> void:
	var m := TrafficManager.spawn(null, g, 30)
	t.eq(m.cars.size(), 30, "spawning 30 cars yields 30 cars")

	var closest := 1e9
	for i in m.cars.size():
		for j in range(i + 1, m.cars.size()):
			closest = minf(closest, m.cars[i].position().distance_to(m.cars[j].position()))
	t.gt(closest, TrafficManager.MIN_SPAWN_GAP, "no two cars spawn on top of each other (closest %.1f m)" % closest)

	# Spread out, not a queue in one corner.
	var cells := {}
	for c in m.cars:
		var key := "%d_%d" % [int(floor(c.position().x / 250.0)), int(floor(c.position().z / 250.0))]
		cells[key] = int(cells.get(key, 0)) + 1
	t.gt(cells.size(), 8, "traffic spreads across the map, not one corner (%d cells occupied)" % cells.size())

	m.despawn_to(0)
	t.eq(m.cars.size(), 0, "despawning empties the streets")
	m.tick(1.0 / 60.0)
	t.eq(m.cars.size(), 30, "the density controller puts the population back")

	m.despawn_to(11)
	t.eq(m.cars.size(), 11, "despawning to a specific count works")
	m.tick(1.0 / 60.0)
	t.eq(m.cars.size(), 30, "and the target still wins over the low-water mark")

	# It runs for a while without anybody falling off the network.
	for i in 900:
		m.tick(1.0 / 60.0)
	t.eq(m.cars.size(), 30, "population holds at target over 15 s of driving")
	var off_road := 0
	for c in m.cars:
		if c.finished() or c.lateral > float(g.edges[c.edge()]["width"]) * 0.5:
			off_road += 1
	t.eq(off_road, 0, "every live car is still on a real lane on a real edge")


## The query the game calls every frame to decide whether the next corner is
## going to be a problem.
func _forward_query(t: TestHarness) -> void:
	var m := _empty_manager()
	var eid := _longest_edge(g)
	var victim := _car(g, lights, eid, g.edge_length(eid) * 0.7, "milgate_van", 0)
	victim.speed = 8.0
	m.cars = [victim]
	m.reindex()

	var p: Vector3 = victim.position() - victim.heading() * 14.0
	m.set_player(p, victim.heading(), 30.0)

	var hit: Dictionary = m.car_ahead(p, victim.heading(), 60.0, victim.lane_width())
	t.eq(hit["found"], true, "forward query finds a car placed ahead")
	t.near(float(hit["distance"]), 14.0, 2.0, "and reports the right distance (%.1f m)" % float(hit["distance"]))
	t.eq(hit["car"], victim, "and returns the right car")
	t.eq(hit["speed"], 8.0, "and its speed")
	t.gt(float(hit["closing"]), 0.0, "and how fast the player is running into it")

	t.eq(m.car_ahead(p, -victim.heading(), 60.0, victim.lane_width())["found"], false,
		"looking the other way finds nothing")
	t.eq(m.car_ahead(p, victim.heading(), 5.0, victim.lane_width())["found"], false,
		"a car beyond the search range is not reported")
	var across: Vector3 = p + victim.heading().cross(Vector3.UP) * (victim.lane_width() * 3.0)
	t.eq(m.car_ahead(across, victim.heading(), 60.0, victim.lane_width())["found"], false,
		"a car in the next lane is not in front of me")

	# An empty road, and a road with cars on it somewhere else entirely.
	m.clear_player()
	t.eq(m.car_ahead(Vector3(6000.0, 0.0, 6000.0), Vector3.FORWARD, 60.0, 3.2)["found"], false,
		"an empty road reports nothing")
	m.despawn_to(0)
	m.reindex()
	t.eq(m.car_ahead(p, victim.heading(), 60.0, victim.lane_width())["found"], false,
		"a cleared road reports nothing even from where the car was")

	# The player's car is an obstacle the traffic has to give way to, which is
	# the entire reason racing through the city is dangerous.
	var blocker := _car(g, lights, eid, g.edge_length(eid) * 0.7, "wandoo_sedan", 0)
	blocker.obedience = 1.0
	m.cars = [blocker]
	m.set_player(blocker.position() + blocker.heading() * 14.0, blocker.heading(), 0.0, 2.3)
	m.reindex()
	var gap := m._leader_gap(blocker)
	t.eq(float(gap["gap"]) >= 0.0, true, "traffic sees the player stopped in front of it (%.1f m)" % float(gap["gap"]))
	m.clear_player()
	m.reindex()
	t.eq(m._leader_gap(blocker)["gap"], -1.0, "and ignores the player once the game clears it")


## Parked cars are at the kerb, not straddling a travel lane.
func _parked_cars(t: TestHarness) -> void:
	var parked: Array = ParkedCars.place(g, 1234, 1.0)
	t.gt(parked.size(), 80, "the streets are occupied (%.0f parked cars)" % parked.size())
	t.eq(parked.size(), ParkedCars.place(g, 1234, 1.0).size(), "placement is deterministic for a seed")

	var off_road := 0
	var in_lane := 0
	var stacked := 0
	var tightest := 1e9
	for i in parked.size():
		var p: Dictionary = parked[i]
		var lat: float = absf(float(p["lateral"]))
		var half: float = float(p["road_half_width"])
		var width: float = (p["spec"] as CarSpec).body_width
		if lat + 0.5 * width > half:
			off_road += 1          # standing on the footpath
		if lat < half - ParkedCars.KERB_DEPTH:
			in_lane += 1           # out in a travel lane
		for j in range(i + 1, parked.size()):
			var q: Dictionary = parked[j]
			var d: float = (p["position"] as Vector3).distance_to(q["position"])
			tightest = minf(tightest, d)
			# Two parked cars may not occupy the same kerb space.
			if d < 0.5 * ((p["spec"] as CarSpec).body_length + (q["spec"] as CarSpec).body_length):
				stacked += 1
				break
	t.eq(off_road, 0, "no parked car stands on the footpath")
	t.eq(in_lane, 0, "no parked car sits in a travel lane")
	t.eq(stacked, 0, "no two parked cars occupy the same space (tightest %.1f m apart)" % tightest)
	t.gt(ParkedCars.place(g, 1234, 2.5).size(), parked.size(), "more parking when you ask for more")


## The roster is the difference between a city and a conveyor belt.
func _roster(t: TestHarness) -> void:
	t.eq(CivilianCars.ALL_IDS.size(), 8, "roster has 8 civilian vehicles")
	var silhouettes := {}
	var accels := {}
	for id in CivilianCars.ALL_IDS:
		var s: CarSpec = CivilianCars.get_spec(id)
		t.eq(s.id, id, "%s is registered under its own id" % id)
		t.fails(s.display_name.is_empty(), "%s has a display name" % id)
		t.gt(s.mass, 400.0, "%s has a plausible mass (%.0f kg)" % [id, s.mass])
		t.between(s.body_length, 3.0, 6.6, "%s has a plausible length" % id)
		t.between(s.body_width, 1.4, 2.3, "%s has a plausible width" % id)
		t.between(s.body_height, 1.2, 2.8, "%s has a plausible height" % id)
		t.gt(s.tyre_peak_mu, 0.5, "%s has usable grip" % id)
		t.gt(s.top_speed_mps(), 20.0, "%s has a top speed" % id)
		silhouettes["%.2f/%.2f/%.2f" % [s.body_length, s.body_width, s.body_height]] = true
		# The driving character the traffic system derives from the spec.
		var c := TrafficCar.new()
		c.set_spec(s, _rng(7))
		t.between(c.accel, 0.6, 6.0, "%s has a sane pull-away acceleration (%.2f m/s2)" % [id, c.accel])
		t.between(c.decel, 2.0, 9.0, "%s can stop (%.2f m/s2)" % [id, c.decel])
		t.between(c.cruise_factor, 0.3, 1.0, "%s cruises under the speed limit" % id)
		accels[id] = c.accel
	t.eq(silhouettes.size(), 8, "all 8 have distinct silhouettes")

	# The roster has to be ordered like the real thing: the family hatchback is
	# quickest off the line and the loaded tray truck is last, every step of the
	# way. A total order is a much stronger claim than any single ratio.
	var order := ["corvo_hatch", "wandoo_sedan", "binda_suv", "quill_mini",
		"tallow_ute", "reef_ute", "milgate_van", "barra_truck"]
	for i in order.size() - 1:
		t.ok(float(accels[order[i]]) > float(accels[order[i + 1]]),
			"%s pulls away harder than the %s (%.2f vs %.2f m/s2)"
				% [order[i], order[i + 1], float(accels[order[i]]), float(accels[order[i + 1]])])
	t.ok(float(accels["barra_truck"]) < float(accels["corvo_hatch"]) * 0.5,
		"the tray truck is less than half the acceleration of the hatchback")
	t.eq(silhouettes.size(), 8, "silhouettes and drive characters are both distinct")


# ---------------------------------------------------------------------- helpers

func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


## A manager with nothing in it, for driving a specific pair of cars.
func _empty_manager() -> TrafficManager:
	var m := TrafficManager.new()
	m.graph = g
	m.lights = lights
	m.rng.seed = 99
	m.target_count = 0
	return m


## A ready-to-drive car partway along an edge, with a route long enough not to
## run out mid-test.
func _car(graph: RoadGraph, sig: TrafficLights, eid: int, along: float,
		model: String, lane: int) -> TrafficCar:
	var c := TrafficCar.new()
	c.graph = graph
	c.lights = sig
	c.place(graph, eid, true, along)
	c.set_lane(lane)
	c.lateral = c.target_lateral
	c.set_spec(CivilianCars.get_spec(model), _rng(eid * 7 + int(along)))
	for i in 20:
		if not c.extend_route(rng):
			break
	return c


## The longest non-arterial edge: long enough that a car following another has
## room to do the whole test without reaching a junction.
func _longest_edge(graph: RoadGraph) -> int:
	var best := 0
	var best_len := 0.0
	for e in graph.edges:
		if int(e["class"]) > RoadGraph.RoadClass.ARTERIAL:
			continue
		var l: float = graph.edge_length(int(e["id"]))
		if l > best_len:
			best_len = l
			best = int(e["id"])
	return best


## A miniature network with a genuine one-way, so the legality rules are
## actually exercised rather than trivially true.
func _oneway_graph() -> RoadGraph:
	var og := RoadGraph.new()
	og.build([
		{"name": "ONE WAY", "class": RoadGraph.RoadClass.STREET, "oneway": true,
			"points": [Vector2(0, 0), Vector2(0, 100)]},
		{"name": "CROSS", "class": RoadGraph.RoadClass.STREET,
			"points": [Vector2(-100, 50), Vector2(100, 50)]},
		{"name": "SPUR", "class": RoadGraph.RoadClass.STREET,
			"points": [Vector2(0, 100), Vector2(200, 100)]},
	])
	return og
