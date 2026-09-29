extends SceneTree
## Headless test entry point. Run via ./test.sh
##
## Usage:  ./test.sh            all suites
##         ./test.sh vehicle    only suites whose name contains "vehicle"
##
## Uses `_initialize` rather than `_init`: the SceneTree is not registered as the
## main loop until then, so `Engine.get_main_loop()` is null inside `_init`.

const SUITES := [
	"res://Tests/test_vehicle_math.gd",
	"res://Tests/test_cars.gd",
	"res://Tests/test_vehicle.gd",
	"res://Tests/test_camera.gd",
	"res://Tests/test_world.gd",
	"res://Tests/test_race.gd",
	"res://Tests/test_ai.gd",
	"res://Tests/test_traffic.gd",
	"res://Tests/test_economy.gd",
	"res://Tests/test_save.gd",
	"res://Tests/test_weather.gd",
]


func _initialize() -> void:
	var filter := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) != "all":
		filter = String(args[0])

	var t := TestHarness.new()
	t.tree = self
	var ran := 0

	print("=".repeat(58))
	print("  CAIRNS AFTER DARK - test suite")
	print("  filter: %s" % (filter if filter != "" else "(none)"))
	print("=".repeat(58))

	for path in SUITES:
		if not ResourceLoader.exists(path):
			continue
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
