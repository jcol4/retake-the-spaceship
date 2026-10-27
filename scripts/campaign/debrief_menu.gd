class_name DebriefMenu
extends CanvasLayer
## The Debrief (GDD §7.1 step 6, extraction plan 4.2): what the last mission was
## worth, read off the summary CampaignState.apply_report returned — who came home
## and how, what sold for what, what went into the stash, the payout, and the
## money before and after. Code-built like the other overlays.
##
## Display only. The accounting happened when the mission ended (ironman — see
## Campaign.book_result); this screen cannot change it. On a co-op client it shows
## the summary the host sent, since the client owns no campaign (A7).

signal closed

const _OUTCOME_TEXT := {
	MissionResult.Outcome.EXTRACTED: "Extracted",
	MissionResult.Outcome.WIPED: "Squad lost",
	MissionResult.Outcome.ABANDONED: "Abandoned",
	MissionResult.Outcome.CLEARED: "Deck cleared",
}

const _FATE_COLOR := {
	CampaignState.FATE_SURVIVED: Color(0.7, 1.0, 0.7),
	CampaignState.FATE_RECOVERED: Color(1.0, 0.85, 0.5),
	CampaignState.FATE_LOST: Color(1.0, 0.5, 0.45),
}


## `client`: the co-op client's copy — the button says so, and the hub is not
## next (the client waits for the host's next deployment instead).
func setup(summary: Dictionary, client: bool = false) -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	outer.custom_minimum_size = Vector2(640, 0)
	panel.add_child(outer)

	var title := Label.new()
	title.text = "Debrief — Mission %d" % int(summary.get("mission", 0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 420)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	if summary.is_empty():
		vbox.add_child(_line("Waiting for the host's debrief..."))
	else:
		_fill(vbox, summary)

	var button := Button.new()
	if client:
		button.text = "OK"
	elif summary.get("game_over", false):
		button.text = "Continue"
	else:
		button.text = "Continue to hub"
	button.pressed.connect(func() -> void:
		closed.emit()
		queue_free())
	outer.add_child(button)


func _fill(vbox: VBoxContainer, summary: Dictionary) -> void:
	vbox.add_child(_heading(_OUTCOME_TEXT.get(int(summary.get("outcome", 0)), "Mission over")))
	var contract := String(summary.get("contract", ""))
	if contract != "":
		var paid := int(summary.get("payout", 0))
		vbox.add_child(_line("%s — %s" % [contract,
			"complete, paid %d cr" % paid if paid > 0
			else ("complete, but nobody extracted to collect" if summary.get("objective_complete", false)
			else "not complete — no payout")]))
	else:
		vbox.add_child(_line("No contract"))

	vbox.add_child(_heading("Squad"))
	for s: Dictionary in summary.get("soldiers", []):
		var l := _line("%s (%s): %s" % [s.get("name", "?"), s.get("class", "?"), s.get("detail", "")])
		l.modulate = _FATE_COLOR.get(String(s.get("fate", "")), Color.WHITE)
		vbox.add_child(l)

	var sold: Array = summary.get("sold", [])
	vbox.add_child(_heading("Sold — %d cr" % int(summary.get("sale_total", 0))))
	if sold.is_empty():
		vbox.add_child(_line("Nothing to sell."))
	for item: Dictionary in sold:
		vbox.add_child(_line("%s   +%d cr" % [item.get("name", "?"), int(item.get("value", 0))]))

	var gear: Array = summary.get("gear", [])
	if not gear.is_empty():
		vbox.add_child(_heading("Gear"))
		for g in gear:
			vbox.add_child(_line(String(g)))

	for n in summary.get("notes", []):
		var note := _line(String(n))
		note.modulate = Color(1.0, 0.8, 0.5)
		vbox.add_child(note)

	vbox.add_child(_heading("Credits: %d -> %d" % [int(summary.get("credits_before", 0)), int(summary.get("credits_after", 0))]))
	if summary.get("game_over", false):
		var over := _heading("Not enough soldiers left to field a squad, and not enough credits to hire one. The campaign is over.")
		over.modulate = Color(1.0, 0.5, 0.45)
		vbox.add_child(over)


func _heading(text: String) -> Label:
	var label := _line(text)
	label.add_theme_font_size_override("font_size", 20)
	return label


func _line(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
