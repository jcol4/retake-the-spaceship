class_name Credits
extends RefCounted
## The shipped attribution text. THIS IS THE SOURCE OF TRUTH — CREDITS.md at the
## repo root documents the licences and their obligations for us, but this is
## what a player actually sees, and it is the only copy that satisfies a licence
## requiring credit. Adding an asset that needs attribution means editing here,
## not only the markdown.
##
## Deliberately a const rather than parsed from CREDITS.md at runtime: Godot's
## exporter filters by extension and does not ship .md files unless the export
## preset is told to, so a markdown-driven screen renders fine in the editor and
## comes up EMPTY in an exported build — the one place the credit legally has to
## appear.

const SECTIONS: Array[Dictionary] = [
	{
		"heading": "Audio",
		"entries": [
			"Sound effects obtained from https://www.zapsplat.com",
		],
	},
	{
		"heading": "Engine",
		"entries": [
			"Made with Godot Engine — https://godotengine.org",
			"GodotSteam by Cœur de Lion / GP Garcia (MIT)",
		],
	},
]


## Flattened to the lines the credits panel draws, headings included.
static func lines() -> PackedStringArray:
	var out := PackedStringArray()
	for section in SECTIONS:
		if not out.is_empty():
			out.append("")
		out.append(section["heading"])
		for entry: String in section["entries"]:
			out.append("    " + entry)
	return out
