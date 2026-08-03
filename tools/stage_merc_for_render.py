"""Stage the demo merc into the sprite-render camera/light rig.

  blender.exe -b art_src/merc_render.blend -P stage_merc.py -- art_src/merc_anim.blend

Appends the rigged character + rifle from assets/mixamo_test_fixed.blend, sizes
and orients it to the contract in tools/render_sprites.py (1.92 m tall, feet on
z=0 at the origin, facing Blender +Y), drops the appended camera/light, and
clears the leftover mixamo T-pose action.
"""

import math
import os
import sys

import bpy
from mathutils import Vector

SRC = os.path.abspath("assets/mixamo_test_fixed.blend")

## Appended by OBJECT, not by collection, and all five in ONE operation.
##
## The source blend splits the character across two places: `Collection` holds
## Armature/Ch36 (plus a camera and a light we don't want), while the rifle and
## its two empties are loose in the scene's root collection. Appending
## `Collection` therefore silently leaves the rifle behind.
##
## One operation rather than five because Blender resolves parenting only
## between objects appended together -- append the Empty on its own and it drags
## in a SECOND copy of the armature as a dependency.
SRC_OBJECTS = ["Armature", "Ch36", "AssaultRifle2_1", "Empty", "Empty.001"]
ARMATURE = "Armature"
MESH = "Ch36"
DEAD_ACTION = "Armature|mixamo.com|Layer0"

CHARACTER_HEIGHT = 1.92  # mirrors render_sprites.CHARACTER_HEIGHT


def append_objects():
    before = set(bpy.data.objects.keys())
    bpy.ops.wm.append(
        directory=os.path.join(SRC, "Object") + os.sep,
        files=[{"name": n} for n in SRC_OBJECTS],
    )
    new = [bpy.data.objects[n] for n in bpy.data.objects.keys() if n not in before]
    print("[stage] appended: %s" % ", ".join(sorted(o.name for o in new)))
    missing = [n for n in SRC_OBJECTS if n not in bpy.data.objects]
    if missing:
        sys.exit("[stage] append missed: %s" % ", ".join(missing))
    dupes = [o.name for o in new if o.name not in SRC_OBJECTS]
    if dupes:
        sys.exit("[stage] append pulled duplicates: %s" % ", ".join(dupes))
    return new


def drop_extra_cameras_and_lights(new_objects):
    """The source blend ships its own Camera and Light; SpriteCam/SpriteKey win."""
    doomed = [o for o in new_objects if o.type in ("CAMERA", "LIGHT")]
    for o in doomed:
        print("[stage] removing appended %s %r" % (o.type.lower(), o.name))
        bpy.data.objects.remove(o, do_unlink=True)
    return [o for o in new_objects if o not in doomed]


def rest_bounds(mesh_obj, armature):
    """World-space bounds of the UNDEFORMED mesh.

    `bound_box` is the mesh datablock's box, so it already ignores the armature
    modifier -- which is what we want: the rest pose is the thing being sized,
    not whatever frame the leftover action happens to sit on.
    """
    corners = [mesh_obj.matrix_world @ Vector(c) for c in mesh_obj.bound_box]
    return corners


def stage_transform(armature, mesh_obj):
    corners = rest_bounds(mesh_obj, armature)
    z_min = min(c.z for c in corners)
    z_max = max(c.z for c in corners)
    height = z_max - z_min
    scale = CHARACTER_HEIGHT / height
    print("[stage] rest height %.3f m -> scale %.4f" % (height, scale))

    # Feet point -Y on this rig (foot bone direction is (0, -0.93, -0.33)), and
    # the pipeline renders bucket 0 assuming a character facing +Y. 180 degrees.
    armature.rotation_euler = (0.0, 0.0, math.pi)
    armature.scale = (scale, scale, scale)
    armature.location = (0.0, 0.0, 0.0)
    bpy.context.view_layer.update()

    # Anchor on the midpoint between the feet rather than the bbox centre: the
    # bbox is dominated by the T-pose arm span, the feet are what stand on the
    # tile. Measured after the rotation/scale are live, so the values are world.
    feet = [armature.matrix_world @ armature.data.bones[n].head_local
            for n in ("foot.L", "foot.R") if n in armature.data.bones]
    if feet:
        mid = sum(feet, Vector()) / len(feet)
        armature.location.x -= mid.x
        armature.location.y -= mid.y
    armature.location.z -= z_min * scale
    bpy.context.view_layer.update()
    print("[stage] armature loc=%s rot_z=%.0f deg scale=%.4f"
          % (tuple(round(v, 4) for v in armature.location),
             math.degrees(armature.rotation_euler.z), scale))


def fix_rifle_alpha(rifle):
    """The FBX gave every rifle material Alpha = 0.

    Invisible in Cycles, and invisible in EEVEE too since the same import set
    blend_method to HASHED -- but NOT invisible in solid-shaded viewport, which
    is why it looks fine while you model and then renders as nothing.
    """
    fixed = []
    for mat in rifle.data.materials:
        if mat is None or not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED" and not node.inputs["Alpha"].is_linked:
                if node.inputs["Alpha"].default_value < 1.0:
                    node.inputs["Alpha"].default_value = 1.0
                    fixed.append(mat.name)
        mat.blend_method = "OPAQUE"
    print("[stage] alpha 0 -> 1 on: %s" % (", ".join(fixed) or "nothing"))


def reset_pose(armature):
    """Back to rest, so the first action is keyed from a clean pose.

    Dropping the action leaves whatever pose was last evaluated sitting on the
    bones -- pose transforms live on the OBJECT, not in the action, so removing
    one does not undo the other.
    """
    for pb in armature.pose.bones:
        pb.location = (0.0, 0.0, 0.0)
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.rotation_axis_angle = (0.0, 0.0, 1.0, 0.0)
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()
    print("[stage] cleared pose transforms on %d bones" % len(armature.pose.bones))


def clear_dead_action(armature):
    if armature.animation_data:
        armature.animation_data.action = None
    act = bpy.data.actions.get(DEAD_ACTION)
    if act is not None:
        act.use_fake_user = False
        bpy.data.actions.remove(act)
        print("[stage] removed action %r" % DEAD_ACTION)
    remaining = [a.name for a in bpy.data.actions]
    print("[stage] actions now: %s" % (remaining or "none"))


def verify(armature, mesh_obj):
    corners = rest_bounds(mesh_obj, armature)
    z_min = min(c.z for c in corners)
    z_max = max(c.z for c in corners)
    print("[stage] VERIFY height %.3f m, feet z %.4f, head z %.3f"
          % (z_max - z_min, z_min, z_max))
    foot = armature.data.bones.get("foot.L")
    if foot:
        d = (armature.matrix_world.to_3x3() @ (foot.tail_local - foot.head_local)).normalized()
        print("[stage] VERIFY toe direction %s (want +Y)"
              % (tuple(round(v, 2) for v in d),))
    scene = bpy.context.scene
    print("[stage] VERIFY scene camera %r, fps %d, engine %s"
          % (scene.camera.name if scene.camera else None,
             scene.render.fps, scene.render.engine))
    # The rifle must ride the armature, or rotating the character through the 8
    # facings would leave the gun behind in world space.
    rifle = bpy.data.objects.get("AssaultRifle2_1")
    chain, node = [], rifle
    while node is not None:
        chain.append(node.name if not node.parent_bone else
                     "%s(bone %s)" % (node.name, node.parent_bone))
        node = node.parent
    print("[stage] VERIFY rifle parent chain: %s" % " -> ".join(chain))
    hand = armature.matrix_world @ armature.data.bones["hand.R"].head_local
    muzzle_gap = (rifle.matrix_world.translation - hand).length
    print("[stage] VERIFY rifle origin %s, %.3f m from hand.R"
          % (tuple(round(v, 3) for v in rifle.matrix_world.translation), muzzle_gap))

    roots = [o for o in bpy.data.objects if o.type == "ARMATURE" and o.parent is None]
    print("[stage] VERIFY root armatures: %s (render_sprites needs exactly one)"
          % ", ".join(o.name for o in roots))


def main():
    out = sys.argv[sys.argv.index("--") + 1:][0]

    if bpy.data.objects.get(ARMATURE):
        sys.exit("[stage] %r already present -- refusing to append twice" % ARMATURE)

    new = drop_extra_cameras_and_lights(append_objects())
    armature = bpy.data.objects[ARMATURE]
    mesh_obj = bpy.data.objects[MESH]

    stage_transform(armature, mesh_obj)
    fix_rifle_alpha(bpy.data.objects["AssaultRifle2_1"])
    clear_dead_action(armature)
    reset_pose(armature)
    verify(armature, mesh_obj)

    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out))
    print("[stage] wrote %s" % out)


if __name__ == "__main__":
    main()
