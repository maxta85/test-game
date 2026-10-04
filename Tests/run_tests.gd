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
##
## WHAT IS GUARANTEED, and by what. A suite file that cannot be turned into a
## running object is named, the run carries on, the normal summary still
## prints, and the process exits non-zero - see `_acquire`. That case is the
## one that used to cost the whole run, because `load()` hands back a NON-NULL
## GDScript for a file that failed to compile, so the old null check never
## fired and the failure only surfaced as a `.new()` throw inside this file's
## own coroutine.
##
## THE LIMIT, MEASURED, NOT GUESSED. GDScript has no try/catch and no API that
## reports whether a coroutine aborted, so a suite that throws part way through
## `run()` cannot be detected at the throw site. With
## `Tests/test_probe_runthrow.gd` as the only broken file, the run printed
## `-- probe_runthrow: 1 passed, 0 failed`, a summary of `6 passed, 0 failed`,
## and exited 0 - measured 2026-10-03. Godot's own `SCRIPT ERROR` line names
## the file and line, so the information is in the transcript, but it is not in
## the counts.
##
## The realistic cases are still caught, because a suite that throws almost
## always leaves one of the three traces `end_suite()` inspects, and each of
## those names the suite: `Engine.time_scale` left moved, nodes left standing,
## or the tree left paused. A suite engineered to die leaving none of the three
## is the only shape that slips through, and closing it would mean guessing
## ("zero assertions means broken"?) - which is the same move that made a run
## green without testing anything. Deliberately not done: a false failure on a
## healthy suite is worse than this gap, because it trains people to ignore the
## runner.

const TESTS_DIR := "res://Tests/"

## Suites that were discovered but never ran, kept on their own axis.
## Deliberately NOT recorded through `t.ok`: an unloadable file is not a
## suite whose assertions passed and not a suite whose assertions failed -
## it contributed no assertions at all, and the run's honesty depends on
## that being visible as its own thing.
var _unloadable: Array[Dictionary] = []

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
		t.begin_suite(name)
		var got: Variant = _acquire(path)
		# `typeof` is tested first on purpose. `_acquire` can itself be torn
		# down by a throw it could not contain, and a torn-down call comes
		# back null - calling `.is_empty()` on that null is the same crash,
		# one call deeper.
		if typeof(got) != TYPE_DICTIONARY or got.is_empty():
			_record_unloadable(path,
				"instantiation threw inside the runner and could not be contained")
		else:
			var suite: Object = got.get("suite", null)
			if suite == null:
				_record_unloadable(path, got.get("error", "unknown reason"))
			elif not suite.has_method("run"):
				_record_unloadable(path,
					"it instantiated, but the object has no run(t) method to call")
			else:
				await suite.call("run", t)
		t.end_suite()
		await _isolate(t, name)
		ran += 1

	if ran == 0:
		print("no suites matched filter")
	# UNPARSEABLE is a separate outcome, not a failed assertion: the counters
	# are left exactly as the suites left them, and the non-zero status is
	# added on top of the summary's own.
	var exit_code: int = t.summary()
	# Printed AFTER `summary()`, not before it. Measured 2026-10-03 with a
	# deliberately unparseable probe: printing this block first left
	# "7 passed, 0 failed" as the LAST line on screen, so the tail of a run
	# whose exit code was 1 read as a clean pass. The warning about the file
	# that never ran has to be the last thing printed, not the thing a
	# half-reading skims past. (w5's original comment here said "after the
	# summary" while the code printed it before; the code was what ran.)
	_record_unloadable_summary()
	if not _unloadable.is_empty():
		exit_code = maxi(exit_code, _unloadable.size())
	quit(exit_code)


## Loads and instantiates ONE suite, keeping every way that can fail inside
## this function.
##
## Measured 2026-10-03 against a `Tests/test_t75_probe.gd` holding an
## unclosed paren - the 06:10Z gate failure, reproduced to the letter:
##
##     ERROR: Failed to load script "res://Tests/test_t75_probe.gd" with
##            error "Parse error".
##     SCRIPT ERROR: Invalid call. Nonexistent function 'new' in base
##               'GDScript'.
##               at: _initialize (res://Tests/run_tests.gd:78)
##
## Two facts in that transcript decide this whole function.
##
## 1. `load()` returns a NON-NULL GDScript for a file that failed to
##    compile. So the runner's old `if script == null` check never fired
##    for the one case it was written for, and control fell straight
##    through to `.new()`. A null check alone cannot fix this; the loaded
##    object has to be interrogated.
## 2. That `.new()` ran in `_initialize`'s own frame. A GDScript runtime
##    error aborts the function it happens in, so it aborted the runner's
##    coroutine: `end_suite()`, `_isolate()`, the rest of the loop and
##    `quit()` were all skipped, the SceneTree idled on an empty script,
##    and the process was killed at the 900 s timeout - exit 124, no
##    summary. Hanging is what an aborted runner looks like from outside.
##
## So there are two defences, because either alone leaves a hole.
##
##   a. `can_instantiate()` is checked BEFORE `.new()`, so the common case
##      (a parse error) never calls `.new()` and never aborts anything.
##   b. `.new()` is still called from here rather than from `_initialize`,
##      so a throw from any OTHER cause - a script that compiles but whose
##      `_init()` dies - is contained in this function and the caller
##      carries on. That containment is not a guess: the harness
##      self-check has always depended on it, because
##      `_SelfCheckAbort.run` throws and the runner runs on past it.
##
## Returns `{"suite": Object|null, "error": String}`.
func _acquire(path: String) -> Dictionary:
	var script: Script = load(path)
	if script == null:
		return {"suite": null,
			"error": "load() returned null - Godot logged the parse/compile error immediately above"}
	if not script.can_instantiate():
		# reload() re-runs the parser and hands back the engine's own verdict,
		# so the report carries the error code and not just "it broke". It
		# also re-prints the parse error next to this line, which is what puts
		# Godot's "Expected closing )" text in the middle of the report.
		var err: int = script.reload()
		return {"suite": null,
			"error": "the GDScript loaded but Godot refused to compile it: "
				+ "can_instantiate() = false, reload() = %d (%s). " % [err, error_string(err)]
				+ "The parse error Godot printed above names the offending line."}
	var suite: Object = script.new()
	if suite == null:
		return {"suite": null,
			"error": "the script compiled and instantiated, but the object came back null"}
	return {"suite": suite, "error": ""}


## Records a suite that never ran. Kept off `t.ok`/`t.problem` so it cannot
## be counted as a pass, counted as a failure, or filed as a cleanup
## problem - it is none of those three things.
func _record_unloadable(path: String, reason: String) -> void:
	_unloadable.append({"path": path, "reason": reason})
	print("    [UNPARSEABLE] %s" % path)
	print("                 %s" % reason)
	print("                 0 assertions ran; every other suite still runs.")


## The UNPARSEABLE block, printed after the normal end-of-run summary so it
## reads as its own section and cannot be skimmed as part of the counts.
func _record_unloadable_summary() -> void:
	if _unloadable.is_empty():
		return
	print("\n%s" % "=".repeat(58))
	print("  UNPARSEABLE SUITES (%d) - discovered, never ran:" % _unloadable.size())
	for u in _unloadable:
		print("    UNPARSEABLE %s" % u["path"])
		print("                %s" % u["reason"])
	print("  %d suite(s) contributed no assertions. That is a broken file, not" % _unloadable.size())
	print("  a failing test: fix the file(s) above, the rest of the run stands.")
	print("=".repeat(58))


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
