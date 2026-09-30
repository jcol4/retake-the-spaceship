class_name AttachmentData
extends WeaponMod
## One weapon attachment (design doc `weapons/attachments.md`): a WeaponMod that
## fits one slot. The roster lives in `AttachmentPresets`, mirroring WeaponPresets.

enum Slot { UNDERBARREL, BARREL, OPTIC, MAGAZINE, STOCK }

@export var slot: Slot = Slot.UNDERBARREL
