extends Node
## Background music. Autoloaded so a track survives scene changes: the front end
## reloads front_end.tscn on every "Back to title" and on the return from a
## mission, and music parented into that scene would restart from the top each
## time. Here, asking for the track that is already playing is a no-op.
##
## Plays on the Music bus, so GameSettings.music_volume applies.

const TRACKS := {
	"menu": "res://assets/audio/music/menu.mp3",
}

var _player: AudioStreamPlayer
var _current := ""


func _ready() -> void:
	# Keep playing while the tree is paused (a pause menu over the front end).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.bus = GameSettings.BUS_MUSIC
	add_child(_player)


## Starts `key` looping, unless it is already the track playing.
func play(key: String) -> void:
	if key == _current and _player.playing:
		return
	var path: String = TRACKS.get(key, "")
	if path == "" or not ResourceLoader.exists(path):
		push_warning("Music '%s' has no file at %s — staying silent" % [key, path])
		return
	var stream: AudioStream = load(path)
	if "loop" in stream:
		stream.loop = true
	_current = key
	_player.stream = stream
	_player.play()


func stop() -> void:
	_current = ""
	_player.stop()
