extends SceneTree
## Is the game playable by a player who has never driven it before?
##
##     godot --headless --path . --script res://Game/playable_probe.gd -- [--drive]
##
## Prints one `PLAYABLE-*` line per thing that has to be true before a first
## session is playable, and a final `PLAYABLE=YES` / `PLAYABLE=NO`.
##
## Why this is not `./test.sh menu_wiring`: that suite sets the profile itself -
## `Cfg.money = 1500` and two owned cars - before it walks the menus, so it proves
## the menu -> race -> results chain works for a player who is already set up. It
## cannot answer whether a NEW player is playable, because it never leaves them
## in that state. Everything below is measured on the profile `Cfg` builds itself.
##
## `--drive` additionally puts throttle in for a few seconds and reports whether
## the car actually moves and stays on the tarmac, which is the difference
## between "a race started" and "the player is playing".

const DRIVE_SECONDS := 4.0


func _initialize() -> void:
	await process_frame
	await process_frame

	var cfg: Node = root.get_node_or_null("Cfg")
	if cfg == null:
		print("PLAYABLE-NO reason=no Cfg autoload in the tree")
		quit(1)
		return

	# A first session: whatever `Cfg` itself decides a new player gets. Any save
	# on this machine is not evidence about a new player, so it is discarded.
	cfg.call("_reset_new_game")
	await process_frame

	print("== the profile Cfg gives a new player ==")
	print("  money        : %d" % int(cfg.get("money")))
	print("  owned cars   : %s" % str(Array(cfg.get("owned_cars"))))
	print("  active car   : %s" % str(cfg.get("active_car")))

	var main: Node = load("res://Game/main.gd").new()
	root.add_child(main)
	await process_frame
	await process_frame

	print("== the game as it boots ==")
	print("  screen       : %s" % str(main.menus.screen_name()))
	print("  race state   : %s" % str(main.race.state_name()))
	print("  player car   : %s" % ("none" if main.player_car == null
		else String(main.player_car.spec.id)))
	print("  owned car?   : %s" % ("yes" if cfg.owns_car(String(cfg.active_car)) else "NO"))

	var reasons: Array[String] = []
	var board: Array = main.menus.races()
	print("== the board: %d routes, wallet %d ==" % [board.size(), int(cfg.money)])
	var affordable := 0
	for d in board:
		var fee := int(d.entry_fee)
		var len_m := float(d.length_m(main.graph))
		var ok := fee <= int(cfg.money)
		if ok:
			affordable += 1
		print("  %-22s %-10s %d lap(s) %6.0f m  fee %4d  %s" % [
			String(d.display_name), String(d.kind_name()), int(d.laps),
			len_m, fee, "enterable" if ok else "TOO EXPENSIVE"])
		if not d.valid():
			reasons.append("%s is not a route that exists on this map" % d.display_name)
		if len_m < 100.0:
			reasons.append("%s is only %.0f m long" % [d.display_name, len_m])
	if affordable == 0:
		reasons.append("no route on the board is affordable with %d" % int(cfg.money))

	# The player's own route through the menus, not a signal poked from outside:
	# main menu -> race select -> the first route the player can afford.
	main.menus.show_race_select()
	await process_frame
	if String(main.menus.screen_name()) != "race_select":
		reasons.append("the board cannot be reached from the main menu")

	var chosen: RaceDef = null
	for d in board:
		if int(d.entry_fee) <= int(cfg.money):
			chosen = d
			break
	if chosen == null:
		reasons.append("nothing to enter")
	else:
		var before := int(cfg.money)
		main.menus.race_select().race_chosen.emit(String(chosen.id))
		await process_frame
		await process_frame
		print("== after choosing %s ==" % String(chosen.display_name))
		print("  race state   : %s" % str(main.race.state_name()))
		print("  money       : %d -> %d" % [before, int(cfg.money)])
		print("  entrants     : %d" % main.race.entrants.size())
		print("  hud visible  : %s" % str(main.hud.visible))
		print("  menus hidden : %s" % str(not main.menus.menu_visible()))
		if main.race.state == RaceDirector.State.IDLE:
			reasons.append("choosing %s did not start a race" % chosen.display_name)
		elif not main.hud.visible:
			reasons.append("the race started with the HUD down")

		# Lights out, so the car is actually being raced rather than held.
		for i in int(RaceDirector.COUNTDOWN_TIME * 60.0) + 30:
			await physics_frame
			if main.race.state == RaceDirector.State.RACING:
				break
		print("  after lights : %s" % str(main.race.state_name()))
		if main.race.state != RaceDirector.State.RACING:
			reasons.append("the countdown never reached racing")

		if reasons.is_empty() and OS.get_cmdline_user_args().has("--drive"):
			await _drive(main, cfg)

	for r in reasons:
		print("PLAYABLE-NO reason=%s" % r)
	print("PLAYABLE=%s" % ("NO" if not reasons.is_empty() else "YES"))
	quit(0)


## Throttle in, hands off the wheel. Reports the two things a "the race started"
## assertion cannot see: does the car move, and is it still on the road.
func _drive(main: Node, cfg: Node) -> void:
	var car: Node = main.player_car
	var graph: RoadGraph = main.graph
	var start: Vector3 = car.global_position
	var top := 0.0
	var off_road := 0
	var samples := int(DRIVE_SECONDS * 60.0)
	# `PlayerController` reads the `throttle` action every physics frame, so this
	# is the same surface `Tools/playtest.gd` drives with - no bespoke setter.
	Input.action_press("throttle", 1.0)
	for i in samples:
		await physics_frame
		top = maxf(top, float(car.linear_velocity.length()))
		if graph.nearest_road(car.global_position).lateral > 12.0:
			off_road += 1
	Input.action_release("throttle")
	print("== throttle for %.1f s ==" % DRIVE_SECONDS)
	print("  travelled    : %.1f m" % start.distance_to(car.global_position))
	print("  top speed    : %.1f km/h" % (top * 3.6))
	print("  off-road     : %d of %d samples" % [off_road, samples])
	if start.distance_to(car.global_position) < 5.0:
		print("PLAYABLE-NO reason=the car does not move under full throttle")
	if off_road > samples / 4:
		print("PLAYABLE-NO reason=the car left the road on %d of %d samples"
			% [off_road, samples])