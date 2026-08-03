"""Put the rifle on a dedicated `weapon` bone instead of straight on the hand.

  blender.exe -b art_src/merc_anim.blend -P tools/add_weapon_bone.py -- art_src/merc_anim.blend

WHY THIS EXISTS
---------------
`tools/render_sprites.py` drives ONE datablock -- the armature's action. Object
level keyframes on the rifle or on its parent Empty are never evaluated, so a
rifle bone-parented directly to `IK-hand.R` can only ever do exactly what the
hand does. That is fine for idle, run and aim; it makes `reload` impossible,
because a reload is precisely the moment the rifle must hold still while the
right hand leaves it for a magazine.

Routing the rifle through a pose bone makes it animatable inside the action.

WHY THE BONE HAS NO PARENT
--------------------------
Blender's Child Of composes `target_world @ inverse @ owner_world`, and
`owner_world` already contains the owner's own parent chain. Parenting `weapon`
under `Main` would therefore apply the root's motion twice the moment the
character walks. A constraint-driven bone is left at the root of the armature
for this reason; the Child Of is the only thing that positions it.

USAGE ONCE RIGGED
-----------------
Animate `weapon` never, and it rides the right hand. For a reload, key
`weapon`'s Child Of influence 1 -> 0 on the frame the hand lets go, pose the
bone through the reload, and key it back to 1. Both the influence and the bone's
own channels live in the action, so both render.
"""

import os
import sys

import bpy
from mathutils import Matrix

ARMATURE = "Armature"
RIFLE_HOLDER = "Empty"     # the rifle's parent; carries the fitted grip offset
RIFLE = "AssaultRifle2_1"
BONE = "weapon"
HAND_BONE = "IK-hand.R"    # what the rifle was bone-parented to, and the Child Of target
BONE_LENGTH = 0.22         # long enough to grab in the viewport, short of the muzzle


def create_bone(armature):
    """A root-level, non-deforming bone sitting where the grip already is.

    Placed at the hand rather than at the rifle's origin: the origin of an FBX
    weapon is wherever its exporter left it (here, off past the stock), and a
    control you cannot see next to the hand it belongs to is a control nobody
    uses.
    """
    if BONE in armature.data.bones:
        sys.exit("[weapon] bone %r already exists -- nothing to do" % BONE)

    hand = armature.data.bones[HAND_BONE]
    head = hand.head_local.copy()
    # Down the hand's own axis, so the bone reads as an extension of the grip
    # rather than as an arbitrary stick.
    direction = (hand.tail_local - hand.head_local).normalized()

    bpy.context.view_layer.objects.active = armature
    bpy.ops.object.mode_set(mode="EDIT")
    eb = armature.data.edit_bones.new(BONE)
    eb.head = head
    eb.tail = head + direction * BONE_LENGTH
    eb.parent = None            # see module docstring
    eb.use_deform = False       # the mesh has no `weapon` vertex group
    bpy.ops.object.mode_set(mode="OBJECT")

    bone = armature.data.bones[BONE]
    # Without this the new bone lands in no collection and is simply invisible
    # in the viewport -- it would exist, and you could not select it.
    for coll in armature.data.bones[HAND_BONE].collections:
        coll.assign(bone)
    print("[weapon] created %r (deform=%s, parent=%s, collections=%s)"
          % (BONE, bone.use_deform, bone.parent,
             [c.name for c in bone.collections]))
    return bone


def add_child_of(armature):
    """Child Of `IK-hand.R`, with its inverse baked so nothing jumps.

    The inverse is the piece the UI's "Set Inverse" button computes; in a
    headless script it has to be written by hand or the rifle teleports by the
    full world transform of the hand.
    """
    pb = armature.pose.bones[BONE]
    con = pb.constraints.new("CHILD_OF")
    con.name = "Hold"
    con.target = armature
    con.subtarget = HAND_BONE
    bpy.context.view_layer.update()
    target_world = armature.matrix_world @ armature.pose.bones[HAND_BONE].matrix
    con.inverse_matrix = target_world.inverted()
    bpy.context.view_layer.update()
    print("[weapon] Child Of -> %s, influence %.1f" % (HAND_BONE, con.influence))
    return con


def reparent_rifle(armature, holder):
    """Move the holder Empty from the hand bone onto `weapon`, in place.

    The Empty carries the offset that seats the rifle in the fist, so it is the
    thing that gets re-parented -- not the rifle, whose local transform relative
    to the Empty is the fitted pose and must not change.
    """
    before = holder.matrix_world.copy()

    holder.parent = armature
    holder.parent_type = "BONE"
    holder.parent_bone = BONE
    holder.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.view_layer.update()
    # Re-assert the world transform through the new parent chain. A BONE parent
    # hangs off the bone's TAIL, so the basis this computes is not the one the
    # old IK-hand.R parenting used, and assuming otherwise slides the rifle.
    holder.matrix_world = before
    bpy.context.view_layer.update()

    drift = (holder.matrix_world.translation - before.translation).length
    print("[weapon] re-parented %r to bone %r (drift %.6f m)" % (holder.name, BONE, drift))
    if drift > 1e-4:
        sys.exit("[weapon] rifle moved during re-parent -- aborting")


def verify(armature, rifle):
    chain, node = [], rifle
    while node is not None:
        chain.append(node.name if not node.parent_bone
                     else "%s(bone %s)" % (node.name, node.parent_bone))
        node = node.parent
    print("[weapon] VERIFY chain: %s" % " -> ".join(chain))

    # The real test: move the hand and confirm the rifle came along.
    pb = armature.pose.bones[HAND_BONE]
    rest = rifle.matrix_world.translation.copy()
    pb.location.z += 0.30
    bpy.context.view_layer.update()
    moved = rifle.matrix_world.translation.copy()
    pb.location.z -= 0.30
    bpy.context.view_layer.update()
    back = rifle.matrix_world.translation.copy()
    print("[weapon] VERIFY hand +0.30 m moves rifle %.3f m; returns to within %.6f m"
          % ((moved - rest).length, (back - rest).length))
    if (moved - rest).length < 0.05:
        sys.exit("[weapon] rifle did NOT follow the hand -- Child Of is not working")


def main():
    out = sys.argv[sys.argv.index("--") + 1:][0]
    armature = bpy.data.objects[ARMATURE]
    holder = bpy.data.objects[RIFLE_HOLDER]

    create_bone(armature)
    add_child_of(armature)
    reparent_rifle(armature, holder)
    verify(armature, bpy.data.objects[RIFLE])

    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out))
    print("[weapon] wrote %s" % out)


if __name__ == "__main__":
    main()
