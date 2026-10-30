extends SceneTree
## Co-op player colours: who gets which swatch, and the merc marker that shows it.
##
##   godot --headless --path . --script res://tools/test_coop_players.gd
##
## Scripts are load()ed and locals stay untyped: a --script tool is compiled before
## the class registry and the autoloads exist. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const GREEN := 0
const PURPLE := 1
const YELLOW := 2
const WHITE := 3
const ORANGE := 4
const NEVER_PICKED := -1

var _failures := 0
var _coop: Node
var _turns: Node


func _initialize() -> void:
	_coop = root.get_node("CoopPlayers")
	_turns = root.get_node("TurnManager")
	_check_slot_defaults()
	_check_saved_choice()
	_check_contested_swatch()
	_check_bad_index()
	await _check_marker_colors()
	await _check_action_row()
	print("")
	print("FAILED: %d" % _failures if _failures > 0 else "All passed")
	quit(1 if _failures > 0 else 0)


func _check_slot_defaults() -> void:
	var colors := {}
	for peer_id in [1, 20, 30, 40]:
		colors[peer_id] = _coop.resolve_color(colors, peer_id, NEVER_PICKED)
	_expect(colors[1] == GREEN, "the host defaults to green")
	_expect(colors[20] == PURPLE, "player 2 defaults to purple")
	_expect(colors[30] == YELLOW, "player 3 defaults to yellow")
	_expect(colors[40] == WHITE, "player 4 defaults to white")


func _check_saved_choice() -> void:
	var colors := {1: GREEN}
	_expect(_coop.resolve_color(colors, 20, ORANGE) == ORANGE, "a saved choice that is free is honoured")
	_expect(_coop.resolve_color({1: ORANGE}, 20, ORANGE) == GREEN,
		"a saved choice that is taken falls back to the first free swatch")


func _check_contested_swatch() -> void:
	var colors := {1: GREEN, 20: PURPLE}
	_expect(_coop.resolve_color(colors, 20, GREEN) == PURPLE, "a taken swatch leaves the asker's colour alone")
	_expect(_coop.resolve_color(colors, 20, PURPLE) == PURPLE, "asking for your own colour keeps it")
	_expect(_coop.resolve_color(colors, 20, ORANGE) == ORANGE, "a free swatch can be swapped to")


func _check_bad_index() -> void:
	var colors := {1: GREEN}
	_expect(_coop.resolve_color(colors, 1, 99) == GREEN, "an index past the palette changes nothing")
	_expect(_coop.resolve_color(colors, 1, NEVER_PICKED) == GREEN, "-1 changes nothing for a player with a colour")


func _check_marker_colors() -> void:
	var a = load(PLAYER).instantiate()
	var b = load(PLAYER).instantiate()
	root.add_child(a)
	root.add_child(b)
	await process_frame
	_coop._colors = {1: PURPLE, 20: ORANGE}
	a.owner_peer_id = 1
	b.owner_peer_id = 20

	_turns.active_unit = a
	await process_frame
	var marker = a.get_node("ActiveMarker")
	var ring_color: Color = marker.get_node("Ring").get_surface_override_material(0).albedo_color
	_expect(_same_rgb(ring_color, _coop.PALETTE[PURPLE]), "the active merc's ring is its owner's colour")
	_expect(is_equal_approx(ring_color.a, marker.RING_ALPHA), "the ring keeps its transparency")

	_turns.active_unit = b
	await process_frame
	var other: Color = b.get_node("ActiveMarker/Ring").get_surface_override_material(0).albedo_color
	_expect(_same_rgb(other, _coop.PALETTE[ORANGE]), "another owner's merc shows that owner's colour")
	var still: Color = a.get_node("ActiveMarker/Ring").get_surface_override_material(0).albedo_color
	_expect(_same_rgb(still, _coop.PALETTE[PURPLE]), "recolouring one merc does not recolour the others")

	# A squadmate drops and the host takes over their soldiers (main.gd).
	b.owner_peer_id = 1
	await process_frame
	var handed: Color = b.get_node("ActiveMarker/Ring").get_surface_override_material(0).albedo_color
	_expect(_same_rgb(handed, _coop.PALETTE[PURPLE]), "a merc handed to the host turns the host's colour")

	# Out of a lobby there is no table: solo's soldiers keep the default green.
	_coop.clear()
	b.owner_peer_id = 0
	await process_frame
	var solo: Color = b.get_node("ActiveMarker/Ring").get_surface_override_material(0).albedo_color
	_expect(_same_rgb(solo, _coop.PALETTE[GREEN]), "solo stays green")
	var arrow: Color = b.get_node("ActiveMarker/Arrow").get_surface_override_material(0).albedo_color
	_expect(arrow.is_equal_approx(_coop.PALETTE[GREEN].lightened(marker.ARROW_LIGHTEN)), "the arrow follows the ring")

	_turns.active_unit = null
	a.free()
	b.free()


func _check_action_row() -> void:
	var hud = load("res://scenes/hud.tscn").instantiate()
	root.add_child(hud)
	var mine = load(PLAYER).instantiate()
	var partner = load(PLAYER).instantiate()
	var enemy = load("res://scenes/enemy_unit.tscn").instantiate()
	root.add_child(mine)
	root.add_child(partner)
	root.add_child(enemy)
	await process_frame
	var local_id: int = mine.multiplayer.get_unique_id()
	mine.owner_peer_id = local_id
	partner.owner_peer_id = local_id + 1
	var row = hud.get_node("Actions")

	_expect(not row.visible, "no actions before anyone is active")
	hud._refresh(mine)
	_expect(row.visible, "your own active merc shows the actions")
	hud._refresh(partner)
	_expect(not row.visible, "a partner's active merc hides them")
	hud._refresh(mine)
	hud._refresh(enemy)
	_expect(not row.visible, "an enemy's activation hides them")
	# A squadmate drops and their soldiers become this player's (main.gd).
	partner.owner_peer_id = local_id
	hud._refresh(partner)
	_expect(row.visible, "a merc handed over shows them again")
	mine.life_state = load("res://scripts/unit.gd").LifeState.DOWNED
	hud._refresh(mine)
	_expect(not row.visible, "a downed merc hides them")

	hud.free()
	mine.free()
	partner.free()
	enemy.free()


func _same_rgb(x: Color, y: Color) -> bool:
	return is_equal_approx(x.r, y.r) and is_equal_approx(x.g, y.g) and is_equal_approx(x.b, y.b)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("ok   - %s" % label)
	else:
		print("FAIL - %s" % label)
		_failures += 1
