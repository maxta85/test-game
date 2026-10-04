class_name RoundResult
extends RefCounted
## One completed round, kept: the finishing order, what it paid, and the balance
## it ran on.
##
## `RaceDirector.results` is the classification of the race currently on the road,
## and `reset()` throws it away the moment the next entry is paid for. That is
## right for a lap counter and wrong for a game loop. After a round the player has
## a *history* - where they came in, what the night paid them, what their best lap
## was - and a balance that moved. Without a record of that, a race is a demo: the
## board shows LAP 1/1 and POS 1/2, the wallet reads $0, and the same night can be
## run for ever with nothing accumulating on either side.
##
## So a finished race writes one of these, the director keeps the last few, and the
## HUD reads them without asking the director to still be in the state that made
## them. Written once, never mutated: history that rewrites itself is not history.
##
## Deliberately free of any reference to `RaceDirector` or to the UI - the
## director fills it in, and everyone downstream reads it. That keeps the
## dependency one-way (`RaceDirector` -> `RoundResult`) instead of a cycle.
##
## ORIGINAL GAME CONTENT.

## How many rounds a director keeps. Long enough to show a session's form on the
## HUD, short enough that a player who races all night is not carrying a log file.
const HISTORY_LIMIT := 8

## 1-based, counting every round this director has run. So the HUD can say ROUND 3
## rather than nothing at all on the first night.
var round_index: int = 0
var race_id: String = ""
var race_name: String = ""
var laps_required: int = 1
## How many cars were classified.
var field_size: int = 0

## Classification order, position 1 first. Each row is
## `{ pos, index, car, time, best_lap, laps, finished, paid }`, where `index` is
## the entrant slot - 0 is the player - and `paid` is what that position was worth
## to that driver under the definition's sliding scale.
var positions: Array = []

## The player's finishing time per lap, in order, as completed laps.
var splits: Array = []
## The player's fastest lap in this round. 0.0 when no lap was banked.
var best_lap: float = 0.0
var finished: bool = false

## The entry fee the player paid to take part, and what the round paid back.
var fee: int = 0
var paid: int = 0
## The wallet as it stood when the lights went out - i.e. *after* the entry fee.
## This is the figure that makes "$0" mean something: a player who spends their
## last dollar on the fee runs the round from an empty balance, and this is the
## proof that the round put something back into it.
var money_before: int = 0
var money_after: int = 0


# ------------------------------------------------------------------ the facts

## What the round did to the bank, ignoring the fee - which was already gone
## before the lights went out. `paid` is the same number by construction; this
## exists so a reader does not have to know that to check it.
func net() -> int:
	return money_after - money_before


## Where the player came in, or 0 if they were not classified.
func player_position() -> int:
	for r in positions:
		if int(r.get("index", -1)) == 0:
			return int(r.get("pos", 0))
	return 0


## What a given finishing position was worth, from the round's own record.
func paid_to_position(pos: int) -> int:
	for r in positions:
		if int(r.get("pos", 0)) == pos:
			return int(r.get("paid", 0))
	return 0


## The finishing order as entrant slots, e.g. "2>0>1" for second, first, third.
## The compact witness of "the order is what it says it is": two rounds with the
## same signature put the same cars in the same places.
func order_signature() -> String:
	var parts := PackedStringArray()
	for r in positions:
		parts.append(str(int(r.get("index", -1))))
	return ">".join(parts)


## True when the record is internally honest: positions run 1..n with no gaps or
## repeats, and everyone who finished is ahead of everyone who did not, ordered by
## the time they took. This is the invariant a results board rests on, so it is
## stated in terms of the stored record rather than of the director that wrote it.
func is_ordered() -> bool:
	var count := positions.size()
	if count == 0 or field_size != count:
		return false
	var seen_finish := false
	var last_time := -INF
	var last_progress := INF
	for i in count:
		var r: Dictionary = positions[i]
		if int(r.get("pos", 0)) != i + 1:
			return false
		if i > 0 and int(positions[i - 1].get("index", -1)) == int(r.get("index", -1)):
			return false
		var fin: bool = bool(r.get("finished", false))
		if fin:
			if seen_finish:
				return false
			var t: float = float(r.get("time", -1.0))
			if t < 0.0 or t < last_time:
				return false
			last_time = t
		else:
			seen_finish = true
			var p: float = float(r.get("progress", 0.0))
			if p > last_progress:
				return false
			last_progress = p
	return true


# ------------------------------------------------------------------ the wording

## The one-line summary. The HUD shows this: it is the answer to "what did that
## round do" without needing the results board to still be up.
func headline() -> String:
	return "ROUND %d  P%d/%d  PAID %s  BAL %s" % [
		round_index, player_position(), maxi(field_size, 1),
		money_text(paid), money_text(money_after)]


## The classification, one string per row, in finishing order. The HUD renders
## these; a test reads them back and can tell the order without re-deriving it.
func board_rows() -> Array:
	var out: Array = []
	for r in positions:
		out.append("P%d %s %s %s" % [
			int(r.get("pos", 0)), label_for(int(r.get("index", -1))),
			clock_text(float(r.get("time", -1.0))) if bool(r.get("finished", false)) else "DNF",
			money_text(int(r.get("paid", 0)))])
	return out


## Lap times as driven, for the split readout.
func splits_text() -> String:
	var parts := PackedStringArray()
	for s in splits:
		parts.append(clock_text(float(s)))
	return " ".join(parts)


## The player's name in a classification. Kept here rather than asked of CarDB so
## that a record is readable without the car's spec being alive - a results board
## that prints a node id is worse than one that prints nothing clever.
static func label_for(index: int) -> String:
	return "YOU" if index == 0 else ("RIVAL %d" % index if index > 0 else "?")


## m:ss.hh, the house clock format (`UI/ui_palette.gd` `clock`). Duplicated rather
## than imported because `UI/` must not be a dependency of the race system.
static func clock_text(t: float) -> String:
	if t < 0.0:
		return "--:--.--"
	var whole := int(t)
	var m := whole / 60
	return "%d:%05.2f" % [m, t - float(m) * 60.0]


## $n, negative out.
static func money_text(n: int) -> String:
	return "-$%d" % -n if n < 0 else "$%d" % n