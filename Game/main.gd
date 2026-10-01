extends Node3D
## Boots the game: builds the Cairns block, puts the player in a car, and hands
## control over. Everything heavy happens once, here.
##
## Also the host for the front of house. `UI/menu_flow.gd` owns the four menu
## screens and routes between them, but it cannot start a race, open the garage
## or stop the world, so those come back out of it as signals and are answered
## here. That is also why this file, and not the UI, is where the game opens on
## the main menu instead of dropping the player straight into a race.

signal world_ready(graph: RoadGraph)

const SHOT_MODE := "--shot"

## How far below the world counts as "fell out of the map". Generous, because
## kerbs, dips and the odd jump legitimately put the body below zero, and a
## recovery that fires while the car is still on the road is worse than none.
const RECOVER_BELOW_Y := -8.0

var graph: RoadGraph
var world: WorldBuilder
var night: NightEnv
var camera: ChaseCamera
var player_car: CarBody
var race: RaceDirector
var hud: RaceHUD
var menus: MenuFlow
var garage: Garage
var garage_screen: GarageScreen
## The route, marked on the road. Built per race from the definition the
## director is running, so the marks and the scoring can never be two different
## routes.
var track: TrackMarker
var _rivals: Array = []
var player_controller: PlayerController
var _sun: DirectionalLight3D
var _stuck_time := 0.0
## The results board stays up until the player leaves it, so the race finishing is
## a thing that happens once.
var _results_shown := false


func _ready() -> void:
	var shot_path := _shot_request()

	print("[Boot] building Cairns (OSM)...")
	var t0 := Time.get_ticks_msec()

	graph = RoadGraph.new()
	graph.build(OSMLayout.corridors())
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

	_open_menus()

	if shot_path != "":
		# A frame grab has nobody at the keyboard to walk the menus, and the
		# presets frame the grid, so a shot needs a race already under way.
		_auto_start_race()
		_capture(shot_path)


## The front page. Built last, once there is a world behind it to look at.
##
## The director and the HUD are made here rather than per race: the HUD is a
## handful of labels, and the director holds the wallet the garage and the results
## board read, so one of each for the whole session is what they were written for.
func _open_menus() -> void:
	race = RaceDirector.new()
	garage = Garage.new()

	menus = MenuFlow.create(graph)
	add_child(menus)
	menus.race_start_requested.connect(_on_race_start_requested)
	menus.garage_requested.connect(_on_garage_requested)
	menus.quit_requested.connect(_on_quit_requested)

	hud = RaceHUD.new()
	hud.name = "RaceHUD"
	add_child(hud)
	hud.visible = false
	# The map, off the same graph the streets are built from, so the shape on it
	# is the shape under the car rather than a picture of somewhere else.
	hud.minimap.set_graph(graph)


## The route the board is holding under `race_id`, as the definition the director
## will run. The board built these off the same graph, so this is a lookup and not
## a second catalogue.
func _race_def(race_id: String) -> RaceDef:
	for d in menus.races():
		if String(d.id) == race_id:
			return d
	return null


## The board committed to a race. Pay the entry, put the car the player left the
## garage in on the grid, and hand the world over to the director.
func _on_race_start_requested(race_id: String) -> void:
	var d := _race_def(race_id)
	if d == null:
		push_warning("no race on the board called %s" % race_id)
		menus.show_race_select()
		return
	# `try_enter` only takes an entry from an idle director, so a second race has to
	# clear the first. `reset` keeps the entry, so the fee below is the only charge.
	race.reset()
	if not race.try_enter(d):
		# The board is built from the map, not from the wallet, so a fee can be
		# refused here. Back to the board rather than into a race nobody entered.
		menus.show_race_select()
		return

	_drive(garage.race_spec())
	_results_shown = false
	if not race.start(d, graph, _entrants()):
		push_warning("could not put the cars on the grid for %s" % d.display_name)
		hud.visible = false
		menus.show_race_select()
		return
	# The flow closes its own screens before it emits, but a race owning the screen
	# is the host's claim to make: left up, the menus also eat ESC, because that is
	# what a visible menu board does with it.
	menus.close()
	hud.visible = true
	_mark_the_route(d)
	print("[Race] %s: %s, %d laps, %.0f m of street" % [
		d.display_name, d.kind_name(), d.laps, d.length_m(graph)])


## Puts the route on the road and on the map.
##
## Both read the one definition the director is scoring on, and the map is fed
## the marker's own polyline rather than re-deriving it from the junction list -
## so the line on the minimap is the line the barriers are built along, and the
## two cannot drift apart.
func _mark_the_route(d: RaceDef) -> void:
	if track == null:
		track = TrackMarker.new()
		track.name = "TrackMarker"
		add_child(track)
	track.build(graph, d)
	hud.minimap.set_route(track.route_points(), d.closed)


## The player is entrant 0, which is what the director treats as "the race is
## over when they cross the line".
func _entrants() -> Array:
	var out: Array = [RaceEntrant.new(player_car)]
	for r in _rivals:
		out.append(RaceEntrant.new(r))
	return out


## ESC mid-race. In the menus it is the screens' own business, and once the tree
## is paused this node stops hearing input at all - the pause board unpauses.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if race != null and (race.state == RaceDirector.State.COUNTDOWN
			or race.state == RaceDirector.State.RACING):
		menus.set_paused(true)


## The race is over. The director has banked the payout; it has not written it to
## disk, and it cannot know the session is ending rather than the next race
## starting, so saving is the host's call.
func _conclude_if_over() -> void:
	if _results_shown or race.state != RaceDirector.State.FINISHED:
		return
	_results_shown = true
	hud.visible = false
	# The route stops being a race route the moment the race is over; the street
	# goes back to being a street, and the map with it.
	if track != null:
		track.clear()
	hud.minimap.clear()
	Cfg.save_game()
	menus.show_results(race)


## The garage. It is a host screen: the flow routes the four menu screens and
## reports that the player asked for this one, but nothing in `UI/` builds it.
func _on_garage_requested() -> void:
	if garage_screen == null:
		garage_screen = GarageScreen.new(garage)
		garage_screen.name = "GarageScreen"
		add_child(garage_screen)
		garage_screen.car_selected.connect(_on_garage_car_selected)
		garage_screen.start_race.connect(_on_garage_start)
		garage_screen.closed.connect(_on_garage_closed)
	menus.close()
	hud.visible = false
	garage_screen.visible = true


## Browsing a car in the garage is not choosing one. The screen draws whatever it
## is handed and then reads the profile back through `garage.selected()`, so with
## nothing committing the choice the browse cursor cannot move at all: every press
## steps off the car that is already selected. This is the seam `car_selected` is
## for. It also refuses for a car the player does not own, which is the answer
## they want until they buy it - `buy` takes it out.
func _on_garage_car_selected(car_id: String) -> void:
	garage.select(car_id)


## The garage's START commits the car, it does not pick a route - the signal
## carries a car, not a race - so it lands on the board. Everything bought or
## fitted is written to the save first, on the way past.
func _on_garage_start(_car_id: String, spec: CarSpec) -> void:
	garage.save()
	_drive(spec)
	_close_garage()
	menus.show_race_select()


func _on_garage_closed() -> void:
	_close_garage()
	menus.show_main_menu()


func _close_garage() -> void:
	if garage_screen != null:
		garage_screen.visible = false


func _on_quit_requested() -> void:
	Cfg.save_game()
	get_tree().quit()


## Frame-grab mode: no player is at the keyboard to walk the menus, and every
## preset frames the grid, so a shot starts the first route on the board.
func _auto_start_race() -> void:
	var board: Array = menus.races()
	if board.is_empty():
		push_warning("no races could be built from the road graph")
		return
	_on_race_start_requested(String(board[0].id))


## Puts the car the player left the garage in behind the wheel. A new body rather
## than a new spec on the old one, because the mass, the collider and the
## bodywork are all sized off the spec when the car is built and never re-read it.
func _drive(spec: CarSpec) -> void:
	if spec == null or (player_car != null and spec.id == player_car.spec.id):
		return
	# Drop the director's hold on the car being replaced first: an entrant holds
	# the body it was built around, and that reference outlives a freed object.
	# Freed outright rather than deferred - a `queue_free` would still have the old
	# "PlayerCar" in the tree when the new one is added, and the new body would be
	# the one silently renamed out from under everything that looks it up by name.
	race.reset()
	player_car.free()
	_spawn_player_car(spec)


func _process(delta: float) -> void:
	if race != null:
		for e in race.entrants:
			if e is RaceEntrant:
				(e as RaceEntrant).sync()
		race.tick(delta)
		_recover_from_stuck(delta)
		_conclude_if_over()
	# The HUD reads the director's entrants by index, so it is not fed a director
	# that has never been started.
	if hud != null and race.entrants.size() > 0:
		hud.update(player_car, race, delta)


func _spawn_player() -> void:
	_spawn_player_car(Cfg.active_spec())

	camera = ChaseCamera.new()
	camera.name = "Camera"
	camera.position = player_car.position
	add_child(camera)
	camera.set_car(player_car)

	player_controller = PlayerController.new()
	player_controller.name = "PlayerController"
	player_controller.car = player_car
	player_controller.camera = camera
	add_child(player_controller)

	# A rival already on the grid, so there is something to race against.
	var rival_spec := CarDB.get_spec("shinobi_rs")
	rival_spec.start_position = OSMLayout.start_grid_position(1)
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


## Builds the player's body for `spec`. Split out of `_spawn_player` because the
## garage swaps the car mid-session and the camera and the controller both hold a
## reference to the body that has to follow it.
func _spawn_player_car(spec: CarSpec) -> void:
	spec.start_position = OSMLayout.start_grid_position(0)
	spec.start_rotation = Vector3(0, -PI * 0.5, 0)

	player_car = CarBody.new()
	player_car.name = "PlayerCar"
	player_car.spec = spec
	add_child(player_car)
	player_car.reset_to(spec.start_position, spec.start_rotation)

	if camera != null:
		camera.set_car(player_car)
	if player_controller != null:
		player_controller.car = player_car


## The camera preset name, given as the second value after --shot.
func _shot_preset() -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(SHOT_MODE)
	if i >= 0 and i + 2 < args.size():
		return String(args[i + 2])
	return ""


## Nudges a car that has been pinned against scenery back onto the road, and
## catches one that has dropped out of the world. A prototype needs both: a car
## wedged in a wall ends the player's night, and so does one in the void.
func _recover_from_stuck(delta: float) -> void:
	if player_car == null or race == null:
		return
	if race.state != RaceDirector.State.RACING:
		_stuck_time = 0.0
		return

	# Below the world is its own case, and it must not wait on the stuck timer.
	# The stuck test asks for speed_kph < 4, and a car falling off the map is
	# moving fast the whole way down, so it never qualified - which is how a
	# fall became permanent. Checking depth is also instantaneous and always
	# right, rather than being a guess about how long is too long.
	if player_car.global_position.y < RECOVER_BELOW_Y:
		if _stuck_time <= 0.0:
			hud.flash("RECOVERED")
		_stuck_time += delta
		if _stuck_time > 1.0:
			_stuck_time = 0.0
			if player_controller:
				player_controller.reset_to_road()
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


## Frame-grab mode for automated visual checks. Lets the world settle, poses the
## camera, then writes a PNG and quits.
##
## The preset is applied *here* rather than at the end of `_ready` because the
## race director puts the cars on the starting grid a frame or two after the
## race starts. A preset applied before that frames the street where the car
## used to be, which is how every shot so far managed to contain no car.
func _capture(path: String) -> void:
	for i in 40:
		await get_tree().process_frame

	var preset := _shot_preset()
	if preset != "":
		# Hand the camera over: without this the chase camera reasserts its own
		# pose on the very next frame and every preset renders as a chase shot.
		camera.tracking = false
		ShotPoser.apply(camera, preset)
		for i in 4:
			await get_tree().process_frame

	# Print the pose the shot was actually taken from. Every "the preset does not
	# work" bug so far has been a camera quietly being driven by something else.
	var cam3d: Camera3D = null
	for c in camera.get_children():
		if c is Camera3D:
			cam3d = c
	if cam3d != null:
		print("[Shot] preset=%s camera=%s fov=%.1f | car=%s | %.2f m apart, tracking=%s" % [
			preset if preset != "" else "(chase)", str(cam3d.global_position.round()), cam3d.fov,
			str(player_car.global_position.round()),
			cam3d.global_position.distance_to(player_car.global_position), camera.tracking])

	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[Shot] wrote %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	get_tree().quit()
