extends RefCounted
## Tests for the wheels CarVisual lifts back out of a scanned glb.
##
## The scanned models are all different - two of them name their wheels
## Object_NN, one bakes both front wheels into a single mesh across the
## centreline, one welds its tyres into the body panels - so these tests are
## written against what the rig has to guarantee rather than against any one
## model's node names: every car in the roster ends up with four steer/spin
## pairs, the spin node turns by exactly the angle the tyre model reports, and
## the steer node answers the steering input.

const CORNERS := ["FL", "FR", "RL", "RR"]


## Builds a world with a flat ground plane and returns it.
static func make_world(t: TestHarness) -> Node3D:
	var world := t.new_root("ScanWorld")
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0, -0.5, 0)
	world.add_child(body)
	return world


## Every car in the roster is dropped into the same world, so they are parked a
## car's-length apart: sharing a spawn point turns the run into a pile-up and the
## wheels stop touching anything.
static func spawn(world: Node3D, car_id: String, slot: int) -> CarBody:
	var spec := CarDB.get_spec(car_id)
	var at := Vector3(float(slot) * 12.0, spec.tyre_radius + 0.05, 0.0)
	spec.start_position = at
	spec.start_rotation = Vector3.ZERO
	var car := CarBody.new()
	car.spec = spec
	world.add_child(car)
	return car


## Total vertices across every mesh under a rig node.
static func mesh_verts(node: Node) -> int:
	var total: int = 0
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh: Mesh = (child as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				total += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return total


## Every car in the roster, scanned or procedural, has to end up with a full set
## of wheel rigs and real geometry under them.
static func _every_car_has_four_wheels(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(4)
		var vis := car.visual
		t.ok(vis != null, "%s builds a visual" % car_id)
		var nodes: Array = vis.wheel_nodes()
		t.eq(nodes.size(), 4, "%s has four wheel rigs" % car_id)
		var seen := {}
		for w in nodes:
			seen[String(w["name"])] = true
			t.ok(w["steer"] is Node3D and w["spin"] is Node3D, "%s %s rig is steer+spin" % [car_id, w["name"]])
			var spin: Node3D = w["spin"]
			t.ok(mesh_verts(spin) > 0, "%s %s rig carries geometry" % [car_id, w["name"]])
		for corner in CORNERS:
			t.ok(seen.has(corner), "%s has a %s rig" % [car_id, corner])
		car.queue_free()
		await t.ticks(1)



## The scanned cars are the point of the change, so they are checked by name: a
## silent fall back to procedural cylinders on a scanned car would still pass the
## test above.
## Four of the five models carry per-corner wheel nodes, so those cars must be
## rigged from that geometry. wrx_gc8 has its tyres welded into its body panels:
## the scan says so, and the car must then take the fit convention's procedural
## wheels rather than spin a bumper blade or half a body panel.
const SCANNED_MODELS := ["akuma_gt", "hayate_turbo", "kairo_s13", "tatsuya_gt"]
const BAKED_MODELS := ["shinobi_rs"]


static func _scanned_cars_are_rigged(t: TestHarness, world: Node3D) -> void:
	for slot in CarVisual.MODELS.keys().size():
		var car_id: String = CarVisual.MODELS.keys()[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(4)
		var vis := car.visual
		var scanned: int = 0
		for w in vis.wheel_nodes():
			var spin: Node3D = w["spin"]
			for child in spin.get_children():
				if child is MeshInstance3D and (child as MeshInstance3D).mesh is ArrayMesh:
					scanned += 1
		if SCANNED_MODELS.has(car_id):
			t.ok(scanned > 0, "%s rigs wheel geometry" % car_id)
			t.eq(vis.scan_fallback_reason(), "",
				"%s rigs its own wheel nodes without falling back" % car_id)
			# A cylinder rig is two MeshInstance3D children per wheel; a scanned rig
			# never has fewer, and never has a CylinderMesh.
			for w in vis.wheel_nodes():
				var spin: Node3D = w["spin"]
				for child in spin.get_children():
					if child is MeshInstance3D:
						t.ok(not ((child as MeshInstance3D).mesh is CylinderMesh),
							"%s %s uses scan geometry" % [car_id, String(w["name"])])
		else:
			t.ok(vis.scan_fallback_reason().length() > 0,
				"%s records why it cannot rig its own wheels" % car_id)
			# The fallback has to sit on the fit convention, not wherever the scan
			# gave up, or the procedural wheel ends up inside the arch. Its height
			# is the strut's own compression, so the axle is checked in x/z and the
			# height against the physics rather than against zero.
			var spec := car.spec
			var half_track: float = spec.track_width * 0.5
			var half_base: float = spec.wheelbase * 0.5
			for w in vis.wheel_nodes():
				var steer: Node3D = w["steer"]
				var corner := String(w["name"])
				t.eq(steer.get_child_count(), 1, "%s %s has a spin node" % [car_id, corner])
				var x: float = -half_track if corner.ends_with("L") else half_track
				var z: float = -half_base if corner.begins_with("F") else half_base
				t.near(steer.position.x, x, 0.0001, "%s %s sits on the fit track" % [car_id, corner])
				t.near(steer.position.z, z, 0.0001, "%s %s sits on the fit wheelbase" % [car_id, corner])
				t.near(steer.position.y, float(car.get_wheel(corner)["compression"]), 0.001,
					"%s %s hangs at its own strut compression" % [car_id, corner])
		car.queue_free()
		await t.ticks(1)


## Every model on the roster has to end up with four steer/spin rigs, whether it
## was rigged from its own geometry or from the procedural fallback, and the
## baked case has to be named rather than silently shipping cylinders.
static func _roster_split_is_known(t: TestHarness, world: Node3D) -> void:
	var scanned: Array[String] = []
	var baked: Array[String] = []
	for slot in CarVisual.MODELS.keys().size():
		var car_id: String = CarVisual.MODELS.keys()[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(4)
		if car.visual.scan_fallback_reason().is_empty():
			scanned.append(car_id)
		else:
			baked.append(car_id)
		t.eq(car.visual.wheel_nodes().size(), 4, "%s ends up with four rigs" % car_id)
		car.queue_free()
		await t.ticks(1)
	scanned.sort()
	baked.sort()
	t.eq(scanned, SCANNED_MODELS, "exactly the models with per-corner wheel nodes are rigged")
	t.eq(baked, BAKED_MODELS, "exactly the models with welded tyres fall back")



## The wheels have to follow the tyre model, not a clock. Driving in a straight
## line and comparing the spin node's angle with the wheel's own `spin_vis`
## catches a rig that turns the wrong axis, the wrong way, or not at all.
static func _spin_follows_the_tyre_model(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		car.throttle = 0.85
		car.steer = 0.0
		await t.ticks(90)
		for w in car.visual.wheel_nodes():
			var name := String(w["name"])
			var src: Dictionary = car.get_wheel(name)
			var spin: Node3D = w["spin"]
			t.eq(snappedf(spin.rotation.x, 0.0001), snappedf(float(src["spin_vis"]), 0.0001),
				"%s %s spin node tracks spin_vis" % [car_id, name])
			t.ok(src["omega"] > 0.0, "%s %s is rolling (omega %.2f rad/s)" % [car_id, name, float(src["omega"])])
			t.ok(src["contact"], "%s %s is on the ground" % [car_id, name])
		# And the rig has to have actually turned, not merely agree with a zero.
		t.ok(car.get_wheel("RL")["spin_vis"] > 0.05, "%s rear wheel has turned" % car_id)
		car.queue_free()
		await t.ticks(1)



## Spin accumulates from a wrapped angle, so a long run has to add up rather than
## stick at TAU. Accumulated here rather than read off the node, because the node
## holds a wrapped angle by design.
static func _spin_advances_monotonically(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		car.throttle = 1.0
		await t.ticks(60)
		var before: float = float(car.get_wheel("RR")["spin_vis"])
		var wrapped: float = before
		var unwrapped: float = before
		for i in 240:
			await t.ticks(1)
			var now: float = float(car.get_wheel("RR")["spin_vis"])
			# `spin_vis` is wrapped into [0, TAU), so each tick's contribution is the
			# shortest arc between two wrapped values, not their difference.
			unwrapped += fposmod(now - wrapped + PI, TAU) - PI
			wrapped = now
		var total: float = unwrapped - before
		t.ok(total > 1.0, "%s wheel accumulated %.2f rad over 4 s of full throttle" % [car_id, total])
		t.eq(snappedf(fposmod(unwrapped, TAU), 0.01), snappedf(wrapped, 0.01),
			"%s accumulated angle agrees with the wrapped one" % car_id)
		car.queue_free()
		await t.ticks(1)



## Steering input has to reach the front wheels and only the front wheels.
static func _steering_reaches_the_front_wheels(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(30)
		car.throttle = 0.5
		car.steer = 1.0
		await t.ticks(45)
		var front := 0.0
		for name in ["FL", "FR"]:
			var src: Dictionary = car.get_wheel(name)
			var steer: Node3D = car.visual.wheel_nodes()[CORNERS.find(name)]["steer"]
			t.eq(snappedf(steer.rotation.y, 0.0001), snappedf(float(src["steer_angle"]), 0.0001),
				"%s %s steer node tracks steer_angle" % [car_id, name])
			t.ok(absf(float(src["steer_angle"])) > 0.01, "%s %s is steered (%.4f rad)" % [car_id, name, float(src["steer_angle"])])
			front = maxf(front, absf(float(src["steer_angle"])))
		for name in ["RL", "RR"]:
			t.ok(absf(float(car.get_wheel(name)["steer_angle"])) < 1e-6,
				"%s %s stays straight" % [car_id, name])
		t.ok(front > 0.01, "%s steers its front wheels" % car_id)
		car.queue_free()
		await t.ticks(1)



## True lowest world-space vertex under a node. A world AABB is the bottom of a
## box drawn round a tilted wheel, which sits lower than the tyre does - the
## measured error was 6 cm on a car that was parked dead level - so contact has to
## be asked of the vertices.
## The road surface in this world: a flat plane whose top is y=0.
static func road_y() -> float:
	return 0.0


static func lowest_vertex(node: Node) -> float:
	var low := INF
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			for v in verts:
				low = minf(low, (mi.global_transform * v).y)
	for child in node.get_children():
		low = minf(low, lowest_vertex(child))
	return low


## Every tyre has to be ON the road, not above it and not through it, and the
## physics has to agree that it is carrying load. This is the check the whole rig
## used to fail: the wheels were hung twice their own axle offset from the
## geometry they held, a metre up and at the wrong end of the car, and every test
## above still passed because they only ever counted nodes and compared angles.
##
## The tolerance is the model's own tyre radius against the spec's, which is a
## property of the downloaded glb and not something the rig can change: measured
## worst case is the Supra at 41 mm, whose baked tyres are 0.358 m across the
## hub where the spec says 0.320 m. Everything else is inside 30 mm.
const CONTACT_TOL := 0.045
const SHELL_CLEARANCE := 0.20    ## most the shell may sit above the road once its
                                 ## tyres are accounted for (the Supra: 142 mm)


static func _all_four_tyres_reach_the_road(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(150)          # long enough for the springs to settle
		t.eq(car.wheels_on_ground, 4, "%s has all four wheels on the ground" % car_id)
		# The car has to be ON the road, not hovering over it. The imported models
		# were dropped the wrong way by a whole tyre radius, which left the body
		# 0.5 m up; every wheel test below still passed, because the wheel rig hangs
		# off the car rather than off the model holder and so cannot see it. This is
		# the only assertion in the suite that looks at the shell.
		var holder := car.visual.get_node_or_null("Model") as Node3D
		t.between(lowest_vertex(car.visual) - road_y(), -CONTACT_TOL, CONTACT_TOL,
			"%s lowest geometry reaches the road (%.3f m, road %.3f m)" % [
				car_id, lowest_vertex(car.visual), road_y()])
		if holder != null:
			# The shell's own lowest vertex is the arch lip, not the tyre: the tyres
			# are the model's lowest geometry and they have been lifted into the rig.
			# The Supra's is the highest on the roster at 142 mm; the lift bug put it
			# at 750 mm.
			t.between(lowest_vertex(holder) - road_y(), -CONTACT_TOL, SHELL_CLEARANCE,
				"%s shell stands on the road, not above it (%.3f m, road %.3f m)" % [
					car_id, lowest_vertex(holder), road_y()])
		for w in car.visual.wheel_nodes():
			var name := String(w["name"])
			var src: Dictionary = car.get_wheel(name)
			t.ok(bool(src["contact"]), "%s %s physics reports contact" % [car_id, name])
			t.gt(float(src["load"]), 1.0, "%s %s carries load (%.0f N)" % [car_id, name, float(src["load"])])
			# Asked: the strut's own contact point. Got: the tyre geometry's lowest
			# vertex in the world.
			var road: float = float(src["contact_point"].y)
			var tyre_y: float = lowest_vertex(w["spin"])
			t.between(tyre_y - road, -CONTACT_TOL, CONTACT_TOL,
				"%s %s tyre reaches the road (tyre %.3f m, road %.3f m)" % [car_id, name, tyre_y, road])
			# Asked: the mount plus the strut's compression. Got: where the rig put
			# it. These differ by at most one frame of settling.
			var asked: Vector3 = (car.get_wheel(name)["mount"] as Vector3) \
				+ Vector3(0.0, float(src["compression"]), 0.0)
			var got: Vector3 = (w["steer"] as Node3D).position
			t.between((got - asked).length(), 0.0, 0.02,
				"%s %s rig sits where its strut put it (%.3f m off)" % [car_id, name, (got - asked).length()])
		car.queue_free()
		await t.ticks(1)


## The geometry a wheel node holds is baked about that wheel's hub, so the node's
## own transform is the wheel's placement. Baked in absolute car space instead -
## which is what it was - the same node moves the geometry a second time: measured
## 2.00 m on the player's S13, 2.28 m on the Supra.
const HUB_LOCAL_TOL := 0.20


static func _wheel_geometry_is_baked_on_its_hub(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(4)
		for w in car.visual.wheel_nodes():
			var name := String(w["name"])
			var centre := Vector3.ZERO
			var count: int = 0
			for child in (w["spin"] as Node).get_children():
				if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
					var mi := child as MeshInstance3D
					for s in mi.mesh.get_surface_count():
						var verts: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
						for v in verts:
							centre += v
							count += 1
			if count == 0:
				t.ok(false, "%s %s has vertices to centre" % [car_id, name])
				continue
			centre /= float(count)
			t.between(centre.length(), 0.0, HUB_LOCAL_TOL,
				"%s %s geometry is centred on its own hub (%.3f m off)" % [car_id, name, centre.length()])
		car.queue_free()
		await t.ticks(1)


## Steering has to reach the wheel as a rotation about the right axis at the
## right angle. The physics builds its wheel frame as `basis.rotated(UP,
## steer_angle)` and reads the rolling direction off it as -Z, so the rig's wheel
## frame has to end up pointing -Z the same way. The tolerance is 2.5 deg: the rig
## turns about the car's own Y, and the difference from the physics' world-up
## rotation is second order because -Z is perpendicular to that axis - measured at
## 0.3 deg on a body pitched 6 deg. The axle check is the other half: the wheel has
## to spin about its axle, not about its own rolling direction.
static func _front_wheels_steer_where_the_physics_steers(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(150)
		for sign_input in [1.0, -1.0]:
			car.steer = sign_input
			await t.ticks(4)
			for name in ["FL", "FR", "RL", "RR"]:
				var src: Dictionary = car.get_wheel(name)
				var w: Dictionary = car.visual.wheel_nodes()[CORNERS.find(name)]
				var steer_node: Node3D = w["steer"]
				var spin_node: Node3D = w["spin"]
				var asked := -car.global_transform.basis.rotated(Vector3.UP,
					float(src["steer_angle"])).z
				var got := -steer_node.global_basis.z
				t.gt(got.normalized().dot(asked.normalized()), 0.999,
					"%s %s %s wheel frame follows the physics (%.4f rad asked)" % [
						car_id, name, "left" if sign_input > 0.0 else "right", float(src["steer_angle"])])
				# The spin node's X is the axle: it has to stay square across the
				# rolling direction and roughly level, or the wheel is spinning
				# about the wrong axis or lying on its edge.
				var axle: Vector3 = spin_node.global_basis * Vector3.RIGHT
				t.near(absf(axle.normalized().dot(got.normalized())), 0.0, 0.05,
					"%s %s axle is square across its rolling direction" % [car_id, name])
				t.near(absf(axle.normalized().dot(Vector3.UP)), 0.0, 0.20,
					"%s %s axle is level with the road" % [car_id, name])
				if name.begins_with("F"):
					t.ok(signf(float(src["steer_angle"])) == sign_input,
						"%s %s takes the input's sign" % [car_id, name])
				else:
					t.near(float(src["steer_angle"]), 0.0, 1e-6, "%s %s stays straight" % [car_id, name])
		car.steer = 0.0
		await t.ticks(4)
		car.steer = 0.0
		car.queue_free()
		await t.ticks(1)


## Rolling is a rate, and the visual has to show the rate the tyre model
## integrates rather than one of its own: `spin_vis` accumulates `omega * delta`,
## so summing omega over the run has to reproduce the angle the wheel mesh ended
## up at. The road distance is the sanity band around it, not the target - slip is
## the tyre model's job and is not this rig's - so the check is that the wheel
## turns the same way, at a plausible fraction of the rolling rate, instead of
## standing still or spinning on the spot.
##
## `spin_vis` is a wrapped angle and three seconds of rolling is twenty-odd turns,
## so no single difference can recover it: each tick contributes the shortest arc
## between two wrapped values and the running sum is the real rotation.
static func _wheels_roll_at_the_rolling_rate(t: TestHarness, world: Node3D) -> void:
	for slot in CarDB.ALL_IDS.size():
		var car_id: String = CarDB.ALL_IDS[slot]
		var car := spawn(world, car_id, slot)
		await t.ticks(90)
		car.throttle = 0.6
		await t.ticks(120)          # get up to speed and hold a line
		var start := car.global_position
		var wrapped := {}
		var turned := {}
		var integrated := {}
		for name in CORNERS:
			wrapped[name] = float(car.get_wheel(name)["spin_vis"])
			turned[name] = 0.0
			integrated[name] = 0.0
		var ticks := 180
		var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
		for i in ticks:
			await t.ticks(1)
			for name in CORNERS:
				var src: Dictionary = car.get_wheel(name)
				var now: float = float(src["spin_vis"])
				turned[name] = float(turned[name]) + fposmod(now - float(wrapped[name]) + PI, TAU) - PI
				integrated[name] = float(integrated[name]) + float(src["omega"]) * dt
				wrapped[name] = now
		var travelled: float = car.global_position.distance_to(start)
		var roll: float = travelled / car.spec.tyre_radius
		for name in CORNERS:
			var src: Dictionary = car.get_wheel(name)
			var node: Node3D = car.visual.wheel_nodes()[CORNERS.find(name)]["spin"]
			t.near(float(turned[name]), float(integrated[name]), 0.5,
				"%s %s angle matches the integral of its own omega" % [car_id, name])
			# Forward motion, forward wheels, at a rate a rolling tyre could manage.
			t.between(float(turned[name]) / maxf(roll, 0.001), 0.5, 2.0,
				"%s %s turns forward at %.2f x the rolling rate (%.1f kph, %.2f rad vs %.2f)" % [
					car_id, name, float(turned[name]) / maxf(roll, 0.001), car.speed_kph,
					float(turned[name]), roll])
			t.eq(snappedf(node.rotation.x, 0.0001), snappedf(float(src["spin_vis"]), 0.0001),
				"%s %s node shows the angle the tyre model integrated" % [car_id, name])
		car.queue_free()
		await t.ticks(1)


func run(t: TestHarness) -> void:
	var world := make_world(t)
	await _every_car_has_four_wheels(t, world)
	await _scanned_cars_are_rigged(t, world)
	await _roster_split_is_known(t, world)
	await _all_four_tyres_reach_the_road(t, world)
	await _wheel_geometry_is_baked_on_its_hub(t, world)
	await _spin_follows_the_tyre_model(t, world)
	await _spin_advances_monotonically(t, world)
	await _steering_reaches_the_front_wheels(t, world)
	await _front_wheels_steer_where_the_physics_steers(t, world)
	await _wheels_roll_at_the_rolling_rate(t, world)
	await t.drop(world)
