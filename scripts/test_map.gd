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

## The deployment deck `build_deck` last built ({} if the deck came from the
## command line or `layout_path`), so main.gd can tell whether it still has to
## build the one its deployment names.
var built_deck: Dictionary = {}


func _ready() -> void:
	# A campaign mission (extraction plan 4.2) names its deck in the deployment:
	# the contract's generated deck, or the host's command-line override. It comes
	# first, and it is the SAME dictionary on every co-op peer (Campaign sends it),
	# so a client builds the host's deck here without the rebuild the old
	# `_rpc_use_layout` handshake needed.
	if build_deck(Campaign.deployment.get("deck", {})):
		return
	var seed_arg: Variant = _cmdline_seed()
	if seed_arg != null:
		build(MapGenerator.generate(seed_arg))
		# The same deck a deployment's command-line override names
		# (Campaign._apply_cmdline_deck), so main.gd need not build it twice.
		built_deck = {"kind": "generated", "seed": seed_arg, "size": CampaignEconomy.DeckSize.MEDIUM}
	else:
		build_layout(resolve_layout())
		if resolve_layout() != layout_path:
			built_deck = {"kind": "layout", "path": resolve_layout()}


## Builds a deployment's deck: {"kind": "generated", "seed", "size"} (size a
## CampaignEconomy.DeckSize) or {"kind": "layout", "path"}. False, building
## nothing, for {} or anything it does not recognise.
func build_deck(deck: Dictionary) -> bool:
	built_deck = deck.duplicate()
	match String(deck.get("kind", "")):
		"generated":
			build_generated(int(deck.get("seed", 0)), ContractOffer.config_for(int(deck.get("size", CampaignEconomy.DeckSize.MEDIUM))))
			return true
		"layout":
			build_layout(String(deck.get("path", layout_path)))
			return true
	return false


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


## The generated deck's seed if this peer built one (`--seed=`), else null —
## what the co-op host hands a client alongside `resolve_layout()`, since a
## host on a generated deck has no layout file for the client to load.
func generated_seed() -> Variant:
	return _cmdline_seed()


func build_generated(map_seed: int, cfg: MapGenerator.Config = null) -> void:
	build(MapGenerator.generate(map_seed, cfg))


## `--seed=<n>` from the command line, or null if not passed. A generated deck
## takes priority over `--map=` when both are given, since asking for a seed
## is the more specific request.
func _cmdline_seed() -> Variant:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			return int(arg.trim_prefix("--seed="))
	return null
