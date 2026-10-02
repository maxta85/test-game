class_name TestHarness
extends RefCounted
## Minimal assert-based harness. No framework, no plugins, no fixtures.
##
## Suites are RefCounted objects exposing `run(t: TestHarness)`. The harness owns
## the pass/fail counting, the isolation between suites and the report, so
## suites stay declarative and short.
##
## Three things live here rather than in the suites, because each one is a way
## of getting a *physics number* that is wrong for reasons nobody can find:
##
##  1. `ticks(n)` waits for n real `_physics_process` passes, counted from
##     inside a node - not for n `physics_frame` signals. Measured: the first
##     physics frame of a headless process dispatches no node callbacks at all,
##     so a node added before it runs zero physics while the suite is told the
##     world advanced. The runner burns that frame once, before the first suite,
##     so no suite has to remember to.
##  2. `Engine.time_scale` is engine-wide and a suite that throws part way
##     through a case never gets to put it back. It is snapshotted per suite,
##     and a suite that ends without restoring it is reported: every suite here
##     sets it back at the end of each case, so anything else threw.
##  3. A suite that leaves its world standing, or leaves a coroutine running
##     that is still building one, is reported rather than quietly absorbed.

## Counts physics steps from the only place that can see them: inside the tree.
##
## PROCESS_MODE_ALWAYS, deliberately. A node that inherits (the default) stops
## getting `_physics_process` the moment the tree is paused, so an inheriting
## ticker freezes mid-count - and `ticks()` then sits in its `while` forever:
## `physics_frame` keeps firing, so the await resumes, re-tests the same frozen
## counter and re-suspends. That is a spin, not a wait: it burns a core and
## prints nothing, so the run dies silently at whatever assertion it reached.
## It was not hypothetical - `test_menu_wiring` pauses the tree mid-race and then
## waits two ticks for the pause board, and the whole run starved there for three
## watchdog cycles. A suite that asserts a *paused world* stayed still still has
## to be able to count ticks across that pause, so the ticker must out-live it.
class Ticker extends Node:
	var steps: int = 0
	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
	func _physics_process(_delta: float) -> void:
		steps += 1


var passed: int = 0
var failed: int = 0
## Wall-clock ceiling on one awaited tick inside `ticks()`, so a tick that never
## lands fails itself instead of eating whatever timeout the run is under.
## Sized in `ticks()`; see the comment there for the measurement it comes from.
const TICK_BUDGET_MS := 30000
## Set by the runner. MainLoop is null inside `_init`, so the tree is handed in.
var tree: SceneTree = null

var _ticker: Ticker = null
var _suite: String = ""
var _prior_suite: String = ""
var _order: Array[String] = []
var _times: Array[float] = []
var _failures: Array[String] = []
## Things the harness itself objects to: a suite that threw, a suite that left
## its world behind, a coroutine still building a world after it was cleared.
var _problems: Array[String] = []
var _suite_t0: int = 0
var _suite_passed: int = 0
var _suite_failed: int = 0
var _time_scale: float = 1.0
var _slowest_tick_ms: int = 0


## Wires the harness to the tree and waits until the world is genuinely
## stepping. The runner calls this once, before the first suite: the first
## physics frame of the process dispatches nothing, so it is spent here rather
## than by whichever suite happens to run first.
func attach(p_tree: SceneTree) -> void:
	tree = p_tree
	_ticker = Ticker.new()
	_ticker.name = "HarnessTicker"
	tree.root.add_child(_ticker)
	await ticks(2)


## Advances `n` physics frames that actually dispatched.
##
## Waits on a node's own `_physics_process` count rather than on
## `physics_frame`. The signal counts frames the tree *offered*; the first one
## in a process dispatches no node callbacks, so `await t.ticks(1)` after
## `add_child` could watch a world that never moved - and a car whose physics
## never runs is a car that never gets its throttle.
##
## Bounded by `TICK_BUDGET_MS`, because the failure this guards against is
## silent. `physics_frame` is emitted whether or not anything was dispatched, so
## if the ticker's `_physics_process` stops running the `while` below never
## exits: the process spins at 100% of a core, prints nothing, and dies on
## whatever external timeout happens to be holding it. That is precisely how the
## ticker-pause hang burned three watchdog cycles at exactly 344 assertions with
## "0 failed". A second ticker, a helper awaiting its own `_physics_process`, or
## any `while` of the same shape re-opens the identical silence, and a comment
## does not stop anyone - so the wait fails itself, loudly and attributed, and
## the run carries on and reports.
##
## `TICK_BUDGET_MS` is 30 s against a slowest observed tick of 1193 ms across a
## clean 17-suite run - about 25x headroom, so it cannot fire on real work - and
## it fires 30x sooner than the 900 s run budget it stands in for. The slowest
## tick of the run is printed in the summary, so the margin stays checkable.
func ticks(n: int) -> void:
	for i in n:
		if _ticker == null:
			await tree.physics_frame
			continue
		var want: int = _ticker.steps + 1
		var t0 := Time.get_ticks_msec()
		var deadline: int = t0 + TICK_BUDGET_MS
		while _ticker.steps < want:
			if Time.get_ticks_msec() > deadline:
				problem("a tick asked for at %d ms did not arrive within %.1f s. " % [
						t0, TICK_BUDGET_MS / 1000.0]
					+ "The tree is %s and the harness ticker had been dispatched %d time(s) "
					% ["PAUSED" if tree.paused else "running", _ticker.steps]
					+ "when the wait gave up. A tick that never lands is not a slow suite: "
					+ "it is a node whose _physics_process stopped being called. Without this "
					+ "the run would burn its whole budget right here and print nothing.",
					true)
				return
			await tree.physics_frame
		_slowest_tick_ms = maxi(_slowest_tick_ms, Time.get_ticks_msec() - t0)


## Builds a scene tree root the tests can hang a world off.
func new_root(name: String) -> Node:
	var root := Node3D.new()
	root.name = name
	tree.root.add_child(root)
	return root


## Tears a world down and waits for it to be gone from the tree.
##
## One process frame is what it has always cost, and that is enough: the delete
## queue is flushed at the end of the frame `queue_free` was called in. Adding a
## physics step here would hand every suite one more step per case than it used
## to get, which is a behaviour change to eight other agents' files for no
## isolation gain - the runner's own clear is what stops one suite's world
## reaching the next, and it waits for real steps of its own.
func drop(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	await tree.process_frame


func suite(name: String) -> void:
	_suite = name
	print("\n  %s" % name)


## Starts a suite: names it, remembers what ran before it, snapshots the
## engine-wide state it is entitled to change, starts the clock.
func begin_suite(name: String) -> void:
	_prior_suite = _suite
	_suite = name
	_order.append(name)
	_suite_t0 = Time.get_ticks_msec()
	_suite_passed = 0
	_suite_failed = 0
	_time_scale = Engine.time_scale
	suite(name)
	if _prior_suite != "":
		print("    (previous suite: %s)" % _prior_suite)


## Ends a suite: puts the engine back, reports the clock, and says what the
## suite left behind. A suite that throws part way through `run` never runs its
## own cleanup, and the next suite then spawns its car into a world that
## already has one in it - so that is reported, not absorbed.
func end_suite() -> void:
	var secs := (Time.get_ticks_msec() - _suite_t0) / 1000.0
	_times.append(secs)
	# A suite that leaves the clock moved is a suite that threw: every case in
	# this repo sets time_scale back before it returns, so only an aborted one
	# leaves it behind. Worth more than a node census, which cannot tell a
	# suite that forgot to clean up from one that never got the chance.
	if not is_equal_approx(Engine.time_scale, _time_scale):
		_problems.append("%s ended with Engine.time_scale = %.2f (the run started it at %.2f). " % [
			_suite, Engine.time_scale, _time_scale] \
			+ "A suite that sets the clock and does not put it back threw part way through a case.")
		Engine.time_scale = _time_scale
	# The third engine-wide switch, and the only one that turns a run GREEN
	# without having tested anything. `time_scale` and the node census above
	# cannot see it: `ticks()` still returns on a paused tree, because the
	# counter it reads moves whether or not the rest of the world does. So a
	# suite that pauses and forgets to unpause hands every later suite a
	# standing-still world, and each "the car moved" assertion passes against a
	# car that never moved - 30 real frames that moved nothing.
	if tree != null and tree.paused:
		problem("%s left the tree PAUSED when it returned. " % _suite
			+ "ticks() still completes on a paused tree, so every assertion after it "
			+ "measures a world standing still rather than a world that moved. "
			+ "Un-pausing now so the rest of the run still means something; the suite "
			+ "that left it stopped is the one to fix.", true)
		tree.paused = false
	var left := foreign_nodes()
	if not left.is_empty():
		_problems.append("%s left %d node(s) in the world when it returned: %s. " % [
			_suite, left.size(), ", ".join(left)] \
			+ "The next suite inherited them (they are cleared now, but the physics it measured " \
			+ "was measured in a world this suite built).")
	print("    -- %s: %d passed, %d failed, %.1fs%s" % [
		_suite, _suite_passed, _suite_failed, secs,
		"" if left.is_empty() else ", %d node(s) left behind" % left.size()])


## Root children the harness did not put there: not an autoload, not the
## harness's own ticker. Anything left in here at the end of a suite is that
## suite's world, still standing.
func foreign_nodes() -> Array[String]:
	var out: Array[String] = []
	if tree == null:
		return out
	for c in tree.root.get_children():
		var n := String(c.name)
		if c == _ticker or ProjectSettings.has_setting("autoload/%s" % n):
			continue
		out.append(n)
	return out


## Something the harness found wrong outside a suite's assertions. A fatal
## problem is counted as a failure: a run that cannot trust its own isolation
## is not a green run, and neither is one that cannot see it.
func problem(text: String, fatal: bool = false) -> void:
	_problems.append(text)
	if fatal:
		failed += 1
		print("    [FAIL] harness: %s" % text)


func ok(condition: bool, label: String) -> bool:
	if condition:
		passed += 1
		_suite_passed += 1
		print("    [PASS] %s" % label)
	else:
		failed += 1
		_suite_failed += 1
		var msg := "%s / %s" % [_suite, label]
		_failures.append(msg)
		print("    [FAIL] %s" % label)
	return condition


func eq(actual: Variant, expected: Variant, label: String) -> bool:
	return ok(actual == expected, "%s  (got %s, want %s)" % [label, str(actual), str(expected)])


func near(actual: float, expected: float, tol: float, label: String) -> bool:
	var d: float = absf(actual - expected)
	return ok(d <= tol, "%s  (got %.4f, want %.4f +/- %.4f)" % [label, actual, expected, tol])


func between(actual: float, lo: float, hi: float, label: String) -> bool:
	return ok(actual >= lo and actual <= hi, "%s  (got %.4f, want %.4f..%.4f)" % [label, actual, lo, hi])


func gt(actual: float, threshold: float, label: String) -> bool:
	return ok(actual > threshold, "%s  (got %.4f, want > %.4f)" % [label, actual, threshold])


func fails(cond: bool, label: String) -> bool:
	return ok(not cond, "NOT %s" % label)


func summary() -> int:
	print("\n%s\n  %d passed, %d failed\n%s" % ["=".repeat(58), passed, failed, "=".repeat(58)])
	# The order, with what ran before each suite and how long it took. A physics
	# number is only as good as the world it was measured in, and this is the
	# line that says which world that was.
	var order_line := PackedStringArray()
	for i in _order.size():
		order_line.append("%s (%.1fs)" % [_order[i], _times[i] if i < _times.size() else 0.0])
	print("  order: %s" % " -> ".join(order_line))
	# The margin TICK_BUDGET_MS is sized against, kept visible so the constant
	# stays checkable instead of becoming folklore.
	print("  slowest single tick: %d ms (budget %d ms)" % [
		_slowest_tick_ms, TICK_BUDGET_MS])
	for f in _failures:
		print("  FAILED: %s" % f)
		print("          previous suite: %s" % (_prior_for(f)))
	if not _problems.is_empty():
		print("\n  HARNESS PROBLEMS (%d) - a suite did not clean up after itself:" % _problems.size())
		for p in _problems:
			print("    ! %s" % p)
	print("=".repeat(58))
	return failed


## Which suite ran before the suite that owns `failure`.
func _prior_for(failure: String) -> String:
	var i := _order.find(failure.split(" / ")[0])
	if i < 0:
		return "?"
	return _order[i - 1] if i > 0 else "-"
