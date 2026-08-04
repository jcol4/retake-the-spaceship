extends SceneTree
## Builds one `SpriteFrames` per layer from the loose PNGs in assets/sprites/,
## which is what makes the `[layer]_[variant]_[pose]_[dir]_[frame].png` naming
## convention load-bearing rather than documentation. Hand-writing these is not
## viable: a character is 18 poses x 8 directions x N layers, and
## `body_swarm.tres` -- 90 entries all pointing at one texture -- was already at
## the limit of what is reasonable to type.
##
##   SF_VARIANT=merc SF_LAYERS=body,arm \
##     godot --headless --path . --script res://tools/build_sprite_frames.gd
##
## Every pose/direction pair is emitted whether art exists for it or not.
## Missing pairs fall back to the nearest thing that does exist (see _pick), so
## a half-drawn character never has a layer that resolves to nothing and hides
## itself mid-turn -- the failure mode `body_swarm.tres`'s comment describes.
## Rerun after every export; it overwrites.

## Poses, mirroring unit_visual.gd's PLACEHOLDER_POSES. Duplicated rather than
## imported on purpose: a `--script` tool that names `UnitVisual` compiles it,
## and unit_visual.gd reads the LightingManager/GridManager autoloads, which are
## not registered when a tool script is compiled.
const POSES := [
	"idle", "run", "walk", "crouch_idle", "overwatch_hold", "aim_hold",
	"shoot_recoil", "run_stop", "stand_to_crouch", "crouch_to_stand", "melee",
	"reload", "throw_grenade", "interact", "hit_react", "downed",
	"alert_scream", "idle_fidget",
]

## All EIGHT, not the five-plus-mirror set. A character carrying a rifle cannot
## be mirrored -- unit_visual.gd's MIRROR table would put the weapon in the wrong
## hand -- so the asymmetric path in `_resolve` (art for the mirrored direction
## wins over the mirror table) is the one taken here.
##
## Order is irrelevant here (this only ever emits names), but it is kept
## identical to unit_visual.gd's DIRECTIONS so the two lists can be diffed by
## eye. The screen diagonals are the four world grid axes; the screen cardinals
## are the four world diagonals.
const DIRECTIONS := ["ne", "n", "nw", "w", "sw", "s", "se", "e"]

const LOOPING := ["idle", "run", "walk", "crouch_idle", "overwatch_hold", "aim_hold"]

## Seconds a one-shot occupies, copied from unit_visual.gd's FALLBACK_TIME.
## `speed` is derived as frames/duration, so the animation takes exactly this
## long however many frames get drawn for it -- which is the property that keeps
## turn pacing identical as art lands.
const ONE_SHOT_TIME := {
	"melee": 1.20, "reload": 1.20, "throw_grenade": 1.00, "interact": 1.00,
	"hit_react": 0.47, "downed": 0.80, "alert_scream": 2.80,
}
const DEFAULT_ONE_SHOT_TIME := 0.4

## Seconds ONE CYCLE of each looping stance takes. Duration, not frames per
## second, and that distinction is the whole point: a fps constant silently
## encodes a frame count, so drawing a cycle in ten frames instead of eight
## would stretch it and slide the boots off the footstep cadence. Stating the
## duration instead makes frame count a free art decision -- draw a cycle in 4,
## 8, 10 or 12 and it occupies the same time either way, exactly as the one-shots
## in ONE_SHOT_TIME already do.
##
## `run` is the one that is forced rather than chosen: unit_visual.gd emits a
## footstep every FOOTSTEP_GAP (0.333 s), so a two-step cycle must take 0.666 s
## or the sound and the footplant drift apart. `walk` follows from WALK_SPEED
## (1.02 m/s) over a ~0.7 m stride. The rest are held by nothing external and are
## simply chosen to read well.
const LOOP_TIME := {
	"run": 2 * 0.333,  # = unit_visual.gd's 2 x FOOTSTEP_GAP
	"walk": 1.4,
	"idle": 2.0,  # a breathing cycle
	"crouch_idle": 1.6, "overwatch_hold": 1.6, "aim_hold": 1.6,
}
const DEFAULT_LOOP_TIME := 1.6

const DIR := "res://assets/sprites"


func _initialize() -> void:
	var variant := OS.get_environment("SF_VARIANT")
	if variant.is_empty():
		push_error("SF_VARIANT is required")
		quit(1)
		return
	var layers := OS.get_environment("SF_LAYERS").split(",", false)
	if layers.is_empty():
		push_error("SF_LAYERS is required (comma-separated, back to front)")
		quit(1)
		return

	for layer in layers:
		if not _build(layer.strip_edges(), variant):
			quit(1)
			return
	quit(0)


func _build(layer: String, variant: String) -> bool:
	var found := _scan(layer, variant)
	if found.is_empty():
		push_error("no PNGs matched %s_%s_*.png in %s" % [layer, variant, DIR])
		return false

	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	var drawn := 0
	for pose in POSES:
		for dir in DIRECTIONS:
			var textures: Array = _pick(found, pose, dir)
			if found.has("%s/%s" % [pose, dir]):
				drawn += 1
			var name := StringName("%s_%s" % [pose, dir])
			frames.add_animation(name)
			frames.set_animation_loop(name, pose in LOOPING)
			frames.set_animation_speed(name, _speed(pose, textures.size()))
			for tex in textures:
				frames.add_frame(name, tex)

	var path := "%s/%s_%s.tres" % [DIR, layer, variant]
	var err := ResourceSaver.save(frames, path)
	if err != OK:
		push_error("save %s failed: %d" % [path, err])
		return false
	print("[frames] %s  %d animations, %d authored, %d stubbed" % [
		path, frames.get_animation_names().size(), drawn,
		frames.get_animation_names().size() - drawn])
	return true


## Every authored PNG for this layer+variant, keyed "pose/dir" -> textures in
## frame order.
func _scan(layer: String, variant: String) -> Dictionary:
	var prefix := "%s_%s_" % [layer, variant]
	var out: Dictionary = {}
	for file in DirAccess.get_files_at(DIR):
		# Matched STRICTLY on .png. A source tree lists both `x.png` and its
		# sidecar `x.png.import`, so normalising the sidecar's name instead of
		# skipping it counts every frame twice -- which is invisible while a pose
		# has one frame and doubles the playback speed as soon as it has ten.
		# This tool only ever runs against a source tree; it writes .tres into
		# res://.
		if not file.begins_with(prefix) or not file.ends_with(".png"):
			continue
		var stem := file.trim_suffix(".png").substr(prefix.length())
		# stem is "[pose]_[dir]_[frame]", and pose itself contains underscores
		# ("shoot_recoil"), so split from the RIGHT.
		var parts := stem.rsplit("_", true, 2)
		if parts.size() != 3 or not parts[2].is_valid_int():
			push_warning("skipping unparseable name: %s" % file)
			continue
		var key := "%s/%s" % [parts[0], parts[1]]
		if not out.has(key):
			out[key] = []
		out[key].append([parts[2].to_int(), load("%s/%s" % [DIR, file])])
	# Ordered by the parsed index, NOT by filename: lexicographically "_10" sorts
	# before "_2", so any cycle of ten frames or more would play scrambled. The
	# indices need only increase -- they are a running order, not addresses.
	for key: String in out:
		var entries: Array = out[key]
		entries.sort_custom(func(a, b): return a[0] < b[0])
		var textures: Array = []
		for entry in entries:
			textures.append(entry[1])
		out[key] = textures
	return out


## Textures for one pose+direction, or the nearest stand-in. Order of preference:
## the pair itself, the same POSE in any direction (keeps facing wrong but the
## action right), then anything at all. The last case is what
## `body_swarm.tres` does by hand for all 90 of its entries.
func _pick(found: Dictionary, pose: String, dir: String) -> Array:
	var exact := "%s/%s" % [pose, dir]
	if found.has(exact):
		return found[exact]
	for key: String in found:
		if key.begins_with(pose + "/"):
			return found[key]
	return found.values()[0]


## `speed` is frames per second, and a SpriteFrames animation of n frames at
## duration 1.0 each runs for n/speed seconds. So both branches are the same
## calculation -- frames divided by the time the pose is supposed to occupy --
## and neither cares how many frames were drawn.
func _speed(pose: String, frame_count: int) -> float:
	var seconds: float = LOOP_TIME.get(pose, DEFAULT_LOOP_TIME) if pose in LOOPING \
		else ONE_SHOT_TIME.get(pose, DEFAULT_ONE_SHOT_TIME)
	return maxi(frame_count, 1) / seconds
