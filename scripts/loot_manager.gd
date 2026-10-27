extends Node
## Autoload. Every LootContainer on the deck — the generated or authored crates,
## and the piles dropped items form (extraction plan 3.2, plan A6) — found by tile.
##
## HOST-AUTHORITATIVE, mirrored on change. Both peers build the same crates with
## the same contents from their own identical MapData (MapBuilder -> `build_from`),
## so nothing crosses the wire at load. After that, every change to a container's
## contents happens on the host, through `take` / `drop_to_pile` / `put`, and goes
## out as ONE `_rpc_contents` call carrying the tile's full new contents as codes
## — a client never edits a container itself, it only applies snapshots. A pile a
## client has never seen is created by the snapshot that first names it, and
## freed by the one that empties it; names are derived from the tile
## (LootContainer.node_name_for), so it lands at the same node path everywhere.
##
## Corpses are loot sources too, but they are Units and replicate their own pack
## (Unit.inventory_codes); `take` routes to them and only mirrors containers.

## A container's contents changed on this peer (host as it happens, client as the
## snapshot lands), or a pile appeared or went. The HUD's loot panel listens.
signal container_changed(tile: Vector3i)

## Tile -> LootContainer, crates and piles alike (a pile never shares a tile with
## a crate: a crate's tile cannot be stood on, so nothing is ever dropped there).
var _containers: Dictionary = {}


func _is_authority() -> bool:
	return not SteamLobby.is_networked() or SteamLobby.is_host()


## Forgets every container. MapBuilder calls this at the top of every build, when
## it frees the old deck's nodes (piles included — they are parented to the map).
func clear() -> void:
	_containers.clear()


## Builds the deck's authored/generated crates under `parent` (the MapBuilder) on
## every peer, and makes each crate's tile impassable — the crate stands on a
## real GridManager tile, so it can be reached (`Unit.within_reach` and the
## movement neighbours both need the tile to exist) but not walked onto.
func build_from(parent: Node, data: MapData) -> void:
	clear()
	for spot: MapData.LootSpot in data.containers:
		var t: GridTileData = GridManager.get_tile(spot.pos)
		if t:
			t.passable = false
		var crate := LootContainer.new()
		crate.setup(spot.pos, spot.items, false)
		parent.add_child(crate)
		_containers[spot.pos] = crate


func container_at(tile: Vector3i) -> LootContainer:
	var c: LootContainer = _containers.get(tile)
	return c if c != null and is_instance_valid(c) else null


## Every live container and pile, in tile order.
func all_containers() -> Array:
	var tiles: Array = _containers.keys()
	tiles.sort()
	var out: Array = []
	for tile: Vector3i in tiles:
		var c := container_at(tile)
		if c != null:
			out.append(c)
	return out


## Whether `unit` can reach `source` (a container or pile): movement-adjacent, or
## — for a pile, which can be stood on — its own tile.
func in_reach(unit: Unit, source: Object) -> bool:
	return unit != null and source is LootContainer and unit.within_reach((source as LootContainer).tile)


## Containers and piles within `unit`'s reach that hold anything, in tile order.
func sources_in_reach(unit: Unit) -> Array:
	var out: Array = []
	for c: LootContainer in all_containers():
		if not c.items.is_empty() and in_reach(unit, c):
			out.append(c)
	return out


## Host: removes item `index` from any loot source and returns it (null if there
## is none). A container's new contents go to clients; an emptied pile is gone.
## A corpse mirrors itself (its pack is a replicated property).
func take(source: Object, index: int) -> ItemData:
	if source == null or not is_instance_valid(source) or not source.has_method("loot_take"):
		return null
	var item: ItemData = source.loot_take(index)
	if item != null and source is LootContainer:
		_changed(source as LootContainer)
	return item


## Host: puts `item` on the floor at `tile` — into the pile already there, or a
## new one (plan A6: a dropped item forms a lootable pile).
func drop_to_pile(tile: Vector3i, item: ItemData) -> LootContainer:
	if item == null:
		return null
	var pile := container_at(tile)
	if pile == null:
		pile = _spawn(tile, PackedStringArray(), true)
	pile.items.append(item)
	_changed(pile)
	return pile


## Adds the item `code` to the container at `tile`. What a contract uses to plant
## its Retrieve item (ObjectiveManager). Deterministic, so it is run on EVERY peer
## at mission start rather than mirrored; mirroring it as well is harmless.
func put(tile: Vector3i, code: String) -> bool:
	var c := container_at(tile)
	var item := ItemPresets.from_code(code)
	if c == null or item == null:
		return false
	c.items.append(item)
	c.refresh()
	container_changed.emit(tile)
	return true


func _changed(c: LootContainer) -> void:
	_present(c)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_contents.rpc(c.tile, c.codes(), c.is_pile)


## A client applies the host's snapshot of one tile's container.
@rpc("authority", "call_remote", "reliable")
func _rpc_contents(tile: Vector3i, codes: PackedStringArray, pile: bool) -> void:
	var c := container_at(tile)
	if c == null:
		if codes.is_empty():
			return
		c = _spawn(tile, codes, pile)
	else:
		c.items = ItemPresets.items_from(codes)
	_present(c)


## Every peer: label refresh, and an empty pile removed (a crate stays, empty).
func _present(c: LootContainer) -> void:
	var tile := c.tile
	if c.is_pile and c.items.is_empty():
		_containers.erase(tile)
		c.queue_free()
	else:
		c.refresh()
	container_changed.emit(tile)


func _spawn(tile: Vector3i, codes: PackedStringArray, pile: bool) -> LootContainer:
	var c := LootContainer.new()
	c.setup(tile, codes, pile)
	var parent: Node = get_tree().get_first_node_in_group("map")
	if parent == null:
		parent = get_tree().root
	parent.add_child(c)
	_containers[tile] = c
	return c
