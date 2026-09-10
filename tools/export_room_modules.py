"""Turns the raw Rhino/Blender room-tile kit into clean, game-scaled .glb modules.

    blender.exe -b -P tools/export_room_modules.py

Reads every .blend in `assets/room_tiles/source/` (gitignored -- see the comment
next to it) and writes one .glb per module into `assets/room_tiles/modules/`
(tracked; this is what `MapBuilder`'s module table actually instances).

Why this exists at all: the source files are straight CAD exports out of Rhino,
one full Rhino scene's worth of objects per file (the intended module plus
~20-100 sibling parts -- pipes, bolts, a junction box -- that make up the same
assembly), all sitting at whatever offset Rhino happened to place them at, with
`Front`/`Right`/`Top`/`Perspective` preview cameras and empty nulls left in from
the CAD session, and two to four textures baked in at 6400x3600 / 12800x7200.
None of that is reachable from Godot as one clean, correctly-scaled prefab, and
the embedded textures alone are why the source files run 30-770MB each.

The per-file pipeline:

  1. Locate the "structural plate" object(s) -- the load-bearing panel, not any
     pipes/bolts/trim around it. A "_v2" source file is already one clean mesh
     per file (re-authored uniformly at 3m wall height -- see FILES below), so
     that single object IS the reference with no detection needed; `find_refs`
     falls back to the old height/vertex-count heuristic only for a multi-part
     file (kept for the pre-v2 sources still sitting in source/, unused today).
     Used as the reference frame for centring, so a torn-open chunk of debris
     on a damaged variant can't drag the pivot off its undamaged sibling's.
  2. Delete the CAD-session cameras and empties; join every remaining mesh
     object into one.
  3. Recentre: local origin -> (plate centre X, plate centre Y, plate floor Z),
     then move that origin to world (0,0,0). This is what makes the exported
     module's own origin land exactly on `MapBuilder.cell_to_world`'s tile
     centre with no per-module fixup needed at instance time.
  4. Bake a scale into the geometry, derived PER FILE from that file's own
     measured plate height vs. `MapBuilder.WALL_HEIGHT` -- not a single shared
     factor, because "measured uniformly" still means each file's plate comes
     out a few millimetres off 3.0m from the others. Every module ends up at
     scale 1 in game metres regardless.
  5. Downsample every embedded texture over `MAX_TEX` on a side. Real-time tile
     art has no use for a 12800x7200 CAD texture cache.
  6. Export the joined object alone as one .glb.

Known limitation, not solved here: `WallCorner` is a fixed-length bent run (both
legs are full wall-run pieces, not a compact 1-2 tile corner block), so it only
fits a procedurally generated corner whose two adjacent wall runs happen to
match its authored leg lengths. Fine for hand-authored decks built around the
kit's dimensions; an open question for BSP procgen. See MIGRATION_PLAN.md
Phase 8.
"""

import os

import bmesh
import bpy
import mathutils

ROOM_TILES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "assets", "room_tiles")
SOURCE_DIR = os.path.join(ROOM_TILES, "source")
OUT_DIR = os.path.join(ROOM_TILES, "modules")

# MapBuilder.WALL_HEIGHT. What every module's plate height is scaled to match.
WALL_HEIGHT = 3.0

# Real-time tiles have no use for the source kit's 6400x3600 / 12800x7200
# CAD texture caches.
MAX_TEX = 2048

# source filename -> (module name, fallback plate floor Z, centring mode).
#
# Only the three re-authored "_v2" files are wired in for now -- doors and the
# damaged variants are still the old, unfixed-scale exports (see git history)
# and aren't reprocessed until they get the same v2 pass. WallStraight is
# 7.5x3m, WallCorner 7.5x7.5x3m (per leg), WallEnd 4.5x3m -- all multiples of
# TILE_SIZE (1.5m), which is the whole point: MapBuilder places these at
# native scale, unstretched (see SEGMENT_TILES).
#
# `centring mode` is "refs" (use only the detected plate objects -- keeps
# damage debris or door-frame trim from skewing the pivot) except for the
# corner piece, which needs "full" so both legs are represented in its centre.
# Moot for a single-mesh v2 file (both modes read the same one object), kept
# for when a damaged/door v2 file lands and goes back to being multi-part.
#
# The fallback floor Z is only used when a file's plate objects don't match
# `find_refs`'s height window -- taken from an undamaged sibling sharing the
# same Rhino scene's coordinate frame, when one exists.
FILES = {
    "basic wall_v2.blend":      ("WallStraight", None, "refs"),
    "curved_wall_v2.blend":     ("WallCorner",   None, "full"),
    "short side wall_v2.blend": ("WallEnd",      None, "refs"),
}


def find_refs(objs):
    """The structural plate object(s). A "_v2" file has exactly one mesh --
    that IS the plate, no detection needed. Older multi-part files fall back
    to the height/vertex-count heuristic: a consistent ~3.3-3.4-tall mesh with
    a real vertex count, as opposed to the thin trim/bolt/pipe geometry that
    happens to share similar proportions."""
    mesh_objs = [o for o in objs if o.type == 'MESH']
    if len(mesh_objs) == 1:
        return mesh_objs
    cands = [o for o in mesh_objs if 3.1 <= o.dimensions.z <= 3.6
             and len(o.data.vertices) >= 400]
    if not cands:
        return []
    cands.sort(key=lambda o: -len(o.data.vertices))
    top = len(cands[0].data.vertices)
    return [o for o in cands if len(o.data.vertices) >= top * 0.85][:4]


def world_bbox(objs):
    mn = mathutils.Vector((1e18,) * 3)
    mx = mathutils.Vector((-1e18,) * 3)
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ mathutils.Vector(c)
            mn.x = min(mn.x, w.x); mn.y = min(mn.y, w.y); mn.z = min(mn.z, w.z)
            mx.x = max(mx.x, w.x); mx.y = max(mx.y, w.y); mx.z = max(mx.z, w.z)
    return mn, mx


def export_one(fname, out_name, fallback_floor, center_mode):
    bpy.ops.wm.open_mainfile(filepath=os.path.join(SOURCE_DIR, fname))

    mesh_objs = [o for o in bpy.data.objects if o.type == 'MESH']
    refs = find_refs(mesh_objs)
    full_mn, full_mx = world_bbox(mesh_objs)

    if refs:
        ref_mn, ref_mx = world_bbox(refs)
        floor_z = ref_mn.z
        plate_height = ref_mx.z - ref_mn.z
    else:
        floor_z = fallback_floor if fallback_floor is not None else full_mn.z
        ref_mn, ref_mx = full_mn, full_mx
        plate_height = full_mx.z - full_mn.z
    scale = WALL_HEIGHT / plate_height if plate_height > 0.01 else 1.0

    if center_mode == "refs" and refs:
        center_x = (ref_mn.x + ref_mx.x) / 2
        center_y = (ref_mn.y + ref_mx.y) / 2
    else:
        center_x = (full_mn.x + full_mx.x) / 2
        center_y = (full_mn.y + full_mx.y) / 2

    # Every mesh is parented to a Rhino "layer" empty carrying a 0.3048 (1 ft)
    # scale -- that's how the source kit's Rhino-to-Blender bridge expresses
    # its foot-to-metre correction, and it's why the bounding boxes above (via
    # matrix_world) already come out correct. But it means deleting those
    # empties without baking their transform into the mesh FIRST un-scales
    # every child back up by 1/0.3048 the moment the depsgraph next
    # evaluates. `parent_clear(type='CLEAR_KEEP_TRANSFORM')` was tried here
    # and did not reliably survive the join afterwards; baking each object's
    # matrix_world into its own vertex data by hand does, so that's what this
    # does instead -- after this loop every mesh object sits at an identity
    # transform with no parent, and its geometry alone already reflects
    # everything the old parent chain used to contribute.
    mesh_objs = [o for o in bpy.data.objects if o.type == 'MESH']
    for o in mesh_objs:
        mat = o.matrix_world.copy()
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
        baked = bpy.data.meshes.new(o.data.name + "_baked")
        bm.to_mesh(baked)
        bm.free()
        for m in o.data.materials:
            baked.materials.append(m)
        o.data = baked
        o.parent = None
        o.matrix_world = mathutils.Matrix.Identity(4)

    # Drop the CAD-session cameras and empties; nothing downstream reads them.
    for o in list(bpy.data.objects):
        if o.type != 'MESH':
            bpy.data.objects.remove(o, do_unlink=True)

    mesh_objs = [o for o in bpy.data.objects if o.type == 'MESH']
    for o in bpy.data.objects:
        o.select_set(False)
    for o in mesh_objs:
        o.select_set(True)
    view_layer = bpy.context.view_layer
    view_layer.objects.active = mesh_objs[0]
    if len(mesh_objs) > 1:
        with bpy.context.temp_override(active_object=mesh_objs[0], selected_editable_objects=mesh_objs,
                                        view_layer=view_layer):
            bpy.ops.object.join()
    joined = view_layer.objects.active
    joined.name = out_name

    # Local origin -> (centre, floor), then that origin -> world (0,0,0), so
    # the module's own origin lands on MapBuilder.cell_to_world's tile centre.
    bpy.context.scene.cursor.location = (center_x, center_y, floor_z)
    with bpy.context.temp_override(active_object=joined, selected_editable_objects=[joined],
                                    view_layer=view_layer, scene=bpy.context.scene):
        bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
    joined.location = (0.0, 0.0, 0.0)

    joined.scale = (scale,) * 3
    with bpy.context.temp_override(active_object=joined, selected_editable_objects=[joined],
                                    view_layer=view_layer):
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    for img in bpy.data.images:
        if img.name in ("Render Result", "Viewer Node"):
            continue
        w, h = img.size[0], img.size[1]
        if w > MAX_TEX or h > MAX_TEX:
            tex_scale = MAX_TEX / max(w, h)
            img.scale(max(1, round(w * tex_scale)), max(1, round(h * tex_scale)))

    os.makedirs(OUT_DIR, exist_ok=True)
    outpath = os.path.join(OUT_DIR, out_name + ".glb")
    for o in bpy.data.objects:
        o.select_set(o is joined)
    view_layer.objects.active = joined
    with bpy.context.temp_override(active_object=joined, selected_editable_objects=[joined],
                                    view_layer=view_layer, scene=bpy.context.scene):
        bpy.ops.export_scene.gltf(
            filepath=outpath,
            export_format='GLB',
            use_selection=True,
            export_yup=True,
            export_apply=True,
            export_materials='EXPORT',
            export_image_format='AUTO',
        )
    size_mb = os.path.getsize(outpath) / (1024 * 1024)
    print(f"exported {fname} -> {out_name}.glb ({size_mb:.2f} MB) "
          f"plate_height={plate_height:.4f} scale={scale:.4f}")


if __name__ == "__main__":
    for fname, (out_name, fallback_floor, center_mode) in FILES.items():
        export_one(fname, out_name, fallback_floor, center_mode)
