extends SceneTree
## Headless test entry point. Run via ./test.sh
##
## Usage:  ./test.sh            all suites
##         ./test.sh vehicle    only suites whose name contains "vehicle"
##
## Uses `_initialize` rather than `_init`: the SceneTree is not registered as the
## main loop until then, so `Engine.get_main_loop()` is null inside `_init`.

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


func _initialize() -> void:
	var filter := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) != "all":
		filter = String(args[0])

	var suites := _discover()
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
		ran += 1

	if ran == 0:
		print("no suites matched filter")
	quit(t.summary())


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
