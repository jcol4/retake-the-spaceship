"""Builds the Mixamo zombie's .blend (Fodder) from the raw Mixamo downloads.

    blender.exe -b -P tools/build_zombie_mixamo.py

Reads art_src/zombie_mixamo/: the skinned character (Ch10_nonPBR.fbx) and one
skinless FBX per clip, all downloaded against that same character so the bone
names match. Each clip FBX brings its own armature; only its ACTION is kept,
renamed to the pose the game plays it as, and the armature is deleted -- the
export wants exactly one root armature (render_sprites.find_character).

A demo stand-in until the in-house zombie is animated: it replaces the civilian
on scenes/swarm_unit.tscn and touches nothing else.

Writes art_src/zombie_mixamo.blend, which tools/export_models.py exports:

    blender.exe -b art_src/zombie_mixamo.blend -P tools/export_models.py -- --variant zombie

Re-runnable: it starts from an empty scene every time.
"""

import os

import bpy

SRC_DIR = os.path.join("art_src", "zombie_mixamo")
OUT_BLEND = os.path.join("art_src", "zombie_mixamo.blend")
CHARACTER = "Ch10_nonPBR.fbx"

## Pose name -> the Mixamo download it is drawn from. The pose names are the
## game's own (UnitVisual), so no POSE_ACTION alias is needed.
CLIPS = {
    "idle": "Zombie Idle.fbx",
    "run": "Zombie Running.fbx",
    "melee": "Zombie Neck Bite.fbx",
    "downed": "Zombie Death.fbx",
    "alert_scream": "Zombie Scream.fbx",
}
## Mixamo's root motion lives on this bone. The game moves the unit itself.
## Matched by suffix: the prefix is numbered per download (`mixamorig5:Hips`).
HIPS = ":Hips"
## Clips that travel in Mixamo but must play in place here. The run's forward
## drift is flattened; the death keeps its fall and the bite its lunge, since a
## one-shot hands back to the stance and its travel is part of the read.
IN_PLACE = ["run"]


def import_fbx(name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=os.path.abspath(os.path.join(SRC_DIR, name)),
                             automatic_bone_orientation=False, ignore_leaf_bones=False)
    return [o for o in bpy.data.objects if o not in before]


def armature_in(objects):
    arms = [o for o in objects if o.type == "ARMATURE"]
    if len(arms) != 1:
        raise SystemExit("[build_zombie] expected one armature, got %d" % len(arms))
    return arms[0]


def flatten_root_motion(action):
    """Removes each Hips location channel's start-to-end drift, linearly over the
    clip, so a loop that walks off ends where it began. A clip downloaded with
    "In Place" already has none and comes through unchanged."""
    for fcurve in _fcurves(action):
        if not fcurve.data_path.endswith('%s"].location' % HIPS) or len(fcurve.keyframe_points) < 2:
            continue
        keys = fcurve.keyframe_points
        f0, v0 = keys[0].co
        f1, v1 = keys[-1].co
        drift = v1 - v0
        if abs(drift) < 1.0:  # rest units are cm: under 1 cm is noise
            continue
        print("[build_zombie] %s: flattening %.1f cm of Hips drift on axis %d"
              % (action.name, drift, fcurve.array_index))
        for k in keys:
            t = (k.co[0] - f0) / (f1 - f0)
            shift = drift * t
            k.co[1] -= shift
            k.handle_left[1] -= shift
            k.handle_right[1] -= shift
        fcurve.update()


def _fcurves(action):
    # Blender 4.4+ keeps fcurves in layered channelbags.
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield from bag.fcurves


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    character = armature_in(import_fbx(CHARACTER))
    character.name = "Armature"
    # The character download carries a T-pose take of its own; no pose uses it.
    stray = set(bpy.data.actions)

    for pose, filename in CLIPS.items():
        objects = import_fbx(filename)
        rig = armature_in(objects)
        action = rig.animation_data.action if rig.animation_data else None
        if action is None:
            raise SystemExit("[build_zombie] %s has no animation" % filename)
        action.name = pose
        action.use_fake_user = True
        if pose in IN_PLACE:
            flatten_root_motion(action)
        print("[build_zombie] %s <- %s (frames %d-%d)" % (pose, filename, *action.frame_range))
        for obj in objects:
            bpy.data.objects.remove(obj, do_unlink=True)

    for action in stray:
        bpy.data.actions.remove(action)
    character.animation_data_create()
    character.animation_data.action = bpy.data.actions["idle"]

    # Height check against the unit's 1.8 m collision capsule.
    meshes = [o for o in character.children_recursive if o.type == "MESH"]
    zs = [(o.matrix_world @ v.co).z for o in meshes for v in o.data.vertices]
    print("[build_zombie] rest height %.2f m" % (max(zs) - min(zs)))

    bpy.ops.file.pack_all()
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(OUT_BLEND))
    print("[build_zombie] wrote %s" % OUT_BLEND)


main()
