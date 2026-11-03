"""Add the merc's status lights: a health band down the back and three down pips
on the right breast.

  blender.exe -b art_src/merc_anim_gunswap.blend -P tools/add_merc_lights.py

Writes the .blend in place (Blender keeps the previous save as .blend1). Run it
again to rebuild the lights: any existing ones are deleted first. Then export as
usual (export_models.py --variant merc).

WHAT IT BUILDS
--------------
  * `health_band` -- a vertical strip hugging the upper back along the spine.
    The game colours it by HP bracket (unit_visual.gd `set_health_lights`).
  * `down_pip_1..3` -- small discs in a row across the right breast, innermost
    first. One lights red per down; the third down kills.
  * `mag_pip_1..6` -- square tiles in a column of three down each side of the
    band, numbered from the bottom row, right then left. One per spare magazine,
    fullest first, coloured by how full it is and dark once empty.

Each is fitted to the armour by raycasting the body in REST pose, lifted a hair
off the surface, and SKINNED: every vertex copies the bone weights of the body
vertex nearest it. So the lights bend with the torso exactly as the armour
under them does, through every animation, with nothing to keep in sync by hand.
The materials are placeholders; the game replaces them with its own glow.
"""


import bpy
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ARMATURE = "Armature"
BODY = "vanguard_Mesh"
BAND = "health_band"
PIPS = ("down_pip_1", "down_pip_2", "down_pip_3")
IDLE = "idle"

## All in world metres, the merc being ~1.84 m tall in this file. Heights are
## world Z with the rig at rest; sideways offsets are along the merc's right.
BAND_BOTTOM, BAND_TOP = 1.41, 1.55
BAND_WIDTH = 0.07
BAND_ROWS = 7
## Pips: height above the chest bone's head in the posed idle.
PIP_RISE = 0.17
PIP_OFFSETS = (0.07, 0.105, 0.14)
PIP_RADIUS = 0.017
## Magazine pips: rows bottom first (world Z, centred on the band's height), columns
## as offsets along the merc's right, leaving a 0.03 gap from the band's 0.035 half
## width. Narrow enough to read as columns of their own, tall enough to cover two or
## three pixels at the closest game camera.
MAG_PIPS = tuple("mag_pip_%d" % i for i in range(1, 7))
MAG_PIP_ROWS = (1.42, 1.48, 1.54)
MAG_PIP_COLUMNS = (0.08, -0.08)
MAG_PIP_WIDTH = 0.03
MAG_PIP_HEIGHT = 0.05
## How far off the armour the lights float, so they never z-fight it.
LIFT = 0.012


def body_bvh(body):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(dg)
    mesh = ev.to_mesh()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.transform(body.matrix_world)
    ev.to_mesh_clear()
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    return tree


def body_kd(body):
    """Nearest-vertex lookup over the body in rest pose, world space."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(dg)
    mesh = ev.to_mesh()
    kd = KDTree(len(mesh.vertices))
    for v in mesh.vertices:
        kd.insert(body.matrix_world @ v.co, v.index)
    kd.balance()
    ev.to_mesh_clear()
    return kd


def cast(tree, origin, direction):
    hit, normal, _, _ = tree.ray_cast(origin, direction)
    if hit is None:
        raise SystemExit("[add_merc_lights] ray from %s missed the body" % origin)
    # Facing the ray, whatever the winding.
    if normal.dot(direction) > 0:
        normal = -normal
    return hit, normal


def make_object(name, verts, faces, material, arm):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    mesh.update()
    mesh.materials.append(material)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = arm
    obj.matrix_world = arm.matrix_world.copy()
    # Verts were made in world space; bring them into the object's own.
    to_local = obj.matrix_world.inverted()
    for v in mesh.vertices:
        v.co = to_local @ v.co
    return obj


def skin(obj, body, kd, arm, anchor=None):
    """Copies the nearest body vertex's weights onto every vertex of `obj`. With
    `anchor`, every vertex takes that one body vertex's weights instead: the
    disc then moves as one piece, but exactly as the armour under its centre
    does. Per-vertex weights near the collar pulled part of a pip after the
    neck and stretched it; one bone outright let it sink into the plate, which
    is blended between bones there."""
    names = {g.index: g.name for g in body.vertex_groups}
    groups = {}
    for v in obj.data.vertices:
        src = anchor if anchor is not None else kd.find(obj.matrix_world @ v.co)[1]
        for g in body.data.vertices[src].groups:
            name = names[g.group]
            if name not in groups:
                groups[name] = obj.vertex_groups.new(name=name)
            groups[name].add([v.index], g.weight, "REPLACE")
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm


def glow(name, color):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.diffuse_color = color  # the viewport/workbench colour
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = 2.0
    return mat


def build_band(tree, center, back, right, mat, arm):
    # Flat across its width and bridging the spine groove: each row sits at the
    # outermost point of the armour across a slightly wider span than the band,
    # and then at the outermost of its neighbours too. Hugging every ridge left
    # the band dipping under the armour in pieces.
    span = [BAND_WIDTH * (i / 6.0 - 0.5) * 1.4 for i in range(7)]
    rows, depth = [], []
    for r in range(BAND_ROWS + 1):
        z = BAND_BOTTOM + (BAND_TOP - BAND_BOTTOM) * r / BAND_ROWS
        axis = Vector((center.x, center.y, z))
        out = max((cast(tree, axis + right * c + back * 1.0, -back)[0] - axis).dot(back)
                  for c in span)
        rows.append(axis)
        depth.append(out)
    depth = [max(depth[max(r - 1, 0):r + 2]) for r in range(len(depth))]
    verts, faces = [], []
    for axis, out in zip(rows, depth):
        for c in (-BAND_WIDTH / 2, BAND_WIDTH / 2):
            verts.append(axis + back * (out + LIFT) + right * c)
    for r in range(BAND_ROWS):
        a = r * 2
        # Wound to face out of the back (toward +back).
        faces.append((a, a + 2, a + 3, a + 1))
    return make_object(BAND, verts, faces, mat, arm)


def skin_matrix(body, vertex, arm):
    """The world-space linear-blend matrix the armature applies to `vertex` of
    `body` in the current pose: rest position in, posed position out."""
    total = Matrix(((0,) * 4,) * 4)
    weight = 0.0
    for g in body.data.vertices[vertex].groups:
        pb = arm.pose.bones.get(body.vertex_groups[g.group].name)
        if pb is None or g.weight <= 0.0:
            continue
        m = arm.matrix_world @ pb.matrix @ pb.bone.matrix_local.inverted() \
            @ arm.matrix_world.inverted()
        total += m * g.weight
        weight += g.weight
    return total * (1.0 / weight)


def build_pip(name, tree, kd, body, center, back, right, offset, mat, arm):
    """Fitted in the POSED idle, where the merc hunches and its head comes
    forward over the upper chest -- a rest-pose fit landed somewhere the idle
    buries. The bulb is then carried back to rest through the skinning of the
    armour vertex under its centre, which is also the weighting it gets, so in
    idle it sits exactly where it was fitted.

    A bulb, not a flat disc: the pec curves away steeply here, and a disc in
    its tangent plane read as a sliver from the front."""
    front = -back
    origin = center + Vector((0, 0, PIP_RISE)) + right * offset + front * 1.0
    hit, normal = cast(tree, origin, back)
    # Half sunk into the plate, so it reads as set into the armour.
    base = hit + normal * (PIP_RADIUS * 0.4)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=1, radius=PIP_RADIUS)
    posed = [base + v.co for v in bm.verts]
    faces = [tuple(v.index for v in f.verts) for f in bm.faces]
    bm.free()
    anchor = kd.find(hit)[1]
    to_rest = skin_matrix(body, anchor, arm).inverted()
    return make_object(name, [to_rest @ v for v in posed], faces, mat, arm), anchor


def build_mag_pips(tree, kd, center, back, right, mat, arm):
    """Flat tiles square to the back like the band, all in one plane: the outermost
    point of the armour under any of them, plus LIFT. Each box runs back until it
    meets the armour, so none floats. Following the armour's own slopes instead
    fanned them out at angles and broke up the rows. All six take the weights of the
    armour vertex under the band's middle, so the set moves as one piece."""
    w, h = MAG_PIP_WIDTH / 2, MAG_PIP_HEIGHT / 2
    corners = [(-w, -h), (w, -h), (w, h), (-w, h)]
    spots = [(z, offset) for z in MAG_PIP_ROWS for offset in MAG_PIP_COLUMNS]
    origin = Vector((center.x, center.y, 0.0))
    depths = []
    for z, offset in spots:
        axis = origin + Vector((0, 0, z)) + right * offset
        hits = [cast(tree, axis + right * a + Vector((0, 0, b)) + back * 1.0, -back)[0]
                for a, b in corners]
        depths.append([(hit - origin).dot(back) for hit in hits])
    plane = max(max(d) for d in depths) + LIFT
    middle = origin + Vector((0, 0, sum(MAG_PIP_ROWS) / len(MAG_PIP_ROWS)))
    anchor = kd.find(cast(tree, middle + back * 1.0, -back)[0])[1]
    faces = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    built = []
    for name, (z, offset), depth in zip(MAG_PIPS, spots, depths):
        axis = origin + Vector((0, 0, z)) + right * offset
        tile = [axis + right * a + Vector((0, 0, b)) for a, b in corners]
        outer = [v + back * plane for v in tile]
        inner = [v + back * (min(depth) - LIFT) for v in tile]
        built.append((make_object(name, outer + inner, faces, mat, arm), anchor))
    return built


def main():
    arm = bpy.data.objects[ARMATURE]
    body = bpy.data.objects[BODY]
    for name in (BAND,) + PIPS + MAG_PIPS:
        old = bpy.data.objects.get(name)
        if old is not None:
            bpy.data.objects.remove(old, do_unlink=True)

    saved_pose = arm.data.pose_position
    arm.data.pose_position = "REST"
    bpy.context.view_layer.update()

    rot = arm.matrix_world.to_3x3().normalized()
    # The rig faces -Y and its right hand is at -X (armature space).
    back = (rot @ Vector((0, 1, 0))).normalized()
    right = (rot @ Vector((-1, 0, 0))).normalized()
    back.z = right.z = 0.0
    back.normalize()
    right.normalize()
    chest = arm.data.bones["chest"]
    center = arm.matrix_world @ chest.head_local

    tree = body_bvh(body)
    kd = body_kd(body)
    band_mat = glow("health_band_glow", (0.2, 1.0, 0.8, 1.0))
    pip_mat = glow("down_pip_glow", (1.0, 0.1, 0.08, 1.0))
    mag_mat = glow("mag_pip_glow", (1.0, 0.95, 0.6, 1.0))

    built = [(build_band(tree, center, back, right, band_mat, arm), None)]
    built += build_mag_pips(tree, kd, center, back, right, mag_mat, arm)

    # The pips are fitted on the idle's first frame (see build_pip).
    anim = arm.animation_data
    saved_action, saved_slot = anim.action, anim.action_slot
    anim.action = bpy.data.actions[IDLE]
    if anim.action_slot is None and anim.action.slots:
        anim.action_slot = anim.action.slots[0]
    arm.data.pose_position = "POSE"
    bpy.context.scene.frame_set(int(anim.action.frame_range[0]))
    posed_tree = body_bvh(body)
    posed_kd = body_kd(body)
    posed_center = arm.matrix_world @ arm.pose.bones["chest"].head
    for name, offset in zip(PIPS, PIP_OFFSETS):
        built.append(build_pip(name, posed_tree, posed_kd, body, posed_center,
                               back, right, offset, pip_mat, arm))
    for obj, anchor in built:
        skin(obj, body, kd, arm, anchor)
        print("[add_merc_lights] built %s (%d verts, %d groups)"
              % (obj.name, len(obj.data.vertices), len(obj.vertex_groups)))

    anim.action, anim.action_slot = saved_action, saved_slot
    arm.data.pose_position = saved_pose
    bpy.ops.wm.save_mainfile()
    print("[add_merc_lights] saved %s" % bpy.data.filepath)


main()
