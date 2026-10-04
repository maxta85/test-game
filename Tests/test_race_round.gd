extends RefCounted
## Race rounds: what a finished race leaves behind. Run with: ./test.sh race_round
##
## `Tests/test_race.gd` covers the classification of the race on the road. This
## covers the part that outlives it - the ordered positions, the payout, the
## balance, the splits and the HUD readout - because a lap counter that resets on
## the next entry is a demo rather than a loop: the board reads LAP 1/1, POS 1/2
## and $0, and the same night can be run for ever with nothing accumulating on
## either side.
##
## Two things are worth stating up front.
##
## First, **a round has to pay a wallet that is empty**. A payout is only visible
## if the player was somewhere near broke when they took the fee, so the paying
## cases here spend the bank down to exactly $0 on entry and then check that
## finishing put something back in it. A director that pays nothing leaves a player
## at $0 and unable to enter the next race, which is the deadlock.
##
## Second, **the contract is probed before it is called**. Every new method is
## checked with `has_method` and the suite returns early if any are missing, so a
## director that was never asked to remember anything produces one clear failure
## naming what is absent rather than a chain of "nonexistent function" errors from
## the middle of a case. That matters for the runner as well as for the message:
## a suite that throws part way through a case loses the assertions after it.

## The whole contract the loop rests on, as one list, so a missing method is
## reported by name rather than as whichever call happened to come first.
const ROUND_API := [
	"last_round", "round_history", "round_count", "career_best_lap",
	"clear_history", "money_before", "last_paid", "splits",
]
const RECORD_API := [
	"is_ordered", "order_signature", "board_rows", "headline", "player_position",
	"paid_to_position", "net", "money_before", "money_after", "paid",
	"splits", "splits_text", "best_lap", "field_size", "finished", "round_index",
]
const HUD_API := ["round_text", "board_rows", "board_visible"]

## The director needs nothing but `position` and `facing`, so the round content is
## measured on pure logic - the same stub `Tests/test_race.gd` uses.
class FakeCar extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var facing: Vector3 = Vector3.FORWARD


var g: RoadGraph
var _saved_money: int = 0


func run(t: TestHarness) -> void:
	g = RoadGraph.new()
	g.build(ManundaLayout.corridors())
	_saved_money = Cfg.money

	if not _probe(t):
		Cfg.money = _saved_money
		return

	_ordered_positions(t)
	_ordered_with_retirements(t)
	_pays_an_empty_wallet(t)
	_losing_is_paid(t)
	_splits(t)
	_history(t)
	_determinism(t)
	await _hud(t)

	Cfg.money = _saved_money


## Reports every method the loop needs, once, and stops the suite if any are
## missing. The HUD's three are probed on an off-tree instance: creating it is
## cheap and nothing is added to the world.
func _probe(t: TestHarness) -> bool:
	var missing := _missing(RaceDirector.new(), ROUND_API)
	var hud := RaceHUD.new()
	missing.append_array(_missing(hud, HUD_API).map(func(m: String) -> String: return "hud." + m))
	hud.free()
	t.ok(missing.is_empty(), "the loop API is all there%s" % [
		"" if missing.is_empty() else " (missing: %s)" % ", ".join(missing)])
	return missing.is_empty()


func _missing(o: Object, methods: Array) -> Array:
	var out: Array = []
	for m in methods:
		var name := String(m)
		# `has_method` alone would call every recorded *property* missing - the
		# record is mostly fields, and the probe has to see both.
		if not o.has_method(name) and not (name in o):
			out.append(name)
	return out


# ------------------------------------------------------------------- positions

## A round that ends is a classification, not a tally: positions run 1..n with no
## gaps and no repeats. Read out of the record rather than off `results`, because
## the record is the thing that has to survive the next entry.
func _ordered_positions(t: TestHarness) -> void:
	var d := _def("round_order", 2)
	var dr := _on_the_grid(d, _field(4))
	_green_light(dr)
	_race(dr, [3.0, 5.0, 8.0, 12.0], _limits(4, d, 2))

	var round: RoundResult = dr.last_round()
	t.ok(round != null, "a concluded race hands back a round")
	if round == null:
		return
	var missing := _missing(round, RECORD_API)
	t.ok(missing.is_empty(), "the round carries its whole record%s" % [
		"" if missing.is_empty() else " (missing: %s)" % ", ".join(missing)])
	if not missing.is_empty():
		return

	t.eq(dr.state_name(), "finished", "the race is over")
	t.ok(round.is_ordered(), "the classification is ordered 1..n, finishers first")
	t.eq(round.field_size, 4, "all four cars were classified")
	t.eq(round.order_signature(), "3>2>1>0",
		"four constant speeds give one unambiguous order, fastest first")
	t.eq(round.player_position(), 4, "the slowest car on the grid came in last")

	var rows: Array = round.board_rows()
	t.eq(rows.size(), 4, "one board row per classified car")
	for i in rows.size():
		t.ok(String(rows[i]).begins_with("P%d " % (i + 1)),
			"board row %d is printed in position %d (%s)" % [i, i + 1, String(rows[i])])

	# The sliding scale, read off the record: the round owes the winner more than
	# the last car, and owes the player something for finishing at all.
	t.gt(float(round.paid_to_position(1)), float(round.paid_to_position(4)),
		"the winner's share beats last place's")
	t.gt(float(round.paid_to_position(4)), 0.0, "the player is paid for finishing")

	# The record and the live classification are written in one pass, so they cannot
	# disagree about who came in where.
	var agrees := true
	for i in rows.size():
		agrees = agrees and int(dr.results[i]["pos"]) == i + 1
	t.ok(agrees, "the round agrees with the classification it was written from")


## A player who wins alone is classified first, and the two cars that never got
## home are still classified - in order, behind everyone who did. This is the
## shape a street race actually ends in, and the ordering rule has to hold for it
## or a result board is showing a DNF where the leader finished.
func _ordered_with_retirements(t: TestHarness) -> void:
	var d := _def("round_dnf", 2)
	var dr := _on_the_grid(d, _field(3))
	_green_light(dr)
	# Two cars are told not to move at all: the race is called the instant the
	# player crosses, so they are still on the grid when it is classified.
	_race(dr, [12.0, 0.0, 0.0], [_route(d).size() * 2, 0, 0])

	var round: RoundResult = dr.last_round()
	t.eq(dr.state_name(), "finished", "the leader finishing ends the race")
	t.ok(round.is_ordered(), "a round with two retirements in it is still ordered")
	t.eq(round.order_signature(), "0>1>2", "the winner leads and the retirements are behind")
	t.eq(round.player_position(), 1, "the player won")
	t.eq(bool(round.finished), true, "and finished")
	t.fails(bool(round.positions[1]["finished"]), "a car still on the grid is not a finisher")
	t.fails(bool(round.positions[2]["finished"]), "nor is the one behind it")
	t.ok(String(round.board_rows()[1]).contains("DNF"),
		"and the board says so rather than printing a time (%s)" % String(round.board_rows()[1]))
	t.gt(float(round.paid_to_position(2)), 0.0,
		"a retirement is still paid its share of the round")
	t.gt(float(round.paid_to_position(1)), float(round.paid_to_position(2)),
		"but less than the winner's")


# ---------------------------------------------------------------------- payout

## The whole point of a round: a player who spends their last dollar on the entry
## fee finishes the race with money in the bank. This is the "$0 becomes a payable"
## case, and it runs from an exactly empty balance so the payout cannot hide behind
## an opening float.
func _pays_an_empty_wallet(t: TestHarness) -> void:
	var d := _def("round_pays", 2)
	d.payout = 900
	d.entry_fee = 640

	Cfg.money = d.entry_fee
	var dr := _on_the_grid(d, _field(4))
	t.eq(Cfg.money, 0, "the entry fee took the bank to $0")
	t.eq(dr.money_before(), 0, "and the director knows the round starts from nothing")

	_green_light(dr)
	t.eq(Cfg.money, 0, "the wallet is still empty mid-race - nothing has been paid yet")
	_race(dr, [12.0, 8.0, 5.0, 3.0], _limits(4, d, 2))

	var round: RoundResult = dr.last_round()
	t.eq(dr.state_name(), "finished", "the round is decided")
	t.eq(dr.last_paid(), 900, "winning a four car race pays the whole pot")
	t.gt(float(Cfg.money), 0.0, "a finished round turns $0 into a payable ($%d)" % Cfg.money)
	t.eq(Cfg.money, round.paid, "the credited figure is exactly what the round recorded")
	t.eq(round.money_before, 0, "the record says the round ran on an empty balance")
	t.eq(round.net(), round.paid, "the net is the payout; the fee was already gone")
	t.eq(Cfg.money, round.money_before + round.net(),
		"the bank agrees with the round: before + net == after")
	t.eq(round.fee, d.entry_fee, "the fee the round cost is on the record")
	t.ok(Cfg.get_race_record(d.id).has("best_time"),
		"and the run is on the player's profile")


## Losing is paid too. A round that pays only the winner is a race with a single
## outcome, and the sliding scale on `RaceDef` already says what losing is worth.
func _losing_is_paid(t: TestHarness) -> void:
	var d := _def("round_loses", 1)
	d.payout = 800
	d.entry_fee = 800

	Cfg.money = d.entry_fee
	var dr := _on_the_grid(d, _field(3))
	t.eq(Cfg.money, 0, "entered from the last of the money")
	_green_light(dr)
	_race(dr, [2.0, 6.0, 10.0], _limits(3, d, 1))

	var round: RoundResult = dr.last_round()
	t.eq(round.player_position(), 3, "the player finished last")
	t.gt(float(Cfg.money), 0.0, "last place is still paid - $%d left in the bank" % Cfg.money)
	t.eq(Cfg.money, round.paid, "for exactly what the record says")
	t.ok(float(round.paid) < float(d.payout), "and less than the winner would have taken")
	t.near(float(round.paid), d.payout_for_position(3, 3), 0.001,
		"on the sliding scale the definition already promises")


# ---------------------------------------------------------------------- splits

## A lap timer that only shows the minimum is not a lap timer. Three laps driven at
## three different speeds have to come back as three different splits, with the
## quick ones either side of the slow one.
func _splits(t: TestHarness) -> void:
	var d := _def("round_splits", 3)
	var dr := _on_the_grid(d, _field(1))
	_green_light(dr)

	var lap := _route(d).size()
	var at := 0
	at = _walk(dr, 10.0, lap, at)
	at = _walk(dr, 2.0, lap, at)
	at = _walk(dr, 10.0, lap, at)

	t.eq(dr.state_name(), "finished", "three laps of a three lap race is a finish")
	t.eq(dr.laps(0), 3, "every lap was banked")

	var sp: Array = dr.splits(0)
	t.eq(sp.size(), 3, "a split per lap, not just the best one")
	var all_timed := true
	for s in sp:
		all_timed = all_timed and float(s) > 0.0
	t.ok(all_timed, "and every one of them is timed (%s)" % str(sp))
	t.gt(float(sp[1]), float(sp[0]), "the slow lap is recorded as the slow one")
	t.gt(float(sp[1]), float(sp[2]), "and slower than the one after it")
	var fastest: float = minf(minf(float(sp[0]), float(sp[1])), float(sp[2]))
	t.near(dr.best_lap(0), fastest, 0.001, "the best lap is the fastest of the three splits")

	var round: RoundResult = dr.last_round()
	t.eq(round.splits.size(), 3, "the round carries the splits")
	t.near(round.best_lap, fastest, 0.001, "and the best lap it ran")
	t.eq(round.splits_text(), "%s %s %s" % [
		RoundResult.clock_text(float(sp[0])), RoundResult.clock_text(float(sp[1])),
		RoundResult.clock_text(float(sp[2]))], "the splits render in the order they were driven")


# --------------------------------------------------------------------- history

## A second round has to add to the first rather than replace it, and `reset()` -
## which is what the next entry on the grid goes through - must not be the thing
## that erases a night's work.
func _history(t: TestHarness) -> void:
	var d := _def("round_history", 1)
	var dr := _on_the_grid(d, _field(3))
	t.eq(dr.round_history().size(), 0, "nothing has been run yet")
	t.eq(dr.round_count(), 0, "and no round has been counted")

	_green_light(dr)
	_race(dr, [10.0, 6.0, 2.0], _limits(3, d, 1))
	var first: RoundResult = dr.last_round()
	t.eq(dr.round_count(), 1, "the first round is counted")
	t.eq(first.round_index, 1, "and is round 1")
	t.eq(first.player_position(), 1, "the player won the first round")
	t.eq(first.order_signature(), "0>1>2", "from the back of the grid")

	dr.reset()
	t.eq(dr.results.size(), 0, "a reset still clears the live classification")
	t.eq(dr.round_history().size(), 1, "but it does not throw the round away")
	t.eq(dr.last_round(), first, "and the round is still the last one")
	t.eq(dr.money_before(), first.money_before,
		"clearing the grid does not rewrite the balance the last round ran on")

	# The retry goes straight through `start()` - `reset()` kept the entry paid for,
	# so this is the same money, not a second fee. A fee taken twice here would show
	# up as a `money_before` that is not what the bank held.
	Cfg.money = 500
	var before_retry := Cfg.money
	t.ok(dr.start(d, g, _field(3)), "the paid-up race goes on the grid again")
	t.eq(Cfg.money, before_retry, "a retry is not charged for a second time")
	_green_light(dr)
	_race(dr, [2.0, 6.0, 10.0], _limits(3, d, 1))

	var second: RoundResult = dr.last_round()
	t.eq(dr.round_count(), 2, "two rounds have been run")
	t.eq(second.round_index, 2, "the second is round 2")
	t.eq(second.player_position(), 3, "and the player came in last this time")
	t.eq(second.money_before, before_retry, "the second round started from what the first left")
	t.eq(dr.round_history().size(), 2, "the history holds both")
	t.eq(dr.round_history()[0], first, "oldest first: round 1 is still the first entry")
	t.eq(dr.round_history()[1], second, "and round 2 is the second")
	t.ok(first != second, "the two rounds are two records")
	t.eq(first.order_signature(), "0>1>2", "round 1's order is still its own")
	t.eq(second.order_signature(), "2>1>0", "and round 2's is not overwritten by it")

	# A personal best is worth having across rounds, so it is read out of the
	# history rather than off the last race.
	t.near(dr.career_best_lap(d.id), minf(first.best_lap, second.best_lap), 0.001,
		"the best lap over both rounds is the faster of the two")
	t.eq(dr.career_best_lap("a_route_never_driven"), 0.0,
		"a route never driven has no best lap, rather than one borrowed from elsewhere")

	# Clearing the history is deliberate, so it is the one thing that does it.
	dr.clear_history()
	t.eq(dr.round_history().size(), 0, "the history can be cleared on purpose")
	t.eq(dr.last_round(), null, "and the round it was holding goes with it")
	t.eq(dr.round_count(), 0, "and the count goes back to nothing")


# ---------------------------------------------------------------- determinism

## The same night, twice. Anything that varies between two identical runs - a dict
## iteration, a float accumulated in a different order, a sort that is not stable -
## shows up here as a different order or a different figure, which is the only way
## a payout can be checked at all.
func _determinism(t: TestHarness) -> void:
	var d := _def("round_determinism", 2)
	d.payout = 1234
	d.entry_fee = 1234

	var first := _play_out(d, [3.0, 7.0, 12.0])
	var second := _play_out(d, [3.0, 7.0, 12.0])
	t.eq(String(second["order"]), String(first["order"]),
		"the same field over the same route finishes in the same order (%s)" % String(first["order"]))
	t.eq(int(second["paid"]), int(first["paid"]),
		"and pays the same (%d both runs)" % int(first["paid"]))
	t.eq(int(second["money"]), int(first["money"]),
		"and leaves the same balance (%d both runs)" % int(first["money"]))
	t.eq(String(second["headline"]), String(first["headline"]),
		"so the HUD line for it is the same too")


# ------------------------------------------------------------------------ HUD

## The HUD has to *show* the round, not merely hold the data for someone to show.
## Driven straight off the director the way the game drives it, so nothing here
## depends on a host remembering to push a round in.
func _hud(t: TestHarness) -> void:
	var d := _def("round_hud", 1)
	d.payout = 1500
	d.entry_fee = 0

	var dr := _on_the_grid(d, _field(3))
	_green_light(dr)
	_race(dr, [2.0, 6.0, 10.0], _limits(3, d, 1))
	var round: RoundResult = dr.last_round()
	t.ok(round != null, "the round under test was decided")
	if round == null:
		return

	var world := t.new_root("RoundHUDWorld")
	var hud := RaceHUD.new()
	hud.name = "RoundHUD"
	world.add_child(hud)
	await t.ticks(1)

	hud.update(null, dr, 0.0)
	t.ok(hud.board_visible(), "a decided round puts the classification on the HUD")
	t.eq(hud.round_text(), round.headline(),
		"the HUD's summary line is the round's own headline (%s)" % hud.round_text())
	t.ok(hud.round_text().contains("PAID $%d" % round.paid),
		"and it names the payout the round paid")

	var rows: Array = hud.board_rows()
	var expected: Array = round.board_rows()
	t.eq(rows.size(), expected.size(), "one HUD row per classified car")
	var ordered := true
	for i in mini(rows.size(), expected.size()):
		ordered = ordered and String(rows[i]) == String(expected[i])
		ordered = ordered and String(rows[i]).begins_with("P%d " % (i + 1))
	t.ok(ordered, "the HUD prints the classification in finishing order: %s" % [
		", ".join(expected.map(func(r: Variant) -> String: return String(r)))])

	# It is driven, not a one-shot: a second round replaces the first rather than
	# leaving the last result on screen for ever.
	dr.reset()
	t.ok(dr.start(d, g, _field(3)), "a second round starts on the same director")
	_green_light(dr)
	_race(dr, [10.0, 6.0, 2.0], _limits(3, d, 1))

	hud.update(null, dr, 0.0)
	var second: RoundResult = dr.last_round()
	t.ok(second != round, "the second round is a different record")
	t.eq(hud.round_text(), second.headline(), "the next round replaces the readout")
	t.ok(hud.round_text() != round.headline(), "and it is a different line, so the swap is real")
	t.eq(hud.board_rows().size(), 3, "the classification is still three rows long")

	await t.drop(world)


# ------------------------------------------------------------------- plumbing

## A runnable circuit with a payout worth racing for.
func _def(id: String, laps: int) -> RaceDef:
	var d := RaceDef.circuit(g, 0, 700.0, id, "Round %s" % id, laps)
	d.payout = 800
	d.entry_fee = 200
	return d


func _field(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(FakeCar.new())
	return out


## A director entered and started, with `cars` on the grid. `start()` keeps its own
## copy of the array, so a case that wants to drive must use `dr.entrants`.
func _on_the_grid(d: RaceDef, cars: Array) -> RaceDirector:
	Cfg.money = maxi(Cfg.money, d.entry_fee)
	var dr := RaceDirector.new()
	assert(dr.try_enter(d), "the test race should be affordable: %s" % d.id)
	assert(dr.start(d, g, cars), "the paid-up race should start: %s" % d.id)
	return dr


func _green_light(dr: RaceDirector) -> void:
	for i in 4:
		dr.tick(1.0)
	assert(dr.state_name() == "racing", "the countdown should be over")


## The route to drive, ending 30 m past the line so a lap ends on a real crossing.
func _route(d: RaceDef) -> Array:
	var out: Array = []
	for n in d.path:
		var p: Vector2 = g.node_pos(int(n))
		out.append(Vector3(p.x, 0.0, p.y))
	out.append(out[0] + (out[1] - out[0]).normalized() * 30.0)
	return out


## Enough waypoints for every car to run every lap, so a limit of this size means
## "drive the whole race" and anything smaller means "leave it behind".
func _limits(n: int, d: RaceDef, laps: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(_route(d).size() * laps)
	return out


## Runs the field until the race is decided. `speeds[i]` is metres a tick and
## `limit[i]` how many waypoints car i is allowed; a speed or a limit of 0 leaves
## that car exactly where it was put.
func _race(dr: RaceDirector, speeds: Array, limit: Array) -> void:
	var wps := _route(dr.def)
	var cars: Array = dr.entrants
	var idx: Array = []
	for i in cars.size():
		idx.append(0)
	var guard := 0
	while dr.state_name() == "racing" and guard < 60000:
		for i in cars.size():
			if int(idx[i]) >= int(limit[i]):
				continue
			var step: float = float(speeds[i])
			if step <= 0.0:
				continue
			var car = cars[i]
			var target: Vector3 = wps[int(idx[i]) % wps.size()]
			if car.position.distance_to(target) > step * 0.5:
				car.facing = (target - car.position).normalized()
				car.position = car.position.move_toward(target, step)
			else:
				idx[i] = int(idx[i]) + 1
		dr.tick(0.05)
		guard += 1


## Walks the player `count` waypoints at `step` metres a tick, returning the
## waypoint index it reached. The index comes back because the next lap has to
## carry on from where this one stopped rather than starting the route again.
func _walk(dr: RaceDirector, step: float, count: int, from: int) -> int:
	var wps := _route(dr.def)
	var car = dr.entrants[0]
	var idx := from
	var guard := 0
	while idx < from + count and guard < 60000:
		var target: Vector3 = wps[idx % wps.size()]
		if car.position.distance_to(target) > step * 0.5:
			car.facing = (target - car.position).normalized()
			car.position = car.position.move_toward(target, step)
		else:
			idx += 1
		dr.tick(0.05)
		guard += 1
	return idx


## One whole race, from the fee to the bank. Everything `_determinism` compares.
func _play_out(d: RaceDef, speeds: Array) -> Dictionary:
	Cfg.money = d.entry_fee
	var dr := _on_the_grid(d, _field(speeds.size()))
	_green_light(dr)
	_race(dr, speeds, _limits(speeds.size(), d, d.laps))
	var round: RoundResult = dr.last_round()
	return {
		"order": round.order_signature() if round != null else "",
		"paid": dr.last_paid(),
		"money": Cfg.money,
		"headline": round.headline() if round != null else "",
	}