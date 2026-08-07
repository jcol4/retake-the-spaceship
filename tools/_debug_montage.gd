extends SceneTree
## A contact sheet from an explicit list of image paths, so renders from
## different runs can be compared by eye. Not part of the pipeline.
##
##   MONTAGE_FILES="a.png;b.png" MONTAGE_COLS=8 MONTAGE_OUT=sheet.png \
##     godot --headless --path . --script res://tools/_debug_montage.gd
##
## Written to diagnose a facing bug, and kept because that class of bug is
## invisible any other way: a sprite rendered at the wrong base rotation is a
## perfectly good image with the correct name, and the only thing wrong with it
## is which way the character points. Lay one pose's eight directions over
## another's and a rotation offset is obvious in a second.
##
## Paths are absolute and OS-native (not res://), so freshly rendered frames in a
## scratch directory can be put beside the shipped ones without importing them.

## Cell size. Set MONTAGE_CELL to the source resolution (256) to compare at full
## detail — downscaling a sprite is exactly what makes a facing hard to read.
var CELL := int(OS.get_environment("MONTAGE_CELL")) if \
	OS.has_environment("MONTAGE_CELL") else 220


func _initialize() -> void:
	var files := OS.get_environment("MONTAGE_FILES").split(";", false)
	var cols := int(OS.get_environment("MONTAGE_COLS")) if \
		OS.has_environment("MONTAGE_COLS") else mini(files.size(), 9)
	var rows := int(ceil(float(files.size()) / cols))
	var sheet := Image.create(CELL * cols, CELL * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.12, 0.12, 0.14, 1.0))
	for i in files.size():
		var img := Image.load_from_file(files[i])
		if img == null:
			print("missing ", files[i])
			continue
		img.resize(CELL, CELL, Image.INTERPOLATE_LANCZOS)
		img.convert(Image.FORMAT_RGBA8)
		sheet.blend_rect(img, Rect2i(0, 0, CELL, CELL),
			Vector2i((i % cols) * CELL, (i / cols) * CELL))
	sheet.save_png(OS.get_environment("MONTAGE_OUT"))
	print("wrote ", OS.get_environment("MONTAGE_OUT"))
	quit(0)
