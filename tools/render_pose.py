"""Render one frame of one clip from a built character GLB, as a contact sheet.

The support-hand lock (tools/build_anims.py) moves the wrist by up to 200 mm in
some clips, which is far too much to accept on a numeric check alone -- a solve
can put the wrist exactly on target and still bend the elbow somewhere the arm
does not go. This is the eyeball half of that verification.

Renders Workbench, not EEVEE: the Mixamo character's textures are irrelevant to
whether an arm is broken, and Workbench is roughly an order of magnitude faster.

Usage:
    blender -b -P tools/render_pose.py -- --glb assets/soldier_mixamo.glb \
        --clips aim_hold-loop,idle-loop,run-loop --out out/support_lock.png
"""

import math
import os
import sys

import bpy
from mathutils import Matrix, Vector


def log(msg):
    print(f"[render_pose] {msg}")


def find_armature():
    arms = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not arms:
        raise SystemExit("no armature in the file")
    return arms[0]


def bind(arm, act):
    ad = arm.animation_data or arm.animation_data_create()
    ad.action = act
    if hasattr(ad, "action_slot") and ad.action_slot is None:
        slots = getattr(act, "slots", None)
        if slots:
            ad.action_slot = slots[0]


def proxy_weapon(arm, place, name):
    """A rod on the grip axis: from behind the right hand out past the left.

    The numeric check proves the hands are a fixed distance apart. It cannot
    show whether they are oriented to hold anything -- a wrist rotated 90 degrees
    off still measures a perfect 400 mm. Drawing the axis both hands are supposed
    to be gripping makes that visible: on a good lock the fingers of both hands
    curl around the rod, and a bad one reads immediately as a hand floating
    beside it.
    """
    rh = arm.pose.bones["RightHand"]
    lh = arm.pose.bones["LeftHand"]
    mw = arm.matrix_world
    grip = mw @ rh.matrix.translation
    support = mw @ lh.matrix.translation
    axis = (support - grip)
    if axis.length < 1e-6:
        return []
    length = axis.length
    axis = axis.normalized()
    u = axis.orthogonal().normalized()
    v = axis.cross(u).normalized()

    # Stock end a little behind the grip, muzzle well past the support hand, so
    # the rod reads as a weapon rather than as a segment between two points.
    a = grip - axis * (length * 0.45)
    b = grip + axis * (length * 1.75)
    r = 0.018
    verts, faces = [], []
    for end in (a, b):
        for du, dv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            verts.append(end + u * (du * r) + v * (dv * r))
    faces.append((0, 1, 2, 3))
    faces.append((7, 6, 5, 4))
    for i in range(4):
        j = (i + 1) % 4
        faces.append((i, 4 + i, 4 + j, j))

    me = bpy.data.meshes.new(f"{name}_proxy")
    me.from_pydata([tuple(p) for p in verts], [], faces)
    me.validate()
    obj = bpy.data.objects.new(f"{name}_proxy", me)
    bpy.context.collection.objects.link(obj)
    obj.matrix_world = place @ obj.matrix_world
    return [obj]


def snapshot(arm, meshes, act, frame, offset_x, yaw_deg, proxy=False):
    """Freeze the posed mesh into a static copy at `offset_x`, yawed."""
    bind(arm, act)
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()

    made = []
    deps = bpy.context.evaluated_depsgraph_get()
    # Composed, not assigned component-wise. Setting matrix_world and then
    # overwriting .location/.rotation_euler discards the source's scale, and a
    # Mixamo import carries a 0.01 -- which renders as a 100x blob filling the
    # frame rather than as anything recognisably wrong.
    place = (Matrix.Translation((offset_x, 0.0, 0.0))
             @ Matrix.Rotation(math.radians(yaw_deg), 4, "Z"))
    for src in meshes:
        ev = src.evaluated_get(deps)
        me = bpy.data.meshes.new_from_object(ev)
        obj = bpy.data.objects.new(f"{act.name}_{frame}_{src.name}", me)
        bpy.context.collection.objects.link(obj)
        obj.matrix_world = place @ src.matrix_world
        made.append(obj)
    if proxy:
        made += proxy_weapon(arm, place, f"{act.name}_{frame}")
    return made


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--glb" not in argv or "--out" not in argv:
        raise SystemExit(
            "usage: blender -b -P tools/render_pose.py -- --glb <p> --out <p> "
            "[--clips a,b,c] [--yaw 35]")
    glb = argv[argv.index("--glb") + 1]
    out = argv[argv.index("--out") + 1]
    yaw = float(argv[argv.index("--yaw") + 1]) if "--yaw" in argv else 35.0
    want = (argv[argv.index("--clips") + 1].split(",")
            if "--clips" in argv else None)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)
    arm = find_armature()
    found = [o for o in bpy.data.objects if o.type == "MESH"]
    if not found:
        raise SystemExit("no mesh in the file")
    # Body only, unless asked otherwise. A Mixamo character ships secondary
    # meshes (eyes) that do not share the body's object scale, so including them
    # puts a pair of metre-wide spheres over the pose this render exists to
    # check. Vertex count is a reliable way to pick the body out.
    meshes = found if "--all-meshes" in argv else [
        max(found, key=lambda o: len(o.data.vertices))]
    log(f"armature {arm.name!r}, {len(found)} mesh(es), "
        f"rendering {[o.name for o in meshes]}")

    acts = [a for a in bpy.data.actions if want is None or a.name in want]
    if not acts:
        raise SystemExit(f"none of {want} found in {[a.name for a in bpy.data.actions]}")

    # One panel per clip, sampled at its midpoint -- the middle of a loop is the
    # settled pose, where the ends can be mid-transition.
    spacing = 1.1
    panels = []
    for i, act in enumerate(acts):
        lo, hi = act.frame_range
        frame = int(round((lo + hi) / 2.0))
        panels += snapshot(arm, meshes, act, frame, i * spacing, yaw,
                           proxy="--proxy" in argv)
        log(f"  panel {i}: {act.name!r} @ f{frame}")

    for o in list(meshes) + [arm]:
        o.hide_render = True

    scene = bpy.context.scene

    # Frame from the actual geometry rather than from assumed character size --
    # the panels' real extent is the only thing that reliably tracks whatever
    # scale the source happens to carry.
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in panels:
        for corner in o.bound_box:
            p = o.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
    centre = (lo + hi) / 2.0
    width, height = hi.x - lo.x, hi.z - lo.z
    pad = 1.06
    log(f"  bounds {width:.2f} x {height:.2f} m")

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(width, height) * pad
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = Vector((centre.x, lo.y - max(width, height) * 2.0, centre.z))
    cam.rotation_euler = (math.radians(90.0), 0.0, 0.0)
    scene.camera = cam

    scene.render.engine = "BLENDER_WORKBENCH"
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.color_type = "SINGLE"
    shading.single_color = (0.55, 0.55, 0.58)
    shading.show_cavity = True
    scene.render.film_transparent = False
    scene.render.resolution_y = 900
    scene.render.resolution_x = max(200, int(900 * width / max(height, 1e-6)))
    scene.render.image_settings.file_format = "PNG"
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    scene.render.filepath = os.path.abspath(out)
    bpy.ops.render.render(write_still=True)
    log(f"wrote {out}")


if __name__ == "__main__":
    main()
