# Weapon Attachments

## Rules

- "+N% accuracy" is +N points on the hit chance.
- Damage percents ADD across all mods (Long Barrel +20% with Hollow Point +50% = +70%).
- Noise and visibility multipliers MULTIPLY (Suppressor x0.5 with Subsonic x0.7 = x0.35).
- AP discounts are capped at -2 per action however they stack. Increases aren't capped.
- "Within N tiles" includes N.
- "Armored" is a per-unit flag (`UnitStats.armored`): contractors, mercs and robots are armored,
  aliens aren't. Armor choices will be able to change it later.
- Detection: Suppressor and Subsonic shrink gunfire noise; Laser Sight makes the carrier visible
  from further away.
- Thermal removes the darkness accuracy penalty only; it doesn't let you see in the dark.
- Attachments are tiered loot. Weaker items in a slot are the easy finds.
- Unlocks: each attachment unlock is one copy for one soldier at a time. Ammo unlocks are per type,
  usable by any number of soldiers.
- Fit: magazines don't fit the Shotgun; everything else fits every weapon. Rifle ammo fits the
  Assault Rifle, Battle Rifle, SMG and LMG (and the pistol, once there is one).

## Underbarrel
Vertical Grip
+5% accuracy

Angled Grip
+7% accuracy if enemy within 7 tiles

Laser Sight
+3% accuracy
-1AP on Shoot
+50% detection range

## Barrel

Suppressor
-50% detection range
+2% accuracy

Muzzle Break
+5% accuracy

Long Barrel
+1AP Shoot, Overwatch, Aimed Shot, Suppress
+20% damage
+4% accuracy

## Optic

Holo Sight
+5% accuracy
-1AP on Shoot, Overwatch

Scope
-2AP on Aimed shot
-1AP on Shoot, Overwatch
+1AP on Suppress
+5% accuracy


Thermal Sight
+7% accuracy
ignore negative modifiers due to light
-1AP on Shoot, Overwatch

## Magazine

Extended Mag 
+1 ammo to mag size

Drum Mag 
+2 ammo to mag size, +1AP to reload

Light Mag 
-1AP to reload

## Stock

Heavy Stock
+3% accuracy

Sawed Off Stock
-10% accuracy 
-1AP Shoot, Overwatch Action

Ergo Stock
-1AP Shoot, Overwatch, Aimed Shot Action

## Ammo

### Rifle/Pistol/SMG/LMG

Penetrator Rounds
+34% damage versus armored targets

Hollow Point
+50% damage versus unarmored targets
-15% damage versus armored targets

Subsonic
-30% detection range

FMJ
+3 tiles optimal range

### Shotgun

Slug Rounds
+3 tiles optimal range (3 -> 6)
-34% damage within 4 tiles
+50% damage versus armored targets
+25% damage versus unarmored targets
