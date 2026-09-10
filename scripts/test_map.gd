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
##
## `-- --seed=<n>` instead builds a procedurally generated deck (MapGenerator)
## with that seed, rather than loading a file at all — this is the playable
## path for the room/corridor/cover overhaul, kept alongside the hand-authored
## decks rather than replacing them so nothing already tested against
## test_deck/coordination_deck regresses.

const DEFAULT_LAYOUT := "res://maps/test_deck.txt"

@export var layout_path: String = DEFAULT_LAYOUT


func _ready() -> void:
	var seed_arg: Variant = _cmdline_seed()
	if seed_arg != null:
		build(MapGenerator.generate(seed_arg))
	else:
		build_layout(resolve_layout())


## Split out from `_ready()` so main.gd can REBUILD from a different layout
## once it knows one — in co-op, the joining client's own `--map=` (or lack
## of one) can't be trusted; only the HOST's resolved path is authoritative
## for both peers. `MapBuilder.build` is safe to call a second time (it clears
## whatever a previous build left behind), so this doubles as "load" and
## "override the local guess" without any special-casing here.
func build_layout(path: String) -> void:
	build(MapAscii.load_file(path))


## The layout this scene will load. `--map=<name>` resolves to `maps/<name>.txt`;
## anything else falls back to the exported path, so the editor and the existing
## tests keep the small deck without knowing this option exists.
func resolve_layout() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			return "res://maps/%s.txt" % arg.trim_prefix("--map=")
	return layout_path


## `--seed=<n>` from the command line, or null if not passed. A generated deck
## takes priority over `--map=` when both are given, since asking for a seed
## is the more specific request.
func _cmdline_seed() -> Variant:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			return int(arg.trim_prefix("--seed="))
	return null
