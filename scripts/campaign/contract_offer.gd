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


## A fresh offer off the campaign's RNG. Seeds are 31-bit so they survive JSON
## (a double holds them exactly) and an int RPC argument unchanged.
static func generate(rng: RandomNumberGenerator) -> ContractOffer:
	var o := ContractOffer.new()
	o.type = OFFERED_TYPES[rng.randi_range(0, OFFERED_TYPES.size() - 1)]
	o.size = _weighted(CampaignEconomy.DECK_SIZE_WEIGHTS, rng)
	for _attempt in SEED_ATTEMPTS:
		o.map_seed = rng.randi() & 0x7fffffff
		var data := MapGenerator.generate(o.map_seed, config_for(o.size))
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


static func config_for(p_size: int) -> MapGenerator.Config:
	var cfg := MapGenerator.Config.new()
	var dims: Vector2i = CampaignEconomy.DECK_DIMENSIONS.get(p_size, CampaignEconomy.DECK_DIMENSIONS[CampaignEconomy.DeckSize.MEDIUM])
	cfg.width = dims.x
	cfg.depth = dims.y
	cfg.player_spawn_count = CampaignEconomy.MAX_SQUAD
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
	return c


func type_name() -> String:
	return Contract.TYPE_NAME.get(type, "Contract")


func size_name() -> String:
	return CampaignEconomy.DECK_SIZE_NAME.get(size, "?")


## The board line: type, deck size, payout.
func describe() -> String:
	var dims: Vector2i = CampaignEconomy.DECK_DIMENSIONS.get(size, Vector2i.ZERO)
	return "%s — %s deck (%dx%d, %d hangars, %d rooms) — pays %d cr" % [
		type_name(), size_name(), dims.x, dims.y, hangar_count, room_count, payout]


## The deck as a deployment names it (see Campaign / TestMap): generated from a
## seed at a size.
func deck() -> Dictionary:
	return {"kind": "generated", "seed": map_seed, "size": size}


func to_dict() -> Dictionary:
	return {
		"type": type, "size": size, "map_seed": map_seed, "contract_seed": contract_seed,
		"payout": payout, "hangars": hangar_count, "rooms": room_count,
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
