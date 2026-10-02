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
##
## The runner's job is isolation: each suite gets the world to itself, the
## engine-wide state it is entitled to change, and a report that says what ran
## before it. A suite that throws should cost its own assertions, not the next
## suite's, and it should never cost the run its honesty - an aborted suite
## used to be a silent pass, which is how a whole suite could die at its first
## line and the run still print "0 failed".

const TESTS_DIR := "res://Tests/"

## A throwaway suite, for the self-check: it builds a world and then dies half
## way through it, which is the shape the runner has to survive.
class _SelfCheckAbort extends RefCounted:
	func run(t: TestHarness) -> void:
		t.new_root("SelfCheckAbandonedWorld")
		await t.ticks(1)
		var gone: Node = null
		gone.anything()      # the throw: no return, world still standing


## An async case called without `await` by its caller: exactly the mistake the
## brief says has to be loud.
class _SelfCheckUnawaited extends RefCounted:
	func case_late(t: TestHarness) -> void:
		await t.ticks(2)
		t.new_root("SelfCheckLateWorld")
	func run(t: TestHarness) -> void:
		case_late(t)        # no await: the caller does not wait for the case


func _initialize() -> void:
	var filter := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and String(args[0]) != "all":
		filter = String(args[0])

	var suites := _discover()
	var t := TestHarness.new()
	# The world has to be genuinely stepping before the first suite hangs
	# anything off it: the first physics frame of a headless process dispatches
	# no node callbacks, so a node added in that window never runs physics. The
	# harness spends that frame here, once, instead of leaving it as a rule
	# every suite has to remember.
	await t.attach(self)
	var ran := 0

	print("=".repeat(58))
	print("  CAIRNS AFTER DARK - test suite")
	print("  filter: %s" % (filter if filter != "" else "(none)"))
	print("  %d suites discovered" % suites.size())
	print("=".repeat(58))

	await _self_check(t)

	for path in suites:
		var name: String = String(path).get_file().replace("test_", "").replace(".gd", "")
		if filter != "" and not name.contains(filter):
			continue
		var script: Script = load(path)
		t.begin_suite(name)
		if script == null:
			t.ok(false, "suite failed to load: %s" % path)
		else:
			var suite: Object = script.new()
			await suite.call("run", t)
		t.end_suite()
		await _isolate(t, name)
		ran += 1

	if ran == 0:
		print("no suites matched filter")
	quit(t.summary())


## The harness's own promises, checked on every run. A few physics frames, and
## they are the only thing here that can tell us the world is really being
## advanced - which is the assumption every number in every suite rests on.
##
## The failure this exists for: `await tree.physics_frame` counts frames the
## tree offered, and the first frame of a headless process dispatches no node
## callbacks at all. A suite that adds a car and awaits one tick can then watch
## a car whose physics never ran, and a car that never gets its physics is a car
## that never gets its throttle.
func _self_check(t: TestHarness) -> void:
	print("\n  harness self-check")
	var stepper := TestHarness.Ticker.new()
	root.add_child(stepper)
	await t.ticks(1)
	t.ok(stepper.steps >= 1, "a node added to the tree has run physics after ticks(1) (%d step(s))" % stepper.steps)
	var mark: int = stepper.steps
	await t.ticks(3)
	t.eq(stepper.steps - mark, 3, "ticks(3) advances the world by exactly 3 steps")
	stepper.queue_free()
	await t.ticks(1)

	# A suite that throws with its world still standing has to be visible to the
	# census, or the next suite inherits a world it never built.
	await _SelfCheckAbort.new().call("run", t)
	t.ok(not t.foreign_nodes().is_empty(),
		"a suite that throws with its world standing is reported, not absorbed")
	await _isolate(t, "harness self-check")
	t.ok(t.foreign_nodes().is_empty(), "and the world does not reach the next suite")

	# An async case called without `await` by its caller.
	await _SelfCheckUnawaited.new().call("run", t)
	await _isolate(t, "harness self-check")
	t.ok(t.foreign_nodes().is_empty(), "an un-awaited async case does not build a world in the next suite")


## Empties the tree of everything the suite built, and then proves it stayed
## empty.
##
## A suite that throws part-way through `run` has its coroutine torn down with
## its world still standing - CarBodies, StaticBody3D colliders and all. The
## next suite then spawns its car into a world that already has one in it, and
## fails on physics it never caused.
##
## What is NOT ours to free: the autoloads and the harness's own ticker.
## `queue_free()` on the Cfg autoload leaves every later suite holding a freed
## singleton, which reads as "Invalid assignment ... on a base object of type
## 'previously freed'" and kills that suite at its first line - silently,
## because a suite that dies on the way in reports no failures. That is how
## test_race lost 100+ assertions in every full run while the run still said
## "0 failed". `foreign_nodes()` skips the ticker and anything registered as an
## autoload by name, so iterating its result cannot reach one - measured: the
## `ui` suite died on SIGSEGV in `MenuShell.refresh_status` because the `ai`
## suite, three suites earlier, cleared `Cfg`. Autoloads are the environment
## every suite is handed, not a suite's debris.
##
## The two physics frames afterwards are the check that makes an un-awaited
## async test case loud: an awaited case cannot build anything once `run` has
## returned, so a node appearing after the clear can only come from a coroutine
## that is still running. That is a hard failure, not a slow leak.
func _isolate(t: TestHarness, suite_name: String) -> void:
	var foreign := {}
	for name in t.foreign_nodes():
		foreign[name] = true
	for child in root.get_children():
		if foreign.has(String(child.name)):
			child.queue_free()
	await t.ticks(2)
	await process_frame
	var orphans := t.foreign_nodes()
	if not orphans.is_empty():
		t.problem("suite %s left a coroutine running: %s appeared in the world AFTER it was "
			% [suite_name, ", ".join(orphans)]
			+ "cleared. An async test case was called without `await`, so it is still "
			+ "building its world in parallel with whatever runs next.", true)


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
