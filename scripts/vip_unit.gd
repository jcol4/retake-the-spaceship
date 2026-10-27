class_name VipUnit
extends Unit
## The Recover objective's VIP (GDD §7.5, extraction plan Phase 6): "find a downed
## VIP and carry them out." A Contractor-side `Unit` nobody controls, spawned
## DOWNED in a far room and carried like a downed soldier (GDD §4.4).
##
## WHY A UNIT. Everything Recover needs already exists for downed soldiers and
## keys off a Unit: the carry pair and its replication, the 25% redirect of a hit
## on the carrier (`redirects_hit_to_carried` — plan: "the 25% redirect applies to
## them"), riding aboard as the carrier's rider (ExtractionManager.riders_of), the
## downed bar a grenade or a redirected round comes off, the body label. A prop
## would have had to reimplement all of it.
##
## HOW IT DIFFERS FROM A DOWNED SOLDIER (decisions log, "Phase 6 — Recover"):
##   - It DOES NOT BLEED (plan A10: "stable, not bleeding"): `bleeds_out` is
##     false, so TurnManager's round-start drain skips it. Damage still comes off
##     the downed bar, and an empty bar kills it — which fails the contract.
##   - It CANNOT BE REVIVED (`can_be_revived` false): the contract is to carry
##     them out, and a revived VIP would be a unit with nobody at the controls.
##   - Hostile AI never goes out of its way to finish it (`is_finish_target`
##     false): an alien prowling past the far room would otherwise decide whether
##     the contract is even possible before the squad got there. Stray damage —
##     a grenade, a redirected round — still lands.
##   - It is in no crew (ExtractionManager.crew_of: not player-controlled), so it
##     never counts toward a wipe, a roll call or the debrief. It boards as its
##     carrier's rider, or lying in the square at departure
##     (ExtractionManager._escorts_in_square), and only the objective verdict
##     reads it.
##
## Spawned by main.gd on every peer from the contract (deterministic name, tile
## and stats — nothing rolls), like a nest; ObjectiveManager finds it by tile.
## Placeholder look: the soldier model with a pale tint and no lamp, lying down.

## Group every VIP is in — how ObjectiveManager, the HUD and the tests find one.
const GROUP := "vips"
## Node name main.gd spawns it under (one VIP per contract).
const NODE_NAME := "VIP"
## A civilian's body: a bar of 20 is two LMG bursts' worth of redirected hits, so
## a carrier who keeps to cover gets them home and one who sprints across an open
## bay under fire may not.
const MAX_HP := 20
const VARIANT := &"merc"
## Pale blue-white: reads as "not one of the squad" next to the soldiers.
const TINT := Color(0.8, 0.88, 1.0)


func _init() -> void:
	faction = Faction.Id.CONTRACTORS
	has_flashlight = false
	flashlight_on = false
	# NOT `can_be_downed`: that flag is "goes down instead of dying at 0 HP",
	# which never applies — the VIP starts down. Carrying and reviving ask their
	# own questions (`is_carriable`, `can_be_revived`), overridden below.
	can_be_downed = false
	add_to_group("units")
	add_to_group(GROUP)
	_build_nodes()


## The children a Unit scene would carry, built in code: the Visual and a
## NameLabel. No click Body — the revive/pick-up click falls back to the tile
## (PlayerUnit._body_under_mouse), and a collider on a body only gets in the way of
## line-of-sight rays.
func _build_nodes() -> void:
	var visual_node := UnitVisual.new()
	visual_node.name = "Visual"
	visual_node.variant = VARIANT
	visual_node.has_light = false
	visual_node.faction_tint = TINT
	add_child(visual_node)
	var label := Label3D.new()
	label.name = "NameLabel"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0.0, 2.2, 0.0)
	add_child(label)


## A VIP named `display_name` lying on `tile`. Name it before add_child (co-op
## addresses units by path); add it under the units' parent yourself.
static func make(tile: Vector3i, display_name: String) -> VipUnit:
	var vip := VipUnit.new()
	vip.name = NODE_NAME
	vip.stats = make_stats(display_name)
	vip.position = GridManager.grid_to_world(tile)
	return vip


## Fitness 0 so `base_hp` IS max HP (the nest's trick). No weapon: nothing to
## loot off them, and nothing for `_stow_gear_as_items` to convert.
static func make_stats(display_name: String) -> UnitStats:
	var s := UnitStats.new()
	s.display_name = display_name
	s.fitness = 0
	s.base_hp = MAX_HP
	s.perception = 0
	s.reflexes = 0
	s.luck = 0
	s.base_initiative = 0
	s.equipment_initiative = 0
	s.melee_base_accuracy = 0
	s.melee_damage = 0
	s.weapon = null
	return s


func _ready() -> void:
	super()
	# Starts DOWNED on every peer: the same transition presentation a soldier
	# going down gets (tile freed, collapse pose), with none of `_go_down`'s
	# fight-leaving — there was no fight. The host's life_state replicates as
	# usual from here on.
	_set_life_state(LifeState.DOWNED)


## The VIP is a downed body from the moment it spawns, so it is never drawn and
## the pool never asks it to act; zero for safety.
func ap_pool() -> int:
	return 0


## Plan A10: stable, not bleeding.
func bleeds_out() -> bool:
	return false


func can_be_revived() -> bool:
	return false


func is_finish_target() -> bool:
	return false


## Downed or dead, and nobody already has them. Not gated on `can_be_downed` (the
## soldier rule), which the VIP deliberately does not set.
func is_carriable() -> bool:
	return life_state != LifeState.ACTIVE and carried_by == null


## Alive and well enough to hand over: still DOWNED (a dead VIP is a failed
## contract, however carefully the body is carried home).
func is_alive() -> bool:
	return life_state == LifeState.DOWNED
