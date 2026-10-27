extends SceneTree
## Extraction plan Phase 1: the ship's rules (GDD §7.2–7.4, §7.6), driven through
## ExtractionRules directly — no scene, no turn loop, no autoloads — on the real
## hangar geometry of maps/extraction_test.txt.
##
##   godot --headless --path . --script res://tools/test_extraction.gd
##
## Covers: the 3-round arrival, the 5-round window and the 5-round cooldown;
## dust-off resolving at round end rather than at once; square membership
## deciding extracted vs lost; an empty departure cooling the pad down while the
## mission carries on; a claimed hangar refusing another crew; discovery on room
## entry; and the co-op case — two players' soldiers on one ship.
##
## Scripts are load()ed and the soldiers are stand-ins: a --script tool is
## compiled before the autoloads exist, and Unit touches them. ExtractionRules
## reads only `grid_pos` and `life_state` off a soldier, so a stand-in carrying
## those two (plus `owner_peer_id`, which the rules must IGNORE) is the whole
## contract.

const DECK := "res://maps/extraction_test.txt"

var _failures := 0
var _rules_script
var _data
var R  # ExtractionRules script, for its constants and enum
var LIFE  # Unit.LifeState


## A soldier as far as the rules can see one.
class Soldier:
	var name: String
	var grid_pos: Vector3i
	var life_state: int
	var owner_peer_id: int

	func _init(p_name: String, pos: Vector3i, life: int = 0, owner: int = 0) -> void:
		name = p_name
		grid_pos = pos
		life_state = life
		owner_peer_id = owner


func _initialize() -> void:
	_rules_script = load("res://scripts/extraction_rules.gd")
	R = _rules_script
	LIFE = load("res://scripts/unit.gd").LifeState
	_data = load("res://scripts/map_ascii.gd").load_file(DECK)
	_check(_data.hangars.size() == 2, "the test deck has two hangars (got %d)" % _data.hangars.size())
	if _data.hangars.size() == 2:
		_check_constants()
		_check_discovery()
		_check_arrival_and_window()
		_check_dust_off_at_round_end()
		_check_square_membership()
		_check_empty_departure_cooldown()
		_check_claims()
		_check_coop_cross_owner()
		_check_riders_seam()
		_check_snapshot_round_trip()

	print("")
	if _failures == 0:
		print("extraction: ALL CHECKS PASSED")
		quit(0)
	else:
		print("extraction: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _fresh():
	var rules = _rules_script.new()
	rules.setup(_data.hangars)
	return rules


# Hangar 0 is A, the insertion hangar (west, ramp east); 1 is B (east, ramp west).
const A := 0
const B := 1
const A_SQUARE_CENTRE := Vector3i(7, 0, 6)
const B_SQUARE_CENTRE := Vector3i(32, 0, 6)
## In B's bay but well clear of its square.
const B_BAY_CORNER := Vector3i(29, 0, 2)
## The corridor between the hangars: in no bay.
const CORRIDOR := Vector3i(20, 0, 5)


func _check_constants() -> void:
	print("-- constants")
	_check(R.ARRIVAL_ROUNDS == 3, "arrival is 3 rounds (GDD §7.3)")
	_check(R.LANDED_ROUNDS == 5, "the ship waits 5 rounds (GDD §7.4)")
	_check(R.COOLDOWN_ROUNDS == 5, "an empty departure cools the pad 5 rounds (GDD §7.4)")
	_check(R.CALL_NOISE_RADIUS == 15, "a call-in is a 15-tile noise (GDD §5.4)")
	# The rules mirror Unit.LifeState.DEAD as a literal so they stay engine-free;
	# this is what stops the two drifting apart.
	_check(R.LIFE_DEAD == LIFE.DEAD, "ExtractionRules.LIFE_DEAD matches Unit.LifeState.DEAD")


func _check_discovery() -> void:
	print("-- discovery on room entry")
	var rules = _fresh()
	_check(rules.is_discovered(A) and rules.state_of(A) == R.State.DISCOVERED,
		"the insertion hangar starts discovered")
	_check(not rules.is_discovered(B) and rules.state_of(B) == R.State.UNDISCOVERED,
		"every other hangar starts undiscovered")
	_check(rules.callable_from(B_BAY_CORNER, R.PLAYER_CREW) == -1,
		"an undiscovered hangar cannot be called, even standing in it")
	_check(rules.discover_room(_data.room_index_at(CORRIDOR)) == -1,
		"walking into the corridor discovers nothing")
	_check(rules.discover_room(_data.room_index_at(B_BAY_CORNER)) == B,
		"entering B's bay discovers B")
	_check(rules.is_discovered(B) and rules.state_of(B) == R.State.DISCOVERED, "B is now DISCOVERED")
	_check(rules.discover_room(_data.room_index_at(B_SQUARE_CENTRE)) == -1,
		"re-entering a known hangar reports nothing new")
	_check(rules.callable_from(B_BAY_CORNER, R.PLAYER_CREW) == B,
		"and it can now be called from anywhere in the bay, not just the square")


func _check_arrival_and_window() -> void:
	print("-- 3-round arrival, 5-round window")
	var rules = _fresh()
	_check(rules.call_ship(A, R.PLAYER_CREW, 4), "call at round 4")
	_check(rules.state_of(A) == R.State.CALLED, "the hangar is CALLED")
	_check(rules.rounds_until_arrival(A, 4) == 3, "'Ship in 3' on the call round")
	_check(rules.start_round(5).is_empty() and rules.start_round(6).is_empty(),
		"nothing lands at the start of rounds 5 or 6")
	_check(rules.start_round(7) == [A], "it lands at the start of round 7 (call + 3)")
	_check(rules.state_of(A) == R.State.LANDED, "the hangar is LANDED")
	var due := []
	for turn in range(7, 11):
		due.append_array(rules.departures_due(turn))
	_check(due.is_empty(), "it does not leave at the end of rounds 7-10")
	_check(rules.rounds_until_departure(A, 7) == 4, "'Departs in 4' on the landing round")
	_check(rules.departures_due(11) == [A],
		"it leaves at the end of round 11: five full rounds on the ground (7-11)")
	_check(rules.rounds_until_departure(A, 11) == 0, "'Departs this round' on the last one")


func _check_dust_off_at_round_end() -> void:
	print("-- dust-off resolves at round end")
	var rules = _landed_at_a(1)  # lands at the start of round 4
	_check(rules.request_dust_off(A_SQUARE_CENTRE + Vector3i(0, 0, 2), R.PLAYER_CREW) == -1,
		"dust-off is refused from outside the square")
	_check(rules.dust_off_from(Vector3i(2, 0, 2), R.PLAYER_CREW) == -1,
		"…including from elsewhere in the bay")
	_check(rules.request_dust_off(A_SQUARE_CENTRE, 7) == -1,
		"another crew cannot signal our ship's dust-off")
	_check(rules.request_dust_off(A_SQUARE_CENTRE, R.PLAYER_CREW) == A,
		"a soldier in the square signals dust-off on round 4")
	_check(rules.state_of(A) == R.State.LANDED,
		"the ship has NOT left yet — everyone still in the pool gets an activation")
	_check(rules.departures_due(4) == [A], "it is due out at the end of that same round")
	_check(rules.dust_off_from(A_SQUARE_CENTRE, R.PLAYER_CREW) == -1,
		"dust-off cannot be signalled twice")


func _check_square_membership() -> void:
	print("-- square membership decides extracted vs lost")
	var rules = _landed_at_a(1)
	var in_square := Soldier.new("Reyes", A_SQUARE_CENTRE)
	var corner := Soldier.new("Okafor", A_SQUARE_CENTRE + Vector3i(1, 0, 1))  # still in the 3x3
	var downed_in := Soldier.new("Lindqvist", A_SQUARE_CENTRE + Vector3i(-1, 0, -1), LIFE.DOWNED)
	var dead_in := Soldier.new("Vance", A_SQUARE_CENTRE + Vector3i(1, 0, -1), LIFE.DEAD)
	var just_outside := Soldier.new("Park", A_SQUARE_CENTRE + Vector3i(2, 0, 0))  # one tile off
	var far := Soldier.new("Ito", B_SQUARE_CENTRE)
	var split: Dictionary = rules.split_passengers(A, [in_square, corner, downed_in, dead_in, just_outside, far])
	var out: Array = split["extracted"]
	var lost: Array = split["lost"]
	_check(out.has(in_square) and out.has(corner), "soldiers in the square extract, edge tiles included")
	_check(out.has(downed_in), "a downed soldier lying in the square is carried aboard")
	_check(lost.has(dead_in), "a dead soldier in the square is not (life_state DEAD)")
	_check(lost.has(just_outside), "one tile outside the square is left behind")
	_check(lost.has(far), "a soldier at the other hangar is left behind")
	_check(out.size() == 3 and lost.size() == 3, "3 out, 3 lost (got %d, %d)" % [out.size(), lost.size()])


func _check_empty_departure_cooldown() -> void:
	print("-- empty departure: cooldown, and the mission continues")
	var rules = _landed_at_a(1)  # lands round 4, window ends round 8
	_check(rules.departures_due(8) == [A], "the window runs out at the end of round 8")
	var split: Dictionary = rules.split_passengers(A, [Soldier.new("Reyes", B_SQUARE_CENTRE)])
	_check(split["extracted"].is_empty(), "nobody is in the square — nothing to end the mission with")
	rules.resolve_departure(A, 8, false)
	_check(rules.state_of(A) == R.State.COOLDOWN, "the pad goes to COOLDOWN")
	_check(rules.states[A].claimed_by == R.NO_CREW, "and the claim is released")
	_check(rules.claim_of(R.PLAYER_CREW) == -1, "the crew holds no ship any more")
	_check(not rules.can_call(A, R.PLAYER_CREW), "it cannot be called while cooling down")
	_check(rules.rounds_until_ready(A, 8) == 5, "'Cooldown 5' on the departure round")
	for turn in range(9, 13):
		rules.start_round(turn)
	_check(rules.state_of(A) == R.State.COOLDOWN, "still cooling at round 12")
	_check(rules.start_round(13) == [A], "ready again at the start of round 13 (departure + 5)")
	_check(rules.state_of(A) == R.State.DISCOVERED and rules.can_call(A, R.PLAYER_CREW),
		"and callable again")
	# A departure WITH passengers frees the pad without a cooldown (Phase 8 mercs
	# leave the hangar usable; for the player the mission is over anyway).
	var other = _landed_at_a(1)
	other.resolve_departure(A, 8, true)
	_check(other.state_of(A) == R.State.DISCOVERED, "a departure with passengers leaves the pad idle, not cooling")


func _check_claims() -> void:
	print("-- claims")
	var rules = _fresh()
	rules.discover(B)
	var merc_crew: int = R.MERC_CREW_BASE
	# Phase 8: a merc crew calls only hangars it has walked into (replaces A11).
	_check(rules.call_blocker(A, merc_crew) == "hangar not discovered",
		"a merc crew cannot call a hangar it has not found")
	_check(rules.discover_room_for(rules.hangars[A].room_index, merc_crew) == A,
		"a merc entering A's room learns A")
	_check(rules.call_ship(A, merc_crew, 2), "a merc crew calls hangar A first")
	_check(rules.call_blocker(A, R.PLAYER_CREW) == "another crew has claimed this hangar",
		"the player's call on A is refused: first call claims it")
	_check(not rules.call_ship(A, R.PLAYER_CREW, 2), "and call_ship changes nothing")
	_check(rules.states[A].claimed_by == merc_crew, "A is still the mercs'")
	_check(rules.call_ship(B, R.PLAYER_CREW, 2), "the player can still call B")
	_check(rules.call_blocker(A, R.PLAYER_CREW) != "" and rules.claim_of(R.PLAYER_CREW) == B,
		"the player crew holds exactly one claim")
	# One lift per mission: no second ship while ours is inbound.
	var solo = _fresh()
	solo.discover(B)
	solo.call_ship(A, R.PLAYER_CREW, 1)
	_check(solo.call_blocker(B, R.PLAYER_CREW) == "your ship is already called elsewhere",
		"a crew with a ship inbound cannot call a second hangar")
	_check(solo.call_blocker(A, R.PLAYER_CREW) == "a ship is already inbound",
		"nor call the same one twice")
	# Another crew's call never reveals a hangar (GDD §7.3).
	var quiet = _fresh()
	quiet.discover_room_for(quiet.hangars[B].room_index, merc_crew)
	quiet.call_ship(B, merc_crew, 1)
	_check(not quiet.is_discovered(B) and quiet.state_of(B) == R.State.CALLED,
		"a merc call on an undiscovered hangar leaves it undiscovered to the player")
	quiet.start_round(4)
	quiet.resolve_departure(B, 8, true)
	_check(quiet.state_of(B) == R.State.UNDISCOVERED, "and after their ship leaves it is still unknown")


func _check_coop_cross_owner() -> void:
	print("-- co-op: two players, one crew, one ship")
	var rules = _fresh()
	# Host's soldier (peer 1) calls; the client's (peer 2) is in the square too.
	_check(rules.call_ship(A, R.PLAYER_CREW, 1), "player 1's soldier calls (crew 0)")
	rules.start_round(4)
	var host_soldier := Soldier.new("Reyes", A_SQUARE_CENTRE, LIFE.ACTIVE, 1)
	var client_soldier := Soldier.new("Okafor", A_SQUARE_CENTRE + Vector3i(0, 0, 1), LIFE.ACTIVE, 2)
	var client_straggler := Soldier.new("Lindqvist", CORRIDOR, LIFE.ACTIVE, 2)
	_check(rules.request_dust_off(client_soldier.grid_pos, R.PLAYER_CREW) == A,
		"player 2's soldier may signal dust-off on the ship player 1 called")
	var split: Dictionary = rules.split_passengers(A, [host_soldier, client_soldier, client_straggler])
	_check(split["extracted"].has(host_soldier) and split["extracted"].has(client_soldier),
		"soldiers of BOTH owners extract on the one ship")
	_check(split["lost"] == [client_straggler], "ownership changes nothing about who is left behind")


func _check_riders_seam() -> void:
	print("-- carried bodies seam (Phase 2)")
	var rules = _landed_at_a(1)
	var carrier := Soldier.new("Reyes", A_SQUARE_CENTRE)
	# A carried body shares its carrier's tile in Phase 2; placed elsewhere here to
	# prove it is the carry, not the position, that takes it aboard.
	var body := Soldier.new("Okafor", CORRIDOR, LIFE.DEAD)
	var riders := func(unit) -> Array: return [body] if unit == carrier else []
	var split: Dictionary = rules.split_passengers(A, [carrier, body], riders)
	_check(split["extracted"].has(body) and not split["lost"].has(body),
		"whatever a soldier in the square carries extracts with them, even a corpse")


func _check_snapshot_round_trip() -> void:
	print("-- client mirror (snapshot)")
	var host = _landed_at_a(1)
	host.request_dust_off(A_SQUARE_CENTRE, R.PLAYER_CREW)
	host.discover(B)
	var client = _fresh()
	for i in 2:
		client.apply_snapshot(i, host.snapshot(i))
	_check(client.state_of(A) == R.State.LANDED and client.states[A].dust_off_requested,
		"a client mirrors LANDED + dust-off")
	_check(client.rounds_until_departure(A, 4) == host.rounds_until_departure(A, 4),
		"and derives the same countdown")
	_check(client.is_discovered(B), "and the discovery")
	var bytes := var_to_bytes(host.snapshot(A))
	_check(bytes_to_var(bytes) == host.snapshot(A), "a snapshot survives RPC encoding")


## Rules with hangar A called on `call_turn` and already landed (call + 3).
func _landed_at_a(call_turn: int):
	var rules = _fresh()
	rules.call_ship(A, R.PLAYER_CREW, call_turn)
	rules.start_round(call_turn + R.ARRIVAL_ROUNDS)
	return rules


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
