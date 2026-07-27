extends Node3D
## Root scene script: spawns squads onto the test map, wires signals, starts
## the mission.

const PLAYER_SCENE := preload("res://scenes/player_unit.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy_unit.tscn")
const SWARM_SCENE := preload("res://scenes/swarm_unit.tscn")

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
		enemy.stats = _alien_stats("Alien_%d" % enemy_index)
		enemy.position = GridManager.grid_to_world(spawn)
		add_child(enemy)
		enemy.action_logged.connect(_on_unit_log)
		enemy_index += 1

	var swarm_index := 1
	for spawn in map.swarm_spawns:
		var swarm: SwarmUnit = SWARM_SCENE.instantiate()
		swarm.stats = _swarm_stats("Swarm_%d" % swarm_index)
		swarm.position = GridManager.grid_to_world(spawn)
		add_child(swarm)
		swarm.action_logged.connect(_on_unit_log)
		swarm_index += 1

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


func _auto_play(unit: Unit) -> void:
	# Headless smoke test (`godot -- --auto`): player units mirror the enemy
	# AI so a full skirmish resolves without input.
	var player := unit as PlayerUnit
	if player == null:
		return
	await get_tree().process_frame
	while player.ap > 0 and not player.is_downed and not TurnManager.mission_over:
		var target := _nearest_hostile(player)
		if target == null:
			break
		var in_range := GridManager.chebyshev_dist(player.grid_pos, target.grid_pos) <= 8
		if in_range and GridManager.has_line_of_sight(player, target) and player.can_shoot():
			player.spend_ap(1)
			var result: Combat.ShotResult = await player.fire_at(target, Combat.ShotAction.SHOOT)
			_on_unit_log("%s auto-fired at %s (%d%%): %s" % [player.stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
		elif not player.can_shoot():
			player.spend_ap(1)
			await player.do_reload()
		else:
			var full_path := GridManager.find_path(player.grid_pos, target.grid_pos, 999, true)
			if full_path.size() <= 1:
				break
			full_path.resize(full_path.size() - 1)
			var path := full_path.slice(0, mini(player.move_run(), full_path.size()))
			player.spend_ap(1)
			await player.move_along(path)
			_on_unit_log("%s auto-moved to %s" % [player.stats.display_name, path[-1]])
	if not TurnManager.mission_over:
		player.end_activation()


func _nearest_hostile(player: Unit) -> Unit:
	var best: Unit = null
	var best_dist := 999999
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var enemy := node as Unit
		if enemy == null or enemy.is_downed:
			continue
		var d := GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos)
		if d < best_dist:
			best_dist = d
			best = enemy
	return best


func _on_unit_log(text: String) -> void:
	print(text)
	hud.append_log(text)


func _alien_stats(alien_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = alien_name
	stats.perception = randi_range(30, 50)
	stats.reflexes = randi_range(25, 45)
	stats.fitness = randi_range(30, 45)
	stats.luck = 20
	var weapon := WeaponData.new()
	weapon.base_accuracy = 20
	weapon.damage = 8
	weapon.mag_size = 10
	stats.weapon = weapon
	stats.class_base_initiative = 40
	stats.equipment_initiative = 30
	return stats


func _swarm_stats(swarm_name: String) -> UnitStats:
	# Fodder (Sec 11.3/11.4): tanky, since max HP is Fitness, but each swing is
	# small — three or four of them are what hurts, never one. `mag_size` 0 is
	# what "has no gun" means mechanically: can_shoot() is false forever.
	# Lowest initiative on the board, so a swarm generally acts after the squad
	# has already had its say. (Both roster entries want moving into a spawn
	# table on the Nest node, Sec 11.7, once that exists.)
	var stats := UnitStats.new()
	stats.display_name = swarm_name
	stats.perception = randi_range(25, 40)
	stats.reflexes = randi_range(15, 30)
	stats.fitness = randi_range(50, 65)
	stats.luck = 15
	# stats.weapon stays null — no ranged weapon at all (Sec 11.4); the
	# weapon_base_accuracy/weapon_damage/mag_size getters all read 0 from that.
	stats.melee_base_accuracy = 45
	stats.melee_damage = 5
	stats.class_base_initiative = 25
	stats.equipment_initiative = 20
	return stats
