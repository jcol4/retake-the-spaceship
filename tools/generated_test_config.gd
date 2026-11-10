extends RefCounted
## Existing procedural regressions opt in explicitly after authored plots became default.
static func make():
	var generator = load("res://scripts/map_generator.gd")
	var config = generator.Config.new()
	config.deck_source = generator.DeckSource.GENERATED
	return config
