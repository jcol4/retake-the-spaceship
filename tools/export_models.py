"""Exports a rigged Blender character to the .glb the game draws it with.

    # One character, from the .blend it is animated in.
    blender.exe -b art_src/merc_anim.blend -P tools/export_models.py -- --variant merc

    # A worm pile: writes a LAYOUT (.json), not a model -- see export_pile.
    blender.exe -b art_src/worm_pile_tide.blend -P tools/export_models.py -- --variant worm_tide

    # Everything, each from its own .blend (spawns one Blender per variant).
    blender.exe -b -P tools/export_models.py -- --all

This replaces the sprite render as the path a character reaches the game by.
`render_sprites.py` flattened the rig into eight facings of PNGs and stood them
on a vertical card; the card could not know how far in front of the root a
planted boot was, so the feet floated or sank depending on facing. A real mesh
stands on the floor by construction and there is no anchor left to tune.

What carries over from the sprite pipeline, deliberately IMPORTED from
render_sprites.py rather than restated here, so the two cannot drift:

  * POSES / POSE_ACTION -- which Blender action a game pose is drawn from. The
    exported animations are RENAMED to the pose, so the game looks up `idle`,
    `throw_grenade`, `hit_react` and never has to know the .blend said `grenade`.
  * VARIANT_BUCKET_ZERO / BUCKET_ZERO_DEGREES -- the rig's rest yaw. The sprite
    renderer overwrote the armature's Z rotation with this before every facing;
    the export does the same once, so a unit at yaw 0 faces exactly as bucket 0
    was drawn. POSE_BUCKET_ZERO (the merc's `run`, authored a quarter turn off)
    is written to the sidecar and applied in game while that pose plays.
  * mute_object_transform_curves' reason: object-level keys on the armature
    would fight the facing the game gives the unit, so they are REMOVED (the
    .blend is never written, so this is in memory only).

The sidecar `<variant>.json` next to the .glb carries what the .glb cannot:
the per-pose yaw corrections.
"""

import argparse
import json
import math
import os
import subprocess
import sys

import bpy
from mathutils import Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_sprites as rs  # noqa: E402  (Blender adds this dir only via the line above)

OUT_DIR = os.path.join("assets", "models")

## Cover reloads: drawn in merc_anim.blend and resolved by unit_visual.gd's cover
## chain, but never on render_sprites.py's list because the sprite set skipped them.
EXTRA_POSES = ["reload_low", "reload_high"]

## Which .blend each variant is exported from. Piles are listed separately
## because they are not models (see export_pile).
MODELS = {
    "merc": "art_src/merc_anim.blend",
    "brawler": "art_src/zombie_anim.blend",
    "worm": "art_src/worm_anims.blend",
    "nest": "art_src/worm_spawn_scaled.blend",
}
## Game-budget reductions, applied in memory on the way out. The sources were
## made for 256 px sprite renders and a Mixamo download, not for a scene with
## sixteen of them on screen: the nest shipped four packed 4096 px maps and a
## 132k-poly mesh (a 52 MB .glb), and a 0.35 m worm carries 20k polys that a
## sixteen-worm Tide multiplies.
##
##   decimate    -- collapse ratio for every skinned mesh, placed ahead of the
##                  armature modifier so it runs in rest pose
##   max_texture -- longest edge any image is scaled down to
MAX_TEXTURE = 2048
BUDGET = {
    "nest": {"decimate": 0.15, "max_texture": 1024},
    "worm": {"decimate": 0.3, "max_texture": 1024},
}

PILES = {
    "worm_clutch": "art_src/worm_pile_clutch.blend",
    "worm_knot": "art_src/worm_pile_knot.blend",
    "worm_tide": "art_src/worm_pile_tide.blend",
}
## The model every pile instance is a copy of.
PILE_BASE = "worm"

## Blender (x, y, z) -> Godot (x, z, -y): the axis swap the glTF exporter
## applies with +Y up. Used to hand pile transforms to the game in its own axes.
TO_GODOT = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))


def strip_scene(character):
    """Deletes everything that is not the character: cameras, lights, and any
    object hidden from render (the ground reference, the nest's stowed rifle)."""
    keep = {character} | set(character.children_recursive)
    doomed = [o for o in bpy.data.objects
              if o not in keep or o.type in ("CAMERA", "LIGHT") or o.hide_render]
    # Children of a hidden object go with it, or they would be exported
    # floating where their parent was.
    for obj in list(doomed):
        doomed.extend(obj.children_recursive)
    for obj in set(doomed):
        bpy.data.objects.remove(obj, do_unlink=True)


def pose_actions(variant, character):
    """Renames (or copies) each pose's source action to the pose name, strips
    its object-level armature transform keys, and deletes every action no pose
    uses. Returns the poses exported."""
    wanted = {}
    for pose in rs.POSES + EXTRA_POSES:
        src = bpy.data.actions.get(rs.source_action(pose, variant))
        if src is not None:
            wanted[pose] = src
    if not wanted:
        sys.exit("[export_models] no action matched any pose for %r" % variant)

    # The first pose to claim an action takes it by RENAME; any later pose
    # sharing it (the worm's bite is its idle) gets a copy. Renaming rather than
    # copying keeps the child objects' assignments -- the rifle holder and the
    # muzzle flash are slots on these same actions -- pointing at something that
    # survives the cleanup below.
    staged = {}
    claimed = set()
    for pose, src in wanted.items():
        staged[pose] = src.copy() if src in claimed else src
        claimed.add(src)
    for pose, action in staged.items():
        action.name = "__pose__" + pose  # two passes, so no rename collides
    for pose, action in staged.items():
        action.name = pose
    keep = set(staged.values())
    for action in list(bpy.data.actions):
        if action not in keep:
            bpy.data.actions.remove(action)
    for pose, action in staged.items():
        action.name = pose
        action.use_fake_user = True
        character.animation_data_create()
        character.animation_data.action = action
        if character.animation_data.action_slot is None:
            slots = list(action.slots)
            if slots:
                character.animation_data.action_slot = slots[0]
        # Object-level transform on the ROOT would fight the unit's own facing
        # and position; see the module docstring.
        for bag in rs._character_channelbags(action, character):
            for fcurve in list(bag.fcurves):
                if fcurve.data_path in ("location", "rotation_euler",
                                        "rotation_quaternion", "scale"):
                    bag.fcurves.remove(fcurve)
    # Leaves the character on its idle, so the imported rest is standing.
    if "idle" in staged:
        character.animation_data.action = staged["idle"]
    return sorted(staged)


def apply_budget(variant):
    budget = BUDGET.get(variant, {})
    ratio = budget.get("decimate")
    if ratio:
        for obj in bpy.data.objects:
            if obj.type != "MESH" or not any(m.type == "ARMATURE" for m in obj.modifiers):
                continue
            before = len(obj.data.polygons)
            mod = obj.modifiers.new("export_decimate", "DECIMATE")
            mod.ratio = ratio
            # First in the stack: decimating after the armature would bake a pose.
            with bpy.context.temp_override(object=obj):
                bpy.ops.object.modifier_move_to_index(modifier=mod.name, index=0)
            print("[export_models] %s: decimating %d polys x %.2f" % (obj.name, before, ratio))
    limit = budget.get("max_texture", MAX_TEXTURE)
    for image in bpy.data.images:
        w, h = image.size
        if max(w, h) > limit:
            s = limit / max(w, h)
            image.scale(max(1, int(w * s)), max(1, int(h * s)))
            print("[export_models] %s: %dx%d -> %dx%d" % (image.name, w, h, *image.size))


def export_model(variant, out_dir):
    character = rs.find_character(None)
    strip_scene(character)
    rs.unlink_missing_images()
    apply_budget(variant)
    poses = pose_actions(variant, character)
    # The rest yaw, set once where the sprite renderer set it before every
    # facing. Only Z: the worm's rig lies ~93 degrees about X and that tilt is
    # the model, not a facing.
    character.rotation_mode = "XYZ"
    character.rotation_euler.z = math.radians(
        rs.VARIANT_BUCKET_ZERO.get(variant, rs.BUCKET_ZERO_DEGREES))

    os.makedirs(out_dir, exist_ok=True)
    glb = os.path.join(out_dir, variant + ".glb")
    bpy.ops.export_scene.gltf(
        filepath=glb,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_anim_slide_to_zero=True,
        export_force_sampling=True,
        export_frame_range=False,
        export_def_bones=False,
        export_image_format="AUTO",
    )
    yaw = {pose: delta for pose, delta in rs.POSE_BUCKET_ZERO.get(variant, {}).items()}
    sidecar = {"variant": variant, "poses": poses, "pose_yaw_degrees": yaw}
    with open(os.path.join(out_dir, variant + ".json"), "w") as f:
        json.dump(sidecar, f, indent=2)
    print("[export_models] wrote %s (%d poses: %s)" % (glb, len(poses), ", ".join(poses)))


def export_pile(variant, out_dir):
    """A worm pile is written as a LAYOUT of the single worm, not as a model.

    The pile .blend is N copies of the worm armature parented to a `WormPile`
    Empty, each on its own phase-shifted copy of every action. Exported as a
    mesh that would be N skeletons and N x actions in one file; in game it is N
    instances of worm.glb, each seeked to its own phase -- the same writhe for
    one shared asset.

    Per instance: the transform to give a worm.glb root so its armature lands
    where the pile put it (Godot axes, relative to the pile's origin), and its
    phase as a fraction of the cycle.
    """
    empty = bpy.data.objects.get("WormPile")
    if empty is None:
        sys.exit("[export_models] %s has no WormPile Empty" % bpy.data.filepath)
    empty.rotation_euler = (0.0, 0.0, math.radians(
        rs.VARIANT_BUCKET_ZERO.get(variant, rs.BUCKET_ZERO_DEGREES)))
    empty.location = (0.0, 0.0, 0.0)
    bpy.context.view_layer.update()

    base_zero = math.radians(rs.VARIANT_BUCKET_ZERO.get(PILE_BASE, rs.BUCKET_ZERO_DEGREES))
    instances = []
    for arm in sorted((o for o in empty.children if o.get(rs.PILE_INDEX_PROP) is not None),
                      key=lambda o: int(o[rs.PILE_INDEX_PROP])):
        index = int(arm[rs.PILE_INDEX_PROP])
        # What worm.glb's root holds: the same rig at the origin with its Z
        # replaced by the worm's bucket zero (export_model).
        rot = arm.rotation_euler.copy()
        rot.z = base_zero
        exported = Matrix.LocRotScale(None, rot.to_matrix(), arm.scale)
        root = arm.matrix_world @ exported.inverted()
        g = TO_GODOT @ root @ TO_GODOT.inverted()
        # Phase: how far this instance's idle copy is shifted, as a fraction.
        phase = 0.0
        src = bpy.data.actions.get("worm idle")
        copy = bpy.data.actions.get("worm idle.pile%02d" % index)
        if src is not None and copy is not None:
            period = max(1.0, src.frame_range[1] - src.frame_range[0])
            a = min(k.co.x for fc in _fcurves(src) for k in fc.keyframe_points)
            b = min(k.co.x for fc in _fcurves(copy) for k in fc.keyframe_points)
            # Shifting keys LATER by d means the instance is d frames BEHIND.
            phase = (-(b - a) / period) % 1.0
        instances.append({
            "index": index,
            "basis": [[g[r][c] for c in range(3)] for r in range(3)],
            "origin": [g[r][3] for r in range(3)],
            "phase": phase,
        })
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, variant + ".json")
    with open(path, "w") as f:
        # Only the poses the pile is aliased to (render_sprites.POSE_ACTION):
        # worm.glb also carries `melee`, which a mass does not have -- it
        # tramples by walking.
        json.dump({"variant": variant, "pile_of": PILE_BASE,
                   "poses": sorted(rs.POSE_ACTION.get(variant, {})),
                   "instances": instances}, f, indent=2)
    print("[export_models] wrote %s (%d instances of %s)" % (path, len(instances), PILE_BASE))


def _fcurves(action):
    return [fc for layer in action.layers for strip in layer.strips
            for bag in getattr(strip, "channelbags", ()) for fc in bag.fcurves]


def export_all():
    blender = bpy.app.binary_path
    me = os.path.abspath(__file__)
    for variant, blend in list(MODELS.items()) + list(PILES.items()):
        print("[export_models] --- %s from %s" % (variant, blend))
        result = subprocess.run([blender, "-b", blend, "-P", me, "--", "--variant", variant])
        if result.returncode != 0:
            sys.exit("[export_models] %s failed" % variant)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--out", default=OUT_DIR)
    args = parser.parse_args(argv)
    if args.all:
        export_all()
    elif args.variant in PILES:
        export_pile(args.variant, os.path.abspath(args.out))
    elif args.variant:
        export_model(args.variant, os.path.abspath(args.out))
    else:
        sys.exit("pass --variant <name> or --all")


if __name__ == "__main__":
    main()
