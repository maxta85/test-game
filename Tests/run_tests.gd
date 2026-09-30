extends SceneTree
## Headless test entry point. Run via ./test.sh
##
## Usage:  ./test.sh            all suites
##         ./test.sh vehicle    only suites whose name contains "vehicle"
##
## Uses `_initialize` rather than `_init`: the SceneTree is not registered as the
## main loop until then, so `Engine.get_main_loop()` is null inside `_init`.
##
## Suites are DISCOVERED, not registered. Several agents work in this repo
## concurrently on disjoint files, and a hardcoded list would mean every one of
## them had to edit this file to add a suite - which is exactly the kind of
## shared-file conflict that breaks concurrent work. Drop a `test_*.gd` file in
## Tests/ and it is picked up automatically.

const TESTS_DIR := "res://Tests/"

var _autoloads: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	var filter := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) != "all":
		filter = String(args[0])

	var suites := _discover()
	_autoloads = _autoload_names()
	var t := TestHarness.new()
	t.tree = self
	var ran := 0

	print("=".repeat(58))
	print("  CAIRNS AFTER DARK - test suite")
	print("  filter: %s" % (filter if filter != "" else "(none)"))
	print("  %d suites discovered" % suites.size())
	print("=".repeat(58))

	for path in suites:
		var name: String = String(path).get_file().replace("test_", "").replace(".gd", "")
		if filter != "" and not name.contains(filter):
			continue
		var script: Script = load(path)
		if script == null:
			t.suite(name)
			t.ok(false, "suite failed to load: %s" % path)
			continue
		var suite: Object = script.new()
		t.suite(name)
		await suite.call("run", t)
		await _clear_world()
		ran += 1

	if ran == 0:
		print("no suites matched filter")
	quit(t.summary())


## Empties the tree between suites.
##
## A suite that throws part-way through `run` has its coroutine torn down with
## its world still standing - CarBodies, StaticBody3D colliders and all. The
## next suite then spawns its car into a world that already has one in it, and
## fails on physics it never caused. Clearing between suites costs two frames
## and makes a suite's failures its own.
func _clear_world() -> void:
	for child in root.get_children():
		if not child.name in _autoloads:
			child.queue_free()
	await physics_frame
	await process_frame


## The autoload singletons are project services, not a suite's world. Freeing one
## leaves the `Cfg` identifier bound to a freed object, so every later suite that
## touches money reads through a dangling instance and takes the process down with
## it - measured: the `ui` suite died on SIGSEGV in `MenuShell.refresh_status`
## because the `ai` suite, three suites earlier, cleared it.
func _autoload_names() -> PackedStringArray:
	var out := PackedStringArray()
	for p in ProjectSettings.get_property_list():
		var n := String(p.get("name", ""))
		if n.begins_with("autoload/"):
			out.append(n.substr("autoload/".length()))
	return out


## Every `res://Tests/test_*.gd`, sorted so runs are deterministic.
func _discover() -> Array:
	var out: Array = []
	var dir := DirAccess.open(TESTS_DIR)
	if dir == null:
		push_error("cannot open %s" % TESTS_DIR)
		return out
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(TESTS_DIR + f)
	out.sort()
	return out
