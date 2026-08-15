extends Node3D
## Root scene script: spawns squads onto the test map, wires signals, starts
## the mission.

const PLAYER_SCENE := preload("res://scenes/player_unit.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy_unit.tscn")
const SWARM_SCENE := preload("res://scenes/swarm_unit.tscn")
const BRAWLER_SCENE := preload("res://scenes/brawler_unit.tscn")
const MERC_SCENE := preload("res://scenes/merc_unit.tscn")
const HUNTER_SCENE := preload("res://scenes/agile_hunter_unit.tscn")

@onready var map: Node3D = $TestMap
@onready var camera_rig: Node3D = $CameraRig
@onready var hud: CanvasLayer = $HUD

const SQUAD := [
	[UnitStats.UnitClass.ASSAULT, "Reyes"],
	[UnitStats.UnitClass.SNIPER, "Okafor"],
	[UnitStats.UnitClass.SUPPORT, "Lindqvist"],
]


var _auto := false


func _ready() -> void:
	TurnManager.log_message.connect(func(text: String) -> void: print(text))
	_auto = "--auto" in OS.get_cmdline_user_args()
	if _auto:
		TurnManager.unit_activated.connect(_auto_play)
		TurnManager.mission_ended.connect(func(_won: bool) -> void: get_tree().quit.call_deferred())
	var player_units: Array[PlayerUnit] = []
	var spawn_index := 0
	for entry in SQUAD:
		if spawn_index >= map.player_spawns.size():
			break
		var unit: PlayerUnit = PLAYER_SCENE.instantiate()
		unit.stats = ClassPresets.roll(entry[0], entry[1])
		unit.position = GridManager.grid_to_world(map.player_spawns[spawn_index])
		add_child(unit)  # Unit._ready snaps to grid + registers occupancy
		unit.action_logged.connect(_on_unit_log)
		player_units.append(unit)
		spawn_index += 1

	var enemy_index := 1
	for spawn in map.enemy_spawns:
		var enemy: EnemyUnit = ENEMY_SCENE.instantiate()
		enemy.stats = AlienPresets.ranged("Alien_%d" % enemy_index)
		enemy.position = GridManager.grid_to_world(spawn)
		add_child(enemy)
		enemy.action_logged.connect(_on_unit_log)
		enemy_index += 1

	var swarm_index := 1
	for spawn in map.swarm_spawns:
		var swarm: SwarmUnit = SWARM_SCENE.instantiate()
		swarm.stats = AlienPresets.swarm("Swarm_%d" % swarm_index)
		swarm.position = GridManager.grid_to_world(spawn)
		add_child(swarm)
		swarm.action_logged.connect(_on_unit_log)
		swarm_index += 1

	var brawler_index := 1
	for spawn in map.brawler_spawns:
		var brawler: BrawlerUnit = BRAWLER_SCENE.instantiate()
		brawler.stats = AlienPresets.brawler("Brawler_%d" % brawler_index)
		brawler.position = GridManager.grid_to_world(spawn)
		add_child(brawler)
		brawler.action_logged.connect(_on_unit_log)
		brawler_index += 1

	var hunter_index := 1
	for spawn in map.hunter_spawns:
		var hunter: AgileHunterUnit = HUNTER_SCENE.instantiate()
		hunter.stats = AlienPresets.hunter("Hunter_%d" % hunter_index)
		hunter.position = GridManager.grid_to_world(spawn)
		add_child(hunter)
		hunter.action_logged.connect(_on_unit_log)
		hunter_index += 1

	var merc_index := 1
	# One LMG per squad, handed to whichever member is placed first in a room.
	# The coordinator has to pick a suppressor every engagement, and a squad where
	# that choice is arbitrary reads as arbitrary — this gives it an answer.
	var squads_seen := {}
	for spawn in map.merc_spawns:
		var merc: MercUnit = MERC_SCENE.instantiate()
		# Explicitly typed: `map` is a bare Node3D here, so its return type is
		# unknown at compile time and `:=` has nothing to infer from.
		var room: int = map.room_at(spawn)
		var name := "Merc_%d" % merc_index
		merc.stats = MercPresets.support(name) if not squads_seen.has(room) \
			else MercPresets.rifleman(name)
		squads_seen[room] = true
		# Squad BY COMPARTMENT, the same way a robot takes its security zone from
		# the deck. Two merc teams in two rooms get two independent blackboards
		# without the map needing a second glyph or the spawner a second list —
		# and it means a level author draws squads by drawing walls.
		merc.squad_id = "mercs_room_%d" % room
		merc.position = GridManager.grid_to_world(spawn)
		add_child(merc)
		merc.action_logged.connect(_on_unit_log)
		merc_index += 1

	# Iterates whatever the deck placed, so a map with no robot glyphs — the test
	# deck, currently, so the alien tier can be judged on its own — spawns none
	# without this needing to know that.
	_spawn_security_robots()

	if not map.player_spawns.is_empty():
		camera_rig.focus_on(GridManager.grid_to_world(map.player_spawns[0]))

	# Static fixtures are already baked in (TestMap._ready ran first); layer in
	# the squad's flashlights now that the units themselves exist.
	LightingManager.recompute_dynamic()

	if _auto:
		# Headless smoke test skips the loadout screen entirely — every unit
		# just deploys with its class's suggested-default weapon.
		TurnManager.start_mission.call_deferred()
		return

	var loadout: CanvasLayer = LoadoutMenu.new()
	add_child(loadout)
	loadout.setup(player_units)
	loadout.deployed.connect(func() -> void: TurnManager.start_mission.call_deferred())


func _spawn_security_robots() -> void:
	# One pass over the roster rather than a block per type: the deck says which
	# models it wants and where, and CerberusPresets says what each one is.
	#
	# The zone assignment is the only thing that cannot come from either — it is a
	# property of the DECK's compartment graph, so the builder derives it (see
	# MapBuilder.zone_at). A robot spawned outside any room gets NO_ZONE and
	# simply broadcasts to nobody, which is the right answer rather than an error.
	for kind: int in MapData.CERBERUS_SPAWNS:
		var spawns: Array = map.cerberus_spawns.get(kind, [])
		var index := 1
		for spawn: Vector3i in spawns:
			var robot: CerberusUnit = CerberusPresets.scene_for(kind).instantiate()
			robot.stats = CerberusPresets.make_stats(kind, index if spawns.size() > 1 else 1)
			robot.security_zone = map.zone_at(spawn)
			robot.position = GridManager.grid_to_world(spawn)
			add_child(robot)
			robot.action_logged.connect(_on_unit_log)
			index += 1


## Brains for auto-played soldiers, one per unit. Built lazily and kept, because
## a `GoapBrain` carries the unit's goal commitment and starvation counter — a
## fresh one each activation would reset exactly the state fixes C and F exist to
## accumulate.
var _auto_brains: Dictionary = {}


## Headless smoke test (`godot -- --auto`): soldiers resolve a full skirmish
## without input.
##
## They run the RIVAL MERC DOCTRINE, which is not a shortcut — that doctrine is
## written as full parity with the player (same actions, same weapons, same cover
## rules), so it is the closest thing to a competent human the codebase contains.
## It also means a smoke run exercises the framework from both sides at once, and
## a doctrine bug that only shows up when the player side is the one planning has
## somewhere to surface.
##
## Real play is untouched: nothing below runs unless `--auto` is passed.
func _auto_play(unit: Unit) -> void:
	var player := unit as PlayerUnit
	if player == null:
		return
	await get_tree().process_frame
	var target := _nearest_hostile(player)
	if target != null:
		if not _auto_brains.has(player):
			_auto_brains[player] = Doctrines.merc_brain(Doctrines.blackboard_for("contractors"))
		var brain: GoapBrain = _auto_brains[player]
		SquadCoordinator.assign(brain.blackboard, _living_squad(), target)
		var before := player.ap
		await brain.run(player, target)
		# The planner declining to act must never end the run. A target it cannot
		# plan against — no ammo, no reachable angle — would otherwise leave the
		# soldier idling every turn while the enemy sits UNAWARE, which is the
		# stalemate this harness has already been fixed for once.
		if player.ap == before:
			await _greedy_fallback(player)
	if not TurnManager.mission_over:
		player.end_activation()


func _living_squad() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var member := node as Unit
		if member != null and not member.is_downed:
			out.append(member)
	return out


## The original greedy loop, kept as the harness's floor: shoot, reload, close,
## swing. Crude on purpose — it exists to guarantee the run terminates, not to
## play well.
func _greedy_fallback(player: PlayerUnit) -> void:
	var shoot_cost := player.action_cost(UnitStats.Action.SHOOT)
	var reload_cost := player.action_cost(UnitStats.Action.RELOAD)
	var melee_cost := player.action_cost(UnitStats.Action.MELEE)
	while player.ap > 0 and not player.is_downed and not TurnManager.mission_over:
		var target := _nearest_hostile(player)
		if target == null:
			break
		var in_range := GridManager.chebyshev_dist(player.grid_pos, target.grid_pos) <= 8
		if in_range and GridManager.has_line_of_sight(player, target) and player.can_shoot():
			if player.ap < shoot_cost:
				break  # cannot afford the shot it wants — end the activation
			player.spend_ap(shoot_cost)
			var result: Combat.ShotResult = await player.fire_at(target, Combat.ShotAction.SHOOT)
			_on_unit_log("%s auto-fired at %s (%d%%): %s" % [player.stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
		# `can_reload` matters as much as `can_shoot`, and leaving it out was a
		# hang: a weapon's reserve is finite, so a soldier who burns the mission's
		# whole ammo budget can neither fire nor refill — and this branch happily
		# charged AP to draw zero rounds, every activation, forever. A run could
		# sit at 2000+ turns with one dry survivor doing that.
		#
		# Falling through to the move branch instead is also the better behaviour:
		# a soldier out of ammo walks at the enemy rather than miming a reload,
		# which gets them seen and gets the mission resolved one way or the other.
		elif not player.can_shoot() and player.can_reload():
			if player.ap < reload_cost:
				break
			player.spend_ap(reload_cost)
			await player.do_reload()
		elif GridManager.is_melee_adjacent(player.grid_pos, target.grid_pos):
			# The branch whose absence was the last way this could hang. A soldier
			# with nothing left to fire walks at the enemy (above), arrives, and
			# then had literally no action available: `_move_toward` stops short
			# of the target's tile, so the path goes empty and the activation just
			# ended, every turn, forever. Standing in the dark it was not even
			# noticed — the aliens need light to see, which is the system working,
			# but it left the run unable to finish.
			if player.ap < melee_cost:
				break
			player.spend_ap(melee_cost)
			var hit: Combat.ShotResult = await player.melee_at(target)
			_on_unit_log("%s auto-struck %s (%d%%): %s" % [
				player.stats.display_name, target.stats.display_name,
				hit.accuracy, Combat.describe(hit)])
		else:
			var full_path := GridManager.find_path(player.grid_pos, target.grid_pos, 999, true)
			if full_path.size() <= 1:
				break
			full_path.resize(full_path.size() - 1)
			# Holds back the price of a shot, exactly as the alien loop does — at
			# 1 AP per tile a unit that walks its whole pool never fires.
			var budget := maxi(1, (player.ap - shoot_cost) / player.move_ap_per_tile())
			if player.move_tiles_affordable() < 1:
				break
			var path := full_path.slice(0, mini(budget, full_path.size()))
			player.spend_ap(player.move_cost_for(path.size()))
			await player.move_along(path)
			_on_unit_log("%s auto-moved to %s" % [player.stats.display_name, path[-1]])


## Nearest hostile this unit can actually DO something about — shoot from where
## it stands, or walk to. The reachability half is what stops the smoke test
## deadlocking.
##
## Chebyshev ignores walls, so "nearest" is frequently something on the far side
## of a bulkhead. The old version picked it anyway, `_auto_play` then found no
## path and ended the activation, and the same unreachable unit won the next draw
## too — so both sides idled at each other forever. Harmless while every hostile
## shared one room with the squad; the rival mercs spawn in a compartment of
## their own, and a run promptly stalemated for 3000+ turns.
##
## Costs a pathfind per candidate that would improve on the current best, which
## is nothing at smoke-test scale and buys a run that terminates. This is the
## headless harness's greedy stand-in for AI, not the game's — real units plan
## through `EnemyUnit`.
func _nearest_hostile(player: Unit) -> Unit:
	var best: Unit = null
	var best_dist := 999999
	for enemy in player.hostiles():
		var d := GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos)
		if d >= best_dist or not _can_act_on(player, enemy):
			continue
		best_dist = d
		best = enemy
	return best


func _can_act_on(player: Unit, enemy: Unit) -> bool:
	if GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos) <= 8 \
			and GridManager.has_line_of_sight(player, enemy):
		return true
	return not GridManager.find_path(player.grid_pos, enemy.grid_pos, 999, true).is_empty()


func _on_unit_log(text: String) -> void:
	print(text)
	hud.append_log(text)


