class_name TestHarness
extends RefCounted
## Minimal assert-based harness. No framework, no plugins, no fixtures.
##
## Suites are RefCounted objects exposing `run(t: TestHarness)`. The harness owns
## the pass/fail counting so suites stay declarative and short.

var passed: int = 0
var failed: int = 0
var _suite: String = ""
var _failures: Array[String] = []
## Set by the runner. MainLoop is null inside `_init`, so the tree is handed in.
var tree: SceneTree = null


## Advances `n` physics frames.
func ticks(n: int) -> void:
	for i in n:
		await tree.physics_frame


## Builds a scene tree root the tests can hang a world off.
func new_root(name: String) -> Node:
	var root := Node3D.new()
	root.name = name
	tree.root.add_child(root)
	return root


func drop(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	await tree.process_frame


func suite(name: String) -> void:
	_suite = name
	print("\n  %s" % name)


func ok(condition: bool, label: String) -> bool:
	if condition:
		passed += 1
		print("    [PASS] %s" % label)
	else:
		failed += 1
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
	for f in _failures:
		print("  FAILED: %s" % f)
	print("=".repeat(58))
	return failed
