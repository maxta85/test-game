extends SceneTree
## TEMPORARY: the "quit and come back" check. Deleted after it has been run.
##   godot --headless --path . --script res://Systems/garage/_persist_check.gd -- write
##   godot --headless --path . --script res://Systems/garage/_persist_check.gd -- read
## Autoload identifiers do not resolve in a --script main loop, so Cfg comes off
## the tree (the same way RaceDirector._money and Garage._autoload get it).

func _initialize() -> void:
	await process_frame
	var mode := "read"
	if OS.get_cmdline_user_args().has("write"):
		mode = "write"
	var cfg: Object = root.get_node_or_null("Cfg")
	var g := Garage.new(cfg)
	print("[%s] save: %s (exists=%s)" % [
		mode, ProjectSettings.globalize_path(cfg.SAVE_PATH),
		str(FileAccess.file_exists(cfg.SAVE_PATH))])
	print("[%s] money=%d owned=%s selected=%s upgrades=%s" % [
		mode, g.money(), str(g.owned_cars()), g.selected(), str(cfg.upgrades)])
	if mode == "write":
		cfg.add_money(42000)
		assert(g.buy("shinobi_rs"), "should be able to buy a car")
		assert(g.install("engine1"), "should be able to fit a cam")
		assert(g.install("engine1"), "and a second level of it")
		g.save()
		print("[write] money=%d owned=%s selected=%s upgrades=%s" % [
			g.money(), str(g.owned_cars()), g.selected(), str(cfg.upgrades)])
		print("[write] race_spec: %s at %.1f kW (stock %.1f kW)" % [
			g.race_spec().id, Garage.peak_power_kw(g.race_spec()),
			Garage.peak_power_kw(CarDB.get_spec("shinobi_rs"))])
	quit(0)
