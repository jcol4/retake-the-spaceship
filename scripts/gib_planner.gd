class_name GibPlanner
extends RefCounted
## Which parts of a dying Fodder body come off, and how hard they fly — decided
## from the hit that killed it. Pure: no nodes, no globals, no shared generator.
## The same death info and seed always give the same plan, so it is unit-tested
## (tools/test_gibs.gd) and every peer that sees the same replicated hit agrees.
##
## PURELY VISUAL, like Ragdoll: nothing the game decides ever reads a plan. The
## seed comes from the replicated hit (`Unit.hit_seed`, or the burst's own
## presentation roll on the gunfire path) hashed with the unit's name — NEVER
## the global generator, which seeded runs replay (see Unit._hit_rng).
##
## A plan:
##   mode   Mode
##   parts  Array of {part: StringName (PARTS), speed: float m/s, spin: float rad/s}
##   dir    Vector3, the horizontal push for a directional hit (zero for a blast)
##   from   Vector3, where the hit came from; a blast pushes each part away from it
##   radial bool, true for a blast

enum Mode { NONE, LIMBS, HEAVY }

## Every part a body can lose, in Ragdoll.RIGS' "gib" naming.
const PARTS: Array[StringName] = [&"head", &"arm_l", &"arm_r", &"leg_l", &"leg_r"]
## Combat.BodyPart -> part (by value, so this compiles alone). TORSO has none.
const FROM_BODY_PART := {0: &"head", 2: &"arm_l", 3: &"arm_r", 4: &"leg_l", 5: &"leg_r"}

## Not every kill gibs: chance per kind (Ragdoll.HitKind by value).
const CHANCE_BULLET := 0.35
const CHANCE_MELEE := 0.3
const CHANCE_BLAST := 0.85
## Each point of damage past what killed it adds this much to the chance.
const CHANCE_PER_OVERKILL := 0.08
## Damage past zero HP that takes the whole body apart, whatever did it. Fodder
## has 6-8 HP, so this is a hit that would have killed it twice.
const HEAVY_OVERKILL := 7
## Of the blasts that gib, how many take everything.
const BLAST_HEAVY_CHANCE := 0.5
## A rifle death that gibs takes a second part this often.
const BULLET_SECOND_PART := 0.3

const BULLET_SPEED := Vector2(2.5, 4.0)
const MELEE_SPEED := Vector2(2.0, 3.0)
const BLAST_SPEED := Vector2(4.0, 6.5)
const SPIN := Vector2(4.0, 12.0)

const KIND_NONE := 0
const KIND_BULLET := 1
const KIND_MELEE := 2
const KIND_BLAST := 3


## The seed for one body's plan: the hit's own seed and the unit, mixed.
static func seed_for(hit_seed: int, unit_key: String) -> int:
	return hash([hit_seed, unit_key])


## `info`:
##   fodder    bool — false always plans NONE
##   kind      Ragdoll.HitKind
##   part      Combat.BodyPart struck, or -1
##   from      Vector3, where the attack came from (world)
##   at        Vector3, the body (world)
##   overkill  int, damage past what killed it (0 when unknown)
static func plan(info: Dictionary, rng_seed: int) -> Dictionary:
	var out := {"mode": Mode.NONE, "parts": [], "dir": Vector3.ZERO,
		"from": info.get("from", Vector3.ZERO), "radial": false}
	if not info.get("fodder", false):
		return out
	var kind := int(info.get("kind", KIND_NONE))
	if kind == KIND_NONE:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var overkill := maxi(int(info.get("overkill", 0)), 0)
	var from: Vector3 = info.get("from", Vector3.ZERO)
	var at: Vector3 = info.get("at", Vector3.ZERO)
	var dir := at - from
	dir.y = 0.0
	if dir.length() < 0.01:
		var a := rng.randf() * TAU
		dir = Vector3(cos(a), 0, sin(a))
	out.dir = dir.normalized()

	var base := CHANCE_BULLET
	match kind:
		KIND_MELEE:
			base = CHANCE_MELEE
		KIND_BLAST:
			base = CHANCE_BLAST
	# Rolled first, and always, so how many numbers the rest of the plan draws
	# never depends on a branch taken before it.
	var roll := rng.randf()
	var heavy := overkill >= HEAVY_OVERKILL
	if not heavy and roll >= base + CHANCE_PER_OVERKILL * overkill:
		return out

	var speed := BULLET_SPEED
	var picked: Array[StringName] = []
	if heavy or (kind == KIND_BLAST and rng.randf() < BLAST_HEAVY_CHANCE):
		out.mode = Mode.HEAVY
		picked.assign(PARTS)
		speed = BLAST_SPEED if kind == KIND_BLAST else BULLET_SPEED * 1.3
	else:
		out.mode = Mode.LIMBS
		var struck: StringName = FROM_BODY_PART.get(int(info.get("part", -1)), &"")
		match kind:
			KIND_BLAST:
				speed = BLAST_SPEED
				var pool := PARTS.duplicate()
				_shuffle(pool, rng)
				picked.assign(pool.slice(0, 2 + rng.randi() % 2))
			KIND_MELEE:
				speed = MELEE_SPEED
				# A swing takes one limb: the head it was aimed at, else an arm.
				picked.append(struck if struck == &"head" else [&"arm_l", &"arm_r"][rng.randi() % 2])
			_:
				# A round takes the part it struck; into the torso, something near it.
				picked.append(struck if struck != &"" else PARTS[rng.randi() % PARTS.size()])
				if rng.randf() < BULLET_SECOND_PART:
					var rest := PARTS.filter(func(p: StringName) -> bool: return p != picked[0])
					picked.append(rest[rng.randi() % rest.size()])
	out.radial = kind == KIND_BLAST
	for p in picked:
		out.parts.append({"part": p, "speed": rng.randf_range(speed.x, speed.y),
			"spin": rng.randf_range(SPIN.x, SPIN.y)})
	return out


## The part names in a plan.
static func part_names(p: Dictionary) -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Dictionary in p.get("parts", []):
		out.append(e.part)
	return out


static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
