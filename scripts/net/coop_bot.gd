class_name CoopBot
extends Node
## DEV ONLY: a headless stand-in for a co-op player, so the whole per-player co-op
## loop (MULTIPLAYER_PLAN.md) can be run end to end by two instances of the game
## on one machine over the ENet dev lobby — lobby table, picks, Ready, the merged
## deployment, both boards, the ready handshake, the report split and delivery,
## the drop-and-rejoin, the host's save-and-resume. tools/coop_smoke.sh runs it.
##
##   --coop-bot=<role>   host | guest | guest-drop | host-quit | host-resume | guest-wait
##   --coop-bot-players=N   how many players the host waits for (default 2)
##   --coop-bot-end=N       the round the host ends the mission on (default 4)
##   with --save-slot=<name> --player-key=<k> --player-name=<n> per instance and
##   --enet-host=<port> (host) / --enet-join=127.0.0.1:<port> (guests).
##
## Roles:
##   host         waits for everyone Ready, selects the first contract, launches,
##                passes rounds, gives each guest soldier a valuable, and at the end
##                round extracts everyone standing.
##   guest        readies up; deploys; ends its own soldiers' activations.
##   guest-drop   as guest, but leaves the mission in round 2 and joins again —
##                must be brought back in (rejoin) and get its report.
##   host-quit    as host, but saves and quits in round 2 (the checkpoint).
##   host-resume  loads, resumes the checkpoint, then as host.
##   guest-wait   as guest, and when the host goes keeps trying to join again.
##
## Prints `COOPBOT:` lines; the last is `COOPBOT RESULT: ...` and the process quits
## with 0 if this player's save ended where it should, 1 if not.

var role := ""
## The front end has set this process's campaign up once (front_end._bot_boot).
var booted := false
var _ready_sent_ms := 0
var players_needed := 2
var end_round := 4
var _deadline_ms := 0
var _ended := false
var _dropped := false
var _rejoin_at_ms := 0
var _done := false
var _last_wait_ms := 0
## The host's pause for everyone, seen on this peer (guests) / done (host).
var _pauses_seen := 0
var _paused_once := false


static func requested() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--coop-bot="):
			return arg.trim_prefix("--coop-bot=")
	return ""


## The bot, once per process (it outlives scene changes, under the root).
static var _instance: CoopBot = null


static func ensure(tree: SceneTree) -> CoopBot:
	if _instance != null and is_instance_valid(_instance):
		return _instance
	if requested() == "":
		return null
	_instance = CoopBot.new()
	_instance.name = "CoopBot"
	_instance.role = requested()
	tree.root.add_child.call_deferred(_instance)
	return _instance


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--coop-bot-players="):
			players_needed = int(arg.trim_prefix("--coop-bot-players="))
		elif arg.begins_with("--coop-bot-end="):
			end_round = int(arg.trim_prefix("--coop-bot-end="))
	_deadline_ms = Time.get_ticks_msec() + 240000
	TurnManager.turn_started.connect(_on_turn_started)
	TurnManager.unit_activated.connect(_on_unit_activated)
	TurnManager.mission_ended.connect(_on_mission_ended)
	Campaign.debrief_received.connect(func(_s: Dictionary) -> void: _say("report received"))
	CoopLobby.paused_changed.connect(func(on: bool) -> void:
		if on:
			_pauses_seen += 1
		_say("paused by the host" if on else "unpaused"))
	multiplayer.server_disconnected.connect(_on_host_gone)
	_say("role %s, key %s, save %s" % [role, CoopPlayers.local_key(), Campaign.save_path])


func _say(text: String) -> void:
	print("COOPBOT[%s]: %s" % [role, text])


func _is_host_role() -> bool:
	return role.begins_with("host")


func _process(_delta: float) -> void:
	if _done:
		return
	if Time.get_ticks_msec() > _deadline_ms:
		_finish(false, "timed out")
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	if scene.has_method("_show_hub"):
		_in_front_end(scene)
	elif scene.has_method("quit_mission"):
		_in_mission(scene)


# --- Front end ----------------------------------------------------------------------------


func _in_front_end(fe: Node) -> void:
	# Back from a dropped mission: join the lobby again after a beat.
	if _rejoin_at_ms > 0 and Time.get_ticks_msec() > _rejoin_at_ms and not CoopLobby.in_lobby():
		_rejoin_at_ms = Time.get_ticks_msec() + 3000
		_say("joining again")
		SteamLobby.join_enet("127.0.0.1", _port())
		return
	# A debrief on screen: read the save and finish (or, the host, wait a moment
	# so the guests' reports are out before the lobby closes).
	var debrief := _find(fe, "DebriefMenu")
	if debrief != null:
		_check_debrief()
		return
	if not CoopLobby.in_lobby() or CoopLobby.in_mission():
		return
	if _is_host_role():
		if CoopLobby.selected < 0 and not CoopLobby.board.is_empty():
			CoopLobby.select_contract(0)
		if CoopLobby.order.size() >= players_needed and CoopLobby.launch_blocker() == "":
			_say("launching with %d players, %d soldiers" % [CoopLobby.order.size(), CoopLobby.squad_size()])
			var err := CoopLobby.launch()
			if err != "":
				_say("launch refused: " + err)
				return
			fe.call("_go_to_mission")
	else:
		var me := CoopLobby.me()
		if not (me.get("pick", {}) as Dictionary).is_empty() and not bool(me.get("ready", false)) 				and Time.get_ticks_msec() - _ready_sent_ms > 1000:
			_ready_sent_ms = Time.get_ticks_msec()
			_say("ready")
			CoopLobby.set_ready(true)


func _port() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--enet-join="):
			var t := arg.trim_prefix("--enet-join=")
			return int(t.substr(t.rfind(":") + 1))
	return SteamLobby.ENET_DEFAULT_PORT


# --- Mission ---------------------------------------------------------------------------


func _in_mission(main: Node) -> void:
	# "The host left" (a guest whose host quit): back to the hub.
	for child in main.get_children():
		if child is AcceptDialog:
			_say("host left the mission")
			child.queue_free()
			main.call("_return_to_menu")
			return
	var loadout := _find(main, "LoadoutMenu")
	if loadout != null:
		_say("deploying")
		loadout.call("_on_deploy")
		return
	if _ended:
		return
	# The host passes the time: out of combat, a round at a time.
	if _is_host_role() and TurnManager.in_exploration() and not TurnManager.mission_over and not CoopLobby.paused \
			and Time.get_ticks_msec() - _last_wait_ms > 1500 and TurnManager.turn_number > 0:
		_last_wait_ms = Time.get_ticks_msec()
		TurnManager.wait_round()


func _on_turn_started(turn: int) -> void:
	var main := get_tree().current_scene
	if main == null or not main.has_method("quit_mission") or _ended:
		return
	_say("round %d (%s)" % [turn, "exploring" if TurnManager.in_exploration() else "combat"])
	if role == "guest-drop" and turn >= 2 and not _dropped:
		_dropped = true
		_say("dropping out mid-mission")
		_rejoin_at_ms = Time.get_ticks_msec() + 2000
		main.call_deferred("quit_mission")
		return
	if role == "host-quit" and turn >= 2:
		_ended = true
		_say("saving and quitting mid-mission (checkpoint at round %d)" % turn)
		main.call_deferred("quit_mission")
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			# Back at the hub with the save reloaded: the mission must be resumable.
			var cp := Campaign.load_checkpoint()
			var snap: Dictionary = cp.get("snapshot", {})
			_finish(Campaign.state != null and Campaign.can_resume() and not snap.is_empty(),
				"quit; checkpoint at round %d, %d unit(s)" % [int((snap.get("turn", {}) as Dictionary).get("number", 0)),
					(snap.get("units", []) as Array).size()]))
		return
	# The plain host pauses everyone for a second in round 3 (the guests must see it).
	if role == "host" and turn == 3 and not _paused_once:
		_paused_once = true
		_say("pausing for everyone")
		CoopLobby.set_paused(true)
		get_tree().create_timer(1.0).timeout.connect(func() -> void: CoopLobby.set_paused(false))
	if _is_host_role() and turn >= end_round:
		_end_mission(main)


## Every guest soldier picks up a valuable (theirs to bank), then everyone standing
## extracts.
func _end_mission(main: Node) -> void:
	_ended = true
	var standing: Array = []
	for child in main.get_children():
		var p := child as PlayerUnit
		if p == null or p.aboard or p.life_state == Unit.LifeState.DEAD:
			continue
		if p.owner_key != CoopPlayers.local_key():
			p.add_item(ItemPresets.from_code("fusion_cell"), true)
		standing.append(p)
	_say("extracting %d soldier(s) at round %d" % [standing.size(), TurnManager.turn_number])
	var result := ExtractionManager.build_result({"extracted": standing, "lost": []})
	TurnManager.end_mission(result)


func _on_unit_activated(unit: Unit) -> void:
	# Turn mode: end this player's own soldiers' activations so the round turns over.
	if unit is PlayerUnit and not TurnManager.in_exploration() and unit.is_owned_by_local_player():
		(unit as PlayerUnit).end_activation.call_deferred()


func _on_mission_ended(result: MissionResult) -> void:
	var main := get_tree().current_scene
	if main == null or not main.has_method("quit_mission"):
		return
	# Abandoned (a host gone, or this player leaving): the dialog / the quit path
	# takes it from here, not Continue.
	if result.outcome == MissionResult.Outcome.ABANDONED:
		return
	_ended = true
	_say("mission over")
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		var m := get_tree().current_scene
		if m != null and m.has_method("_on_continue"):
			m.call("_on_continue"))


func _on_host_gone() -> void:
	if role == "guest-wait":
		_say("host gone — will keep trying to join")
		_rejoin_at_ms = Time.get_ticks_msec() + 3000


# --- The verdict ---------------------------------------------------------------------------


func _check_debrief() -> void:
	if _done:
		return
	var s: CampaignState = Campaign.state
	var d: Dictionary = Campaign.last_debrief
	var ok := s != null and s.away.is_empty() and s.in_mission.is_empty() and s.missions_played >= 1
	var detail := "mission %d | payout %d (of %d, /%d) | sold %d | credits %d | roster %d | away %d | pending reports %s | party %d" % [
		int(d.get("mission", 0)), int(d.get("payout", 0)), int(d.get("payout_total", 0)), int(d.get("payout_divisor", 1)),
		int(d.get("sale_total", 0)), s.credits if s else -1, s.roster.size() if s else -1,
		s.away.size() if s else -1, str(s.pending_reports.keys()) if s else "-", (d.get("party", []) as Array).size()]
	if not _is_host_role():
		ok = ok and int(d.get("sale_total", 0)) >= 200  # the valuable its soldier carried out
	if role == "guest":
		ok = ok and _pauses_seen >= 1  # the host's pause reached this peer
	detail += " | pauses seen %d" % _pauses_seen
	# The partners' soldiers listed: the report was split per player.
	ok = ok and not (d.get("party", []) as Array).is_empty()
	if _is_host_role():
		# The guests' reports must be delivered and acked before the lobby goes.
		_done = true
		_say("debrief: " + detail)
		var wait := func() -> void:
			var t := 0
			while not s.pending_reports.is_empty() and t < 100:
				await get_tree().create_timer(0.1).timeout
				t += 1
			_done = false
			_finish(ok and s.pending_reports.is_empty(), detail + " | owed after wait %s" % str(s.pending_reports.keys()))
		wait.call()
		return
	_finish(ok, detail)


func _finish(ok: bool, detail: String) -> void:
	if _done:
		return
	_done = true
	print("COOPBOT RESULT [%s]: %s — %s" % [role, "OK" if ok else "FAIL", detail])
	get_tree().paused = false
	get_tree().create_timer(0.5).timeout.connect(func() -> void: get_tree().quit(0 if ok else 1))


static func _find(node: Node, cls: String) -> Node:
	for child in node.get_children():
		var script: Script = child.get_script()
		if script != null and script.get_global_name() == cls:
			return child
	return null
