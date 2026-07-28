extends MapBuilder
## Hand-authored test map. Three rooms: player squad room (left), central room
## with cover, enemy room (right) containing a raised platform reached by a
## stair tile. The layout itself lives in maps/test_deck.txt — see MapAscii for
## the glyph legend.

const LAYOUT_PATH := "res://maps/test_deck.txt"


func _ready() -> void:
	build(MapAscii.load_file(LAYOUT_PATH))
