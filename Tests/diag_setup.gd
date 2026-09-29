extends SceneTree
## Isolates why CarBody's _ready settings do not stick.

func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var spec := CarDB.get_spec("kairo_s13")
	print("spec.mass=", spec.mass, " spec.tyre_radius=", spec.tyre_radius)

	var car := CarBody.new()
	print("BEFORE add_child: mass=", car.mass, " mode=", car.center_of_mass_mode, " spec=", car.spec)
	car.spec = spec
	world.add_child(car)
	print("AFTER  add_child: mass=", car.mass, " mode=", car.center_of_mass_mode,
		" com=", car.center_of_mass, " com_off_expected=", car.cg_height_offset())
	print("has _ready called? wheels=", car.wheels().size())

	await process_frame
	print("AFTER 1 frame  : mass=", car.mass, " mode=", car.center_of_mass_mode,
		" com=", car.center_of_mass, " layer=", car.collision_layer, " mask=", car.collision_mask)
	quit(0)
