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
			# gave up, or the procedural wheel ends up inside the arch.
			var spec := car.spec
			var half_track: float = spec.track_width * 0.5
			var half_base: float = spec.wheelbase * 0.5
			for w in vis.wheel_nodes():
				var steer: Node3D = w["steer"]
				var corner := String(w["name"])
				t.eq(steer.get_child_count(), 1, "%s %s has a spin node" % [car_id, corner])
				var x: float = -half_track if corner.ends_with("L") else half_track
				var z: float = -half_base if corner.begins_with("F") else half_base
				t.eq((steer.position - Vector3(x, 0.0, z)).length(), 0.0,
					"%s %s sits on the fit axle" % [car_id, corner])
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
			var spin: Node3D = car.visual.wheel_nodes()[CORNERS.find(name)]["spin"]
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



func run(t: TestHarness) -> void:
	var world := make_world(t)
	await _every_car_has_four_wheels(t, world)
	await _scanned_cars_are_rigged(t, world)
	await _roster_split_is_known(t, world)
	await _spin_follows_the_tyre_model(t, world)
	await _spin_advances_monotonically(t, world)
	await _steering_reaches_the_front_wheels(t, world)
	await t.drop(world)
