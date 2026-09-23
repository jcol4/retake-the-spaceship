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
const STREAMS := {
	"rifle_fire": "res://assets/audio/sfx/weapons/rifle_fire.tres",
}

var _voices: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _loaded: Dictionary = {}


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
	var voice := _take_voice()
	voice.stream = stream
	voice.pitch_scale = pitch_scale
	voice.global_position = at
	voice.play()


## Round-robin with voice stealing. Prefers a player that has finished over one
## still sounding, so a quiet moment never interrupts anything; only genuine
## saturation cuts a tail short.
func _take_voice() -> AudioStreamPlayer3D:
	for i in _voices.size():
		var index := (_next_voice + i) % _voices.size()
		if not _voices[index].playing:
			_next_voice = (index + 1) % _voices.size()
			return _voices[index]
	var stolen := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	return stolen
