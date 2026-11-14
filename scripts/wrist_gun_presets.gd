class_name WristGunPresets
extends RefCounted
## Arm-mounted guns for the security robots: the robots' WeaponPresets and
## gunswap in one table. Each type is a WHOLE weapon (its numbers) and how it
## is drawn and heard firing, so swapping a robot's wrist gun changes how it
## fights as well as how it looks. A robot names its type in CerberusPresets.
##
## The model is assets/models/wrist_guns/<model>.glb, mounted on the robot
## model's `wrist_mount` (UnitVisual._mount_gun), and has one `muzzle_flash`,
## `muzzle_flash_2`, ... marker per barrel; the barrels take turns, a round
## each. A new type is a .blend under art_src/wrist_guns/ (tools/rig_wrist_gun.py
## writes one from a gun fitted on the robot), an entry in export_models.py's
## WRIST_GUNS, and a row here.

## APPEND-ONLY, like WeaponPresets.WeaponId.
enum WristGunId { WRIST_LMG, WRIST_CANNON }

## burst: [min, max] rounds a trigger pull draws, rolled per shot. Cosmetic like
## every burst (Unit.BURST_MIN): one pull is still one roll and one round of the
## magazine. tracer_every: see WeaponData.tracer_every -- barrels + 1 is the
## number that walks the tracers across every barrel.
## archetype: the WeaponArchetype distance table each reads (docs/design/systems/
## accuracy). Both are LMG: mounted, unwieldy close, steady through the middle.
const DATA := {
	WristGunId.WRIST_LMG: {
		"display_name": "JXM Wrist Gun",
		# Securus pays 5 AP to fire it (SecurusUnit.SHOT_AP_DISCOUNT).
		"archetype": WeaponArchetype.Id.LMG, "damage": 6, "mag_size": 12,
		"penetration": 60,  # LMG tier (docs/design/systems/penetration)
		"model": &"wrist_lmg",
		"fire_sfx": "lmg_fire",
		# Twin barrels. 7-10 at BURST_CADENCE is 0.8-1.1 s of fire, inside the
		# shortest lmg_fire take (1.27 s), which plays once per burst.
		"burst": [7, 10],
		"tracer_every": 3,
	},
	WristGunId.WRIST_CANNON: {
		# Sagittarii's. The numbers are the old MKV Support Cannon's, unchanged:
		# moving it onto the wrist is a model swap, not a rebalance.
		"display_name": "MKV Support Cannon",
		"archetype": WeaponArchetype.Id.LMG, "damage": 10, "mag_size": 5,
		"penetration": 60,
		"model": &"wrist_cannon",
		"fire_sfx": "battle_rifle_fire",
		# One barrel, a few heavy rounds a pull, each one a tracer.
		"burst": [2, 3],
		"tracer_every": 1,
	},
}


static func make(id: WristGunId) -> WeaponData:
	var d: Dictionary = DATA[id]
	var w := WeaponData.new()
	w.display_name = d["display_name"]
	w.archetype = d["archetype"]
	w.damage = d["damage"]
	w.mag_size = d["mag_size"]
	w.penetration = d["penetration"]
	# Unlimited reserve: the robots' rule, not the gun's (CerberusPresets._make_weapon).
	w.starting_reserve = -1
	w.model = d["model"]
	w.fire_sfx = d["fire_sfx"]
	w.burst_min = d["burst"][0]
	w.burst_max = d["burst"][1]
	w.tracer_every = d["tracer_every"]
	return w
