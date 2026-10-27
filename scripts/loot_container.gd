class_name LootContainer
extends Node3D
## A loot prop (extraction plan 3.2): a crate or locker placed by the deck, or a
## PILE that dropped items form on a tile (plan A6). NOT a Unit — it never acts,
## is never drawn from the pool and cannot be shot; it is a box with items in it.
##
## A container BLOCKS its tile like block cover (MapBuilder leaves the tile in the
## grid but impassable) and is looted from a neighbouring tile. A pile does not
## block: it lies on the floor and can be looted from its own tile or beside it,
## like a body. Either way the reach test is `Unit.within_reach`.
##
## Contents are host-authoritative. Nothing here changes them on its own: every
## change goes through LootManager, which mirrors the new contents to clients.
## That is also why the node is named after its tile (`node_name_for`): the
## manager finds it by tile on every peer, and a co-op loot command addresses it
## by node path, which must resolve to the same container on the host.
##
## Placeholder look (extraction plan art list: crate, locker, item pile): a box,
## or a flat slab for a pile, with a small label of what is left.

## Crate footprint, and a pile's. A crate sits inside its tile with a margin so
## it reads as one tile's worth; a pile is low enough to read as "on the floor".
const CRATE_SIZE := Vector3(1.1, 0.8, 1.1)
const PILE_SIZE := Vector3(0.8, 0.12, 0.8)
const CRATE_COLOR := Color(0.32, 0.4, 0.3)
const PILE_COLOR := Color(0.55, 0.5, 0.35)
const LABEL_HEIGHT := 1.2

var tile: Vector3i
var is_pile := false
var items: Array[ItemData] = []
var _mesh: MeshInstance3D
var _label: Label3D


static func node_name_for(at: Vector3i, pile: bool) -> String:
	return "%s_%d_%d_%d" % ["Pile" if pile else "Loot", at.x, at.y, at.z]


## Call before add_child. `codes` are ItemPresets codes.
func setup(at: Vector3i, codes: PackedStringArray, pile: bool) -> void:
	tile = at
	is_pile = pile
	name = node_name_for(at, pile)
	items = ItemPresets.items_from(codes)


func _ready() -> void:
	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = PILE_SIZE if is_pile else CRATE_SIZE
	_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = PILE_COLOR if is_pile else CRATE_COLOR
	_mesh.material_override = mat
	_mesh.position = Vector3(0, box.size.y / 2.0, 0)
	add_child(_mesh)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.font_size = 14
	_label.outline_size = 5
	_label.position = Vector3(0, LABEL_HEIGHT if not is_pile else 0.5, 0)
	add_child(_label)
	global_position = GridManager.grid_to_world(tile)
	refresh()


## Re-reads `items` into the label. Called by LootManager after every change.
func refresh() -> void:
	if _label == null:
		return
	_label.text = "%s (%d)" % [loot_name(), items.size()] if not items.is_empty() else "%s (empty)" % loot_name()
	_label.modulate = Color(0.85, 0.85, 0.7) if not items.is_empty() else Color(0.5, 0.5, 0.5)


func codes() -> PackedStringArray:
	return ItemPresets.codes_of(items)


# --- Loot source interface (see Unit's "loot source" note) ----------------------


func loot_items() -> Array[ItemData]:
	return items


## Host-side, through LootManager.take only — that is what mirrors the change.
func loot_take(index: int) -> ItemData:
	if index < 0 or index >= items.size():
		return null
	var item: ItemData = items[index]
	items.remove_at(index)
	return item


func loot_tile() -> Vector3i:
	return tile


func loot_name() -> String:
	return "Pile" if is_pile else "Crate"


func has_objective() -> bool:
	for item in items:
		if item.is_objective():
			return true
	return false
