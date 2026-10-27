class_name ItemData
extends Resource
## One inventory item (GDD §7.5, extraction plan 3.1). Every item takes exactly one
## of a soldier's Unit.INVENTORY_SLOTS, whatever it is.
##
## Built only by `ItemPresets` (the roster) — never by hand — so that `code`, the
## wire form, always describes the item completely: an item crosses the network,
## a container's contents are mirrored, and MissionResult.loot is carried out, all
## as codes, and `ItemPresets.from_code(item.code)` rebuilds the same item on the
## other side. Anything that would make two items with one code differ (a rolled
## value, a hidden flag) is a bug in this contract.

## VALUABLE   sells for credits (Phase 4 economy). Salvage from robots is one.
## GEAR       equipment that can be fitted next mission: a weapon (with whatever
##            attachments and ammo were on it, as ONE item), a grenade, an
##            attachment, an ammo type. Corpses are where it comes from today;
##            container gear tables are extraction plan Phase 6.
## OBJECTIVE  the Retrieve contract's item. Worth nothing on its own — the
##            contract's payout is the reward, and only if it extracts.
##
## APPEND-ONLY: Phase 4 saves will hold these.
enum Kind { VALUABLE, GEAR, OBJECTIVE }

## The preset key: "scrap_electronics", "salvage", "weapon", "grenade",
## "data_core"... Several items can share an id and differ in `payload` (two
## weapons, two Salvage piles of different size); `code` is the unique name.
@export var id: String = ""
@export var display_name: String = "Item"
@export var kind: Kind = Kind.VALUABLE
## Credits, for selling (VALUABLE) or a nominal resale price (GEAR). 0 for an
## objective item.
@export var value: int = 0
## Kind-specific detail, always wire-safe (ints, strings, packed arrays):
##   GEAR weapon      {"gear": "weapon", "weapon_id": int, "attachments": PackedInt32Array, "ammo": int}
##   GEAR grenade     {"gear": "grenade"}
##   GEAR attachment  {"gear": "attachment", "attachment_id": int}
##   GEAR ammo        {"gear": "ammo", "ammo_id": int}
##   Salvage          {"points": int} — the robot's salvage_value it came from
## Empty for an ordinary valuable or an objective item.
@export var payload: Dictionary = {}
## Value tier 1-3 for valuables (ItemPresets.TIER_*), 0 otherwise.
@export var tier: int = 0
## The complete wire form; see the header. Set by ItemPresets.
@export var code: String = ""


func is_gear() -> bool:
	return kind == Kind.GEAR


func is_objective() -> bool:
	return kind == Kind.OBJECTIVE


## "Data Core", "Assault Rifle (Holo Sight, Suppressor)" — what a loot panel row says.
func describe() -> String:
	return display_name
