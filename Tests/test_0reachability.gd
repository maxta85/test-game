extends RefCounted
## The reachability invariant: the game boots, and it boots the merged code.
##
## The test runner and the game are different roots. `run_tests.gd` discovers any
## `res://Tests/test_*.gd` and calls `run()` on it, so a suite passes happily
## against a class the game never instantiates. That is how eleven merges landed
## green and dead: 5037 lines of artkit, 2090 of menus, 1498 of OSM buildings,
## 1122 of garage and 1054 of water, all with passing suites and no call site
## anywhere between `project.godot` and the frame.
##
## So this suite closes the gap from the other end. It reads the scene
## `project.godot` actually launches, instantiates it for real, and interrogates
## the live tree. Nothing here is satisfied by a `class_name` sitting in
## `.godot/global_script_class_cache.cfg` - every merged subsystem has one and
## not one of them runs, which is exactly the trap that hid the UI problem.
## A subsystem counts as shipped only when a node carrying its script, or a node
## the subsystem named, is really in the tree, having really had `_ready` run.
##
## NOT_SHIPPED is a to-do list, not an amnesty. Each entry prints a named
## decision, and if the subsystem ever does get wired the entry fails until
## somebody deletes it - a list that cannot be emptied is a list that rots into
## a lie, and a lie here is the whole bug this file exists to prevent.
##
## The leading `0` in the filename is load-bearing, not decoration.
## `run_tests.gd` sorts suites by filename, and this one has to go first: it is
## the only suite that builds the game's real world, and Godot 4.3 segfaults
## (signal 11) inside `main.gd`'s `_spawn_player()` if the shared physics and
## render state has already been churned by the suites ahead of it. Verified
## both ways - seventh in the order it crashed, first in the order it passes.
## The digit sorts ahead of every letter and `./test.sh reachability` still
## finds it, so the name carries the constraint without costing ergonomics.

## Subsystems the game ships, witnessed by the script attached to a live node.
## Every one is wired in `Game/main.gd`; delete the line that constructs it and this
## suite goes red while that subsystem's own unit tests carry on passing, because those
## tests build their own copies. `script` must be attached to a live node in the booted
## scene. The geometry-returning entry points are in SHIPPED_GEOMETRY below.
const SHIPPED := [
	{"id": "world builder", "script": "res://World/world_builder.gd"},
	{"id": "night environment", "script": "res://World/night_env.gd"},
	{"id": "car body", "script": "res://Systems/vehicle/car_body.gd"},
	{"id": "car visual", "script": "res://Systems/vehicle/car_visual.gd"},
	{"id": "chase camera", "script": "res://Systems/camera/chase_camera.gd"},
	{"id": "player controller", "script": "res://Systems/player/player_controller.gd"},
	{"id": "ai racer", "script": "res://AI/ai_racer.gd"},
	{"id": "race hud", "script": "res://UI/race_hud.gd"},
]

## Shipped, but built on a route rather than at boot: the host creates this one
## when the player asks for the garage, so it cannot be in the tree until
## something has asked. Checked after `run()` fires that request - which is also
## why this entry cannot sit in NOT_SHIPPED any more, where it passed for ever
## because nothing in this file ever opened a garage to see it appear.
const SHIPPED_ON_DEMAND := [
	{"id": "garage screen", "script": "res://Systems/garage/garage_screen.gd"},
]

## Shipped subsystems whose entry point is a static function returning geometry
## rather than a node of its own, so no script is ever attached to a live node.
##
## `nodes` are the node names the subsystem leaves in the tree. `ArtKitScatter.attach()`
## names its own root `ArtKitScatter` before populating, and `OSMBuildings.build()`
## parents one mesh per material tint into WorldBuilder - so in both cases the emitted
## node names are the only honest witness, and a `class_name` in the global class cache
## is not.
const SHIPPED_GEOMETRY := [
	{
		"id": "artkit",
		"module": "res://artkit/scatter.gd",
		"nodes": ["ArtKitScatter"],
		"why": "ArtKitScatter.attach() from WorldBuilder._buildings() fills the frontages OSM left unmapped",
	},
	{
		"id": "osm buildings",
		"module": "res://World/osm_buildings.gd",
		"nodes": ["WindowWarm", "WindowCool"],
		"why": "OSMBuildings.build() from WorldBuilder._buildings() replaces the invented boxes",
	},
]

## Merged, tested, and deliberately not reachable from the entry point.
##
## `module` is the file that has to still exist - it catches an entry left
## behind by a deletion. `scripts` are the scripts that would appear on a live
## node once wired. `nodes` are node names, for the subsystems whose entry point
## is a static function that returns geometry rather than a node of its own.
const NOT_SHIPPED := [
	{
		"id": "osm water",
		"module": "res://World/osm_water.gd",
		"scripts": ["res://Systems/water/water_surface.gd"],
		"why": "fc491b2 water is not one of WorldBuilder.build()'s 14 steps; OSMWater.surface() returns a WaterSurface",
	},
	{
		"id": "traffic",
		"module": "res://AI/traffic/traffic_manager.gd",
		"scripts": ["res://Systems/traffic/pedestrians.gd"],
		"why": "TrafficManager is RefCounted; Pedestrians is the only Node and WorldBuilder never spawns one",
	},
	{
		"id": "gevp vehicle dynamics",
		"module": "res://addons/gevp/scripts/vehicle.gd",
		"scripts": ["res://addons/gevp/scripts/vehicle.gd", "res://addons/gevp/scripts/wheel.gd"],
		"why": "addons/gevp has no [editor_plugins] block in project.godot, so the addon is not enabled",
	},
]

## The scene the project really launches, taken from the engine's own parsed
## settings rather than a guess. A hardcoded path would keep passing after
## someone repoints run/main_scene, which is the failure this guards against.
const ENTRY_SCRIPT := "res://Game/main.gd"

## `Cfg`'s mutable profile. Booting the real game is not a free action: the entry
## point enters a race at `main.gd:99`, and `RaceDirector.try_enter` debits the
## entry fee off the autoload at `race_director.gd:71`. One shared Cfg serves
## every suite in the run, so without this the reachability suite would quietly
## spend the player's money and shift the figures `test_race` and `test_garage`
## go on to assert against.
const WALLET_FIELDS := ["money", "active_car", "heat_record"]
const WALLET_CONTAINERS := ["owned_cars", "races_completed", "upgrades", "cosmetics"]

var _live: Dictionary = {}
var _live_nodes: Dictionary = {}


func run(t: TestHarness) -> void:
	# `Cfg` by its bare global name resolves here as well - measured, it is the
	# same object - but it is taken off the tree by path so this suite reads the
	# one autoload there is and does not care how other suites spell it.
	var loop := Engine.get_main_loop()
	var wallet: Object = loop.root.get_node_or_null("Cfg") if loop is SceneTree else null
	var saved := _snapshot(wallet)

	var entry := await _boot_entry_point(t)
	if entry != null:
		_interrogate(entry, t)
		# The garage is a host screen, so it is not in the tree until the player
		# asks for it - and this suite used to carry a NOT_SHIPPED entry for it
		# that could never fail, because nothing here ever opened one. Ask.
		await _open_the_garage(entry, t)
		_interrogate_late(entry, t)
		await t.drop(entry)

	_restore(wallet, saved)


## Fires the garage request the main menu sends and lets a frame pass, so the
## screen the host builds in response is really in the tree.
func _open_the_garage(entry: Node, t: TestHarness) -> void:
	if not t.ok(entry.get("menus") != null, "the entry point holds a menu flow"):
		return
	entry.menus.garage_requested.emit()
	for i in 4:
		await t.tree.process_frame
	_collect(entry)


func _snapshot(wallet: Object) -> Dictionary:
	var out := {}
	if wallet == null:
		return out
	for f in WALLET_FIELDS:
		out[f] = wallet.get(f)
	for f in WALLET_CONTAINERS:
		out[f] = (wallet.get(f) as Variant).duplicate(true)
	return out


func _restore(wallet: Object, saved: Dictionary) -> void:
	if wallet == null:
		return
	for f in WALLET_FIELDS:
		wallet.set(f, saved[f])
	for f in WALLET_CONTAINERS:
		wallet.set(f, saved[f])


## Loads and instantiates the configured entry point into the live tree.
## Returns null once anything is missing, so a broken boot reports its own
## failure instead of cascading into a tree full of absent subsystems.
func _boot_entry_point(t: TestHarness) -> Node:
	var path := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if not t.ok(path != "", "project.godot declares application/run/main_scene"):
		return null
	t.ok(path.begins_with("res://"), "entry scene is a project resource (%s)" % path)

	var packed: Resource = load(path)
	if not t.ok(packed is PackedScene, "%s loads as a PackedScene" % path):
		return null
	if not t.ok((packed as PackedScene).can_instantiate(), "%s can be instantiated" % path):
		return null

	var scene: Node = (packed as PackedScene).instantiate()
	if not t.ok(scene != null, "%s instantiates to a node" % path):
		return null

	t.ok(_script_of(scene) == ENTRY_SCRIPT,
		"the launched scene runs the real game script (%s)" % ENTRY_SCRIPT)

	# The real _ready builds the whole block, so let it finish before looking.
	t.tree.root.add_child(scene)
	for i in 4:
		await t.tree.process_frame
	_collect(scene)
	return scene


## Walks the booted tree once and records every script and node name in it.
func _collect(n: Node) -> void:
	var s: Script = n.get_script()
	if s != null and s.resource_path != "":
		_live[s.resource_path] = true
	_live_nodes[n.name] = true
	for c in n.get_children():
		_collect(c)


func _script_of(n: Node) -> String:
	var s: Script = n.get_script()
	return "" if s == null else s.resource_path


func _interrogate(entry: Node, t: TestHarness) -> void:
	# The scene loading is not the same as the game booting. `is_node_ready` is
	# the only claim here that main.gd's whole _ready completed rather than
	# throwing three lines in - without it a half-built tree would still answer
	# every question below, just with the answer "absent".
	t.ok(entry.is_node_ready(), "the entry scene entered the tree and _ready ran to completion")

	for s in SHIPPED:
		t.ok(_live.has(s["script"]),
			"shipped: %s is instantiated by the entry point (%s)" % [s["id"], s["script"]])

	for g in SHIPPED_GEOMETRY:
		_assert_shipped_geometry(g, t)

	for n in NOT_SHIPPED:
		_assert_not_shipped(n, t)


## The second pass, once the garage has been asked for. NOT_SHIPPED is only an
## honest list at a point where every route into the game has been walked, so it
## is checked here and not at boot.
func _interrogate_late(_entry: Node, t: TestHarness) -> void:
	for s in SHIPPED_ON_DEMAND:
		t.ok(_live.has(s["script"]),
			"shipped on demand: %s is instantiated by the entry point (%s)" % [s["id"], s["script"]])

	for n in NOT_SHIPPED:
		_assert_not_shipped(n, t)


## Same honesty as the SHIPPED table, witnessed by node names because the subsystem
## is a static function and never becomes a node itself.
func _assert_shipped_geometry(entry: Dictionary, t: TestHarness) -> void:
	var id: String = entry["id"]
	t.ok(ResourceLoader.exists(entry["module"]),
		"shipped module on disk: %s (%s)" % [id, entry["module"]])
	var present := _witnesses_present(entry)
	t.ok(not present.is_empty(),
		"shipped: %s is built by the entry point (%s) - %s"
		% [id, ", ".join(entry["nodes"]), entry["why"]])


func _assert_not_shipped(entry: Dictionary, t: TestHarness) -> void:
	var id: String = entry["id"]
	t.ok(ResourceLoader.exists(entry["module"]),
		"not-shipped module still on disk: %s (%s)" % [id, entry["module"]])

	var present := _witnesses_present(entry)
	if present.is_empty():
		t.ok(true, "NOT SHIPPED (recorded): %s - %s" % [id, entry["why"]])
	else:
		# ok(false) rather than fails(true): fails() prefixes "NOT ", and this
		# sentence is already the negative case. A list that outlives the bug it
		# recorded is the exact rot this file is here to prevent.
		t.ok(false,
			"%s is now reachable via %s but is still listed as NOT SHIPPED - delete its entry"
			% [id, ", ".join(present)])


## Which witnesses of a subsystem are live, if any. Empty means not shipped.
func _witnesses_present(entry: Dictionary) -> Array:
	var hits: Array = []
	for p in entry.get("scripts", []):
		if _live.has(p):
			hits.append(p)
	for nm in entry.get("nodes", []):
		if _live_nodes.has(nm):
			hits.append("node '%s'" % nm)
	return hits
