class_name CarVisual
extends Node3D
## The car you actually see. CarBody is physics with no opinion about looks, so
## this builds the exterior procedurally from a CarSpec: a box body, a glass
## greenhouse, a roof, wheels that steer and spin off the real suspension data,
## and working lights.
##
## Boxes on purpose. There are no downloaded assets in this project, and a
## stack of well-proportioned boxes with a good paint material reads as a car at
## night far better than an untextured sphere ever would. Every dimension comes
## from the spec, so a new car in CarDB looks right without touching this file.
##
## The wheels are the only part that has to be built, because the physics already
## computes the right answer for them: each wheel carries its own `steer_angle`
## and `spin_vis`, so the visual follows the tyre model rather than guessing.

## Paint names used by CarDB, as colours. Metallic and low roughness because a
## car in the rain at night is a mirror - the reflection probe on the player
## gives it something to reflect.
const PAINTS := {
	"primer_grey": Color(0.20, 0.20, 0.21),
	"faded_white": Color(0.62, 0.61, 0.57),
	"storm_white": Color(0.78, 0.79, 0.80),
	"pearl_white": Color(0.86, 0.87, 0.88),
	"midnight_blue": Color(0.035, 0.055, 0.115),
	"gunmetal": Color(0.13, 0.14, 0.16),
	"racing_green": Color(0.045, 0.19, 0.10),
	"taxi_yellow": Color(0.72, 0.50, 0.04),
	"burnt_orange": Color(0.42, 0.13, 0.03),
}

const TAIL_IDLE := 1.1      ## emission energy with the brakes off
const TAIL_BRAKING := 4.0   ## ... and with them on. This is a brake light; it
                            ## has to be unmissable in a mirror at 200 km/h,
                            ## but past the glow threshold the lens turns into
                            ## a white blob and the shape of the car is lost.
const REVERSE_IDLE := 0.0
const REVERSE_ON := 4.0

var spec: CarSpec

var _wheels: Array = []          ## [{ "name": String, "steer": Node3D, "spin": Node3D }]
var _tail_mat: StandardMaterial3D
var _reverse_mat: StandardMaterial3D
var _tail_lens: Array[MeshInstance3D] = []
var _reverse_lens: Array[MeshInstance3D] = []
var _lights: Node3D              ## children of this that are Light3D


func _init() -> void:
	spec = null


## Builds the exterior. `body_spec` is the same CarSpec the physics uses, so the
## visual and the collision box can never disagree about how big the car is.
func build(body_spec: CarSpec) -> void:
	spec = body_spec
	if spec == null:
		return
	_lights = Node3D.new()
	_lights.name = "CarLights"
	add_child(_lights)

	_build_shell()
	_build_wheels()
	_build_lights()


func _build_shell() -> void:
	var w: float = spec.body_width
	var h: float = spec.body_height
	var l: float = spec.body_length
	# A coupe's cabin is short and set well back; a hatch or sedan carries more
	# glass and pushes the roof forward. Two numbers of difference is all it takes
	# for the two silhouettes to read differently at a glance.
	var coupe: bool = spec.body_style == "coupe"
	var cabin_l: float = 0.42 * l if coupe else 0.52 * l
	var cabin_z: float = 0.10 * l if coupe else 0.02 * l

	# The lower body has to be narrower than the track, or it swallows the
	# wheels whole: this car is 1.66 m wide across the body but the tyres only
	# reach 1.635 m, so at full width there is no wheel visible from any angle.
	# ponytail: no wheel arches - the body is one slab, so the tyres just stand
	# proud of it. Real arches mean splitting the body into side panels.
	var body_w: float = minf(w, spec.track_width + 0.04)
	var clearance: float = 0.10 * h
	_add_box("LowerBody", Vector3(body_w, 0.56 * h, l), Vector3(0, 0.28 * h + clearance, 0), _paint_mat())
	# Greenhouse in glass, roof panel in paint. Two boxes, and the car stops
	# looking like a shipping crate.
	_add_box("Cabin", Vector3(0.88 * w, 0.40 * h, cabin_l), Vector3(0, 0.76 * h, cabin_z), _glass_mat())
	_add_box("Roof", Vector3(0.90 * w, 0.08 * h, cabin_l * 0.92), Vector3(0, 0.99 * h, cabin_z), _paint_mat())

	if coupe:
		# A ducktail. Reads as a spoiler in silhouette, costs one box.
		_add_box("Spoiler", Vector3(0.80 * w, 0.05 * h, 0.16 * l), Vector3(0, 0.66 * h, 0.46 * l), _paint_mat())
	else:
		# A boot lid / tailgate step, so a sedan and a hatch are not the same box.
		_add_box("Boot", Vector3(0.92 * w, 0.18 * h, 0.26 * l), Vector3(0, 0.60 * h, 0.40 * l), _paint_mat())


func _build_wheels() -> void:
	var r: float = spec.tyre_radius
	var half_base: float = spec.wheelbase * 0.5
	var half_track: float = spec.track_width * 0.5
	var layout := [
		{"name": "FL", "pos": Vector3(-half_track, 0.0, -half_base)},
		{"name": "FR", "pos": Vector3(half_track, 0.0, -half_base)},
		{"name": "RL", "pos": Vector3(-half_track, 0.0, half_base)},
		{"name": "RR", "pos": Vector3(half_track, 0.0, half_base)},
	]
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.022, 0.022, 0.024)
	rubber.roughness = 0.92
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.55, 0.57, 0.62)
	rim_mat.metallic = 0.7
	rim_mat.roughness = 0.30

	for item in layout:
		# steer -> spin -> meshes, so steering and rolling compose instead of
		# fighting over the same transform.
		var steer := Node3D.new()
		steer.name = "Steer_" + String(item["name"])
		steer.position = item["pos"]
		add_child(steer)
		var spin := Node3D.new()
		spin.name = "Spin"
		steer.add_child(spin)
		_add_cylinder(spin, r, 0.215, rubber, "Tyre")
		# Protrudes 10 mm proud of the tyre on each side, so from the chase camera
		# the wheel reads as a wheel and not a black disc.
		_add_cylinder(spin, r * 0.56, 0.235, rim_mat, "Rim")
		_wheels.append({"name": String(item["name"]), "steer": steer, "spin": spin})


func _build_lights() -> void:
	var w: float = spec.body_width
	var h: float = spec.body_height
	var l: float = spec.body_length

	var lens := MatLib.emissive(Color(1.0, 0.96, 0.86), 5.0)
	_add_box("HeadL", Vector3(0.26, 0.13, 0.05), Vector3(-0.30 * w, 0.44 * h, -0.49 * l), lens)
	_add_box("HeadR", Vector3(0.26, 0.13, 0.05), Vector3(0.30 * w, 0.44 * h, -0.49 * l), lens)

	_tail_mat = MatLib.emissive(Color(1.0, 0.09, 0.05), TAIL_IDLE)
	_reverse_mat = MatLib.emissive(Color(1.0, 0.95, 0.9), REVERSE_IDLE)
	for side in [-1.0, 1.0]:
		var tail := _add_box("Tail%s" % ("L" if side < 0.0 else "R"),
			Vector3(0.30, 0.14, 0.05), Vector3(side * 0.30 * w, 0.50 * h, 0.49 * l), _tail_mat)
		_tail_lens.append(tail)
		var rev := _add_box("Reverse%s" % ("L" if side < 0.0 else "R"),
			Vector3(0.13, 0.09, 0.05), Vector3(side * 0.11 * w, 0.50 * h, 0.49 * l), _reverse_mat)
		_reverse_lens.append(rev)

	# One beam per car, not two. The two glowing lens boxes sell the "twin
	# headlight" look; a second spot light doubles the per-car lighting cost for
	# detail nobody can see from behind the car.
	var beam := SpotLight3D.new()
	beam.name = "Headlights"
	beam.position = Vector3(0, 0.52 * h, -0.48 * l)
	beam.rotation_degrees = Vector3(-7.0, 0.0, 0.0)   # -Z is forward; tilt down
	beam.spot_range = 52.0
	beam.spot_angle = 34.0
	beam.spot_angle_attenuation = 0.7
	beam.spot_attenuation = 1.1
	beam.light_color = Color(1.0, 0.95, 0.86)
	beam.light_energy = 6.5
	beam.shadow_enabled = false          # a shadowed spot per car is not worth it here
	_lights.add_child(beam)

	# A soft fill behind and above the car, so the car reads as a shape.
	#
	# Between streetlights a real car at night is a black shape, and that is
	# correct and unplayable: the player spends the entire game looking at the
	# back of their own car. This is the standard "hero light" every racing game
	# ships - dim, cool, no shadows, short range. It sits behind and above rather
	# than straight overhead, because overhead it blows the roof out to a white
	# slab and leaves the sides, which is what the player actually sees, black.
	var fill := OmniLight3D.new()
	fill.name = "HeroFill"
	# High and only slightly behind, raking down the roof and boot. It used to
	# sit at z=+3.4, which put it between the car and the chase camera, so every
	# rear-facing shot got a blown white blob across the tail instead of a car.
	fill.position = Vector3(0, 4.2, 1.6)
	fill.omni_range = 11.0
	fill.omni_attenuation = 1.6
	fill.light_color = Color(0.72, 0.80, 1.0)
	fill.light_energy = 1.5
	fill.shadow_enabled = false
	_lights.add_child(fill)


func _paint_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var col: Color = PAINTS.get(spec.default_paint, Color(0.18, 0.18, 0.19))
	m.albedo_color = col
	# Car paint is a dielectric with a clearcoat, not a metal. Metallic 0.55 was
	# the mistake: a metal car at night reflects a black sky and is therefore
	# invisible, which is precisely the failure this file exists to fix. Low
	# metallic, moderate roughness, so a streetlight actually lands on it.
	m.metallic = 0.18
	m.metallic_specular = 0.6
	m.roughness = 0.42
	return m


func _glass_mat() -> StandardMaterial3D:
	var m := MatLib.window_glass()
	m.metallic = 0.0
	m.roughness = 0.16
	return m


func _add_box(node_name: String, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = at
	mi.material_override = mat
	add_child(mi)
	return mi


func _add_cylinder(parent: Node3D, r: float, height: float, mat: Material, node_name: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var cyl := CylinderMesh.new()
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = height
	cyl.radial_segments = 12
	cyl.rings = 1
	mi.mesh = cyl
	mi.material_override = mat
	# A cylinder's axis is +Y; lay it on its side so the axis is the axle.
	mi.rotation_degrees = Vector3(0, 0, 90)
	parent.add_child(mi)


func _process(_delta: float) -> void:
	var car := get_parent() as CarBody
	if car != null and is_instance_valid(car):
		sync(car)


## Copies the physics state onto the exterior: wheels follow their own struts,
## brake lights follow the brake pedal, reverse lights follow the gear.
func sync(car: CarBody) -> void:
	for w in _wheels:
		var src: Dictionary = car.get_wheel(String(w["name"]))
		if src.is_empty():
			continue
		(w["steer"] as Node3D).rotation.y = float(src["steer_angle"])
		(w["spin"] as Node3D).rotation.x = float(src["spin_vis"])

	if _tail_mat == null:
		return
	var braking: bool = car.brake > 0.05 or car.handbrake > 0.05
	_tail_mat.emission_energy_multiplier = TAIL_BRAKING if braking else TAIL_IDLE
	_reverse_mat.emission_energy_multiplier = REVERSE_ON if car.current_gear < 0 else REVERSE_IDLE


## Lights only, for a car the player is not looking at. Same state, no mesh work.
func set_lights_on(on: bool) -> void:
	if _lights != null:
		_lights.visible = on


func wheel_nodes() -> Array:
	return _wheels
