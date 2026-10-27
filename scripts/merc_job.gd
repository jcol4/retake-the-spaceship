class_name MercJob
extends RefCounted
## A rival merc crew's reason to be on the deck, and when it decides to leave
## (GDD §11.10, extraction plan Phase 8). One per merc squad, shared by every
## member (they all hold the same object), so the squad works and leaves as one.
##
## Engine-free like ExtractionRules: no scene tree, no autoloads, no Unit class.
## MercUnit feeds it what it sees (rooms walked, containers looted, who is still
## standing, the round) and acts on its answers; tools/test_merc_extraction.gd
## drives it directly.
##
##     WORKING  --(job done / packs full / half the crew down / round limit)-->
##     EXTRACTING  --(the ship leaves with somebody aboard)-->  DEPARTED
##
## A crew that is DEPARTED but still has members on the board (left outside the
## square) is stranded: its run is over (ExtractionRules.retired_crews), and the
## stragglers fall back to the plain merc behaviour — patrol and fight.

## LOOT     clean out `loot_goal` containers (crates or piles).
## CONTEST  the player's own Retrieve item (same contract, rival crew): go to
##          wherever it is and take it. Falls back to LOOT once the item is out of
##          reach — in a player's pack, or gone.
## APPEND-ONLY.
enum Kind { LOOT, CONTEST }
enum Phase { WORKING, EXTRACTING, DEPARTED }

## How many containers a LOOT job clears. Containers, not items or credits (the
## Phase 6 note: "count takes, not values") — a crate is a stop on the route, and
## two or three stops is a run about as long as the player's. PLACEHOLDER.
const LOOT_GOAL_MIN := 2
const LOOT_GOAL_MAX := 3
## Leave once this share of the crew is down (the plan's "casualties reach 50%").
## A crew that has lost half its people has lost the fight it came for.
const CASUALTY_FRACTION := 0.5
## Leave once this round is reached whatever else holds — the plan's "a round
## limit is passed". Rolled per crew so two runs do not always end in step, and
## set around the player's own pace (the `--auto` squad calls at round 20, real
## runs take 20–30), so a merc call-in usually lands while the player is still
## aboard and a hangar is worth contesting. PLACEHOLDER.
const LEAVE_ROUND_MIN := 16
const LEAVE_ROUND_MAX := 24
## Chance a crew on a Retrieve deck is after the same item as the player. Half:
## a contested Retrieve is the sharpest merc encounter there is, and every one
## would make Retrieve the "fight the mercs" contract. PLACEHOLDER.
const CONTEST_CHANCE := 0.5
## A rival crew's call-in (the positionless radio notice, GDD §7.3) tells a crew
## the deck is about to get loud and a hangar is about to be taken: it brings its
## own leave round forward to at most this many rounds away.
const HURRY_ROUNDS := 6
## Dust-off while stragglers are still out: once at least half the living crew is
## in the square and the ship has been down this many rounds. Before that the
## crew waits for its people; after it, a professional crew does not hold a ship
## on a hot pad for one man. (With everyone aboard it goes at once.)
const DUST_OFF_PATIENCE_ROUNDS := 3

const NO_TILE := Vector3i(-9999, -9999, -9999)

var crew := -1
var squad_id := ""
var kind: Kind = Kind.LOOT
var phase: Phase = Phase.WORKING
var loot_goal := LOOT_GOAL_MIN
## Container tiles this crew has taken something from. Distinct tiles, so two
## items out of one crate are one stop.
var looted: Dictionary = {}
var start_size := 0
var leave_round := LEAVE_ROUND_MAX
## Why it is extracting ("" while WORKING), for the log and the tests.
var leave_reason := ""
## Rooms a member has stood in. Containers in them are known (they were seen on
## the way through); rooms not in it are where the crew explores next.
var visited_rooms: Dictionary = {}
## The squad's shared destination, so the crew moves as a cluster: a container
## tile while WORKING, NO_TILE for none. Re-picked when it stops being useful.
var target_tile := NO_TILE
## The room the squad is exploring toward, or -1.
var explore_room := -1
## Room index -> its walkable tiles: deck data, built once by whichever member
## first needs it (MercUnit._room_cells) and shared through the job.
var room_cells: Dictionary = {}
## The hangar the crew is walking to while EXTRACTING with no claim yet, or -1.
var target_hangar := -1
## Rolled at setup, used once the contract is known (`resolve_kind`): the
## ExtractionManager arms the crews before ObjectiveManager has the contract.
var _contest_roll := 1.0
var _kind_resolved := false


## A fresh job for crew `p_crew` (`size` members at spawn). `rng` makes the rolls
## deterministic in the deck (ExtractionManager seeds it from the deck seed and
## the squad id); null uses the global RNG.
func setup(p_crew: int, p_squad_id: String, size: int, rng: RandomNumberGenerator = null) -> void:
	crew = p_crew
	squad_id = p_squad_id
	start_size = size
	var r := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		r.randomize()
	loot_goal = r.randi_range(LOOT_GOAL_MIN, LOOT_GOAL_MAX)
	leave_round = r.randi_range(LEAVE_ROUND_MIN, LEAVE_ROUND_MAX)
	_contest_roll = r.randf()


## Settles LOOT vs CONTEST the first time it matters. Idempotent.
func resolve_kind(contract_is_retrieve: bool) -> void:
	if _kind_resolved:
		return
	_kind_resolved = true
	kind = Kind.CONTEST if contract_is_retrieve and _contest_roll < CONTEST_CHANCE else Kind.LOOT


## The contested item is out of reach (a player has it, or it left the deck):
## the crew goes back to plain looting rather than standing around.
func abandon_contest() -> void:
	if kind == Kind.CONTEST:
		kind = Kind.LOOT
		target_tile = NO_TILE


## A member took something from the container at `tile`.
func record_take(tile: Vector3i) -> void:
	looted[tile] = true


## A member stood in `room`. True if the crew had not been there before.
func visit_room(room: int) -> bool:
	if room < 0 or visited_rooms.has(room):
		return false
	visited_rooms[room] = true
	if explore_room == room:
		explore_room = -1
	return true


func has_visited(room: int) -> bool:
	return visited_rooms.has(room)


## Whether the job itself is finished. `holds_objective`: a member carries the
## contested item (only read for CONTEST).
func job_done(holds_objective: bool) -> bool:
	if kind == Kind.CONTEST:
		return holds_objective
	return looted.size() >= loot_goal


## Why the crew should leave now, or "" to keep working. Pure: every input is
## passed in, so the test can walk each trigger on its own.
##   alive       living members (ACTIVE) on the board
##   free_slots  empty pack slots summed over the living members
func leave_reason_for(turn: int, alive: int, free_slots: int, holds_objective: bool) -> String:
	if job_done(holds_objective):
		return "job done"
	if alive > 0 and free_slots <= 0:
		return "packs full"
	if start_size > 0 and float(start_size - alive) >= CASUALTY_FRACTION * start_size:
		return "casualties"
	if turn >= leave_round:
		return "out of time"
	return ""


## Runs the leave decision: WORKING -> EXTRACTING when `leave_reason_for` says
## so. Returns true on the transition (the caller narrates it).
func update(turn: int, alive: int, free_slots: int, holds_objective: bool) -> bool:
	if phase != Phase.WORKING:
		return false
	var why := leave_reason_for(turn, alive, free_slots, holds_objective)
	if why == "":
		return false
	phase = Phase.EXTRACTING
	leave_reason = why
	target_tile = NO_TILE
	explore_room = -1
	return true


## Another crew called a ship in round `turn` (ExtractionManager.ship_called).
func hear_rival_call(turn: int) -> void:
	leave_round = mini(leave_round, turn + HURRY_ROUNDS)


## The crew's ship left with somebody aboard: the run is over.
func depart() -> void:
	phase = Phase.DEPARTED
	target_tile = NO_TILE
	explore_room = -1
	target_hangar = -1


func is_working() -> bool:
	return phase == Phase.WORKING


func is_extracting() -> bool:
	return phase == Phase.EXTRACTING


## Whether a member standing in the square of the crew's landed ship should
## signal dust-off: everyone alive is aboard, or most of them are and the ship has
## waited long enough (DUST_OFF_PATIENCE_ROUNDS).
static func should_dust_off(in_square: int, alive: int, rounds_landed: int) -> bool:
	if in_square <= 0:
		return false
	if in_square >= alive:
		return true
	return in_square * 2 >= alive and rounds_landed >= DUST_OFF_PATIENCE_ROUNDS


func describe() -> String:
	var what := "contest the objective" if kind == Kind.CONTEST else \
		"loot %d/%d containers" % [looted.size(), loot_goal]
	match phase:
		Phase.EXTRACTING:
			return "extracting (%s)" % leave_reason
		Phase.DEPARTED:
			return "departed"
	return "%s, leaves by round %d" % [what, leave_round]
