class_name HubMenu
extends CanvasLayer
## The campaign hub (extraction plan 4.2, GDD §7.1 step 1 and §7.5): the screen
## between missions, on the host (or solo). Built entirely in code, like
## LoadoutMenu and HostJoinMenu — its rows ARE the campaign's data, rebuilt after
## every action.
##
## Tabs:
##   Roster     every soldier: stats, loadout, record, injuries (treat with a medkit)
##   Recruit    this visit's 2–4 candidates, priced by roll quality
##   Stash/Shop owned copies; buy attachments, ammo unlocks, grenades, medkits
##   Contracts  the board of 3: type, deck size, payout — pick one
##   Deploy     choose 2–4 soldiers and their grenades, then Launch
##   Co-op      host or join a party (CoopPanel)
##
## IN A CO-OP LOBBY (MULTIPLAYER_PLAN.md §3) the hub is still this player's own
## save, every tab of it, while the party gets ready: Contracts shows the HOST's
## board (guests vote, the host selects), and Deploy picks this player's 1–2
## soldiers and grenades, sent to the lobby as they change, then Ready (guests) or
## Launch (the host, once everyone is ready). Soldiers away on a co-op mission
## whose report has not come back are marked on the Roster, with Write off.
##
## Every action goes through the Campaign autoload, which saves after it (ironman:
## nothing done here can be taken back by quitting). A refused action shows its
## reason in the status line. If an action leaves the campaign unable to field a
## squad (CampaignState.is_game_over), `game_over` fires instead of a refresh.

signal launched
signal quit_requested
signal game_over
## A write-off was booked; the front end shows its debrief.
signal debrief_ready

const TAB_ROSTER := 0
const TAB_RECRUIT := 1
const TAB_SHOP := 2
const TAB_CONTRACTS := 3
const TAB_DEPLOY := 4
const TAB_COOP := 5

var _tabs: TabContainer
var _header: Label
var _status: Label
## Deploy tab state, kept across rebuilds: the chosen soldiers (record ids, in
## roster order), each one's grenade allotment, and the chosen contract.
var _selected: Array[String] = []
var _grenades: Dictionary = {}
var _offer_index := -1
## The Co-op tab: built once and kept across rebuilds (a half-typed chat line must
## survive the table changing under it).
var _coop_scroll: ScrollContainer = null
## A Write off asked for once and waiting for its confirming click (mission id).
var _write_off_armed := ""


func setup() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Opaque: the hub is its own screen, not an overlay on a deck.
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	root.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var top := HBoxContainer.new()
	vbox.add_child(top)
	var title := Label.new()
	title.text = "Hub"
	title.add_theme_font_size_override("font_size", 28)
	top.add_child(title)
	_header = Label.new()
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_header.add_theme_font_size_override("font_size", 18)
	top.add_child(_header)
	var quit := Button.new()
	quit.text = "Save & quit to title"
	quit.pressed.connect(func() -> void: quit_requested.emit())
	top.add_child(quit)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tabs)

	_status = Label.new()
	_status.modulate = Color(1.0, 0.8, 0.5)
	vbox.add_child(_status)

	var coop := CoopPanel.new()
	coop.status.connect(func(text: String) -> void: _status.text = text)
	_coop_scroll = ScrollContainer.new()
	_coop_scroll.name = "Co-op"
	_coop_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_coop_scroll.add_child(coop)
	coop.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_default_squad()
	CoopLobby.table_changed.connect(_on_table_changed)
	SteamLobby.lobby_ready.connect(_on_lobby_ready)
	_rebuild()
	if CoopLobby.in_lobby():
		_send_pick()


## The squad the Deploy tab opens on: the first soldiers who are home, healthy
## ones first — up to a solo squad, or this player's co-op share in a lobby.
func _default_squad() -> void:
	_selected.clear()
	var by_health := Campaign.state.available_roster()
	by_health.sort_custom(func(a: SoldierRecord, b: SoldierRecord) -> bool:
		return a.injuries.size() < b.injuries.size())
	for r: SoldierRecord in by_health:
		if _selected.size() < _max_pick():
			_selected.append(r.id)
	_reallot_grenades()


## How many soldiers this player may pick: a solo squad, or a co-op share.
func _max_pick() -> int:
	return CampaignEconomy.COOP_MAX_PER_PLAYER if CoopLobby.in_lobby() else CampaignEconomy.MAX_SQUAD


func _on_lobby_ready(_lobby_id: int) -> void:
	# Into a lobby: this player's share is 1–2, whatever the solo squad was.
	while _selected.size() > _max_pick():
		_selected.pop_back()
	_reallot_grenades()
	_send_pick()
	_rebuild.call_deferred()


func _on_table_changed() -> void:
	if not is_inside_tree():
		return
	# Out of the lobby (left, kicked, host gone): back to a solo squad.
	if not CoopLobby.in_lobby() and _selected.size() < CampaignEconomy.MIN_SQUAD:
		_default_squad()
	# The party is back from a mission (picks cleared), or this player's row is
	# new: send their pick again — deferred, and only a valid one, so answering the
	# table never feeds straight back into it.
	if CoopLobby.in_lobby() and not CoopLobby.in_mission() and not CoopLobby.me().is_empty() \
			and (CoopLobby.me().get("pick", {}) as Dictionary).is_empty() \
			and Campaign.state.pick_blocker(_squad_ids()) == "":
		_send_pick.call_deferred()
	_rebuild.call_deferred()


## Tells the lobby what this player is bringing (their pick package, clamped to
## their own stash and stock) and shows the party their roster.
func _send_pick() -> void:
	if not CoopLobby.in_lobby() or Campaign.state == null:
		return
	var s: CampaignState = Campaign.state
	var ids := _squad_ids()
	var counts: Array = []
	for id in ids:
		counts.append(int(_grenades.get(id, 0)))
	var pick: Dictionary = s.make_pick(ids, counts) if s.pick_blocker(ids) == "" else {}
	var roster: Array = []
	for r in s.roster:
		var d := r.to_dict()
		d["away"] = s.is_away(r.id)
		roster.append(d)
	CoopLobby.set_pick(pick, roster)


## Rebuilds every tab from the campaign's current state, keeping the open tab.
func _rebuild() -> void:
	if Campaign.state == null:
		return
	var current := _tabs.current_tab if _tabs.get_tab_count() > 0 else TAB_ROSTER
	for child in _tabs.get_children():
		_tabs.remove_child(child)
		if child != _coop_scroll:
			child.queue_free()
	var s: CampaignState = Campaign.state
	# Drop any selected soldier who is no longer on the roster, or is away.
	_selected.assign(_selected.filter(func(id: String) -> bool: return s.record(id) != null and not s.is_away(id)))
	_header.text = "Mission %d   |   Credits: %d   |   Medkits: %d   |   Grenades: %d   |   Roster: %d/%d%s" % [
		s.missions_played + 1, s.credits, s.medical, s.grenades, s.roster.size(),
		CampaignEconomy.MAX_ROSTER, _coop_text()]
	_add_tab("Roster", _build_roster())
	_add_tab("Recruit", _build_recruit())
	_add_tab("Stash / Shop", _build_shop())
	_add_tab("Contracts", _build_contracts())
	_add_tab("Deploy", _build_deploy())
	_tabs.add_child(_coop_scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "Co-op")
	_tabs.current_tab = clampi(current, 0, _tabs.get_tab_count() - 1)


func _coop_text() -> String:
	if not CoopLobby.in_lobby():
		return ""
	return "   |   Party: %d player(s)%s" % [CoopLobby.order.size(), ", on a mission" if CoopLobby.in_mission() else ""]


func _add_tab(tab_title: String, content: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title.replace("/", "-")
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(content)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, tab_title)  # a node name cannot hold "/"


## Applies a hub action's result: shows a refusal, or refreshes — or, if the
## campaign can no longer field a squad, ends it.
func _after(err: String, done: String = "") -> void:
	_status.text = err if err != "" else done
	if Campaign.state.is_game_over():
		Campaign.wipe()
		game_over.emit()
		return
	# The party sees this player's roster and pick as they change.
	_send_pick()
	# Deferred: this runs inside the pressed/toggled signal of a control the
	# rebuild is about to free.
	_rebuild.call_deferred()


# --- Roster -----------------------------------------------------------------------


func _build_roster() -> Control:
	var list := _list()
	var s: CampaignState = Campaign.state
	# Co-op missions this save's soldiers have not come back from (MULTIPLAYER_PLAN.md).
	for e: Dictionary in s.away:
		var names := PackedStringArray()
		for d: Dictionary in e.get("records", []):
			names.append(String(d.get("name", "?")))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var info := Label.new()
		info.text = "Deployed with %s: %s. They're back when %s's mission ends (rejoin it from the Co-op tab), or write them off." % [
			String(e.get("host_name", "another crew")), ", ".join(names), String(e.get("host_name", "the host"))]
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.modulate = Color(0.75, 0.85, 1.0)
		row.add_child(info)
		var mission_id := String(e.get("mission_id", ""))
		var off := Button.new()
		off.text = "Confirm: they're lost" if _write_off_armed == mission_id else "Write off"
		off.pressed.connect(func() -> void:
			if _write_off_armed != mission_id:
				_write_off_armed = mission_id
				_after("", "Writing them off books them as lost, with their kit. Click again to confirm.")
				return
			_write_off_armed = ""
			if Campaign.write_off(mission_id).is_empty():
				_after("Nothing to write off")
				return
			Campaign.debrief_unseen = true
			debrief_ready.emit())
		row.add_child(off)
		list.add_child(row)
		list.add_child(HSeparator.new())
	for r in s.roster:
		var block := VBoxContainer.new()
		block.add_child(_name_row(r))
		if s.is_away(r.id):
			var away := _dim_label("Deployed with %s" % String(s.away_entry_of(r.id).get("host_name", "another crew")))
			away.modulate = Color(0.75, 0.85, 1.0)
			block.add_child(away)
		block.add_child(_dim_label(r.stats_text()))
		block.add_child(_dim_label("Loadout: %s" % r.loadout_text()))
		var injuries := HBoxContainer.new()
		injuries.add_theme_constant_override("separation", 8)
		var inj_label := Label.new()
		inj_label.text = "Injuries: %s" % r.injury_text()
		if r.is_injured():
			inj_label.modulate = Color(1.0, 0.55, 0.5)
		injuries.add_child(inj_label)
		for part in r.injuries:
			var treat := Button.new()
			treat.text = "Treat %s (%d medkit)" % [Combat.body_part_name(part), CampaignEconomy.MEDICAL_PER_INJURY]
			treat.disabled = s.medical < CampaignEconomy.MEDICAL_PER_INJURY or s.is_away(r.id)
			var id := r.id
			var p: int = part
			treat.pressed.connect(func() -> void:
				_after(Campaign.treat(id, p), "Treated."))
			injuries.add_child(treat)
		block.add_child(injuries)
		list.add_child(block)
		list.add_child(HSeparator.new())
	return list


## The soldier's name as an editable field (Enter or the Rename button commits),
## then class and record. A refused name puts the old one back in the field.
func _name_row(r: SoldierRecord) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var field := LineEdit.new()
	field.text = r.display_name
	field.max_length = CampaignState.MAX_NAME_LENGTH
	field.placeholder_text = "Name"
	field.custom_minimum_size = Vector2(220, 0)
	field.add_theme_font_size_override("font_size", 18)
	field.select_all_on_focus = true
	row.add_child(field)
	var rename := Button.new()
	rename.text = "Rename"
	row.add_child(rename)
	var info := Label.new()
	info.text = "— %s — %d mission(s) survived" % [r.class_name_text(), r.missions_survived]
	info.add_theme_font_size_override("font_size", 18)
	row.add_child(info)
	var id := r.id
	var old_name := r.display_name
	var commit := func(_t: String = "") -> void:
		if field.text.strip_edges() == old_name:
			return
		var err := Campaign.rename(id, field.text)
		if err != "":
			field.text = old_name
		_after(err, "Renamed %s to %s." % [old_name, Campaign.state.record(id).display_name] if err == "" else "")
	field.text_submitted.connect(commit)
	rename.pressed.connect(commit)
	return row


# --- Recruit ----------------------------------------------------------------------


func _build_recruit() -> Control:
	var list := _list()
	var s: CampaignState = Campaign.state
	list.add_child(_dim_label("Candidates this visit. The board is re-rolled after each mission. Price rises with how well each rolled within their class."))
	if s.recruits.is_empty():
		list.add_child(_dim_label("Nobody left on the board this visit."))
	for i in s.recruits.size():
		var r: SoldierRecord = s.recruits[i]["record"]
		var price: int = s.recruits[i]["price"]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var info := Label.new()
		info.text = "%s — %s\n%s" % [r.display_name, r.class_name_text(), r.stats_text()]
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var hire := Button.new()
		hire.text = "Hire — %d cr" % price
		hire.disabled = s.credits < price or s.roster.size() >= CampaignEconomy.MAX_ROSTER
		var index := i
		hire.pressed.connect(func() -> void:
			_after(Campaign.hire(index), "Hired."))
		row.add_child(hire)
		list.add_child(row)
		list.add_child(HSeparator.new())
	return list


# --- Stash / Shop -----------------------------------------------------------------


func _build_shop() -> Control:
	var list := _list()
	var s: CampaignState = Campaign.state

	list.add_child(_heading("Stash"))
	var owned := PackedStringArray()
	for id in AttachmentPresets.DATA:
		if s.attachment_count(id) > 0:
			owned.append("%s x%d" % [AttachmentPresets.DATA[id]["display_name"], s.attachment_count(id)])
	list.add_child(_dim_label("Attachments: %s" % (", ".join(owned) if not owned.is_empty() else "none")))
	var ammo_names := PackedStringArray()
	for a in s.unlocked_ammo:
		ammo_names.append(AmmoPresets.DATA[a]["display_name"])
	list.add_child(_dim_label("Ammo unlocked: %s" % ", ".join(ammo_names)))
	list.add_child(_dim_label("Grenades: %d   Medkits: %d   (copies fitted to a soldier stay yours unless that soldier is lost)" % [s.grenades, s.medical]))

	list.add_child(_heading("Consumables"))
	list.add_child(_shop_row("Grenade — EMP or Frag, up to %d per soldier; unthrown ones come home" % CampaignEconomy.GRENADES_PER_SOLDIER,
		"Buy — %d cr" % CampaignEconomy.GRENADE_PRICE, s.credits < CampaignEconomy.GRENADE_PRICE,
		func() -> void: _after(Campaign.buy_grenade(), "Bought a grenade.")))
	list.add_child(_shop_row("Medkit — treats one injured body part between missions",
		"Buy — %d cr" % CampaignEconomy.MEDICAL_PRICE, s.credits < CampaignEconomy.MEDICAL_PRICE,
		func() -> void: _after(Campaign.buy_medical(), "Bought a medkit.")))

	list.add_child(_heading("Attachments (one copy fits one soldier at a time)"))
	for id in AttachmentPresets.DATA:
		var d: Dictionary = AttachmentPresets.DATA[id]
		var price := CampaignEconomy.attachment_price(id)
		var aid: int = id
		list.add_child(_shop_row("%s (%s) — %s — owned %d" % [d["display_name"],
			String(AttachmentData.Slot.keys()[d["slot"]]).capitalize(), AttachmentPresets.describe(id),
			s.attachment_count(id)], "Buy — %d cr" % price, s.credits < price,
			func() -> void: _after(Campaign.buy_attachment(aid), "Bought %s." % d["display_name"])))

	list.add_child(_heading("Ammo (an unlock fits every gun it suits, for good)"))
	for id in AmmoPresets.DATA:
		if id == AmmoPresets.AmmoId.STANDARD:
			continue
		var d: Dictionary = AmmoPresets.DATA[id]
		var price := CampaignEconomy.ammo_price(id)
		var unlocked := s.unlocked_ammo.has(id)
		var ammo_id: int = id
		list.add_child(_shop_row("%s — %s" % [d["display_name"], AmmoPresets.describe(id)],
			"Unlocked" if unlocked else "Unlock — %d cr" % price, unlocked or s.credits < price,
			func() -> void: _after(Campaign.buy_ammo(ammo_id), "Unlocked %s." % d["display_name"])))
	return list


func _shop_row(text: String, button_text: String, disabled: bool, on_press: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	var button := Button.new()
	button.text = button_text
	button.disabled = disabled
	button.custom_minimum_size = Vector2(150, 0)
	button.pressed.connect(on_press)
	row.add_child(button)
	return row


# --- Contracts --------------------------------------------------------------------


func _build_contracts() -> Control:
	if CoopLobby.in_lobby():
		return _build_coop_contracts()
	var list := _list()
	var s: CampaignState = Campaign.state
	list.add_child(_dim_label("The objective is optional and pays only if someone extracts with it done. The board is re-rolled after each mission."))
	_map_gen_option(list)
	for i in s.contracts.size():
		var offer: ContractOffer = s.contracts[i]
		var index := i
		list.add_child(_shop_row(offer.describe(), "Selected" if i == _offer_index else "Select",
			i == _offer_index, func() -> void:
				_offer_index = index
				_after("", "Contract selected — see Deploy.")))
	return list


## In a lobby the party plays the HOST's board: guests vote (advisory), the host
## selects. Payouts shown scaled for the squad as currently picked.
func _build_coop_contracts() -> Control:
	var list := _list()
	var host := CoopLobby.is_host()
	_map_gen_option(list, not host)
	var scale := CampaignEconomy.squad_scale(CoopLobby.squad_size())
	list.add_child(_dim_label("The host's contract board. %s The payout is split evenly between every player, and it scales up when the squad is bigger than four." % (
		"Your party votes; you choose." if host else "Vote for the one you want; the host chooses.")))
	var my_vote := int(CoopLobby.me().get("vote", -1))
	for i in CoopLobby.board.size():
		var offer := ContractOffer.from_dict(CoopLobby.board[i])
		var index := i
		var votes := CoopLobby.votes_for(i)
		var text := offer.describe()
		if scale > 1.0:
			text += " (x%.1f for this squad: %d cr)" % [scale, CampaignEconomy.scaled_payout(offer.payout, scale)]
		text += "   —   %d vote(s)%s" % [votes, "   [selected by the host]" if i == CoopLobby.selected else ""]
		if host:
			list.add_child(_shop_row(text, "Selected" if i == CoopLobby.selected else "Select",
				i == CoopLobby.selected or CoopLobby.in_mission(), func() -> void:
					CoopLobby.select_contract(index)
					_after("", "Contract selected — see Deploy.")))
		else:
			list.add_child(_shop_row(text, "Your vote" if i == my_vote else "Vote",
				i == my_vote or CoopLobby.in_mission(), func() -> void:
					CoopLobby.vote(index)
					_after("", "Voted.")))
	return list


func _map_gen_option(list: Control, guest := false) -> void:
	var check := CheckBox.new()
	check.name = "MapGen"
	check.text = "Map gen"
	check.tooltip_text = "Checked: procedural maps. Unchecked: authored plots and parcels (experimental). Changing this refreshes the contract board."
	check.button_pressed = Campaign.state.map_gen
	if guest and not CoopLobby.board.is_empty():
		check.button_pressed = int(CoopLobby.board[0].get("deck_source", MapGenerator.DeckSource.GENERATED)) == MapGenerator.DeckSource.GENERATED
	check.disabled = guest or (CoopLobby.in_lobby() and CoopLobby.in_mission())
	check.toggled.connect(_on_map_gen_toggled)
	list.add_child(check)
	list.add_child(_dim_label("Procedural maps" if check.button_pressed else "Authored plots / parcels (experimental; available authored decks only)"))


func _on_map_gen_toggled(enabled: bool) -> void:
	var err := Campaign.set_map_gen(enabled)
	if err == "": _offer_index = -1
	_after(err, "Contract board refreshed. Choose a contract.")


# --- Deploy -----------------------------------------------------------------------


func _build_deploy() -> Control:
	if CoopLobby.in_lobby():
		return _build_coop_deploy()
	var list := _list()
	var s: CampaignState = Campaign.state
	list.add_child(_heading("Contract"))
	if _offer_index >= 0 and _offer_index < s.contracts.size():
		list.add_child(_dim_label(s.contracts[_offer_index].describe()))
	else:
		list.add_child(_dim_label("None chosen — pick one on the Contracts tab."))

	list.add_child(_heading("Squad (%d–%d)   —   grenades in stock: %d" % [
		CampaignEconomy.MIN_SQUAD, CampaignEconomy.MAX_SQUAD, s.grenades]))
	list.add_child(_squad_picker(s))

	var launch := Button.new()
	launch.text = "Launch mission"
	launch.custom_minimum_size = Vector2(220, 44)
	var blocker := s.deploy_blocker(_squad_ids(), _offer_index)
	launch.disabled = blocker != ""
	if blocker != "":
		list.add_child(_dim_label(blocker))
	launch.pressed.connect(_on_launch)
	list.add_child(launch)
	return list


## The roster as checkboxes with grenade spinners: who goes, and with what. Away
## soldiers are listed but cannot be picked. Capped at `_max_pick`.
func _squad_picker(s: CampaignState) -> Control:
	var list := _list()
	for r in s.roster:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var check := CheckBox.new()
		check.text = "%s — %s%s" % [r.display_name, r.class_name_text(),
			"   (injured: %s)" % r.injury_text() if r.is_injured() else ""]
		check.button_pressed = _selected.has(r.id)
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if s.is_away(r.id):
			check.disabled = true
			check.text += "   (deployed with %s)" % String(s.away_entry_of(r.id).get("host_name", "another crew"))
		var id := r.id
		check.toggled.connect(func(on: bool) -> void:
			if on and not _selected.has(id):
				if _selected.size() >= _max_pick():
					_after("You can bring at most %d" % _max_pick())
					return
				_selected.append(id)
			elif not on:
				_selected.erase(id)
			_reallot_grenades()
			_after(""))
		row.add_child(check)
		if _selected.has(r.id):
			var label := Label.new()
			label.text = "Grenades"
			row.add_child(label)
			var spin := SpinBox.new()
			spin.min_value = 0
			spin.max_value = CampaignEconomy.GRENADES_PER_SOLDIER
			spin.value = _grenades.get(r.id, 0)
			spin.value_changed.connect(func(v: float) -> void:
				var others := _grenade_total() - int(_grenades.get(id, 0))
				_grenades[id] = clampi(int(v), 0, maxi(0, s.grenades - others))
				_after(""))
			row.add_child(spin)
		list.add_child(row)
	return list


## Deploy in a co-op lobby: this player's 1–2 soldiers and their grenades, the
## party's picks, then Ready (a guest) or Launch (the host).
func _build_coop_deploy() -> Control:
	var list := _list()
	var s: CampaignState = Campaign.state
	if CoopLobby.in_mission():
		list.add_child(_heading("The party is on a mission"))
		list.add_child(_dim_label("You're in on the next one." if not CoopLobby.is_mission_owner(CoopLobby.my_key())
			else "Your soldiers are out with them — rejoin from the Co-op tab."))
		return list
	list.add_child(_heading("Contract"))
	if CoopLobby.selected >= 0 and CoopLobby.selected < CoopLobby.board.size():
		list.add_child(_dim_label(ContractOffer.from_dict(CoopLobby.board[CoopLobby.selected]).describe()))
	else:
		list.add_child(_dim_label("The host hasn't chosen one yet — see Contracts."))

	list.add_child(_heading("Your soldiers (%d–%d)   —   grenades in stock: %d" % [
		CampaignEconomy.COOP_MIN_PER_PLAYER, CampaignEconomy.COOP_MAX_PER_PLAYER, s.grenades]))
	list.add_child(_dim_label("Your soldiers carry your own stash and your own grenades. What they carry out is yours; the contract pays everyone an even share."))
	list.add_child(_squad_picker(s))
	var mine := s.pick_blocker(_squad_ids())
	if mine != "":
		list.add_child(_dim_label(mine))

	list.add_child(_heading("The party (%d soldiers)" % CoopLobby.squad_size()))
	for key in CoopLobby.order:
		var m: Dictionary = CoopLobby.members.get(key, {})
		var names := PackedStringArray()
		for d: Dictionary in (m.get("pick", {}) as Dictionary).get("records", []):
			names.append(CoopPanel.soldier_line(d))
		var who := "%s%s" % [String(m.get("name", "?")), " (host)" if key == CoopLobby.order[0] else ""]
		var ready_text := "" if key == CoopLobby.order[0] else ("   READY" if bool(m.get("ready", false)) else "   not ready")
		var line := _dim_label("%s%s:\n    %s" % [who, ready_text, "\n    ".join(names) if not names.is_empty() else "nobody picked yet"])
		line.modulate = CoopPlayers.color_of_key(String(key)).lerp(Color.WHITE, 0.4)
		list.add_child(line)

	if CoopLobby.is_host():
		var launch := Button.new()
		launch.text = "Launch mission"
		launch.custom_minimum_size = Vector2(220, 44)
		var blocker := CoopLobby.launch_blocker()
		if blocker == "" and mine != "":
			blocker = mine
		launch.disabled = blocker != ""
		if blocker != "":
			list.add_child(_dim_label(blocker))
		launch.pressed.connect(func() -> void:
			var err := CoopLobby.launch()
			if err != "":
				_status.text = err
				return
			launched.emit())
		list.add_child(launch)
	else:
		var is_ready := bool(CoopLobby.me().get("ready", false))
		var button := Button.new()
		button.text = "Unready" if is_ready else "Ready"
		button.custom_minimum_size = Vector2(220, 44)
		button.disabled = mine != "" and not is_ready
		button.pressed.connect(func() -> void:
			CoopLobby.set_ready(not is_ready)
			_after("", "Ready — waiting for the host to launch." if not is_ready else ""))
		list.add_child(button)
	return list


## The selected soldiers in roster order (which is the spawn and ownership order).
func _squad_ids() -> Array:
	var out: Array = []
	for r in Campaign.state.roster:
		if _selected.has(r.id):
			out.append(r.id)
	return out


func _grenade_total() -> int:
	var total := 0
	for id in _squad_ids():
		total += int(_grenades.get(id, 0))
	return total


## Re-deals the default allotment (one each, then a second each, while stock
## lasts) whenever the squad changes.
func _reallot_grenades() -> void:
	var ids := _squad_ids()
	var counts := CampaignState.auto_grenades(ids.size(), Campaign.state.grenades)
	_grenades.clear()
	for i in ids.size():
		_grenades[ids[i]] = counts[i]


func _on_launch() -> void:
	var ids := _squad_ids()
	var counts: Array = []
	for id in ids:
		counts.append(int(_grenades.get(id, 0)))
	var err := Campaign.launch(ids, _offer_index, counts)
	if err != "":
		_status.text = err
		return
	launched.emit()


# --- Helpers ----------------------------------------------------------------------


func _list() -> VBoxContainer:
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	return list


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	return label


func _dim_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = Color(0.8, 0.8, 0.8)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
