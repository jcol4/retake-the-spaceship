class_name ExtractionRules
extends RefCounted
## The extraction rules (GDD §7.2–7.4), engine-free: hangar discovery, call-in,
## arrival, the landed window, dust-off, departure and cooldown, as plain state
## per hangar. No scene tree, no autoloads, no Unit class — so
## tools/test_extraction.gd drives every timer directly, the same way MapData and
## Combat are tested. ExtractionManager is the thin node wrapper that feeds it
## turn numbers and board positions and turns its answers into noise, ships, RPCs
## and the end of the mission.
##
## Per hangar:
##
##     UNDISCOVERED -> DISCOVERED -> CALLED -> LANDED -> COOLDOWN -> DISCOVERED
##                                   (arrive)  (depart_by,  (ready)
##                                              dust_off)
##
## plus `claimed_by`, the crew holding it from the call until its ship leaves.
##
## "Round" is TurnManager.turn_number (the GDD's round; the code's turn), and
## every countdown here is a comparison against it rather than a counter that
## ticks — so a missed tick cannot drift a clock, and a client mirroring the
## state needs only the target round, not a history.

enum State { UNDISCOVERED, DISCOVERED, CALLED, LANDED, COOLDOWN }

## Crew ids. A crew is one ship's worth of contractors: everyone it lifts out
## leaves together, and one crew holds at most one claim. The player squad —
## BOTH co-op players' soldiers (GDD §7.6) — is crew 0. Rival merc squads
## (extraction plan Phase 8) take ids from MERC_CREW_BASE up, one per squad.
const PLAYER_CREW := 0
const MERC_CREW_BASE := 1
const NO_CREW := -1

## GDD §7.3: the ship lands 3 rounds after the call, at the start of that round.
const ARRIVAL_ROUNDS := 3
## GDD §7.4: once down it waits up to 5 rounds — the round it lands in plus four
## more — and leaves at the end of the last one if nobody signals sooner.
const LANDED_ROUNDS := 5
## GDD §7.4: an empty-square departure leaves the hangar unusable for 5 rounds.
const COOLDOWN_ROUNDS := 5
## GDD §5.4/§7.3: a call-in is the loudest event in the game.
const CALL_NOISE_RADIUS := 15

## Mirrors Unit.LifeState.DEAD. Spelled out rather than read off Unit because
## this file must not depend on anything that touches an autoload (Unit does);
## test_extraction.gd asserts the two agree, so they cannot drift silently.
const LIFE_DEAD := 2


class HangarState:
	var state: int = State.UNDISCOVERED
	## The PLAYER crew's knowledge, kept apart from `state` on purpose. A merc
	## crew (Phase 8) may call a hangar the player has never seen; that call must
	## not reveal it (GDD §7.3), and when its ship leaves the hangar must go back
	## to whichever of UNDISCOVERED/DISCOVERED the player actually knows. The
	## UNDISCOVERED/DISCOVERED states are therefore just the idle state as the
	## player sees it.
	var discovered := false
	## Every OTHER crew's knowledge (Phase 8): crew id -> true once one of its
	## members has entered the hangar room. Merc crews discover hangars the same
	## way the player does and may only call one they know. Host-only: the AI
	## that reads it runs on the host, so it is not in the snapshot.
	var known_by: Dictionary = {}
	var claimed_by: int = NO_CREW
	## The crew whose ship last left this hangar (Phase 8). `claimed_by` is
	## already cleared when the departure is presented, and the presentation has
	## to know whose ship it was: the player's lift hides the squad, a rival's
	## must not, and a rival's at a hangar the player never found must not name
	## it. Rides in the snapshot so a client presents it the same way.
	var last_crew: int = NO_CREW
	var arrive_round := -1
	var depart_by_round := -1
	var ready_round := -1
	var dust_off_requested := false
	## Who has already walked up the ramp (GDD §7.4 "Board"): units of the
	## claiming crew, off the board and safe, who leave with this ship whenever it
	## goes — on the crew's Extract, or when the window runs out. Untyped (no Unit
	## here). Host-only: clients are told who boarded by ExtractionManager's RPC,
	## and only the host's departure reads this.
	var aboard: Array = []


## MapData.Hangar, parallel to `states`. Untyped (MapData is engine-free, but
## keeping this file's dependencies to zero costs nothing): only `bay_cells`,
## `square`, `room_index` and `is_insertion` are read.
var hangars: Array = []
var states: Array[HangarState] = []
## Crews whose run is over: their ship left with somebody aboard (Phase 8).
## "One lift ends that crew's run" (GDD §7.4) — for the player crew the mission
## ends with it; a merc crew's left-behind members are stranded and may never
## call again. Host-only, like `known_by`.
var retired_crews: Dictionary = {}


## Fresh state for a deck's hangars. The insertion hangar starts discovered
## (GDD §7.2: it is the one hangar known at mission start).
func setup(p_hangars: Array) -> void:
	hangars = p_hangars.duplicate()
	states.clear()
	retired_crews.clear()
	for h in hangars:
		var s := HangarState.new()
		if h.is_insertion:
			s.discovered = true
			s.state = State.DISCOVERED
		states.append(s)


func hangar_count() -> int:
	return hangars.size()


func state_of(index: int) -> int:
	return states[index].state


func is_valid(index: int) -> bool:
	return index >= 0 and index < states.size()


# --- Lookup ------------------------------------------------------------------


## The hangar whose bay holds `grid_pos`, or -1.
func hangar_at_bay(grid_pos: Vector3i) -> int:
	for i in hangars.size():
		if hangars[i].bay_cells.has(grid_pos):
			return i
	return -1


## The hangar whose extraction square holds `grid_pos`, or -1.
func hangar_at_square(grid_pos: Vector3i) -> int:
	for i in hangars.size():
		if hangars[i].square.has(grid_pos):
			return i
	return -1


## The hangar `crew` currently holds (CALLED or LANDED), or -1. One at most: the
## squad cannot split across two ships (GDD §7.4), so a crew with a ship coming
## may not call a second one.
func claim_of(crew: int) -> int:
	for i in states.size():
		var s := states[i]
		if s.claimed_by == crew and (s.state == State.CALLED or s.state == State.LANDED):
			return i
	return -1


# --- Discovery ----------------------------------------------------------------


## A player soldier is standing in compartment `room_index`. If that is a
## hangar's bay, the whole squad now knows it (GDD §7.2: discovery is shared).
## Returns the hangar index if this DISCOVERED it, else -1 (already known, or not
## a hangar at all).
func discover_room(room_index: int) -> int:
	if room_index < 0:
		return -1
	for i in hangars.size():
		if hangars[i].room_index == room_index:
			return i if discover(i) else -1
	return -1


## Marks hangar `index` known to the player. True if it was not already.
func discover(index: int) -> bool:
	var s := states[index]
	if s.discovered:
		return false
	s.discovered = true
	# Only the idle state is "how the player sees it"; a hangar mid-call by
	# another crew stays CALLED/LANDED — knowing about it changes nothing there.
	if s.state == State.UNDISCOVERED:
		s.state = State.DISCOVERED
	return true


func is_discovered(index: int) -> bool:
	return states[index].discovered


## Crew `crew` has a member in compartment `room_index`: the per-crew
## `discover_room`. The player crew goes through `discover_room` itself (it
## changes the visible state); any other crew only learns it. Returns the hangar
## index if this taught the crew a new hangar, else -1.
func discover_room_for(room_index: int, crew: int) -> int:
	if crew == PLAYER_CREW:
		return discover_room(room_index)
	if room_index < 0 or crew == NO_CREW:
		return -1
	for i in hangars.size():
		if hangars[i].room_index == room_index:
			if states[i].known_by.has(crew):
				return -1
			states[i].known_by[crew] = true
			return i
	return -1


## Whether `crew` knows hangar `index` (GDD §7.2: by having entered its room).
## The player crew's answer is `discovered`.
func crew_knows(index: int, crew: int) -> bool:
	if not is_valid(index):
		return false
	if crew == PLAYER_CREW:
		return states[index].discovered
	return states[index].known_by.has(crew)


## Every hangar `crew` knows, in deck order.
func known_hangars(crew: int) -> Array[int]:
	var out: Array[int] = []
	for i in states.size():
		if crew_knows(i, crew):
			out.append(i)
	return out


func is_retired(crew: int) -> bool:
	return retired_crews.has(crew)


# --- Call-in (GDD §7.3) --------------------------------------------------------


## Why `crew` cannot call the ship to hangar `index` right now, or "" if it can.
## A string rather than a bool so the HUD and the log can say WHY, and so every
## rule lives in one place for both `can_call` and `call_ship`.
##
## Requirements:
##   - the crew must know it: the player crew by discovery, a merc crew by one of
##     its own members having entered the room (Phase 8 — this replaces the
##     plan's A11 "mercs know every hangar"; see the decision log);
##   - the crew's run is not over (one lift per crew);
##   - it is idle: not already called, landed or cooling down;
##   - it is unclaimed (first call claims it — a merc claim blocks the player);
##   - the crew holds no other claim (one lift per mission).
func call_blocker(index: int, crew: int) -> String:
	if not is_valid(index):
		return "no hangar"
	var s := states[index]
	if not crew_knows(index, crew):
		return "hangar not discovered"
	if is_retired(crew):
		return "this crew has already flown out"
	if s.claimed_by != NO_CREW and s.claimed_by != crew:
		return "another crew has claimed this hangar"
	match s.state:
		State.CALLED:
			return "a ship is already inbound"
		State.LANDED:
			return "a ship is already down"
		State.COOLDOWN:
			return "the pad is cooling down"
	if claim_of(crew) >= 0:
		return "your ship is already called elsewhere"
	return ""


func can_call(index: int, crew: int) -> bool:
	return call_blocker(index, crew) == ""


## The hangar a soldier of `crew` standing at `grid_pos` could call to — any
## bay cell counts, there is no console to reach (GDD §7.3) — or -1.
func callable_from(grid_pos: Vector3i, crew: int) -> int:
	var index := hangar_at_bay(grid_pos)
	return index if index >= 0 and can_call(index, crew) else -1


## Calls the ship to hangar `index` for `crew` during round `turn`. It lands at
## the start of round `turn + ARRIVAL_ROUNDS`. The countdown cannot be cancelled
## (GDD §7.3). False, with nothing changed, if `call_blocker` objects.
func call_ship(index: int, crew: int, turn: int) -> bool:
	if not can_call(index, crew):
		return false
	var s := states[index]
	s.state = State.CALLED
	s.claimed_by = crew
	s.arrive_round = turn + ARRIVAL_ROUNDS
	s.depart_by_round = -1
	s.ready_round = -1
	s.dust_off_requested = false
	return true


# --- Round start: landings and cooldowns ----------------------------------------


## Advances every hangar to round `turn` (call at turn start). Returns the
## indices whose state changed, so the wrapper knows which ships to animate and
## which hangars to re-broadcast.
##
##   CALLED   -> LANDED     when `turn >= arrive_round`; the window then runs to
##                         `depart_by_round = turn + LANDED_ROUNDS`.
##   COOLDOWN -> idle      when `turn >= ready_round`.
##
## `>=` rather than `==` so a round skipped by anything (a test jumping ahead, a
## client catching up) still lands the ship instead of stranding it CALLED.
func start_round(turn: int) -> Array[int]:
	var changed: Array[int] = []
	for i in states.size():
		var s := states[i]
		if s.state == State.CALLED and turn >= s.arrive_round:
			s.state = State.LANDED
			s.depart_by_round = turn + LANDED_ROUNDS
			changed.append(i)
		elif s.state == State.COOLDOWN and turn >= s.ready_round:
			s.state = _idle_state(s)
			s.ready_round = -1
			changed.append(i)
	return changed


# --- Dust-off (GDD §7.4) --------------------------------------------------------


## Why a soldier of `crew` at `grid_pos` cannot signal dust-off, or "". They must
## be IN THE SQUARE of a hangar where their own crew's ship is down. Signalling
## twice is refused, so the HUD can hide the button once it has been pressed.
func dust_off_blocker(grid_pos: Vector3i, crew: int) -> String:
	var index := hangar_at_square(grid_pos)
	if index < 0:
		return "not in an extraction square"
	var s := states[index]
	if s.state != State.LANDED or s.claimed_by != crew:
		return "no ship of yours is down here"
	if s.dust_off_requested:
		return "dust-off already signalled"
	return ""


## Why a unit of `crew` at `grid_pos` cannot BOARD (walk up the ramp and out of
## the fight), or "". Same place as dust-off: in the square of a hangar where the
## crew's own ship is down. Boarding never ends the mission by itself — Extract
## does (`extract_blocker`) — so a soldier can get the wounded aboard while
## another still holds the bay.
func board_blocker(grid_pos: Vector3i, crew: int) -> String:
	var index := hangar_at_square(grid_pos)
	if index < 0:
		return "not in an extraction square"
	var s := states[index]
	if s.state != State.LANDED or s.claimed_by != crew:
		return "no ship of yours is down here"
	return ""


## Records `units` as aboard hangar `index`'s ship. The caller has checked
## `board_blocker` and takes them off the board.
func board(index: int, units: Array) -> void:
	for unit in units:
		if unit != null and not states[index].aboard.has(unit):
			states[index].aboard.append(unit)


## Everyone aboard the ship crew `crew` has down, or [].
func aboard_for(crew: int) -> Array:
	var index := claim_of(crew)
	return states[index].aboard.duplicate() if index >= 0 else []


## Why crew `crew` cannot EXTRACT now, or "" (GDD §7.4). The crew's OWN ship must
## be down — so a squad can never leave on a rival's ship — and at least one of
## its people must be aboard it or standing (or lying) alive in its square:
## `candidates` are the crew's units still on the board (anything with `grid_pos`
## and `life_state`). Who is asking, and where they stand, does not matter: any
## soldier of the crew may give the word on their own activation, in the square
## or not, and the ones outside it are left behind.
func extract_blocker(crew: int, candidates: Array) -> String:
	var index := claim_of(crew)
	if index < 0 or states[index].state != State.LANDED:
		return "no ship of yours is down"
	if not states[index].aboard.is_empty():
		return ""
	var square: Array = hangars[index].square
	for unit in candidates:
		if unit != null and square.has(unit.grid_pos) and unit.life_state != LIFE_DEAD:
			return ""
	return "nobody is aboard or in the square"


## The hangar a soldier at `grid_pos` could signal dust-off at, or -1.
func dust_off_from(grid_pos: Vector3i, crew: int) -> int:
	return hangar_at_square(grid_pos) if dust_off_blocker(grid_pos, crew) == "" else -1


## Signals departure: the ship leaves at the END of this round (resolved by
## `departures_due` from the turn-end hook), not now, so every unit still in the
## pool gets one last activation to get in.
func request_dust_off(grid_pos: Vector3i, crew: int) -> int:
	var index := dust_off_from(grid_pos, crew)
	if index >= 0:
		states[index].dust_off_requested = true
	return index


# --- Departure -------------------------------------------------------------------


## Landed hangars whose ship leaves at the end of round `turn`: dust-off was
## signalled, or the window is up. The window is LANDED_ROUNDS full rounds on
## the ground, landing round included, so the last one is `depart_by_round - 1`.
func departures_due(turn: int) -> Array[int]:
	var out: Array[int] = []
	for i in states.size():
		var s := states[i]
		if s.state != State.LANDED:
			continue
		if s.dust_off_requested or turn >= s.depart_by_round - 1:
			out.append(i)
	return out


## Who leaves on hangar `index`'s ship, from `candidates` (the crew's soldiers on
## the board: anything with `grid_pos` and `life_state`). Returns
## `{"extracted": [...], "lost": [...]}`:
##
##   extracted  everyone already ABOARD (`board`), then every candidate standing
##              in the square who is not DEAD — a downed soldier lying in the
##              square is carried aboard by the crew — plus whatever each of them
##              is carrying, per `riders_of`;
##   lost       every other candidate, dead or alive (GDD §7.4: left behind and
##              permanently lost). A candidate who rides out on someone else is
##              extracted, not lost, even though they are not in the square.
##
## `riders_of(unit) -> Array` is the carried-bodies seam: extraction plan Phase 2
## passes ExtractionManager.riders_of, which returns the body a soldier carries.
## Omitted, nobody carries anyone.
##
## Ownership is never consulted: in co-op both players' soldiers are one crew
## (GDD §7.6), and either player's soldier counts in the square.
func split_passengers(index: int, candidates: Array, riders_of: Callable = Callable()) -> Dictionary:
	var square: Array = hangars[index].square
	var extracted: Array = []
	# Already aboard (`board`): they go whatever the square holds, and so does
	# anything they carried up the ramp.
	for unit in states[index].aboard:
		if unit == null or extracted.has(unit):
			continue
		extracted.append(unit)
		if riders_of.is_valid():
			for rider in riders_of.call(unit):
				if rider != null and not extracted.has(rider):
					extracted.append(rider)
	for unit in candidates:
		if unit == null or not square.has(unit.grid_pos) or unit.life_state == LIFE_DEAD:
			continue
		if not extracted.has(unit):
			extracted.append(unit)
		if riders_of.is_valid():
			for rider in riders_of.call(unit):
				if rider != null and not extracted.has(rider):
					extracted.append(rider)
	var lost: Array = []
	for unit in candidates:
		if unit != null and not extracted.has(unit):
			lost.append(unit)
	return {"extracted": extracted, "lost": lost}


## The ship at hangar `index` has left at the end of round `turn`, with
## passengers aboard or not.
##
## With passengers the claim simply clears and the pad goes idle — for the player
## crew the mission is over anyway, and for a merc crew (Phase 8) the hangar is
## free again for whoever is left. EMPTY, the pad goes to COOLDOWN until round
## `turn + COOLDOWN_ROUNDS` and the claim clears with it (GDD §7.4: "can be called
## again after a 5-round cooldown").
func resolve_departure(index: int, turn: int, boarded: bool) -> void:
	var s := states[index]
	s.last_crew = s.claimed_by
	if boarded and s.claimed_by != NO_CREW:
		retired_crews[s.claimed_by] = true
	s.claimed_by = NO_CREW
	s.arrive_round = -1
	s.depart_by_round = -1
	s.dust_off_requested = false
	s.aboard.clear()
	if boarded:
		s.state = _idle_state(s)
		s.ready_round = -1
	else:
		s.state = State.COOLDOWN
		s.ready_round = turn + COOLDOWN_ROUNDS


func _idle_state(s: HangarState) -> int:
	return State.DISCOVERED if s.discovered else State.UNDISCOVERED


# --- Countdowns (HUD) --------------------------------------------------------------


## Rounds from round `turn` until the ship lands (it lands at the START of the
## round this reaches 0 at). Only meaningful while CALLED.
func rounds_until_arrival(index: int, turn: int) -> int:
	return maxi(0, states[index].arrive_round - turn)


## Rounds AFTER round `turn` the ship will still be on the ground; 0 means it
## leaves at the end of this round (always 0 once dust-off is signalled). Only
## meaningful while LANDED.
func rounds_until_departure(index: int, turn: int) -> int:
	var s := states[index]
	if s.dust_off_requested:
		return 0
	return maxi(0, s.depart_by_round - 1 - turn)


## Rounds from round `turn` until a cooling pad can be called again.
func rounds_until_ready(index: int, turn: int) -> int:
	return maxi(0, states[index].ready_round - turn)


# --- Wire form ----------------------------------------------------------------------


## Everything a client needs to mirror hangar `index`, as RPC-safe values:
## [state, claimed_by, round, dust_off_requested, discovered, last_crew], where
## `round` is whichever target round the state counts toward (arrive /
## depart_by / ready). `known_by` and `retired_crews` stay on the host: only its
## AI reads them.
func snapshot(index: int) -> Array:
	var s := states[index]
	var target := -1
	match s.state:
		State.CALLED: target = s.arrive_round
		State.LANDED: target = s.depart_by_round
		State.COOLDOWN: target = s.ready_round
	return [s.state, s.claimed_by, target, s.dust_off_requested, s.discovered, s.last_crew]


func apply_snapshot(index: int, snap: Array) -> void:
	var s := states[index]
	s.state = snap[0]
	s.claimed_by = snap[1]
	s.arrive_round = snap[2] if s.state == State.CALLED else -1
	s.depart_by_round = snap[2] if s.state == State.LANDED else -1
	s.ready_round = snap[2] if s.state == State.COOLDOWN else -1
	s.dust_off_requested = snap[3]
	s.discovered = snap[4]
	s.last_crew = snap[5] if snap.size() > 5 else NO_CREW
