class_name WeaponArchetype
extends RefCounted
## The families guns belong to, and each family's distance table: the aim a shot
## gains or loses at each range (docs/design/systems/accuracy). One table per
## archetype rather than per gun, because more than one gun will share each —
## a second SMG differs from the first by its own `WeaponData.aim_modifier`, not
## by a range shape of its own.
##
## The table replaced three things at once: the old global distance curve, each
## gun's optimal-range falloff, and the close-quarters accuracy penalties on the
## Battle Rifle and LMG. Being bad up close is now just what those tables say at
## 1-3 tiles.

## APPEND-ONLY: weapon resources and presets store these as ints.
enum Id { ASSAULT_RIFLE, SHOTGUN, SMG, LMG, BATTLE_RIFLE, PISTOL }

## Aim added at 1, 2, 3 ... tiles, in order. Distance 0 (two bodies sharing a
## tile) reads the 1-tile value. Past the last entry, TAIL takes that much more
## off per tile, from the last entry's value.
##
## Read as identities, with an Aim 60 soldier against an open target:
##   Shotgun       85 at 2 tiles, 45 at 6, useless past 8. Point-blank or nothing.
##   SMG           78 at 2, 65 at 6, 42 at 10. Short-to-mid, a gentle slope.
##   Pistol        75 at 2, 60 at 6, 28 at 10. The SMG's shape, shorter and weaker.
##   Assault Rifle 70 at 2, 65 at 6, 60 at 10, 48 at 15. Never far from its Aim.
##   LMG           45 at 2, 65 at 6 to 12. Unwieldy close, steady through the middle.
##   Battle Rifle  35 at 2, 60 at 6, 65 from 9 to 18. Clumsy close, best far.
const TABLE := {
	Id.SHOTGUN: [30, 25, 20, 10, 0, -15, -30, -45],
	Id.SMG: [20, 18, 15, 10, 8, 5, 0, -6, -12, -18],
	Id.PISTOL: [15, 15, 10, 5, 5, 0, -8, -16],
	Id.ASSAULT_RIFLE: [10, 10, 10, 10, 5, 5, 5, 5, 0, 0, 0, 0],
	Id.LMG: [-20, -15, -10, 0, 0, 5, 5, 5, 5, 5, 5, 5],
	Id.BATTLE_RIFLE: [-30, -25, -20, -10, -5, 0, 0, 0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5],
}

## Aim lost per tile past the end of each table.
const TAIL := {
	Id.SHOTGUN: 15,
	Id.SMG: 6,
	Id.PISTOL: 8,
	Id.ASSAULT_RIFLE: 4,
	Id.LMG: 4,
	Id.BATTLE_RIFLE: 3,
}

## For the loadout screen and logs.
const NAMES := {
	Id.ASSAULT_RIFLE: "Assault Rifle",
	Id.SHOTGUN: "Shotgun",
	Id.SMG: "SMG",
	Id.LMG: "LMG",
	Id.BATTLE_RIFLE: "Battle Rifle",
	Id.PISTOL: "Pistol",
}


## Aim a gun of `archetype` gains (or loses) shooting `dist` tiles. An unknown
## archetype reads the Assault Rifle's table, the generalist.
static func range_modifier(archetype: int, dist: int) -> int:
	var table: Array = TABLE.get(archetype, TABLE[Id.ASSAULT_RIFLE])
	var tail: int = TAIL.get(archetype, TAIL[Id.ASSAULT_RIFLE])
	var i := maxi(dist, 1) - 1
	if i < table.size():
		return table[i]
	return table[-1] - tail * (i - table.size() + 1)


static func display_name(archetype: int) -> String:
	return NAMES.get(archetype, "?")
