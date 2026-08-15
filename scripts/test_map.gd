extends MapBuilder
## Hand-authored test map. The layout lives in `maps/` as ASCII — see MapAscii
## for the glyph legend.
##
## Which deck it loads is selectable, because the two shipped layouts test
## different things and neither is a superset of the other:
##
##   test_deck          20x14, three rooms. Small, fast, and what every existing
##                      headless test asserts against — several of them hardcode
##                      its spawn counts, so it must not drift.
##   coordination_deck  40x26, seven compartments, one wing per faction. Sized so
##                      crossing takes several activations, which is the only way
##                      the approach, goal commitment and suppression windows
##                      become visible at all. See docs/design/systems/coordinated-ai/.
##
## Selected with `-- --map=coordination_deck` on the command line, so a smoke run
## can switch decks without editing a file that tests depend on.

const DEFAULT_LAYOUT := "res://maps/test_deck.txt"

@export var layout_path: String = DEFAULT_LAYOUT


func _ready() -> void:
	build(MapAscii.load_file(resolve_layout()))


## The layout this scene will load. `--map=<name>` resolves to `maps/<name>.txt`;
## anything else falls back to the exported path, so the editor and the existing
## tests keep the small deck without knowing this option exists.
func resolve_layout() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			return "res://maps/%s.txt" % arg.trim_prefix("--map=")
	return layout_path
