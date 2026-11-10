extends SceneTree
## Contract checkbox -> saved offer -> solo/co-op deployment -> actual map build.
var failures := 0

func _initialize() -> void:
	await process_frame
	var campaign = root.get_node("Campaign")
	var generator = load("res://scripts/map_generator.gd")
	var offer_script = load("res://scripts/campaign/contract_offer.gd")
	var state_script = load("res://scripts/campaign/campaign_state.gd")
	var coop = load("res://scripts/net/coop_rules.gd")
	_check(generator.Config.new().deck_source == generator.DeckSource.GENERATED, "Procedural maps are the default")
	campaign.use_throwaway("", 912)
	var state = campaign.state
	_check(state.map_gen and state.contracts.size() == 3, "Default board uses procedural maps")
	for offer in state.contracts:
		_check(offer.deck_source == generator.DeckSource.GENERATED and offer.room_count > 0 and offer.hangar_count > 0, "Default offers have playable maps")
	var hub = load("res://scripts/campaign/hub_menu.gd").new()
	root.add_child(hub)
	hub.setup()
	var checkbox = hub.find_child("MapGen", true, false)
	_check(checkbox != null and checkbox.button_pressed and not checkbox.disabled, "Contracts show a checked Map gen checkbox")
	var recruits: Array = state.recruits.duplicate()
	var roster: Array = state.roster.duplicate()
	var credits: int = state.credits
	checkbox.button_pressed = false
	await process_frame
	await process_frame
	_check(not state.map_gen and state.contracts.size() == 3, "Unchecking Map gen refreshes authored contracts")
	_check(state.recruits == recruits and state.roster == roster and state.credits == credits, "Map choice preserves recruits, roster and stock")
	_check(hub._offer_index == -1, "Changing map mode clears the selected contract")
	for offer in state.contracts:
		_check(offer.deck_source == generator.DeckSource.PLOT and offer.size == 0, "Authored board only offers available Small plots")
	var restored = state_script.from_dict(JSON.parse_string(JSON.stringify(state.to_dict())))
	_check(not restored.map_gen and restored.contracts[0].deck_source == generator.DeckSource.PLOT, "Campaign and offer retain map choice through JSON")
	var offer = restored.contracts[0]
	var decoded = offer_script.from_dict(JSON.parse_string(JSON.stringify(offer.to_dict())))
	_check(decoded.deck() == offer.deck(), "Deployment descriptor retains map source")
	var pick: Dictionary = state.make_pick([state.roster[0].id, state.roster[1].id], [0, 0])
	var merged: Dictionary = coop.merge_deployment(["host"], {"host": {"pick": pick}}, offer.to_dict(), 1, "test-map-source")
	_check(merged.deck.deck_source == generator.DeckSource.PLOT, "Co-op deployment uses the host's map choice")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	map.build_deck(decoded.deck())
	_check(map.data.authored_layout and map.data.hangars.size() == 2 and not map.player_spawns.is_empty(), "Unchecked option builds an actual authored map")
	_check(decoded.build_contract(map.data) != null, "Authored offer supports its objective")
	var ids: Array = [state.roster[0].id, state.roster[1].id]
	_check(campaign.launch(ids, 0, [0, 0]) == "", "An authored contract launches successfully")
	_check(campaign.deployment.deck.deck_source == generator.DeckSource.PLOT, "Authored launch retains its map source")
	# End this in-memory launch fixture before testing a second board.
	state.in_mission = {}
	campaign.deployment = {}
	var legacy = offer_script.from_dict({"map_seed": 7})
	_check(legacy.deck_source == generator.DeckSource.GENERATED, "Old offers default to procedural generation")
	var legacy_save: Dictionary = state.to_dict()
	legacy_save.erase("map_gen")
	for item: Dictionary in legacy_save.contracts:
		item.erase("deck_source")
		item.rooms = 0
		item.hangars = 0
	var repaired = state_script.from_dict(legacy_save)
	_check(repaired.map_gen and repaired.contracts.size() == 3 and repaired.contracts[0].hangar_count > 0, "Earlier empty contract boards are repaired")
	_check(repaired.roster.size() == state.roster.size() and repaired.credits == credits, "Repair preserves the campaign")
	checkbox = hub.find_child("MapGen", true, false)
	checkbox.button_pressed = true
	await process_frame
	await process_frame
	_check(state.map_gen and state.contracts[0].deck_source == generator.DeckSource.GENERATED, "Rechecking restores procedural contracts")
	map.build_deck(state.contracts[0].deck())
	_check(not map.data.authored_layout and not map.player_spawns.is_empty() and map.data.hangars.size() >= 3, "Checked option builds the old procedural layout")
	# The launch path validates the map before booking grenades or soldiers.
	_check(campaign.launch(ids, 0, [0, 0]) == "", "A procedural contract launches successfully")
	_check(campaign.deployment.deck.deck_source == generator.DeckSource.GENERATED, "Launch pins the source in the deployment")
	map.queue_free()
	hub.queue_free()
	await process_frame
	campaign.deployment = {}
	campaign.state = null
	print("Contract map source: %d failures" % failures)
	quit(1 if failures else 0)

func _check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		failures += 1
		push_error(message)
