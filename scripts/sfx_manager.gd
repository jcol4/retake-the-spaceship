extends Node
## Sound effects. Autoloaded rather than parented into main.tscn the way
## VfxManager is, and that difference is deliberate: VFX only ever happen during
## a mission, but sound is also wanted on the menus that run BEFORE main.tscn
## spawns anything (HostJoinMenu, LoadoutMenu). An autoload is reachable from
## all of them.
##
## Players are pooled and reused. A five-round burst plus a worm swarm can ask
## for thirty sounds inside one frame; allocating an AudioStreamPlayer3D per
## request would both churn nodes and let the master bus clip. MAX_VOICES caps
## it, and the oldest voice is stolen when the pool runs dry — a dropped tail on
## sound 17 is inaudible, a stall or a blown mix is not.

## Positional sounds. Fall off with distance from the camera rig's pivot (see
## CameraRig._make_audio_listener).
const MAX_VOICES := 16

## How far a world sound carries before it is inaudible. Generous, because the
## camera can scroll out to a whole 30x16 deck and gunfire across that deck
## should still register — this is a tactics game where offscreen contact is
## information, not a shooter where it is noise.
const UNIT_SIZE := 18.0
const MAX_DISTANCE := 60.0

## Flat mix trim applied to every voice, as a linear amplitude fraction — 0.5 is
## half volume at every distance, since it scales the player's output rather
## than touching the attenuation curve above.
##
## Deliberately NOT the SFX bus and NOT GameSettings.sfx_volume. Setting it on
## the bus would be silently undone: GameSettings._apply_audio() writes
## linear_to_db(sfx_volume) over the SFX bus on every boot, so anything stored
## in default_bus_layout.tres lasts until the first frame. And sfx_volume is the
## PLAYER's slider — trimming there would mean a slider at 100% is really 50%,
## and the player would have no way back up to full. This is the source mix:
## where the sample sits before the player gets a say.
const MIX_LEVEL := 0.5

## Keyed lookup so call sites say what happened, not which file to open. A key
## with no stream loaded is a no-op, which is what lets sounds be wired up
## before the art for them exists — `Sfx.play("rifle_fire", pos)` is safe to
## commit the day before the sample lands.
##
## One `<weapon>_fire` key per roster weapon — WeaponPresets.FIRE_SFX maps the
## weapon to its key, and `rifle_fire` is what anything off the roster (aliens,
## the door gun) keeps firing. Every gunfire sample is a whole BURST, played once
## per trigger pull (see Unit._on_muzzle), and every one is the "Isolated" take
## from Snake's Authentic Gun Sounds: the pack's "Full Sound" takes carry the
## outdoor range's echo, which is wrong inside a ship's hull.
const STREAMS := {
	"rifle_fire": "res://assets/audio/sfx/weapons/rifle_fire.tres",
	"ar_fire": "res://assets/audio/sfx/weapons/ar_fire.tres",
	"smg_fire": "res://assets/audio/sfx/weapons/smg_fire.tres",
	"lmg_fire": "res://assets/audio/sfx/weapons/lmg_fire.tres",
	"battle_rifle_fire": "res://assets/audio/sfx/weapons/battle_rifle_fire.tres",
	"shotgun_fire": "res://assets/audio/sfx/weapons/shotgun_fire.tres",
	"pistol_fire": "res://assets/audio/sfx/weapons/pistol_fire.tres",
	# Footsteps (Unit.footstep_sfx): boots for anyone in boots, a heavier clank
	# for the security robots.
	"step_boots_metal": "res://assets/audio/sfx/footsteps/step_boots_metal.tres",
	"step_heavy_metal": "res://assets/audio/sfx/footsteps/step_heavy_metal.tres",
}

## Per-key trim in dB, on top of MIX_LEVEL. Missing means 0. Footsteps sit well
## under gunfire: a squad crossing a room is three steps a second per soldier,
## and at gunfire level that is a drum line, not a texture.
const TRIM_DB := {
	"step_boots_metal": -10.0,
	"step_heavy_metal": -8.0,
}

## Keys that only play on a FREE voice and never steal one. Footsteps are
## constant and individually forgettable; a step that stole the voice a burst
## was still ringing on would cut real information short to say nothing.
const LOW_PRIORITY := {
	"step_boots_metal": true,
	"step_heavy_metal": true,
}

## Interface feedback: the clunk a press makes. Flat (no position) — it is the
## player's own hand on the console, not something happening on the deck.
##
## Deliberately QUIET: this is a subconscious "got it", not an event. It should
## sit far under gunfire and footsteps, so that a player who was asked "is there
## a click sound?" would have to stop and listen. UI_LEVEL_DB is the one knob for
## the whole family; the per-kind entries below are trims relative to it.
const UI_LEVEL_DB := -22.0

## kind -> [stream path, trim dB, pitch]. "cancel" is the confirm clunk pitched
## down, so going back sounds like the same switch thrown the other way rather
## than a different device. "denied" (a disabled button, an order the click can
## already tell is illegal) is a dull thud, trimmed because it is the
## denser sample.
const UI_KINDS := {
	&"confirm": ["res://assets/audio/sfx/ui/ui_confirm.ogg", 0.0, 1.0],
	&"cancel": ["res://assets/audio/sfx/ui/ui_confirm.ogg", 0.0, 0.8],
	&"denied": ["res://assets/audio/sfx/ui/ui_denied.ogg", -5.0, 1.0],
}

## A press often reaches more than one hook in the same instant (a Back button
## that also closes a panel whose close is wired, a click both a HUD button and
## an order). One press, one clunk: anything inside this window is swallowed.
const UI_DEBOUNCE_MS := 40

## Buttons whose text or node name reads as backing out play "cancel" rather
## than "confirm". A button can say otherwise with `set_meta(&"ui_sfx", kind)`,
## where kind is any UI_KINDS key or &"none" to stay silent. Whole words only
## ("Backpack" is not "Back"). "Resume" is NOT here: on the front end it means
## "carry on into the mission", so the pause menu tags its own Resume instead.
const UI_CANCEL_PATTERN := "\\b(back|cancel|close|leave|quit|exit|abort)\\b"

const UI_VOICES := 4

var _voices: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _loaded: Dictionary = {}
var _ui_voices: Array[AudioStreamPlayer] = []
var _ui_next := 0
var _ui_streams: Dictionary = {}
var _ui_last_ms := -1000
var _ui_cancel_re := RegEx.create_from_string(UI_CANCEL_PATTERN)


func _ready() -> void:
	for i in MAX_VOICES:
		var player := AudioStreamPlayer3D.new()
		player.bus = &"SFX"
		player.unit_size = UNIT_SIZE
		player.max_distance = MAX_DISTANCE
		player.volume_db = linear_to_db(MIX_LEVEL)
		add_child(player)
		_voices.append(player)
	_preload_streams()
	for i in UI_VOICES:
		var player := AudioStreamPlayer.new()
		# The UI bus, so the "Interface" volume slider (GameSettings.ui_volume)
		# turns the clicks down or off without touching gunfire.
		player.bus = GameSettings.BUS_UI
		# The solo pause menu pauses the tree; its own Resume/Leave must still click.
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(player)
		_ui_voices.append(player)
	for kind: StringName in UI_KINDS:
		var path: String = UI_KINDS[kind][0]
		if ResourceLoader.exists(path):
			_ui_streams[kind] = load(path)
		else:
			push_warning("UI SFX '%s' has no file at %s — calls will be silent" % [kind, path])
	# Every button in the game gets its clunk here rather than at each call site:
	# menus build buttons in code all over the place, and a hook per `pressed`
	# would be forgotten on the next one. Autoloads are in the tree before the
	# main scene, so node_added sees every button that will ever exist.
	get_tree().node_added.connect(_on_node_added)


## The press feedback sound. `kind` is a UI_KINDS key.
func ui(kind: StringName = &"confirm") -> void:
	var stream: AudioStream = _ui_streams.get(kind)
	if stream == null:
		return
	var now := Time.get_ticks_msec()
	if now - _ui_last_ms < UI_DEBOUNCE_MS:
		return
	_ui_last_ms = now
	var voice := _ui_voices[_ui_next]
	_ui_next = (_ui_next + 1) % _ui_voices.size()
	voice.stream = stream
	voice.volume_db = UI_LEVEL_DB + float(UI_KINDS[kind][1])
	voice.pitch_scale = UI_KINDS[kind][2]
	voice.play()


func _on_node_added(node: Node) -> void:
	# Reparenting re-fires node_added; connecting twice would error (and clunk twice).
	if node.has_meta(&"_ui_sfx_hooked"):
		return
	if node is BaseButton or node is PopupMenu:
		node.set_meta(&"_ui_sfx_hooked", true)
	if node is BaseButton:
		var button := node as BaseButton
		button.pressed.connect(_on_button_pressed.bind(button))
		button.gui_input.connect(_on_button_gui_input.bind(button))
	elif node is PopupMenu:
		(node as PopupMenu).index_pressed.connect(func(_i: int) -> void: ui(&"confirm"))


func _on_button_pressed(button: BaseButton) -> void:
	var kind := _ui_kind_for(button)
	if kind != &"none":
		ui(kind)


## `pressed` never fires on a disabled button, which is exactly when a player
## most needs to hear that the click landed and was refused.
func _on_button_gui_input(event: InputEvent, button: BaseButton) -> void:
	if not button.disabled:
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
			and _ui_kind_for(button) != &"none":
		ui(&"denied")


func _ui_kind_for(button: BaseButton) -> StringName:
	if button.has_meta(&"ui_sfx"):
		return button.get_meta(&"ui_sfx")
	# Node names are PascalCase/snake_case ("GrenadeCancel", "settings_close"),
	# so split them into words before the whole-word match.
	var label := String(button.name).to_snake_case().replace("_", " ")
	if button is Button:
		label += " " + (button as Button).text
	return &"cancel" if _ui_cancel_re.search(label.to_lower()) != null else &"confirm"


## Loads what exists and quietly skips what doesn't, so a missing sample is a
## silent effect rather than a crash on mission start. The warning is worth
## keeping: a typo'd path and a sound not yet recorded look identical at the
## call site, and only one of them is intentional.
func _preload_streams() -> void:
	for key: String in STREAMS:
		var path: String = STREAMS[key]
		if not ResourceLoader.exists(path):
			push_warning("SFX '%s' has no file at %s — calls will be silent" % [key, path])
			continue
		_loaded[key] = load(path)


## A world sound at a point on the deck — gunfire, footsteps, a worm.
func play(key: String, at: Vector3, pitch_scale: float = 1.0) -> void:
	var stream: AudioStream = _loaded.get(key)
	if stream == null:
		return
	var voice := _take_voice(not LOW_PRIORITY.has(key))
	if voice == null:
		return
	voice.stream = stream
	voice.pitch_scale = pitch_scale
	voice.volume_db = linear_to_db(MIX_LEVEL) + TRIM_DB.get(key, 0.0)
	voice.global_position = at
	voice.play()


## Round-robin with voice stealing. Prefers a player that has finished over one
## still sounding, so a quiet moment never interrupts anything; only genuine
## saturation cuts a tail short. With `steal` false, saturation returns null.
func _take_voice(steal: bool = true) -> AudioStreamPlayer3D:
	for i in _voices.size():
		var index := (_next_voice + i) % _voices.size()
		if not _voices[index].playing:
			_next_voice = (index + 1) % _voices.size()
			return _voices[index]
	if not steal:
		return null
	var stolen := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	return stolen
