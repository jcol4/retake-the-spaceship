class_name ContractOffer
extends RefCounted
## One contract on the hub's board (extraction plan 4.2): its type, the deck it is
## on, and what it pays — before the deck exists. The mission builds the deck from
## `map_seed` + `size` and places the objective with `contract_seed`
## (`build_contract`), so an offer is a few ints that save to JSON and cross the
## wire, and every co-op peer that holds it builds the same mission.
##
## WHY AN OFFER AND NOT A Contract: a Contract's placement (`target_tile`, the
## Retrieve crate, the nest tile) is a property of a generated deck, and the board
## shows three of them. Generating each deck once at offer time is cheap (~30–150
## ms, MapGenerator) and is done, to check the type fits and count the hangars for
## the board — but the deck itself is not kept; the mission regenerates it.
##
## Phase 6 added Hold-terminal and Recover (Contract.Type, BASE_PAYOUT and
## OFFERED_TYPES). Phase 8 (merc presence) can ride here as another saved field.

## The types the board offers. Contract.supported_types still has the last word
## per deck (`generate` falls back to one the deck supports).
const OFFERED_TYPES: Array[int] = [
	Contract.Type.RETRIEVE, Contract.Type.DESTROY, Contract.Type.HOLD, Contract.Type.RECOVER,
]
## Seeds tried before an offer gives up on its type and takes what the deck has.
const SEED_ATTEMPTS := 6

var type: int = Contract.Type.RETRIEVE
var size: int = CampaignEconomy.DeckSize.MEDIUM
var map_seed: int = 0
var contract_seed: int = 0
var payout: int = 0
## For the board only: what the generated deck turned out to have.
var hangar_count: int = 0
var room_count: int = 0
## -1 preserves seed-rolled profiles for offers saved before themed rooms.
var primary: int = -1
var secondary: int = -1


## A fresh offer off the campaign's RNG. Seeds are 31-bit so they survive JSON
## (a double holds them exactly) and an int RPC argument unchanged.
static func generate(rng: RandomNumberGenerator) -> ContractOffer:
	var o := ContractOffer.new()
	o.type = OFFERED_TYPES[rng.randi_range(0, OFFERED_TYPES.size() - 1)]
	o.size = _weighted(CampaignEconomy.DECK_SIZE_WEIGHTS, rng)
	if o.size != CampaignEconomy.DeckSize.SMALL:
		var weights: Dictionary = DeckLayout.PRIMARY_ODDS.duplicate()
		var preferred := RoomTypes.Zone.ENGINEERING if o.type == Contract.Type.DESTROY else (RoomTypes.Zone.HABITATION if o.type == Contract.Type.RECOVER else RoomTypes.Zone.COMMAND)
		# Retrieve can be either research specimens or command data.
		if o.type == Contract.Type.RETRIEVE and rng.randf() < 0.5:
			preferred = RoomTypes.Zone.MEDICAL
		weights[preferred] = int(weights[preferred]) * 3
		var total := 0
		for value in weights.values():
			total += int(value)
		var roll := rng.randi_range(0, total - 1)
		for zone: int in weights:
			roll -= weights[zone]
			if roll < 0:
				o.primary = zone
				break
		var options: Array = DeckLayout.SECONDARY_OPTIONS[o.primary]
		o.secondary = options[rng.randi_range(0, options.size() - 1)]
	for _attempt in SEED_ATTEMPTS:
		o.map_seed = rng.randi() & 0x7fffffff
		var data := MapGenerator.generate(o.map_seed, config_for(o.size, o.primary, o.secondary, o.type))
		var types := Contract.supported_types(data)
		if types.is_empty():
			continue
		if not types.has(o.type):
			o.type = types[0]
		o.hangar_count = data.hangars.size()
		o.room_count = data.rooms.size() - data.corridors.size()
		break
	o.contract_seed = rng.randi() & 0x7fffffff
	o.payout = CampaignEconomy.payout_for(o.type, o.size)
	return o


static func config_for(p_size: int, p_primary: int = -1, p_secondary: int = -1, p_objective: int = -1) -> MapGenerator.Config:
	var cfg := MapGenerator.Config.new()
	var tree := Engine.get_main_loop() as SceneTree
	var settings := tree.root.get_node_or_null("GameSettings") if tree != null else null
	if OS.is_debug_build() and settings != null and settings.get("generated_decks"):
		cfg.deck_source = MapGenerator.DeckSource.GENERATED
	for arg in OS.get_cmdline_user_args():
		if arg == "--deck-source=generated": cfg.deck_source = MapGenerator.DeckSource.GENERATED
		elif arg == "--deck-source=plot": cfg.deck_source = MapGenerator.DeckSource.PLOT
	var dims: Vector2i = CampaignEconomy.DECK_DIMENSIONS.get(p_size, CampaignEconomy.DECK_DIMENSIONS[CampaignEconomy.DeckSize.MEDIUM])
	cfg.width = dims.x
	cfg.depth = dims.y
	cfg.player_spawn_count = CampaignEconomy.MAX_SQUAD
	# Small decks always roll Mixed (plan "Deck profiles"), with smaller rooms.
	cfg.mixed_profile = p_size == CampaignEconomy.DeckSize.SMALL
	cfg.room_scale = CampaignEconomy.DECK_ROOM_SCALE.get(p_size, 1.0)
	cfg.profile_primary = p_primary
	cfg.profile_secondary = p_secondary
	cfg.objective_kind = p_objective
	return cfg


## The mission's Contract on the deck this offer names (built from `map_seed`):
## placed with its own seeded RNG, so it is the same on every peer and does not
## depend on how much of the global RNG spawning has used. Falls back to any type
## the deck supports, priced for this deck size, if the offered one cannot be
## placed (it was checked at offer time, so only a changed generator gets here).
func build_contract(data: MapData) -> Contract:
	var rng := RandomNumberGenerator.new()
	rng.seed = contract_seed
	var c := Contract.make(type, data, rng)
	if c == null:
		c = Contract.choose(data, rng)
	if c == null:
		return null
	c.payout = payout if c.type == type else CampaignEconomy.payout_for(c.type, size)
	data.select_objective_insertion(c.target_tile, rng)
	return c


func type_name() -> String:
	return Contract.TYPE_NAME.get(type, "Contract")


func size_name() -> String:
	return CampaignEconomy.DECK_SIZE_NAME.get(size, "?")


## The board line: type, deck size, payout.
func describe() -> String:
	var dims: Vector2i = CampaignEconomy.DECK_DIMENSIONS.get(size, Vector2i.ZERO)
	return "%s — %s %s (%dx%d, %d hangars, %d rooms) — pays %d cr" % [
		type_name(), size_name(), profile_name(), dims.x, dims.y, hangar_count, room_count, payout]


func profile_name() -> String:
	var data := MapData.new()
	data.deck_primary = primary
	data.deck_secondary = secondary
	data.deck_mixed = size == CampaignEconomy.DeckSize.SMALL
	var label := data.profile_name()
	return label if not label.is_empty() else "deck"


## The deck as a deployment names it (see Campaign / TestMap): generated from a
## seed at a size.
func deck() -> Dictionary:
	return {"kind": "generated", "seed": map_seed, "size": size, "primary": primary, "secondary": secondary, "objective": type}


func to_dict() -> Dictionary:
	return {
		"type": type, "size": size, "map_seed": map_seed, "contract_seed": contract_seed,
		"payout": payout, "hangars": hangar_count, "rooms": room_count,
		"primary": primary, "secondary": secondary,
	}


static func from_dict(d: Dictionary) -> ContractOffer:
	var o := ContractOffer.new()
	o.type = int(d.get("type", Contract.Type.RETRIEVE))
	o.size = int(d.get("size", CampaignEconomy.DeckSize.MEDIUM))
	o.map_seed = int(d.get("map_seed", 0))
	o.contract_seed = int(d.get("contract_seed", 0))
	o.payout = int(d.get("payout", 0))
	o.hangar_count = int(d.get("hangars", 0))
	o.room_count = int(d.get("rooms", 0))
	o.primary = int(d.get("primary", -1))
	o.secondary = int(d.get("secondary", -1))
	return o


static func _weighted(weights: Array[int], rng: RandomNumberGenerator) -> int:
	var total := 0
	for w in weights:
		total += w
	var roll := rng.randi_range(0, maxi(1, total) - 1)
	for i in weights.size():
		roll -= weights[i]
		if roll < 0:
			return i
	return weights.size() - 1
