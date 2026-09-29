extends Node3D
## Boots the game: builds the Manunda block, puts the player in a car, and hands
## control over. Everything heavy happens once, here.

signal world_ready(graph: RoadGraph)

const SHOT_MODE := "--shot"

var graph: RoadGraph
var world: WorldBuilder
var night: NightEnv
var camera: ChaseCamera
var player_car: CarBody
var race: RaceDirector
var hud: RaceHUD
var _rivals: Array = []
var player_controller: PlayerController
var _sun: DirectionalLight3D
var _stuck_time := 0.0


func _ready() -> void:
	var shot_path := _shot_request()

	print("[Boot] building Manunda...")
	var t0 := Time.get_ticks_msec()

	graph = RoadGraph.new()
	graph.build(ManundaLayout.corridors())
	var stats: Dictionary = graph.stats()
	print("[Boot] road graph: %d junctions, %d edges, %.0f m" % [
		stats["nodes"], stats["edges"], stats["length_m"]])

	night = NightEnv.new()
	night.name = "NightEnvironment"
	add_child(night)

	# A weak cool fill from high up. Not moonlight exactly - more like the sky
	# bouncing city light - but it is what stops the scene going pitch black.
	_sun = DirectionalLight3D.new()
	_sun.light_color = MatLib.MOON
	_sun.light_energy = 0.55
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 180.0
	_sun.rotation_degrees = Vector3(-52, -128, 0)
	add_child(_sun)

	# A reflection probe that follows the player. This is what actually puts the
	# streetlights, neon and sky into the wet road - without it a low-roughness
	# surface has nothing to reflect and just reads as black plastic.
	var probe := ReflectionProbe.new()
	probe.name = "WetProbe"
	probe.size = Vector3(180, 90, 180)
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	probe.intensity = 0.9
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	probe.origin_offset = Vector3(0, 8, 0)
	probe.position = Vector3(0, 12, 40)
	add_child(probe)

	world = WorldBuilder.new()
	if OS.get_cmdline_user_args().has("--probe"):
		add_child(preload("res://Game/probe.gd").new())
	world.name = "World"
	add_child(world)
	world.build(graph)

	_spawn_player()
	world_ready.emit(graph)

	print("[Boot] world built in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))

	_start_first_race()

	if shot_path != "":
		var preset := _shot_preset()
		if preset != "":
			await get_tree().process_frame
			ShotPoser.apply(camera, preset)
		_capture(shot_path)


## Builds the first race from the road graph and drops both cars on the grid.
## The route is generated from the streets themselves, not authored, so it is
## always consistent with the map the player is actually driving on.
func _start_first_race() -> void:
	var catalogue: Array = RaceDef.catalogue(graph)
	if catalogue.is_empty():
		push_warning("no races could be built from the road graph")
		return
	var race_def: RaceDef = catalogue[1] if catalogue.size() > 1 else catalogue[0]
	print("[Race] %s: %s, %d laps, %.0f m of street" % [
		race_def.display_name, race_def.kind_name(), race_def.laps,
		race_def.length_m(graph)])

	race = RaceDirector.new()
	race.def = race_def
	if not race.try_enter(race_def):
		print("[Race] could not enter (entry fee %d, have %d) - running as a free race" % [
			race_def.entry_fee, Cfg.money])
		race_def.entry_fee = 0

	hud = RaceHUD.new()
	hud.name = "RaceHUD"
	add_child(hud)

	# The player is entrant 0, which is what the director treats as "the race
	# ends when they cross the line".
	var entrants: Array = [RaceEntrant.new(player_car)]
	entrants.append(RaceEntrant.new(_rivals[0]) if _rivals.size() > 0 else null)
	entrants = entrants.filter(func(e): return e != null)
	race.start(race_def, graph, entrants)


func _process(delta: float) -> void:
	if race != null:
		for e in race.entrants:
			if e is RaceEntrant:
				(e as RaceEntrant).sync()
		race.tick(delta)
		_recover_from_stuck(delta)
	if hud != null:
		hud.update(player_car, race, delta)


func _spawn_player() -> void:
	var spec := Cfg.active_spec()
	spec.start_position = ManundaLayout.start_grid_position(0)
	spec.start_rotation = Vector3(0, -PI * 0.5, 0)

	player_car = CarBody.new()
	player_car.name = "PlayerCar"
	player_car.spec = spec
	add_child(player_car)
	player_car.reset_to(spec.start_position, spec.start_rotation)

	camera = ChaseCamera.new()
	camera.name = "Camera"
	camera.position = spec.start_position
	add_child(camera)
	camera.set_car(player_car)

	player_controller = PlayerController.new()
	player_controller.name = "PlayerController"
	player_controller.car = player_car
	player_controller.camera = camera
	add_child(player_controller)

	# A rival already on the grid, so there is something to race against.
	var rival_spec := CarDB.get_spec("shinobi_rs")
	rival_spec.start_position = ManundaLayout.start_grid_position(1)
	rival_spec.start_rotation = Vector3(0, -PI * 0.5, 0)
	var rival := CarBody.new()
	rival.name = "RivalCar"
	rival.spec = rival_spec
	add_child(rival)
	rival.reset_to(rival_spec.start_position, rival_spec.start_rotation)
	_rivals.append(rival)
	var ai := AIRacer.new()
	ai.name = "AIRacer"
	ai.car = rival
	ai.graph = graph
	ai.skill = 0.72
	add_child(ai)


## The camera preset name, given as the second value after --shot.
func _shot_preset() -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(SHOT_MODE)
	if i >= 0 and i + 2 < args.size():
		return String(args[i + 2])
	return ""


## Nudges a car that has been pinned against scenery back onto the road. A
## prototype needs this because a car wedged in a wall ends the player's night.
func _recover_from_stuck(delta: float) -> void:
	if player_car == null or race == null:
		return
	if race.state != RaceDirector.State.RACING:
		_stuck_time = 0.0
		return
	var wedged: bool = player_car.wheels_on_ground < 2 and player_car.speed_kph < 4.0
	_stuck_time = (_stuck_time + delta) if wedged else 0.0
	if _stuck_time > 3.0:
		_stuck_time = 0.0
		if player_controller:
			player_controller.reset_to_road()
		if hud:
			hud.flash("RECOVERED")


func _shot_request() -> String:
	for a in OS.get_cmdline_user_args():
		if a == SHOT_MODE:
			var i := OS.get_cmdline_user_args().find(a)
			var args := OS.get_cmdline_user_args()
			if i + 1 < args.size():
				return String(args[i + 1])
	return ""


## Frame-grab mode for automated visual checks. Settles the car, lets the world
## stream in, then writes a PNG and quits.
func _capture(path: String) -> void:
	await get_tree().process_frame
	for i in 40:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[Shot] wrote %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	get_tree().quit()
