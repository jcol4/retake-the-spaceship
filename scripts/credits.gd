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
		"heading": "Art",
		"entries": [
			"\"server rack\" by Jeremy Eyring — poly.pizza/m/6ijQclm8jxw — CC BY 3.0",
			"\"Lab Table\" by Ali12 — poly.pizza/m/NyeiCAto3N — CC BY 3.0",
			"\"Scifi Canister\" by Nick Slough — poly.pizza/m/OzcIJxCDpO — CC BY 3.0",
			"\"Punching Bag\", \"Barbell\", \"Gymmat\" and \"Dumbell\" by Zsky (Ultimate Interior Props Pack) — poly.pizza/bundle/Ultimate-Interior-Props-Pack-9KfkK2H0ve — CC BY 4.0",
			"Used unmodified. Licences: creativecommons.org/licenses/by/3.0/ and creativecommons.org/licenses/by/4.0/",
			"Room kits by Quaternius, Kay Lousberg (KayKit), Kenney and Dipper98; floor textures from ambientCG (all CC0)",
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
