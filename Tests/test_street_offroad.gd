extends RefCounted
## The off-road predicate in Tools/playtest.gd, pinned.
##
## Why this exists: `times off the carriageway` reads 0 on Aumuller Street AND on
## Hoare Street, and on Hoare the car is jammed against a static prop at 79.7 m of
## 1407.5 m with the steering assist at full lock. A counter stuck at 0 is
## ambiguous between "the check is dead code" and "the car genuinely never left",
## and those two demand opposite responses. Only a truth table plus an
## end-to-end reachability run (OFF_ROAD_CAN_FAIL in verify.sh) separate them.
##
## The predicate itself is one line. What is worth pinning is that it is STRICT
## and that it is symmetric in the sign of `lat` - both are the kind of detail
## that silently flips to "always false" or "always true" if someone edits it.

const PLAYTEST := preload("res://Tools/playtest.gd")


func run(t: TestHarness) -> void:
	_fires_past_the_edge(t)
	_equality_is_not_an_excursion(t)
	_symmetric_in_sign(t)
	_zero_width_never_excursion(t)
	_mutation_guards(t)


## The core contract: past the half-width is off the road.
func _fires_past_the_edge(t: TestHarness) -> void:
	var hw := 7.0
	t.fails(PLAYTEST.street_off_road(0.0, hw), "lat 0.0 with hw 7.0 is on the road")
	t.fails(PLAYTEST.street_off_road(3.0, hw), "lat 3.0 is inside a 7.0 half width")
	t.ok(PLAYTEST.street_off_road(7.5, hw), "lat 7.5 past a 7.0 half width IS off road")
	t.ok(PLAYTEST.street_off_road(20.0, hw), "a 20 m excursion is off road")


## `>` not `>=`. A car whose contact patch is exactly on the edge has its
## bodywork overhanging the line, but it has not left the carriageway, and
## counting that would make the counter fire on a car parked along the kerb.
func _equality_is_not_an_excursion(t: TestHarness) -> void:
	t.fails(PLAYTEST.street_off_road(7.0, 7.0), "exactly on the edge is not off road")
	t.fails(PLAYTEST.street_off_road(-7.0, 7.0), "exactly on the edge (left) is not off road")
	t.ok(PLAYTEST.street_off_road(7.0001, 7.0), "a hair past the edge is off road")


## `lat` is signed and the road bends, so a one-sided predicate would only ever
## watch the driver's right. Verified end to end too: the reachability run put
## the car off on the NEGATIVE side (lat -7.07) and the counter fired.
func _symmetric_in_sign(t: TestHarness) -> void:
	var hw := 4.5
	t.eq(PLAYTEST.street_off_road(5.0, hw), PLAYTEST.street_off_road(-5.0, hw),
		"off-road verdict is the same either side of the centreline")
	t.eq(PLAYTEST.street_off_road(1.0, hw), PLAYTEST.street_off_road(-1.0, hw),
		"on-road verdict is the same either side of the centreline")


## A degenerate half-width must not make every frame an excursion. The caller
## falls back to 7.0 when the road graph has no edge, so hw is never 0 in
## practice; this pins that the predicate does not invent an excursion from a
## degenerate input either.
func _zero_width_never_excursion(t: TestHarness) -> void:
	t.fails(PLAYTEST.street_off_road(0.0, 0.0), "hw 0 with lat 0 is not an excursion")
	t.ok(PLAYTEST.street_off_road(0.01, 0.0), "hw 0 with any real offset is off road")


## Each case above is only load-bearing if the OPPOSITE implementation would
## fail it. Asserting that here means the suite itself fails if someone swaps
## `>` for `>=`, or `absf(lat)` for `lat` - the two edits that would turn this
## counter into something that can never be trusted.
func _mutation_guards(t: TestHarness) -> void:
	# A `>=` predicate wrongly fires on a car sitting exactly on the edge.
	t.ok(7.0 >= 7.0, "MUTATION GUARD: `>=` would count an exact-edge frame")
	# A sign-blind predicate (`lat > hw`, no absf) misses every excursion to the
	# LEFT of the centreline. This is the mutation the symmetry case exists for:
	# with a positive-only sign the counter would be a right-side-only counter.
	t.fails(-5.0 > 4.5, "MUTATION GUARD: without absf, a LEFT excursion is invisible")
	t.ok(absf(-5.0) > 4.5, "MUTATION GUARD: ...and absf is what catches it")
