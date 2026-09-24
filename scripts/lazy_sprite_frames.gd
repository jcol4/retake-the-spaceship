class_name LazySpriteFrames
extends RefCounted
## Opens a built SpriteFrames set WITHOUT loading its textures, and fills each
## animation in as it is first shown.
##
## `load()` on one of these .tres files loads every frame it names up front, and
## a character is a lot of frames: the merc body is 2,384 of them, plus as many
## again for its depth sidecar. Loaded that way the first merc to spawn held the
## main thread for 7-20 seconds, long enough for Windows to call the game hung,
## to show one idle pose.
##
## So the .tres is read as a MANIFEST instead — animation names, loop, speed,
## and the texture path of every frame — and turned into a SpriteFrames whose
## frames all point at one stand-in texture. `ensure()` swaps an animation's real
## textures in before it plays (UnitVisual calls it from the sprite's own
## animation signals, so no playback path can miss it), and a background pass
## (`_Warmer`) loads the rest on worker threads so that usually there is nothing
## left for `ensure()` to wait on.
##
## The .tres files are unchanged and build_sprite_frames.gd still writes them —
## this only changes how the game reads them. A plain `load()` of one, as the
## tools do, still works exactly as it did.

## How many animations the warmer has in flight at once. Enough to keep the
## worker threads busy; few enough that a merc stepping into a pose nobody has
## played yet is not queued behind the whole roster.
const WARM_IN_FLIGHT := 4

## path -> SpriteFrames. One per set for the whole session, shared by every unit
## showing it — the same sharing `load()`'s cache gave, which is what makes the
## second merc free.
static var _sets := {}

## SpriteFrames instance id -> {anim StringName -> Array[String] of frame paths}
## for every animation not yet filled in. Emptied as they load; an absent id is
## a set with nothing left to do.
static var _pending := {}

static var _warmer: _Warmer = null


## The set at `path`, frames not yet loaded. Null if there is no such file.
## Starts loading the rest of it in the background.
static func open(path: String) -> SpriteFrames:
	if _sets.has(path):
		return _sets[path]
	if not ResourceLoader.exists(path):
		return null
	var frames := _read_manifest(path)
	if frames == null:
		# Not in the shape build_sprite_frames.gd writes. Loaded whole rather than
		# refused: slow is better than invisible.
		push_warning("LazySpriteFrames: could not read %s as a manifest, loading it whole" % path)
		frames = load(path) as SpriteFrames
	_sets[path] = frames
	_warm(frames)
	return frames


## Starts background loading of `path` ahead of anything showing it, e.g. while
## a menu is up. Harmless to repeat.
static func preload_set(path: String) -> void:
	open(path)


## Makes `anim`'s real textures current in `frames`, loading whatever the warmer
## has not got to yet. Cheap when there is nothing to do, which is almost every
## call.
static func ensure(frames: SpriteFrames, anim: StringName) -> void:
	if frames == null:
		return
	var todo: Dictionary = _pending.get(frames.get_instance_id(), {})
	if not todo.has(anim):
		return
	var paths: Array = todo[anim]
	var textures := {}
	for path: String in paths:
		if textures.has(path):
			continue
		# The warmer may already have asked for it on a worker thread; take that
		# result (waiting for it if need be) rather than loading it twice.
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS or status == ResourceLoader.THREAD_LOAD_LOADED:
			textures[path] = ResourceLoader.load_threaded_get(path)
		else:
			textures[path] = load(path)
	_fill(frames, anim, textures)


static func _fill(frames: SpriteFrames, anim: StringName, textures: Dictionary) -> void:
	var id := frames.get_instance_id()
	var todo: Dictionary = _pending.get(id, {})
	var paths: Array = todo.get(anim, [])
	for i in paths.size():
		var tex: Texture2D = textures.get(paths[i])
		if tex:
			frames.set_frame(anim, i, tex, frames.get_frame_duration(anim, i))
	todo.erase(anim)
	if todo.is_empty():
		_pending.erase(id)


## Parses the text of a built .tres into a SpriteFrames of stand-ins, and records
## what each frame should really be. Relies on build_sprite_frames.gd's output:
## one Texture2D ext_resource per frame image and a single `animations` array.
static func _read_manifest(path: String) -> SpriteFrames:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	var ids := {}
	var ext := RegEx.create_from_string('\\[ext_resource type="Texture2D"[^\\]]*path="([^"]+)" id="([^"]+)"\\]')
	for m in ext.search_all(text):
		ids[m.get_string(2)] = m.get_string(1)
	var start := text.find("animations = [")
	if start == -1 or ids.is_empty():
		return null
	# ExtResource("id") is not a value str_to_var can build outside a resource
	# file, so each becomes its bare id string; everything else in the array is
	# plain Variant syntax.
	var body := text.substr(start + "animations = ".length()).strip_edges()
	var refs := RegEx.create_from_string('ExtResource\\("([^"]+)"\\)')
	var anims: Variant = str_to_var(refs.sub(body, '"$1"', true))
	if not anims is Array or (anims as Array).is_empty():
		return null

	# Every frame starts as the set's first real frame, loaded now. Measuring the
	# canvas needs a texture of the right size (UnitVisual._frame_size), and if a
	# frame were ever drawn before `ensure()` reached it, a still pose is a
	# better thing to see than nothing.
	var first_path := ""
	for anim: Dictionary in anims:
		if not (anim.get("frames", []) as Array).is_empty():
			first_path = ids.get(anim["frames"][0]["texture"], "")
			break
	var stand_in: Texture2D = load(first_path) if first_path != "" else null
	if stand_in == null:
		return null

	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	var todo := {}
	for anim: Dictionary in anims:
		var name := StringName(anim["name"])
		frames.add_animation(name)
		frames.set_animation_loop(name, anim.get("loop", true))
		frames.set_animation_speed(name, anim.get("speed", 5.0))
		var paths: Array[String] = []
		for f: Dictionary in anim.get("frames", []):
			frames.add_frame(name, stand_in, f.get("duration", 1.0))
			paths.append(ids.get(f["texture"], first_path))
		if not paths.is_empty():
			todo[name] = paths
	_pending[frames.get_instance_id()] = todo
	return frames


static func _warm(frames: SpriteFrames) -> void:
	if not _pending.has(frames.get_instance_id()):
		return
	if _warmer == null:
		_warmer = _Warmer.new()
		_warmer.name = "LazySpriteFramesWarmer"
		(Engine.get_main_loop() as SceneTree).root.add_child.call_deferred(_warmer)
	_warmer.queue(frames)


## Loads queued sets one animation at a time on ResourceLoader's worker threads,
## polling from the main thread, which is the only place a SpriteFrames may be
## changed while it is being drawn. Idle poses go first: they are what every
## unit shows the moment it appears.
class _Warmer extends Node:
	var _queue: Array = []  # [SpriteFrames, anim StringName], in load order
	var _in_flight: Array = []  # [SpriteFrames, anim, unique paths]

	func queue(frames: SpriteFrames) -> void:
		var todo: Dictionary = LazySpriteFrames._pending.get(frames.get_instance_id(), {})
		var names: Array = todo.keys()
		var idle: Array = names.filter(func(n: StringName) -> bool: return String(n).begins_with("idle_"))
		var rest: Array = names.filter(func(n: StringName) -> bool: return not String(n).begins_with("idle_"))
		# Idle goes ahead of everything already waiting, too: a set opened now is
		# about to be on screen, unlike the rest of a set opened a while ago.
		var front: Array = idle.map(func(n: StringName) -> Array: return [frames, n])
		_queue = front + _queue
		_queue.append_array(rest.map(func(n: StringName) -> Array: return [frames, n]))

	func _process(_delta: float) -> void:
		for i in range(_in_flight.size() - 1, -1, -1):
			var job: Array = _in_flight[i]
			if _poll(job):
				_in_flight.remove_at(i)
		while _in_flight.size() < LazySpriteFrames.WARM_IN_FLIGHT and not _queue.is_empty():
			var next: Array = _queue.pop_front()
			var job := _start(next[0], next[1])
			if not job.is_empty():
				_in_flight.append(job)

	## Asks for every texture of one animation, or nothing if `ensure()` has
	## already done it.
	func _start(frames: SpriteFrames, anim: StringName) -> Array:
		var todo: Dictionary = LazySpriteFrames._pending.get(frames.get_instance_id(), {})
		if not todo.has(anim):
			return []
		var unique := {}
		for path: String in todo[anim]:
			if unique.has(path):
				continue
			unique[path] = true
			ResourceLoader.load_threaded_request(path, "Texture2D")
		return [frames, anim, unique.keys()]

	## True once the job is finished, whether this filled it in or `ensure()`
	## got there first and collected the textures itself.
	func _poll(job: Array) -> bool:
		var frames: SpriteFrames = job[0]
		var anim: StringName = job[1]
		var todo: Dictionary = LazySpriteFrames._pending.get(frames.get_instance_id(), {})
		if not todo.has(anim):
			return true
		for path: String in job[2]:
			var status := ResourceLoader.load_threaded_get_status(path)
			if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				return false
		var textures := {}
		for path: String in job[2]:
			if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
				textures[path] = ResourceLoader.load_threaded_get(path)
			else:
				textures[path] = load(path)  # failed on the thread; one honest retry
		LazySpriteFrames._fill(frames, anim, textures)
		return true
