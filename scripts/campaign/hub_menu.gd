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
##
## Every action goes through the Campaign autoload, which saves after it (ironman:
## nothing done here can be taken back by quitting). A refused action shows its
## reason in the status line. If an action leaves the campaign unable to field a
## squad (CampaignState.is_game_over), `game_over` fires instead of a refresh.

signal launched
signal quit_requested
signal game_over

const TAB_ROSTER := 0
const TAB_RECRUIT := 1
const TAB_SHOP := 2
const TAB_CONTRACTS := 3
const TAB_DEPLOY := 4

var _tabs: TabContainer
var _header: Label
var _status: Label
## Deploy tab state, kept across rebuilds: the chosen soldiers (record ids, in
## roster order), each one's grenade allotment, and the chosen contract.
var _selected: Array[String] = []
var _grenades: Dictionary = {}
var _offer_index := -1


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

	if SteamLobby.current_lobby_id != 0:
		vbox.add_child(PlayerColorRow.new())

	_status = Label.new()
	_status.modulate = Color(1.0, 0.8, 0.5)
	vbox.add_child(_status)

	# Default squad: the first soldiers on the roster, healthy ones first.
	var by_health := Campaign.state.roster.duplicate()
	by_health.sort_custom(func(a: SoldierRecord, b: SoldierRecord) -> bool:
		return a.injuries.size() < b.injuries.size())
	for r: SoldierRecord in by_health:
		if _selected.size() < CampaignEconomy.MAX_SQUAD:
			_selected.append(r.id)
	_reallot_grenades()
	_rebuild()


## Rebuilds every tab from the campaign's current state, keeping the open tab.
func _rebuild() -> void:
	var current := _tabs.current_tab if _tabs.get_tab_count() > 0 else TAB_ROSTER
	for child in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	var s: CampaignState = Campaign.state
	# Drop any selected soldier who is no longer on the roster.
	_selected.assign(_selected.filter(func(id: String) -> bool: return s.record(id) != null))
	_header.text = "Mission %d   |   Credits: %d   |   Medkits: %d   |   Grenades: %d   |   Roster: %d/%d%s" % [
		s.missions_played + 1, s.credits, s.medical, s.grenades, s.roster.size(),
		CampaignEconomy.MAX_ROSTER, _coop_text()]
	_add_tab("Roster", _build_roster())
	_add_tab("Recruit", _build_recruit())
	_add_tab("Stash / Shop", _build_shop())
	_add_tab("Contracts", _build_contracts())
	_add_tab("Deploy", _build_deploy())
	_tabs.current_tab = clampi(current, 0, _tabs.get_tab_count() - 1)


func _coop_text() -> String:
	if SteamLobby.current_lobby_id == 0:  # in a lobby, not merely holding a peer
		return ""
	return "   |   Squadmate: %s" % ("connected" if not multiplayer.get_peers().is_empty() else "not connected")


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
	# Deferred: this runs inside the pressed/toggled signal of a control the
	# rebuild is about to free.
	_rebuild.call_deferred()


# --- Roster -----------------------------------------------------------------------


func _build_roster() -> Control:
	var list := _list()
	var s: CampaignState = Campaign.state
	for r in s.roster:
		var block := VBoxContainer.new()
		var name_line := Label.new()
		name_line.text = "%s — %s — %d mission(s) survived" % [r.display_name, r.class_name_text(), r.missions_survived]
		name_line.add_theme_font_size_override("font_size", 18)
		block.add_child(name_line)
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
			treat.disabled = s.medical < CampaignEconomy.MEDICAL_PER_INJURY
			var id := r.id
			var p: int = part
			treat.pressed.connect(func() -> void:
				_after(Campaign.treat(id, p), "Treated."))
			injuries.add_child(treat)
		block.add_child(injuries)
		list.add_child(block)
		list.add_child(HSeparator.new())
	return list


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
	var list := _list()
	var s: CampaignState = Campaign.state
	list.add_child(_dim_label("The objective is optional and pays only if someone extracts with it done. The board is re-rolled after each mission."))
	for i in s.contracts.size():
		var offer: ContractOffer = s.contracts[i]
		var index := i
		list.add_child(_shop_row(offer.describe(), "Selected" if i == _offer_index else "Select",
			i == _offer_index, func() -> void:
				_offer_index = index
				_after("", "Contract selected — see Deploy.")))
	return list


# --- Deploy -----------------------------------------------------------------------


func _build_deploy() -> Control:
	var list := _list()
	var s: CampaignState = Campaign.state
	list.add_child(_heading("Contract"))
	if _offer_index >= 0 and _offer_index < s.contracts.size():
		list.add_child(_dim_label(s.contracts[_offer_index].describe()))
	else:
		list.add_child(_dim_label("None chosen — pick one on the Contracts tab."))

	list.add_child(_heading("Squad (%d–%d)   —   grenades in stock: %d" % [
		CampaignEconomy.MIN_SQUAD, CampaignEconomy.MAX_SQUAD, s.grenades]))
	if SteamLobby.current_lobby_id != 0:
		list.add_child(_dim_label("Co-op: the squad is split between the two players in this order, first half to the lower peer id (the host)."))
	for r in s.roster:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var check := CheckBox.new()
		check.text = "%s — %s%s" % [r.display_name, r.class_name_text(),
			"   (injured: %s)" % r.injury_text() if r.is_injured() else ""]
		check.button_pressed = _selected.has(r.id)
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var id := r.id
		check.toggled.connect(func(on: bool) -> void:
			if on and not _selected.has(id):
				if _selected.size() >= CampaignEconomy.MAX_SQUAD:
					_after("A squad is at most %d" % CampaignEconomy.MAX_SQUAD)
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
