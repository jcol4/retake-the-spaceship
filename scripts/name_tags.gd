class_name NameTags
## The J key's world-label mode, read by every owner of a name tag (units, hangar
## markers, crates, the terminal, the HUD's body labels) when it decides whether
## its label shows.
##
##   NORMAL  the game's own rules: a tag follows its model through fog of war,
##           hangar markers wait to be discovered.
##   ALL     debug x-ray (debug builds only): every tag, drawn or not, enemy
##           bodies included and every hangar discovered or not. Shows what the
##           fog hides, so a release build never offers it.
##   NONE    decluttered: only this side's own soldiers and their body bars stay.
##           No enemy tags, hangar markers, crates or terminal.
##
## Static, so it lasts from mission to mission until the game restarts.

enum Mode { NORMAL, ALL, NONE }

## Peers in "units" that run Unit._sync_label; the props run apply_name_tag_mode.
const PROP_GROUP := "name_tag_props"

static var mode: Mode = Mode.NORMAL


## Steps to the next mode and returns it. A release build skips ALL.
static func cycle() -> Mode:
	match mode:
		Mode.NORMAL:
			mode = Mode.ALL if OS.is_debug_build() else Mode.NONE
		Mode.ALL:
			mode = Mode.NONE
		_:
			mode = Mode.NORMAL
	return mode


static func mode_name() -> String:
	return ["NORMAL", "ALL", "NONE"][mode]


## Whether a prop's label (crate, pile, terminal) shows. Props are never fogged.
static func shows_prop() -> bool:
	return mode != Mode.NONE


## Whether a hangar marker shows, given whether it has been discovered.
static func shows_hangar(discovered: bool) -> bool:
	match mode:
		Mode.ALL:
			return true
		Mode.NONE:
			return false
	return discovered
