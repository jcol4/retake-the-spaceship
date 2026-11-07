"""Readies assets/civilian_cleaned.blend for export as `zombie_2`.

    blender.exe -b assets/civilian_cleaned.blend -P tools/clean_zombie_2.py
    blender.exe -b assets/civilian_cleaned.blend -P tools/export_models.py -- --variant zombie_2

export_models.py finds a pose's action BY NAME and deletes every action no pose
claims, so the hand-named clips (`real idle`, `punvh`, ...) would have been
dropped on the way out. They are renamed here to the pose names the game plays.

  real idle        -> idle
  running          -> run
  walking          -> walk
  punvh            -> melee
  hurt 1           -> hit_react
  dies of bodyshot -> downed
  run              -> run_merc   (tools/build_civilian_run.py's, superseded)

`headshot dying` is kept under its own name: a second death, not exported.

Also removes what the Mixamo imports left behind: the `mixamo.com` action
(keyed to `mixamorig1:` bones this rig does not have), an action assigned to the
MESH object, the armature's NLA stash track, and the stray `Main.002` root bone
(dropped only while no vertex is weighted to it).

Writes the .blend in place (Blender keeps the previous save as .blend1).
Re-runnable: a rename whose source is gone is skipped.
"""

import bpy

RENAMES = [
    # The superseded run first, so `running` can take its name.
    ("run", "run_merc"),
    ("real idle", "idle"),
    ("running", "run"),
    ("walking", "walk"),
    ("punvh", "melee"),
    ("hurt 1", "hit_react"),
    ("dies of bodyshot", "downed"),
]
STRAY_BONE = "Main.002"


def rename_actions():
    for old, new in RENAMES:
        action = bpy.data.actions.get(old)
        if action is None:
            continue
        if old == "run" and bpy.data.actions.get("running") is None:
            continue  # already renamed on an earlier pass: `run` IS the new run
        clash = bpy.data.actions.get(new)
        if clash is not None and clash is not action:
            raise SystemExit("[clean_zombie_2] both %r and %r exist" % (old, new))
        action.name = new
        action.use_fake_user = True
        print("[clean_zombie_2] %s -> %s" % (old, new))


def drop_leftovers(arm, mesh):
    for action in list(bpy.data.actions):
        if "mixamo.com" in action.name:
            print("[clean_zombie_2] removing action %s" % action.name)
            bpy.data.actions.remove(action)
    if mesh.animation_data is not None:
        mesh.animation_data_clear()
        print("[clean_zombie_2] cleared the mesh's own action")
    if arm.animation_data is not None:
        for track in list(arm.animation_data.nla_tracks):
            print("[clean_zombie_2] removing NLA track %s" % track.name)
            arm.animation_data.nla_tracks.remove(track)


def drop_stray_bone(arm, mesh):
    if arm.data.bones.get(STRAY_BONE) is None:
        return
    group = mesh.vertex_groups.get(STRAY_BONE)
    if group is not None:
        if any(e.group == group.index and e.weight > 0
               for v in mesh.data.vertices for e in v.groups):
            print("[clean_zombie_2] %s is weighted; left in place" % STRAY_BONE)
            return
        mesh.vertex_groups.remove(group)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    arm.data.edit_bones.remove(arm.data.edit_bones[STRAY_BONE])
    bpy.ops.object.mode_set(mode="OBJECT")
    print("[clean_zombie_2] removed bone %s" % STRAY_BONE)


def main():
    arm = bpy.data.objects["Armature"]
    mesh = bpy.data.objects["Ch36"]
    drop_leftovers(arm, mesh)
    drop_stray_bone(arm, mesh)
    rename_actions()
    # Opens standing.
    idle = bpy.data.actions["idle"]
    arm.animation_data_create()
    arm.animation_data.action = idle
    arm.animation_data.action_slot = idle.slots[0]
    bpy.ops.wm.save_mainfile()
    print("[clean_zombie_2] actions: %s" % ", ".join(sorted(a.name for a in bpy.data.actions)))


main()
