"""Procedural low-poly soldier: mesh, armature, rigid skinning, glTF export.

The character art for Retake the Spaceship is generated rather than modelled, so
proportions and clips are diffable text and every class shares one skeleton by
construction (design doc Sec 4.5).

Run headless:
    blender -b -P tools/gen_soldier.py -- --render out/turn.png
    blender -b -P tools/gen_soldier.py -- --export assets/soldier.glb

Conventions that matter downstream:
  * Blender is Z-up and the figure faces +Y. The glTF exporter maps Blender +Y to
    glTF/Godot -Z, which is Godot's forward, so the model faces the direction
    Unit._step_to yaws toward with no correction node.
  * Origin sits between the feet at z=0, so the Godot scene needs no Y offset
    (unlike the capsule placeholder, whose origin was its centre).
  * One box per bone, every vertex weighted 1.0 to that bone. Rigid deformation
    is the intended look here and sidesteps weight painting entirely.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

# Animations are hand-authored in assets/soldier_rig.blend now, not baked from
# POSE_LIB — see tools/export_soldier_rig.py. --export checks against this
# path so a stray rebuild can't silently overwrite that work.
SHIPPED_SOLDIER_GLB = "assets/soldier.glb"

# ---------------------------------------------------------------------------
# Proportions. Heroic-stylised: broad shoulders, chunky boots, smallish head, so
# the silhouette still reads at the 35-75 degree camera pitch (design doc 10.2).
# ---------------------------------------------------------------------------

HEIGHT = 1.80

# Vertical landmarks (metres from the sole).
Z_SOLE = 0.00
Z_ANKLE = 0.13
Z_KNEE = 0.51
Z_CROTCH = 0.88
Z_WAIST = 1.05
Z_CHEST = 1.28
Z_SHOULDER = 1.46
Z_NECK = 1.55
Z_HEAD_TOP = 1.78

X_HIP = 0.110      # leg centreline
X_ARM = 0.262      # arm centreline — widened for a bulkier upper body
X_SHOULDER = 0.05  # where the clavicle starts

MAT_SUIT = 0
MAT_VEST = 1
MAT_HELMET = 2
MAT_LENS = 3
MAT_DARK = 4
MAT_ACCENT = 5
MAT_POUCH = 6
MAT_PAD = 7
MAT_BOOT = 8

# Global edge bevel. Hard 90-degree corners are the signature of programmer art;
# a few millimetres of chamfer catches a highlight along every edge and is the
# single biggest "less blocky" lever available. Parts are separate un-welded
# shells, so each bevels independently and cleanly.
BEVEL_OFFSET = 0.007
BEVEL_SEGMENTS = 2

# Black-and-grey, but deliberately stepped in value: near-black suit, dark-grey
# vest, mid-grey helmet. A flat black character is invisible at the tactical
# camera's zoom in a ship this dark (design doc Sec 5), so the separation between
# layers is what keeps the forms readable. The mask lenses are emissive for the
# same reason — they're the anchor that says "unit here" in an unlit corridor.
# (name, rgb, emission_strength)
# Taken from the RE2 USS reference: a near-black base broken by olive/khaki
# pouches and red mask lenses. Those two accents are what make the silhouette
# recognisable — an all-grey version reads as generic riot police.
# (name, rgb, emission_strength)
MATERIALS = [
    ("suit", (0.075, 0.078, 0.086), 0.0),
    ("vest", (0.105, 0.110, 0.119), 0.0),
    ("helmet", (0.145, 0.152, 0.162), 0.0),
    # Emission kept low: at 4.0 Godot's tonemapper blew the lenses to pale pink
    # instead of red, losing the reference's strongest cue.
    ("lens", (0.95, 0.11, 0.08), 1.3),
    ("dark", (0.038, 0.040, 0.045), 0.0),
    ("accent", (0.30, 0.60, 1.00), 0.0),
    ("pouch", (0.230, 0.205, 0.098), 0.0),
    # Pads are grey but not bright: at 0.255 against a 0.05 suit they read as
    # stuck-on white rectangles rather than as part of the kit.
    ("pad", (0.165, 0.165, 0.158), 0.0),
    ("boot", (0.150, 0.136, 0.116), 0.0),
]

# Bones: name -> (head, tail, parent). Limb bones point down the limb, so their
# local +Y runs from head toward tail; poses below are authored against that.
BONES = {
    "hips":     ((0, 0, 0.95), (0, 0, 1.06), None),
    "spine":    ((0, 0, 1.06), (0, 0, Z_CHEST), "hips"),
    "chest":    ((0, 0, Z_CHEST), (0, 0, Z_SHOULDER), "spine"),
    "neck":     ((0, 0, Z_SHOULDER), (0, 0, Z_NECK), "chest"),
    "head":     ((0, 0, Z_NECK), (0, 0, Z_HEAD_TOP), "neck"),
}

for side, sx in (("L", 1.0), ("R", -1.0)):
    BONES.update({
        f"shoulder.{side}": ((sx * X_SHOULDER, 0, 1.43), (sx * 0.20, 0, 1.42), "chest"),
        f"upperarm.{side}": ((sx * X_ARM, 0, 1.42), (sx * X_ARM, 0, 1.18), f"shoulder.{side}"),
        f"lowerarm.{side}": ((sx * X_ARM, 0, 1.18), (sx * X_ARM, 0, 0.94), f"upperarm.{side}"),
        f"hand.{side}":     ((sx * X_ARM, 0, 0.94), (sx * X_ARM, 0, 0.82), f"lowerarm.{side}"),
        f"thigh.{side}":    ((sx * X_HIP, 0, Z_CROTCH + 0.02), (sx * X_HIP, 0, Z_KNEE), "hips"),
        f"shin.{side}":     ((sx * X_HIP, 0, Z_KNEE), (sx * X_HIP, 0, Z_ANKLE), f"thigh.{side}"),
        f"foot.{side}":     ((sx * X_HIP, -0.03, 0.10), (sx * X_HIP, 0.13, 0.06), f"shin.{side}"),
    })


def _parts():
    """One tapered box per entry: (bone, A, B, halfA, halfB, material).

    A and B are the ends of the box's long axis; halfA/halfB are cross-section
    half-extents at each end, giving cheap taper without extra geometry.
    """
    parts = [
        # --- torso: broad chest tapering to the waist, so the V-taper does the
        # "muscular" work before any single prop does.
        ("hips", (0, 0, Z_CROTCH - 0.03), (0, 0, Z_WAIST), (0.150, 0.128), (0.156, 0.134), MAT_SUIT, 6),
        ("hips", (0, 0, 0.992), (0, 0, 1.058), (0.162, 0.140), (0.160, 0.138), MAT_DARK, 6),  # belt
        ("spine", (0, 0, Z_WAIST - 0.02), (0, 0, Z_CHEST), (0.156, 0.134), (0.212, 0.166), MAT_SUIT, 6),
        ("chest", (0, 0, Z_CHEST - 0.02), (0, 0, Z_SHOULDER + 0.01), (0.212, 0.166), (0.248, 0.182), MAT_SUIT, 6),
        # Plate carrier: a distinct outer shell, proud of the torso beneath it.
        ("spine", (0, 0, 1.075), (0, 0, Z_CHEST), (0.186, 0.152), (0.222, 0.176), MAT_VEST, 6),
        ("chest", (0, 0, Z_CHEST - 0.01), (0, 0, 1.458), (0.222, 0.176), (0.258, 0.192), MAT_VEST, 6),
        # --- olive mag pouches across the rig front (+Y). The dominant accent.
        ("spine", (0.048, 0.176, 1.092), (0.048, 0.196, 1.204), (0.043, 0.030), (0.040, 0.028), MAT_POUCH),
        ("spine", (-0.048, 0.176, 1.092), (-0.048, 0.196, 1.204), (0.043, 0.030), (0.040, 0.028), MAT_POUCH),
        ("spine", (0.136, 0.168, 1.096), (0.136, 0.186, 1.198), (0.042, 0.029), (0.039, 0.027), MAT_POUCH),
        ("spine", (-0.136, 0.168, 1.096), (-0.136, 0.186, 1.198), (0.042, 0.029), (0.039, 0.027), MAT_POUCH),
        ("chest", (0.092, 0.182, 1.272), (0.092, 0.198, 1.352), (0.038, 0.024), (0.035, 0.022), MAT_POUCH),
        ("chest", (-0.092, 0.182, 1.272), (-0.092, 0.198, 1.352), (0.038, 0.024), (0.035, 0.022), MAT_DARK),
        ("neck", (0, 0, Z_SHOULDER - 0.03), (0, 0, Z_NECK + 0.01), (0.070, 0.070), (0.066, 0.066), MAT_DARK, 8),
        # --- head: full-face respirator, so the whole skull is mask-black.
        ("head", (0, 0, Z_NECK - 0.02), (0, 0, 1.700), (0.094, 0.100), (0.090, 0.098), MAT_DARK, 8),
        # Rounded snout housing the filter, protruding forward and down.
        ("head", (0, 0.066, 1.582), (0, 0.142, 1.570), (0.054, 0.052), (0.040, 0.038), MAT_DARK, 8),
        # Ballistic dome, stacked sections rather than a flat-topped box — the
        # most obvious low-poly tell in the previous version.
        ("head", (0, 0, 1.626), (0, 0, 1.700), (0.108, 0.114), (0.106, 0.112), MAT_HELMET, 12),
        ("head", (0, 0, 1.700), (0, 0, 1.752), (0.106, 0.112), (0.093, 0.098), MAT_HELMET, 12),
        ("head", (0, 0, 1.752), (0, 0, 1.790), (0.093, 0.098), (0.058, 0.062), MAT_HELMET, 12),
        ("head", (0, 0, 1.612), (0, 0, 1.640), (0.110, 0.116), (0.109, 0.115), MAT_DARK, 12),  # strap
        # Round red lenses, emissive — the reference's single strongest cue.
        ("head", (0.046, 0.088, 1.640), (0.046, 0.104, 1.640), (0.032, 0.032), (0.030, 0.030), MAT_LENS, 12),
        ("head", (-0.046, 0.088, 1.640), (-0.046, 0.104, 1.640), (0.032, 0.032), (0.030, 0.030), MAT_LENS, 12),
        # Filter disc on the left cheek.
        ("head", (0.084, 0.020, 1.606), (0.104, 0.022, 1.606), (0.034, 0.034), (0.031, 0.031), MAT_VEST, 10),
        # --- back: pack, radio and antenna break the rear silhouette.
        ("chest", (0, -0.198, 1.10), (0, -0.198, 1.42), (0.128, 0.056), (0.116, 0.050), MAT_VEST, 6),
        ("chest", (0.118, -0.196, 1.30), (0.118, -0.202, 1.42), (0.040, 0.030), (0.037, 0.028), MAT_DARK),
        ("chest", (0.118, -0.202, 1.42), (0.130, -0.216, 1.61), (0.008, 0.008), (0.005, 0.005), MAT_DARK, 6),
        ("hips", (-0.104, -0.158, 0.982), (-0.104, -0.172, 0.868), (0.072, 0.046), (0.066, 0.042), MAT_POUCH),
    ]
    for side, sx in (("L", 1.0), ("R", -1.0)):
        parts += [
            # NOTE on half-extents for near-horizontal axes: _frame puts the
            # first value on Y (depth) and the second on the near-vertical axis
            # (thickness). Getting these the wrong way round is what made the
            # pads 21 cm tall in an earlier pass.
            # Deltoid cap: wide and thick, the main driver of a heavy upper body.
            # Roughly circular in cross-section, not a wide flat plate — a slab
            # reads as a shoulder pauldron stuck on, a rounder one as deltoid.
            (f"shoulder.{side}", (sx * 0.146, 0, 1.466), (sx * 0.298, 0, 1.384),
             (0.100, 0.086), (0.082, 0.070), MAT_VEST, 8),
            # Two segments per limb: the join carries a bulge, which is what
            # reads as muscle rather than pipe.
            (f"upperarm.{side}", (sx * X_ARM, 0, 1.442), (sx * X_ARM, 0, 1.300),
             (0.070, 0.074), (0.078, 0.082), MAT_SUIT, 6),
            (f"upperarm.{side}", (sx * X_ARM, 0, 1.300), (sx * X_ARM, 0, 1.172),
             (0.078, 0.082), (0.058, 0.062), MAT_SUIT, 6),
            (f"lowerarm.{side}", (sx * X_ARM, 0, 1.190), (sx * X_ARM, 0, 1.080),
             (0.058, 0.062), (0.064, 0.068), MAT_SUIT, 6),
            (f"lowerarm.{side}", (sx * X_ARM, 0, 1.080), (sx * X_ARM, 0, 0.950),
             (0.064, 0.068), (0.047, 0.051), MAT_SUIT, 6),
            (f"lowerarm.{side}", (sx * X_ARM, 0.050, 1.186), (sx * X_ARM, 0.044, 1.116),
             (0.050, 0.026), (0.044, 0.024), MAT_PAD, 8),  # elbow pad
            (f"hand.{side}", (sx * X_ARM, 0, 0.948), (sx * X_ARM, 0, 0.844),
             (0.049, 0.047), (0.045, 0.043), MAT_DARK, 6),
            (f"thigh.{side}", (sx * X_HIP, 0, Z_CROTCH + 0.03), (sx * X_HIP, 0, 0.720),
             (0.106, 0.116), (0.110, 0.120), MAT_SUIT, 6),
            (f"thigh.{side}", (sx * X_HIP, 0, 0.720), (sx * X_HIP, 0, Z_KNEE - 0.01),
             (0.110, 0.120), (0.084, 0.094), MAT_SUIT, 6),
            # Cargo pocket on the outer thigh.
            (f"thigh.{side}", (sx * 0.176, 0.010, 0.800), (sx * 0.182, 0.014, 0.690),
             (0.034, 0.052), (0.031, 0.048), MAT_SUIT),
            (f"shin.{side}", (sx * X_HIP, 0, Z_KNEE + 0.01), (sx * X_HIP, 0, 0.400),
             (0.076, 0.084), (0.082, 0.090), MAT_SUIT, 6),  # calf
            (f"shin.{side}", (sx * X_HIP, 0, 0.400), (sx * X_HIP, 0, 0.196),
             (0.082, 0.090), (0.070, 0.076), MAT_SUIT, 6),
            # Big rounded knee cap in light grey — very prominent in reference.
            (f"shin.{side}", (sx * X_HIP, 0.080, Z_KNEE + 0.030), (sx * X_HIP, 0.070, Z_KNEE - 0.105),
             (0.072, 0.034), (0.060, 0.029), MAT_PAD, 8),
            # Tall boot shaft plus a separate sole.
            (f"shin.{side}", (sx * X_HIP, 0.004, 0.210), (sx * X_HIP, 0.008, 0.070),
             (0.076, 0.082), (0.080, 0.086), MAT_BOOT, 6),
            (f"foot.{side}", (sx * X_HIP, -0.060, 0.062), (sx * X_HIP, 0.150, 0.048),
             (0.082, 0.056), (0.066, 0.040), MAT_BOOT, 6),
            (f"foot.{side}", (sx * X_HIP, -0.062, 0.020), (sx * X_HIP, 0.152, 0.016),
             (0.084, 0.020), (0.068, 0.017), MAT_DARK),
        ]
    # Drop-leg holster and pistol grip on the left thigh only — the right hand
    # is holding the rifle.
    parts += [
        ("thigh.L", (0.186, 0.022, 0.766), (0.190, 0.028, 0.624),
         (0.040, 0.052), (0.036, 0.047), MAT_DARK, 6),
        ("thigh.L", (0.186, 0.034, 0.800), (0.188, 0.052, 0.746),
         (0.020, 0.028), (0.018, 0.024), MAT_DARK),
    ]
    return parts


def _section(n):
    """Unit cross-section outline: a rectangle for 4, an n-gon above that."""
    if n == 4:
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    return [(math.cos(2.0 * math.pi * i / n + math.pi / n),
             math.sin(2.0 * math.pi * i / n + math.pi / n)) for i in range(n)]


def _frame(axis):
    """Orthonormal cross-section basis (u, v) for a box running along `axis`."""
    axis = axis.normalized()
    if abs(axis.z) > 0.9:  # near-vertical: cross(Z, axis) degenerates
        u = Vector((1.0, 0.0, 0.0))
    else:
        u = Vector((0.0, 0.0, 1.0)).cross(axis).normalized()
    v = axis.cross(u).normalized()
    return u, v


def build_boxes(obj_name, mesh_name, parts):
    """Build one object from a list of tapered boxes.

    Returns (object, groups) where groups pairs each part's bone name with its
    vertex indices, ready for rigid skinning. Parts whose bone is None (the
    rifle) simply produce no groups.
    """
    verts, faces, mats, groups = [], [], [], []
    for part in parts:
        bone, a, b, ha, hb, mat = part[:6]
        sides = part[6] if len(part) > 6 else 4  # >4 gives a round cross-section
        section = _section(sides)
        a, b = Vector(a), Vector(b)
        u, v = _frame(b - a)
        base = len(verts)
        for end, half in ((a, ha), (b, hb)):
            for cu, cv in section:
                verts.append(end + u * (cu * half[0]) + v * (cv * half[1]))
        faces.append(tuple(range(base, base + sides)))                    # cap A
        faces.append(tuple(reversed(range(base + sides, base + 2 * sides))))  # cap B
        for i in range(sides):
            j = (i + 1) % sides
            faces.append((base + i, base + sides + i, base + sides + j, base + j))
        mats += [mat] * (2 + sides)
        if bone is not None:
            groups.append((bone, list(range(base, base + 2 * sides))))

    mesh = bpy.data.meshes.new(mesh_name)
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    mesh.validate()
    # The hand-written face winding above isn't reliably outward, which shows up
    # as lit interior faces. Let bmesh settle it rather than tracking winding
    # per part.
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    for name, (r, g, b), emission in MATERIALS:
        m = bpy.data.materials.get(name)
        if m is None:  # shared between the soldier and the rifle
            m = bpy.data.materials.new(name)
            m.use_nodes = True
            bsdf = m.node_tree.nodes["Principled BSDF"]
            bsdf.inputs["Base Color"].default_value = (r, g, b, 1.0)
            bsdf.inputs["Roughness"].default_value = 0.55 if emission == 0.0 else 0.2
            if emission > 0.0:
                bsdf.inputs["Emission Color"].default_value = (r, g, b, 1.0)
                bsdf.inputs["Emission Strength"].default_value = emission
            m.diffuse_color = (r, g, b, 1.0)  # Workbench viewport/render colour
        mesh.materials.append(m)
    for poly, mat in zip(mesh.polygons, mats):
        poly.material_index = mat
    mesh.shade_flat()

    obj = bpy.data.objects.new(obj_name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj, groups


# ---------------------------------------------------------------------------
# Rifle. Exported as its own glb: in Godot it hangs off a BoneAttachment3D on
# hand.R, so each class can swap the weapon without touching a single clip
# (design doc Sec 4.5). It is built here too because the aim poses can't be
# authored without seeing where the hands actually have to be.
# ---------------------------------------------------------------------------

# Origin at the trigger/grip, barrel down +Y, sights up +Z — the same axes as
# the soldier, so "point the weapon forward" needs no extra rotation.
MUZZLE = (0.0, 0.455, 0.014)  # Marker3D position in Godot for the flash/tracer

RIFLE_PARTS = [
    (None, (0, -0.125, 0.0), (0, 0.185, 0.0), (0.023, 0.036), (0.021, 0.032), MAT_DARK),
    (None, (0, 0.175, 0.014), (0, MUZZLE[1], 0.014), (0.013, 0.013), (0.011, 0.011), MAT_DARK),
    (None, (0, 0.180, 0.0), (0, 0.330, 0.0), (0.025, 0.025), (0.022, 0.022), MAT_SUIT),
    (None, (0, -0.120, -0.004), (0, -0.300, -0.022), (0.021, 0.039), (0.019, 0.030), MAT_SUIT),
    (None, (0, 0.030, -0.030), (0, 0.048, -0.165), (0.017, 0.031), (0.015, 0.028), MAT_VEST),
    (None, (0, -0.020, -0.024), (0, -0.055, -0.135), (0.019, 0.025), (0.017, 0.022), MAT_DARK),
    (None, (0, 0.055, 0.048), (0, 0.200, 0.048), (0.015, 0.019), (0.013, 0.017), MAT_VEST),
]


def build_rifle():
    obj, _ = build_boxes("Rifle", "RifleMesh", RIFLE_PARTS)
    return obj


def build_armature():
    arm = bpy.data.armatures.new("SoldierRig")
    obj = bpy.data.objects.new("Rig", arm)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (head, tail, _) in BONES.items():
        eb = arm.edit_bones.new(name)
        eb.head, eb.tail, eb.roll = Vector(head), Vector(tail), 0.0
    for name, (_, _, parent) in BONES.items():
        if parent:
            arm.edit_bones[name].parent = arm.edit_bones[parent]
            arm.edit_bones[name].use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def bevel_mesh(mesh):
    """Chamfer every edge.

    MUST run after vertex groups are assigned. The bevel adds and renumbers
    vertices, so beveling first leaves bind() applying stale indices — verts end
    up on the wrong bones and the new ones on none at all, which looks fine at
    rest and tears apart the moment the model animates. Run afterwards, bmesh
    interpolates the existing deform weights instead.
    """
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.bevel(bm, geom=list(bm.edges), offset=BEVEL_OFFSET,
                    offset_type="OFFSET", segments=BEVEL_SEGMENTS, profile=0.5,
                    affect="EDGES", clamp_overlap=True, material=-1)
    bm.to_mesh(mesh)
    bm.free()


def unweighted_count(obj):
    """Vertices with no bone influence — must be zero or they tear on animation."""
    total = 0
    for vert in obj.data.vertices:
        if not vert.groups or sum(g.weight for g in vert.groups) < 0.0001:
            total += 1
    return total


def bind(mesh_obj, rig_obj, groups):
    for bone, indices in groups:
        vg = mesh_obj.vertex_groups.get(bone) or mesh_obj.vertex_groups.new(name=bone)
        vg.add(indices, 1.0, "REPLACE")
    mesh_obj.parent = rig_obj
    mod = mesh_obj.modifiers.new("Armature", "ARMATURE")
    mod.object = rig_obj


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.actions):
        for item in list(coll):
            coll.remove(item)


def build():
    clear_scene()
    mesh_obj, groups = build_boxes("Soldier", "SoldierMesh", _parts())
    rig_obj = build_armature()
    bind(mesh_obj, rig_obj, groups)
    bevel_mesh(mesh_obj.data)  # after bind: see bevel_mesh's docstring
    rifle_obj = build_rifle()
    bevel_mesh(rifle_obj.data)
    stray = unweighted_count(mesh_obj)
    if stray:
        print(f"[gen_soldier] WARNING: {stray} unweighted vertices — these WILL "
              f"tear during animation")
    tris = sum(len(p.vertices) - 2 for p in mesh_obj.data.polygons)
    rifle_tris = sum(len(p.vertices) - 2 for p in rifle_obj.data.polygons)
    print(f"[gen_soldier] soldier {tris} tris, rifle {rifle_tris} tris, "
          f"{len(rig_obj.data.bones)} bones, {len(MATERIALS)} materials")
    return mesh_obj, rig_obj, rifle_obj


# ---------------------------------------------------------------------------
# Review render: three linked copies of the rest-pose mesh at different yaws,
# one orthographic camera, Workbench engine. Fast, and enough to judge
# proportion and silhouette.
# ---------------------------------------------------------------------------

def render_turnaround(mesh_obj, path, hide=(), yaws=(0.0, 40.0, 90.0, 180.0)):
    scene = bpy.context.scene
    temps = []
    # The originals sit at the origin and would render as an extra figure in the
    # middle of the row.
    hidden = [mesh_obj] + [o for o in hide if o]
    for obj in hidden:
        obj.hide_render = True
    spacing = 0.95
    for i, yaw in enumerate(yaws):
        copy = bpy.data.objects.new(f"view{i}", mesh_obj.data)  # shares mesh data
        # Negated: the camera looks down -Y, so its screen-right is world -X.
        # Without this the views come out right-to-left.
        copy.location = (-(i - (len(yaws) - 1) / 2.0) * spacing, 0.0, 0.0)
        copy.rotation_euler = (0.0, 0.0, math.radians(yaw))
        bpy.context.collection.objects.link(copy)
        temps.append(copy)

    cam_data = bpy.data.cameras.new("ReviewCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = len(yaws) * spacing + 0.25
    cam = bpy.data.objects.new("ReviewCam", cam_data)
    # The figure faces +Y, so the camera has to sit on +Y looking back along -Y
    # to see its front. Rx(90) aims down +Y, Rz(180) flips it to -Y.
    cam.location = (0.0, 8.0, 0.95)
    cam.rotation_euler = (math.radians(90.0), 0.0, math.radians(180.0))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    scene.render.engine = "BLENDER_WORKBENCH"
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.color_type = "MATERIAL"
    shading.show_shadows = True
    shading.show_cavity = False  # cavity muddied the flat faces
    shading.show_object_outline = True  # silhouette is the thing being judged
    shading.object_outline_color = (0.02, 0.02, 0.03)
    shading.background_type = "VIEWPORT"
    shading.background_color = (0.16, 0.17, 0.19)
    scene.render.film_transparent = False
    scene.render.resolution_x = 1400
    scene.render.resolution_y = 760
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print(f"[gen_soldier] wrote {path}")

    for obj in temps + [cam]:
        bpy.data.objects.remove(obj, do_unlink=True)
    for obj in hidden:
        obj.hide_render = False


# ---------------------------------------------------------------------------
# Posing. A pose is {bone: (rx, ry, rz)} in degrees, bone-local, plus the
# optional key "_loc" carrying a hips translation (also bone-local: +y is along
# the hips bone, i.e. up). Signs are per Blender's roll-0 bone axes, which is
# what the --calibrate render exists to pin down.
# ---------------------------------------------------------------------------

def apply_pose(rig, pose):
    for pb in rig.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
    for bone, value in pose.items():
        if bone == "_loc":
            rig.pose.bones["hips"].location = value
            continue
        rig.pose.bones[bone].rotation_euler = tuple(math.radians(a) for a in value)
    bpy.context.view_layer.update()


def _snapshot(mesh_obj, name, offset_x, yaw):
    """Freeze the currently-posed, armature-deformed mesh into a static object."""
    dg = bpy.context.evaluated_depsgraph_get()
    data = bpy.data.meshes.new_from_object(mesh_obj.evaluated_get(dg))
    obj = bpy.data.objects.new(name, data)
    obj.location = (offset_x, 0.0, 0.0)
    obj.rotation_euler = (0.0, 0.0, math.radians(yaw))
    bpy.context.collection.objects.link(obj)
    return obj


# Rifle placement relative to the hand.R pose bone. pose_bone.matrix has its
# origin at the bone head with +Y running down the bone, and in the aim poses
# that axis already points roughly where the barrel should, so this is close to
# a pure offset. Godot mirrors it on a BoneAttachment3D.
GRIP_LOCAL = Matrix.Translation((0.0, 0.055, 0.0)) @ Matrix.Rotation(math.radians(-8), 4, "X")


def _snapshot_rifle(rifle_obj, rig_obj, name, offset_x, yaw):
    """Place the (undeformed) rifle on hand.R for the current pose."""
    hand = rig_obj.pose.bones["hand.R"]
    panel = Matrix.Translation((offset_x, 0.0, 0.0)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    obj = bpy.data.objects.new(name, rifle_obj.data)  # shares mesh data
    bpy.context.collection.objects.link(obj)
    obj.matrix_world = panel @ rig_obj.matrix_world @ hand.matrix @ GRIP_LOCAL
    return obj


def _review_scene(path, n_panels, spacing, res_y=620):
    """Ortho camera framing a row of n_panels, plus Workbench render settings."""
    scene = bpy.context.scene
    cam_data = bpy.data.cameras.new("ReviewCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = n_panels * spacing + 0.25
    cam = bpy.data.objects.new("ReviewCam", cam_data)
    cam.location = (0.0, 8.0, 0.95)
    cam.rotation_euler = (math.radians(90.0), 0.0, math.radians(180.0))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    scene.render.engine = "BLENDER_WORKBENCH"
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.color_type = "MATERIAL"
    shading.show_shadows = True
    shading.show_cavity = False
    shading.show_object_outline = True
    shading.object_outline_color = (0.02, 0.02, 0.03)
    shading.background_type = "VIEWPORT"
    shading.background_color = (0.16, 0.17, 0.19)
    scene.render.film_transparent = False
    # Width follows the panel count so every panel keeps the same scale.
    scene.render.resolution_y = res_y
    scene.render.resolution_x = int(res_y * cam_data.ortho_scale / 2.28)
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = path
    return cam


def render_poses(mesh_obj, rig_obj, poses, path, yaw=45.0, hide=(), rifle_obj=None):
    """Contact sheet: one panel per (label, pose), left to right."""
    spacing = 0.95
    hidden = [mesh_obj] + [o for o in hide if o]
    for obj in hidden:
        obj.hide_render = True
    temps = []
    for i, (label, pose) in enumerate(poses):
        apply_pose(rig_obj, pose)
        # Negated: camera looks down -Y, so its screen-right is world -X.
        offset = -(i - (len(poses) - 1) / 2.0) * spacing
        temps.append(_snapshot(mesh_obj, f"pose_{label}", offset, yaw))
        if rifle_obj is not None:
            temps.append(_snapshot_rifle(rifle_obj, rig_obj, f"gun_{label}", offset, yaw))
    cam = _review_scene(path, len(poses), spacing)
    bpy.ops.render.render(write_still=True)
    print(f"[gen_soldier] wrote {path} ({len(poses)} panels: "
          + ", ".join(label for label, _ in poses) + ")")
    for obj in temps + [cam]:
        bpy.data.objects.remove(obj, do_unlink=True)
    for obj in hidden:
        obj.hide_render = False
    apply_pose(rig_obj, {})


# One panel per axis of one bone from each family (spine points up, limb bones
# point down, foot points forward), which is enough to read off every sign.
CALIBRATION = [
    ("rest", {}),
    ("uarmR_X40", {"upperarm.R": (40, 0, 0)}),
    ("uarmR_Y40", {"upperarm.R": (0, 40, 0)}),
    ("uarmR_Z40", {"upperarm.R": (0, 0, 40)}),
    ("thighR_X40", {"thigh.R": (40, 0, 0)}),
    ("spine_X20", {"spine": (20, 0, 0)}),
]

# Read off the calibration sheet, and uniform across every bone family:
#   +X  flexion — arms and legs swing forward, spine bends forward
#    Y  twist about the bone's own length
#   +Z  sideways; mirrored between .L and .R
# Knees therefore need NEGATIVE X to bend backwards like a real knee.


def pose(*layers, **extra):
    """Merge pose fragments left to right; later layers win."""
    out = {}
    for layer in layers:
        out.update(layer)
    out.update(extra)
    return out


def nudge(base, **deltas):
    """Copy `base` with per-bone rotations added rather than replaced."""
    out = dict(base)
    for bone, delta in deltas.items():
        old = out.get(bone, (0, 0, 0))
        out[bone] = tuple(a + b for a, b in zip(old, delta))
    return out


# GRIP_LOCAL's own pitch, which counts toward where the barrel ends up.
GRIP_PITCH = -8


def level_weapon(p, pitch=0.0):
    """Set hand.R so the barrel sits at `pitch` degrees from horizontal.

    Every X rotation down the chain (spine, chest, shoulder, elbow, wrist, grip)
    adds up about the same world axis, and the arm hangs 90 degrees below
    horizontal at rest — so the wrist just absorbs whatever the rest of the chain
    overshoots by. Without this the barrel pointed 26 degrees skyward in every
    aim pose.
    """
    chain = sum(p.get(b, (0, 0, 0))[0]
                for b in ("spine", "chest", "upperarm.R", "lowerarm.R"))
    out = dict(p)
    out["hand.R"] = (90.0 + pitch - chain - GRIP_PITCH, 0, 0)
    return out


# Both hands on the weapon, shouldered and pointing forward. Every shooting,
# overwatch and reload pose is built on this so the grip stays consistent.
GRIP_AIM = {
    "upperarm.R": (38, 0, 85),
    "lowerarm.R": (78, 0, 0),
    "upperarm.L": (58, 0, -85),
    "lowerarm.L": (88, 0, 0),
    "chest": (2, 0, -8),
}

# Weapon carried low across the body.
GRIP_LOW = {
    "upperarm.R": (16, 0, 75),
    "lowerarm.R": (48, 0, 0),
    "upperarm.L": (32, 0, -75),
    "lowerarm.L": (62, 0, 0),
    "chest": (3, 0, -4),
}

THIGH_LEN = (Z_CROTCH + 0.02) - Z_KNEE   # 0.39
SHIN_LEN = Z_KNEE - Z_ANKLE              # 0.38


def crouch_legs(thigh_deg, shin_world_deg, spine_deg=22, chest_deg=8):
    """Legs for a squat, with the hip drop solved from the bone lengths.

    thigh_deg swings the knee forward; shin_world_deg is the shin's angle from
    vertical in world terms (negative tilts the ankle back under the hips).
    Guessing the hip drop instead is what made the first attempt float and read
    as sitting on a chair.
    """
    a, b = math.radians(thigh_deg), math.radians(shin_world_deg)
    drop = (THIGH_LEN + SHIN_LEN) - (THIGH_LEN * math.cos(a) + SHIN_LEN * math.cos(b))
    return {
        "_loc": (0.0, -drop, 0.0),
        "thigh.L": (thigh_deg, 0, 5), "shin.L": (shin_world_deg - thigh_deg, 0, 0),
        "thigh.R": (thigh_deg, 0, -5), "shin.R": (shin_world_deg - thigh_deg, 0, 0),
        # Sole stays flat: cancel the shin's world tilt at the ankle.
        "foot.L": (-shin_world_deg, 0, 0), "foot.R": (-shin_world_deg, 0, 0),
        "spine": (spine_deg, 0, 0), "chest": (chest_deg, 0, 0),
    }


# Torso leans well forward — an upright squat reads as sitting, not as taking
# cover.
CROUCH_LEGS = crouch_legs(42, -38)


# ---------------------------------------------------------------------------
# Run cycle. Built from the classic five-key chart — contact (straight leg),
# down, push, up, contact — rather than hand-placed extremes, so the timing and
# the arcs come out of the reference instead of out of guesswork.
#
# Two things the reference cannot give us directly:
#  * Its free arms swing in opposition. Ours are both on the weapon, so they
#    cannot. The whole arm-plus-rifle unit pumps as one instead — see run_key.
#  * It has a flight phase, and so does this: --traj measures each boot on the
#    floor for 5 frames of every 10. That is not a choice. The hip pivot is
#    0.90 m up and the leg reaches 0.77 m, so a foot can only touch the ground
#    while its leg is within ~20 degrees of vertical — about 0.13 m of reach
#    either side of the hips. Any pose that reaches out far enough to look like
#    the chart is, by construction, off the ground. A continuously grounded run
#    is available, but only with a short crouched stride, which is the heavy
#    hunch this cycle replaced.
#
# Sign conventions that bite here: the shin's WORLD angle is thigh + shin, and a
# flat sole needs foot = -shin_world (see crouch_legs). Anything below that
# points the toe down; anything above lifts it.
# ---------------------------------------------------------------------------

# Muzzle-down and across the body, matching the idle carry.
RUN_PITCH = -20.0

# Straight-leg reach. Neither foot is loaded yet: the front heel is still coming
# down and the back toe has just left. This is the widest pose in the cycle and
# it alone sets the stride length.
RUN_LEGS_CONTACT = {
    "hips": (0, -7, 3),
    "thigh.L": (50, 0, 4), "shin.L": (-4, 0, 0), "foot.L": (-34, 0, 0),
    # Trailing knee stays nearly straight and the ankle is plantarflexed past
    # vertical (shin_world + foot = -114 deg, so the toe trails BEHIND the
    # ankle). Both matter: curling the knee up or letting the toe point forward
    # pulls the foot back under the hips and costs ~0.15 m of stride each.
    "thigh.R": (-46, 0, -4), "shin.R": (-28, 0, 0), "foot.R": (-40, 0, 0),
}
# Down: the plant. Weight is over the left foot, the knee absorbs it and the
# hips reach their lowest point. This — not contact — is the frame the footstep
# fires on.
RUN_LEGS_DOWN = {
    "hips": (0, -4, 2),
    "thigh.L": (24, 0, 4), "shin.L": (-52, 0, 0), "foot.L": (26, 0, 0),
    "thigh.R": (-20, 0, -4), "shin.R": (-72, 0, 0), "foot.R": (47, 0, 0),
}
# Push: the support leg drives out of the compression and the hips start to
# rise. The swing knee is coming through with the heel tucked up under it.
RUN_LEGS_PUSH = {
    "hips": (0, 0, 0),
    "thigh.L": (-8, 0, 4), "shin.L": (-24, 0, 0), "foot.L": (2, 0, 0),
    "thigh.R": (10, 0, -4), "shin.R": (-82, 0, 0), "foot.R": (42, 0, 0),
}
# Up: highest hips, support leg extended behind. The toe is pointed hard, which
# keeps it grazing the floor a couple of frames longer than a relaxed ankle
# would and so shortens the flight phase; it is also what the chart's silhouette
# does at the top of the bob.
RUN_LEGS_UP = {
    "hips": (0, 5, -2),
    "thigh.L": (-26, 0, 4), "shin.L": (-4, 0, 0), "foot.L": (-25, 0, 0),
    "thigh.R": (44, 0, -4), "shin.R": (-66, 0, 0), "foot.R": (27, 0, 0),
}

# Seed angles for the arm solver. Both arms are solved per key (solve_grips),
# so these only need to be in the right neighbourhood for coordinate descent to
# find its way; they are not the poses that ship.
RUN_GRIP = {
    "upperarm.R": (34, 0, 80), "lowerarm.R": (74, 0, 0),
    "upperarm.L": (40, 0, -80), "lowerarm.L": (80, 0, 0),
}


def mirror_legs(p):
    """Mirror the lower body only.

    Mirroring the whole skeleton would hand the trigger to the left hand and put
    the right hand on the barrel for half the cycle, so only the leg dicts go
    through here — hips, thighs, shins and feet. The arms are authored per key.
    X is flexion and survives untouched; Y (twist) and Z (sideways) invert.
    """
    out = {}
    for bone, value in p.items():
        if bone.endswith(".L"):
            name = bone[:-2] + ".R"
        elif bone.endswith(".R"):
            name = bone[:-2] + ".L"
        else:
            name = bone
        out[name] = (value[0], -value[1], -value[2])
    return out


def run_key(lift, legs, drive, twist):
    """Assemble the torso and legs of one run key; the arms are solved later.

    `lift` is the hip height offset (negative drops the hips), `legs` the lower
    body, and `twist` counter-rotates the shoulders against the pelvis. `drive`
    is carried through to solve_grips, which is what actually moves the arms;
    here it only rolls the chest, the sideways half of the pump.
    """
    body = {
        "_loc": (0.0, lift, 0.0),
        # NEGATIVE X leans the torso FORWARD. The calibration note above says
        # "+X ... spine bends forward", which holds for the limbs but not for
        # the spine and chest: those bones point up, so the same local rotation
        # tips them the other way (measured — +20 on the spine carries the
        # shoulders 0.12 m BACKWARD). The forward lean is doing double duty
        # here: it is the reference's posture, and it carries the left shoulder
        # far enough forward for the support hand to reach the handguard at all.
        "spine": (-15, twist * 0.4, 0),
        "chest": (-5, twist, -drive * 0.35),
        # Head tips back against the lean so the soldier keeps looking down his
        # line of travel, and counter-twists so he isn't scanning left and right
        # once per stride.
        "head": (14, -twist * 0.6, 0),
    }
    # level_weapon here is only a seed for the solver — it cannot account for
    # the shoulder twist the solver introduces, so _aim_barrel replaces its
    # answer once the rig exists.
    return level_weapon(pose(RUN_GRIP, legs, body), RUN_PITCH)


# (name, legs, hip lift, arm drive, shoulder counter-twist) for the half-stride
# that leads with the left foot. The right-lead half mirrors the legs and
# negates the pump.
RUN_KEYS = (
    ("contact", RUN_LEGS_CONTACT, -0.045, 12, -8),
    ("down", RUN_LEGS_DOWN, -0.085, 7, -5),
    ("push", RUN_LEGS_PUSH, -0.055, 0, 0),
    ("up", RUN_LEGS_UP, -0.020, -7, 5),
)

# ---------------------------------------------------------------------------
# Standing stances. Two of them, and the whole point is that they read as
# different intentions at a glance:
#
#   idle — LOW READY. Weapon in both hands but carried across the body with the
#          muzzle depressed. Not pointed at anything. The soldier is holding
#          ground, not engaging.
#   aim  — weapon brought up and levelled, torso bladed in behind it. Engaging.
#
# Both are the same braced two-handed silhouette borrowed from the Space Marine
# reference — elbows out, support arm reaching across, weapon lying along a
# diagonal — separated by how high the weapon rides and where it points.
# ---------------------------------------------------------------------------

# Bladed fighting stance, left foot forward, right dropped back and turned out.
#
# A leg tilted away from vertical does not reach as far down as an upright one,
# so the stagger cannot just be opened out: the first attempt left the rear boot
# hanging 26 mm in the air. The rear leg is therefore carried noticeably
# straighter than the front one, which both makes up the reach and is what a
# weight-forward fighting stance does anyway. Feet cancel their own shin's world
# angle to keep both soles flat; the lift is whatever is left of the 0.77 m leg
# once the knees are softened. Verified with --traj: both toes land within 5 mm
# of the 0.060 m rest height.
READY_LEGS = {
    "_loc": (0.0, -0.027, 0.0),
    "hips": (0, 6, 0),
    # NEGATIVE Z abducts a .L bone. The calibration note's "+Z sideways;
    # mirrored between .L and .R" is true but does not say which way: +Z on the
    # left leg swings it ACROSS the body. Widening the stance with positive Z
    # crossed the legs over each other instead, and still measured 0.228 m wide
    # because the toes had simply swapped sides.
    "thigh.L": (16, 0, -8), "shin.L": (-8, 0, 0), "foot.L": (-8, 0, -10),
    "thigh.R": (-8, 0, 8), "shin.R": (0, 0, 0), "foot.R": (8, 0, 14),
}
# Aim deliberately reuses READY_LEGS rather than defining its own. Raising a
# weapon does not move your feet, and the shoot clips blend out of the idle
# stance in 80 ms — any difference in the legs shows up as the boots skating
# across the floor every time the unit fires.
AIM_LEGS = READY_LEGS

# Weapon placement, as the right WRIST position in armature space plus a barrel
# angle — the same parametrisation the run uses, for the same reason: the rifle
# hangs off hand.R, so this fixes the whole weapon and both arms are then solved
# to it. `support` is how far up the barrel the left hand grips; poses that hold
# the weapon further out have to slide it back down to stay inside the left
# arm's 0.535 m reach.
READY_WRIST = Vector((-0.09, 0.14, 1.20))
READY_PITCH = -26.0
# The muzzle is also swung across to the soldier's left, off his own line of
# travel. This is the single clearest "not engaging" cue at tactical camera
# distance — a depressed barrel still reads as aiming if it points where the
# character is facing, but one crossing the body plainly does not.
READY_YAW = 12.0
READY_SUPPORT = 0.20
# Aim brings the weapon up to the shoulder and levels it onto the line of sight.
AIM_WRIST = Vector((-0.15, 0.12, 1.36))
AIM_PITCH = 0.0
AIM_SUPPORT = 0.20

# The magazine, in rifle space: RIFLE_PARTS' MAT_VEST section hanging below and
# forward of the receiver. Reload solves the support hand onto this instead of
# the handguard, so the hand genuinely leaves the weapon rather than drifting a
# few degrees off it.
MAG_LOCAL = Vector((0.0, 0.045, -0.13))
MAG_SEATED = Vector((0.0, 0.045, -0.07))

# Idle sway. Six seconds, sampled every half second.
#
# Every layer's period divides the loop a whole number of times, or the clip
# would jump at the seam. Within that constraint they are given different rates
# and different phases so they only ever line up at the loop point — a single
# breath rate on everything reads as a pulsing machine.
IDLE_SECONDS = 6.0
IDLE_KEYS = 12


def idle_key_name(i):
    return f"idle_{i:02d}"


def idle_sway(phase):
    """Sway offsets at `phase` (0..1) through the idle loop.

    Breathing runs three times per loop, the muzzle's figure-eight twice (its
    vertical axis) against once (its horizontal), and the weight shift and head
    scan once each, offset from everything else. The weapon is held in world
    space rather than swayed with the chest — the arms re-solve onto it every
    key — so the body breathes around a steady weapon, which is what a braced
    two-handed hold actually looks like.
    """
    turn = 2.0 * math.pi * phase
    return {
        "breath": math.sin(3.0 * turn),
        "weight": math.sin(turn + 0.6 * math.pi),
        "scan": math.sin(turn + 1.3 * math.pi),
        # Figure-eight: the muzzle's vertical drift cycles twice per horizontal.
        "pitch": 1.4 * math.sin(2.0 * turn),
        "yaw": 1.8 * math.sin(turn),
        # A breath lifts the shoulders, and the weapon rides up with them.
        "settle": 0.006 * math.sin(3.0 * turn),
    }


def ready_key(phase):
    """One key of the idle loop: stance plus sway. Arms are solved later."""
    s = idle_sway(phase)
    legs = dict(READY_LEGS)
    legs["hips"] = (0, 6, 2.0 * s["weight"])
    return level_weapon(pose(GRIP_LOW, legs, {
        # Negative X leans the torso forward — see run_key for why the
        # calibration note's sign is wrong for the spine and chest.
        "spine": (-8 + 0.6 * s["breath"], 0, -1.2 * s["weight"]),
        "chest": (-2 + 1.2 * s["breath"], 8, 1.5 * s["weight"]),
        # Head up and turned off the weapon's line: watching the room, not the
        # sights. The slow scan rides on top of that.
        "head": (10, -20 + 3.5 * s["scan"], 0),
    }), READY_PITCH)


# Where the support hand belongs: this far up the barrel from the grip, on the
# handguard (RIFLE_PARTS' MAT_SUIT section spans 0.180-0.330). Poses that carry
# the weapon further from the left shoulder slide the hand back down it. PALM is
# how far down the hand bone the palm sits — the same 0.055 offset GRIP_LOCAL
# uses to seat the trigger hand on the grip.
SUPPORT_GRIP_Y = 0.22
PALM = 0.055

# The weapon's own path through the cycle, as the position of the right WRIST in
# armature space. Authoring this instead of shoulder and elbow angles is what
# makes the two-handed carry tractable: the rifle hangs off hand.R, so this
# point plus RUN_PITCH fixes the whole weapon, and both arms are then solved to
# wherever it went.
#
# It is carried high and tucked in against the chest, and that is not a style
# choice. The support hand has a 0.535 m reach from the left shoulder; drop the
# grip to the right hip like a relaxed low carry and the handguard sits 0.8 m
# away, which no left-arm pose can close.
WEAPON_HOME = Vector((-0.08, 0.15, 1.22))
# One pump per full stride — locked arms cannot swing in opposition, so the
# whole arm-and-rifle unit travels instead. Mostly up and across rather than
# forward: a forward reach costs support-hand range, and the diagonal is what
# stands in for the reference's opposed arm swing anyway. Metres at |drive| = 12.
WEAPON_DRIVE = Vector((0.11, 0.09, 0.11))


def _solve_arm(rig_obj, out, side, target, tip):
    """Aim one arm at a point. Mutates `out`; returns the residual in mm.

    Puts the spot `tip` metres down the hand bone onto `target` by coordinate
    descent over the shoulder's three angles and the elbow's one — four
    parameters for a three-dimensional goal, seeded from whatever `out` already
    holds. Runs against the real rig at build time and reports how close it got,
    so a target that is simply out of reach cannot pass silently.
    """
    upper, lower = f"upperarm.{side}", f"lowerarm.{side}"

    def error(v):
        out[upper] = (v[0], v[1], v[2])
        out[lower] = (v[3], 0.0, 0.0)
        apply_pose(rig_obj, out)
        point = rig_obj.pose.bones[f"hand.{side}"].matrix @ Vector((0.0, tip, 0.0))
        return (point - target).length

    seed_u = out.get(upper, (30.0, 0.0, 0.0))
    best_v = [float(seed_u[0]), float(seed_u[1]), float(seed_u[2]),
              float(out.get(lower, (60.0, 0.0, 0.0))[0])]
    best = error(best_v)
    step = 12.0
    while step > 0.2:
        improved = False
        for i in range(4):
            for delta in (step, -step):
                trial = list(best_v)
                trial[i] += delta
                dist = error(trial)
                if dist < best - 1e-5:
                    best_v, best, improved = trial, dist, True
        if not improved:
            step *= 0.5
    error(best_v)  # leave `out` holding the winning angles
    return best * 1000.0


def _aim_barrel(rig_obj, out, pitch, yaw=0.0):
    """Solve the right wrist so the barrel points at `pitch`/`yaw`. Mutates
    `out`; returns the residual in degrees. +yaw swings the muzzle to the
    soldier's left.

    level_weapon does this arithmetically by summing the X rotations down the
    arm, which is exact only while that chain is pure flexion. The solved
    trigger arm is not — it abducts and twists the shoulder as well — and
    ignoring that left the muzzle up to 40 degrees off, pointing at the sky for
    most of the cycle. So measure the barrel and drive the wrist to the answer.
    """
    level = math.cos(math.radians(pitch))
    want = Vector((level * math.sin(math.radians(yaw)),
                   level * math.cos(math.radians(yaw)),
                   math.sin(math.radians(pitch))))

    def error(v):
        out["hand.R"] = (v[0], 0.0, v[1])
        apply_pose(rig_obj, out)
        aim = (rig_obj.pose.bones["hand.R"].matrix @ GRIP_LOCAL).to_3x3() \
            @ Vector((0.0, 1.0, 0.0))
        return math.degrees(aim.normalized().angle(want))

    best_v = [float(out.get("hand.R", (0.0, 0.0, 0.0))[0]), 0.0]
    best = error(best_v)
    step = 40.0
    while step > 0.05:
        improved = False
        for i in range(2):
            for delta in (step, -step):
                trial = list(best_v)
                trial[i] += delta
                off = error(trial)
                if off < best - 1e-6:
                    best_v, best, improved = trial, off, True
        if not improved:
            step *= 0.5
    error(best_v)
    return best


def solve_two_handed(rig_obj, p, wrist, pitch, yaw=0.0, support=SUPPORT_GRIP_Y):
    """Put both hands on the weapon. Returns (pose, hand mm, barrel degrees).

    Strictly ordered, because each step depends on the one before: place the
    trigger wrist where the weapon is meant to be (hand.R's own rotation does
    not move its head, so this is independent of the barrel angle), then aim the
    barrel, and only then is the handguard's position known and the support hand
    solvable.
    """
    out = dict(p)
    _solve_arm(rig_obj, out, "R", wrist, 0.0)
    off = _aim_barrel(rig_obj, out, pitch, yaw)
    handguard = (rig_obj.pose.bones["hand.R"].matrix
                 @ GRIP_LOCAL) @ Vector((0.0, support, 0.0))
    return out, _solve_arm(rig_obj, out, "L", handguard, PALM), off


def _derive_engaged_poses(rig_obj):
    """Rebuild everything that hangs off "aim" now that "aim" has been solved.

    overwatch and the recoils used to be authored against GRIP_AIM
    independently. Now that the aim pose puts both hands on the weapon for real,
    deriving from it keeps the trigger arm and the weapon exactly where aim left
    them — an independently authored version would pop the rifle sideways the
    moment a clip crossed between them. All of these nudge the spine, chest and
    head only, which is safe: both arms hang off the chest, so rotating the
    torso carries the whole two-handed assembly with it and the grip survives.

    reload is the exception, and the one pose that deliberately breaks the hold:
    its support hand is solved down onto the magazine instead of the handguard.
    """
    aim = POSE_LIB["aim"]
    POSE_LIB["overwatch"] = nudge(aim, spine=(0, 0, 12), chest=(0, 6, 0),
                                  head=(0, -4, 0))
    POSE_LIB["recoil_snap"] = nudge(aim, chest=(-7, 0, 0), head=(-4, 0, 0))
    POSE_LIB["watch_l"] = nudge(POSE_LIB["overwatch"], spine=(0, 0, -22),
                                head=(0, 0, 8))
    POSE_LIB["watch_r"] = POSE_LIB["overwatch"]

    for name, mag in (("reload", MAG_LOCAL), ("mag_in", MAG_SEATED)):
        p = nudge(aim, head=(6, 10, 0), chest=(2, 0, -4))
        apply_pose(rig_obj, p)
        target = (rig_obj.pose.bones["hand.R"].matrix @ GRIP_LOCAL) @ mag
        _solve_arm(rig_obj, p, "L", target, PALM)
        POSE_LIB[name] = p

    # crouch is solved the same way as aim (see solve_grips) rather than left on
    # level_weapon's arithmetic, which is only exact for pure flexion and drifts
    # tens of degrees off once the shoulder abducts as far as this grip does.
    # Its own derivatives follow the same pattern as aim's above.
    POSE_LIB["crouch"] = crouch = nudge(POSE_LIB["crouch"], chest=(2, 0, -8))
    POSE_LIB["recoil_crouch"] = nudge(crouch, chest=(-8, 0, 0), head=(-4, 0, 0))
    POSE_LIB["crouch_b"] = nudge(crouch, spine=(2, 0, 0), head=(1, 0, 0))


def solve_grips(rig_obj):
    """Solve every pose that holds the weapon in both hands.

    Needs the built rig, so it cannot happen where POSE_LIB is declared. Every
    downstream path (clips, sheets, trajectory, export) reads POSE_LIB, so doing
    it here keeps them all consistent.
    """
    worst_hand = (0.0, "")
    worst_aim = (0.0, "")

    def solve(name, wrist, pitch, yaw=0.0, support=SUPPORT_GRIP_Y):
        nonlocal worst_hand, worst_aim
        POSE_LIB[name], mm, deg = solve_two_handed(
            rig_obj, POSE_LIB[name], wrist, pitch, yaw, support)
        worst_hand = max(worst_hand, (mm, name))
        worst_aim = max(worst_aim, (deg, name))

    for key, _legs, _lift, drive, _twist in RUN_KEYS:
        for side in "LR":
            # The right-lead half of the stride is the far end of the same pump.
            swing = drive / 12.0 * (1.0 if side == "L" else -1.0)
            solve(f"run_{key}_{side}", WEAPON_HOME + WEAPON_DRIVE * swing,
                  RUN_PITCH)

    for i in range(IDLE_KEYS):
        sway = idle_sway(i / float(IDLE_KEYS))
        solve(idle_key_name(i), READY_WRIST + Vector((0.0, 0.0, sway["settle"])),
              READY_PITCH + sway["pitch"], READY_YAW + sway["yaw"], READY_SUPPORT)
    # Other clips key off "idle" as their neutral, so it has to be the phase-0
    # sway key rather than a separate pose that would pop against it.
    POSE_LIB["idle"] = POSE_LIB[idle_key_name(0)]

    solve("aim", AIM_WRIST, AIM_PITCH, support=AIM_SUPPORT)
    solve("crouch", AIM_WRIST, AIM_PITCH, support=0.0)
    _derive_engaged_poses(rig_obj)

    apply_pose(rig_obj, {})
    print(f"[gen_soldier] grips: support hand within {worst_hand[0]:.1f} mm of "
          f"the handguard ({worst_hand[1]}), barrel within {worst_aim[0]:.1f} "
          f"deg of target ({worst_aim[1]})")

POSE_LIB = {
    # Both replaced below by solved two-handed versions; these are only seeds.
    "idle": level_weapon(pose(GRIP_LOW, spine=(3, 0, 0), head=(-2, 0, 0)), -20),
    "aim": level_weapon(pose(GRIP_AIM, spine=(4, 0, 0)), 0),
    # chest carries both the crouch lean and the grip's shoulder turn.
    # The crouched lean itself (on top of CROUCH_LEGS' own spine/chest) is
    # applied as a nudge after solve_grips solves the grip — see
    # _derive_engaged_poses — so the support hand is solved against a torso
    # close to the standing aim pose's, which is within its reach, rather than
    # already twisted into the crouch's final lean.
    "crouch": level_weapon(pose(CROUCH_LEGS, GRIP_AIM), 0),
    # Overwatch is the aim pose turned off-centre: the scan sweeps from here.
    "overwatch": level_weapon(pose(GRIP_AIM, spine=(4, 0, 12), head=(0, 0, -6)), 0),
    # Reload: weapon stays up on the right, left hand drops away to the
    # magazine. Pulled well clear of the aim pose so the two read differently at
    # a glance.
    "reload": level_weapon(pose(GRIP_AIM, **{
        "upperarm.R": (30, 0, -26), "lowerarm.R": (66, 0, 0),
        "upperarm.L": (4, 0, 30), "lowerarm.L": (118, 0, 0),
        "head": (12, 0, 8), "chest": (6, 0, -4),
    }), -12),
    # Interact and grenade both reach with the LEFT arm: the rifle is bolted to
    # hand.R, so reaching with the right would swing the barrel at the terminal.
    # These three are upper-body actions played out of the idle stance, so they
    # carry READY_LEGS: without it their lower body is the rest pose and the
    # boots visibly slide together every time one plays.
    "interact": level_weapon(pose(GRIP_LOW, READY_LEGS, **{
        "upperarm.L": (76, 0, 12), "lowerarm.L": (16, 0, 0),
        "spine": (6, 0, 10), "head": (4, 0, 8),
    }), -24),
    "grenade": level_weapon(pose(GRIP_LOW, READY_LEGS, **{
        "upperarm.L": (-50, 0, 30), "lowerarm.L": (94, 0, 0),
        "spine": (-8, 0, 14), "chest": (0, 0, 10),
    }), -20),
    # Thighs are READY_LEGS' own values with the flinch added, rather than
    # replacing them, so the stance survives the hit.
    "hit": level_weapon(pose(GRIP_LOW, READY_LEGS, **{
        "spine": (-16, 0, 0), "chest": (-8, 0, 4), "head": (-14, 0, 0),
        "thigh.L": (8, 0, 5), "thigh.R": (2, 0, -7),
    }), -34),
    # Collapsed on its back. Rotating the hips lays the whole body down.
    "downed": pose({
        "_loc": (0.0, -0.62, 0.0),
        "hips": (-82, 0, 0),
        "spine": (-10, 0, 0), "chest": (-6, 0, 0), "head": (24, 0, 0),
        "thigh.L": (74, 0, 10), "shin.L": (-52, 0, 0),
        "thigh.R": (66, 0, -8), "shin.R": (-38, 0, 0),
        "upperarm.R": (-28, 0, -46), "lowerarm.R": (34, 0, 0),
        "upperarm.L": (-20, 0, 42), "lowerarm.L": (28, 0, 0),
    }),
}

# Run keys, both halves. The legs mirror; the arms deliberately do not.
for _name, _legs, _lift, _drive, _twist in RUN_KEYS:
    POSE_LIB[f"run_{_name}_L"] = run_key(_lift, _legs, _drive, _twist)
    POSE_LIB[f"run_{_name}_R"] = run_key(_lift, mirror_legs(_legs), -_drive, -_twist)

# Idle sway keys, and the aim stance. Seeds only — solve_grips replaces the arms
# on all of them once the rig exists.
for _i in range(IDLE_KEYS):
    POSE_LIB[idle_key_name(_i)] = ready_key(_i / float(IDLE_KEYS))
POSE_LIB["aim"] = level_weapon(pose(GRIP_AIM, AIM_LEGS, {
    "spine": (-8, 0, 0),
    # Bladed in behind the weapon: the twist squares the left shoulder up to the
    # target, which is both what the reference does and what buys the support
    # arm the reach to get out onto the handguard.
    "chest": (-4, 12, 0),
    # Head goes DOWN behind the weapon and stops counter-twisting — the soldier
    # is looking along the barrel, not scanning past it. Against the idle's
    # raised, turned-away head this is most of what separates the two stances.
    "head": (-4, -14, 0),
}), AIM_PITCH)

# Derived variants. Everything that hangs off "aim" or "crouch" — the recoils,
# overwatch, reload — is rebuilt in _derive_engaged_poses instead, because
# neither is final until the rig exists and its grip has been solved. Only the
# poses built on grenade and interact can be finished here.
POSE_LIB["throw"] = nudge(POSE_LIB["grenade"], **{"upperarm.L": (108, 0, -16),
                                                  "lowerarm.L": (-64, 0, 0),
                                                  "spine": (14, 0, -8)})
POSE_LIB["press"] = nudge(POSE_LIB["interact"], **{"upperarm.L": (6, 0, 0),
                                                   "lowerarm.L": (10, 0, 0)})

REVIEW_A = ["idle", "aim", "crouch", "overwatch", "reload", "interact"]
REVIEW_B = ["grenade", "hit", "downed", "run_contact_L", "run_up_L"]


# ---------------------------------------------------------------------------
# Clips. Names must match the constants in scripts/unit_visual.gd exactly.
# 30 fps. Loop flags can't ride along in glTF — set them in Godot's Advanced
# Import Settings, where they persist in the .import file across re-exports.
# Firing has no muzzle frame: play_burst emits one muzzle event per round as it
# replays shoot_recoil, so the count is decided at runtime rather than baked.
# ---------------------------------------------------------------------------

FPS = 30

CLIPS = {
    # Generated: IDLE_KEYS sway keys evenly spaced round a 6 s loop, closing on
    # the first key again. Authored keys would have to be re-hand-tuned every
    # time the sway rates change.
    "idle":            [(round(i * IDLE_SECONDS * FPS / IDLE_KEYS),
                         idle_key_name(i % IDLE_KEYS))
                        for i in range(IDLE_KEYS + 1)],
    "crouch_idle":     [(0, "crouch"), (55, "crouch_b"), (110, "crouch")],
    "overwatch_hold":  [(0, "watch_l"), (55, "watch_r"), (110, "watch_l")],
    # Frame count is derived from the measured stride, not chosen: see
    # dump_trajectory's skate check. Key spacing within each half-stride follows
    # the reference chart's 1/3/5/8/12 proportions, so the slow settle after the
    # plant and the quick snap through the top are preserved at our frame count.
    "run":             [(0, "run_contact_L"), (2, "run_down_L"),
                        (4, "run_push_L"), (7, "run_up_L"),
                        (10, "run_contact_R"), (12, "run_down_R"),
                        (14, "run_push_R"), (17, "run_up_R"),
                        (20, "run_contact_L")],
    # Firing is built from two clips rather than one per shot type, because the
    # burst length is rolled at runtime (3-5) and no fixed-length clip can match
    # a count it doesn't know. aim_hold carries the raise and the settle either
    # side of the burst; shoot_recoil is a single round's kick and recovery,
    # replayed from frame 0 once per round. UnitVisual.play_burst drives both.
    "aim_hold":        [(0, "aim"), (45, "aim")],
    "shoot_recoil":    [(0, "aim"), (1, "recoil_snap"), (4, "aim")],
    "reload":          [(0, "aim"), (7, "reload"), (17, "mag_in"),
                        (27, "aim"), (36, "aim")],
    "throw_grenade":   [(0, "idle"), (9, "grenade"), (15, "throw"),
                        (24, "idle"), (30, "idle")],
    "interact":        [(0, "idle"), (10, "interact"), (17, "press"),
                        (25, "idle"), (30, "idle")],
    "hit_react":       [(0, "idle"), (3, "hit"), (8, "hit"), (14, "idle")],
    "downed":          [(0, "idle"), (5, "hit"), (24, "downed")],
}

# The muzzle event is no longer a frame inside a clip: play_burst emits one per
# round as it replays shoot_recoil, so the flash lands on frame 0 of each kick.


def bake_clips(rig_obj):
    """One Blender Action per clip, keyed on every bone at every listed frame."""
    rig_obj.animation_data_create()
    made = []
    for name, keys in CLIPS.items():
        action = bpy.data.actions.new(name)
        action.use_fake_user = True  # survives with no object assigned
        rig_obj.animation_data.action = action
        for frame, pose_name in keys:
            apply_pose(rig_obj, POSE_LIB[pose_name])
            for pb in rig_obj.pose.bones:
                pb.keyframe_insert("rotation_euler", frame=frame)
            rig_obj.pose.bones["hips"].keyframe_insert("location", frame=frame)
        action.use_frame_range = True
        action.frame_start, action.frame_end = keys[0][0], keys[-1][0]
        made.append(f"{name}({keys[-1][0] / FPS:.2f}s)")
    rig_obj.animation_data.action = None
    apply_pose(rig_obj, {})
    print("[gen_soldier] clips: " + ", ".join(made))


# Must match Unit.MOVE_SPEED in scripts/unit.gd. Step length is not a free
# choice: it is MOVE_SPEED * cycle / 2, and if the authored stride disagrees the
# feet skate and every bit of apparent weight is lost.
MOVE_SPEED = 4.5


def render_clip_strip(mesh_obj, rig_obj, clip, path, frames=9, yaw=90.0,
                      hide=(), rifle_obj=None):
    """Lay `frames` evenly spaced frames of one clip out in a row.

    Static pose sheets can't show timing or arc, which is exactly why the run
    was the weak clip — it was authored without ever being seen in motion. A
    side-on strip is readable and shows both.
    """
    action = bpy.data.actions[clip]
    rig_obj.animation_data_create()
    rig_obj.animation_data.action = action
    start, end = int(action.frame_start), int(action.frame_end)
    spacing = 1.05
    hidden = [mesh_obj] + [o for o in hide if o]
    for obj in hidden:
        obj.hide_render = True
    temps = []
    scene = bpy.context.scene
    for i in range(frames):
        frame = start + int(round((end - start) * i / max(frames - 1, 1)))
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        offset = -(i - (frames - 1) / 2.0) * spacing
        temps.append(_snapshot(mesh_obj, f"strip{i}", offset, yaw))
        if rifle_obj is not None:
            temps.append(_snapshot_rifle(rifle_obj, rig_obj, f"stripgun{i}", offset, yaw))
    cam = _review_scene(path, frames, spacing)
    bpy.ops.render.render(write_still=True)
    print(f"[gen_soldier] wrote {path} ({clip}, frames {start}-{end})")
    for obj in temps + [cam]:
        bpy.data.objects.remove(obj, do_unlink=True)
    for obj in hidden:
        obj.hide_render = False
    rig_obj.animation_data.action = None
    scene.frame_set(start)


def dump_trajectory(rig_obj, clip):
    """Per-frame hip height and foot positions, plus the skate check.

    Judging weight by eye is unreliable; this states objectively whether the hips
    dip on contact and whether the authored stride matches MOVE_SPEED.
    """
    action = bpy.data.actions[clip]
    rig_obj.animation_data_create()
    rig_obj.animation_data.action = action
    start, end = int(action.frame_start), int(action.frame_end)
    scene = bpy.context.scene
    rows = []
    for frame in range(start, end + 1):
        scene.frame_set(frame)
        bpy.context.view_layer.update()
        row = {"f": frame, "hip_z": rig_obj.pose.bones["hips"].matrix.translation.z}
        for side in ("L", "R"):
            pb = rig_obj.pose.bones[f"foot.{side}"]
            tip = pb.matrix @ Vector((0.0, rig_obj.data.bones[f"foot.{side}"].length, 0.0))
            row[side] = (tip.y, tip.z)
        # Barrel is +Y in rifle space; GRIP_LOCAL maps rifle space into hand.R.
        aim = (rig_obj.matrix_world @ rig_obj.pose.bones["hand.R"].matrix
               @ GRIP_LOCAL).to_3x3() @ Vector((0.0, 1.0, 0.0))
        aim.normalize()
        row["pitch"] = math.degrees(math.asin(max(-1.0, min(1.0, aim.z))))
        row["fwd"] = aim.y
        # How far the head and chest are tipped forward. Each bone's local +Y
        # runs up the bone and is vertical at rest, so the angle of that axis
        # away from vertical toward +Y (forward) is the lean. Positive = looking
        # down/forward, negative = tipped back and looking up.
        for name, key in (("head", "hlean"), ("chest", "clean")):
            up = (rig_obj.matrix_world @ rig_obj.pose.bones[name].matrix).to_3x3() \
                @ Vector((0.0, 1.0, 0.0))
            row[key] = math.degrees(math.atan2(up.y, up.z))
        rows.append(row)

    print(f"[traj] {clip}: frame  hip_z   Lfwd   Lup    Rfwd   Rup    pitch  fwd  "
          f"headLean chestLean (+ = looking down)")
    for row in rows:
        print("[traj]   %5d  %.3f  %+.3f %.3f  %+.3f %.3f  %+6.1f  %+.2f  %+6.1f %+6.1f" % (
            row["f"], row["hip_z"], row["L"][0], row["L"][1], row["R"][0], row["R"][1],
            row["pitch"], row["fwd"], row["hlean"], row["clean"]))
    cycle = (end - start) / float(FPS)
    needed = MOVE_SPEED * cycle / 2.0
    hips = [r["hip_z"] for r in rows]
    print("[traj] hip travel %.3f m (dip %.3f -> peak %.3f)" % (
        max(hips) - min(hips), min(hips), max(hips)))
    for side in ("L", "R"):
        ys = [r[side][0] for r in rows]
        print("[traj] foot.%s forward travel = %.3f m" % (side, max(ys) - min(ys)))
    print("[traj] cycle %.3fs @ %.1f m/s needs step = %.3f m "
          "(derive frame count from the measured stride, not the reverse)"
          % (cycle, MOVE_SPEED, needed))
    rig_obj.animation_data.action = None
    scene.frame_set(start)


def export_glb(path, objects):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
    )
    size = os.path.getsize(path) / 1024.0
    print(f"[gen_soldier] wrote {path} ({size:.0f} KB)")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    bpy.context.scene.render.fps = FPS
    mesh_obj, rig_obj, rifle_obj = build()
    # Needs the built rig, so it can't happen where POSE_LIB is declared. Every
    # downstream path (clips, sheets, trajectory, export) reads POSE_LIB, so
    # solving here keeps them all consistent.
    solve_grips(rig_obj)
    if "--clips" in argv or "--export" in argv or "--save" in argv:
        bake_clips(rig_obj)
    if "--render" in argv:
        out = argv[argv.index("--render") + 1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        render_turnaround(mesh_obj, out, hide=(rig_obj, rifle_obj))
    if "--calibrate" in argv:
        out = argv[argv.index("--calibrate") + 1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        render_poses(mesh_obj, rig_obj, CALIBRATION, out, hide=(rig_obj, rifle_obj))
    if "--poses" in argv:
        out = argv[argv.index("--poses") + 1]
        names = argv[argv.index("--poses") + 2].split(",")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        sheet = [(n, POSE_LIB[n]) for n in names]
        render_poses(mesh_obj, rig_obj, sheet, out, hide=(rig_obj, rifle_obj),
                     rifle_obj=rifle_obj)
    if "--strip" in argv:
        i = argv.index("--strip")
        os.makedirs(os.path.dirname(argv[i + 2]), exist_ok=True)
        render_clip_strip(mesh_obj, rig_obj, argv[i + 1], argv[i + 2],
                          hide=(rig_obj, rifle_obj), rifle_obj=rifle_obj)
    if "--traj" in argv:
        dump_trajectory(rig_obj, argv[argv.index("--traj") + 1])
    if "--export" in argv:
        out = argv[argv.index("--export") + 1]
        # assets/soldier_rig.blend is the source of truth for Contractor
        # animations now (hand-authored in Blender, see
        # tools/export_soldier_rig.py) — this path building fresh POSE_LIB
        # poses and overwriting the shipped glb would silently wipe that work.
        # --force-export exists for the rare deliberate rebase (e.g. starting
        # a new soldier_rig.blend after a proportions change).
        if os.path.abspath(out) == os.path.abspath(SHIPPED_SOLDIER_GLB) \
                and "--force-export" not in argv:
            raise SystemExit(
                f"[gen_soldier] refusing to overwrite {out}: animations are "
                "now hand-authored in assets/soldier_rig.blend and shipped "
                "via tools/export_soldier_rig.py. Pass --force-export if you "
                "really mean to rebase it from POSE_LIB instead.")
        # Soldier and rig only. The rifle ships as its own glb so Godot can hang
        # it off a BoneAttachment3D and swap it per class.
        export_glb(out, [rig_obj, mesh_obj])
    if "--export-rifle" in argv:
        export_glb(argv[argv.index("--export-rifle") + 1], [rifle_obj])
    if "--save" in argv:
        out = argv[argv.index("--save") + 1]
        os.makedirs(os.path.dirname(out), exist_ok=True)
        # Grip the rifle onto hand.R the same way Godot's BoneAttachment3D
        # does at runtime, so scrubbing any action in the dope sheet carries
        # the weapon along with it instead of leaving it stranded where build()
        # left it. inverse_matrix is set directly (not via "Set Inverse") to
        # GRIP_LOCAL, which is exactly the constant hand-to-grip offset the
        # runtime attachment uses, so this tracks correctly at any pose.
        con = rifle_obj.constraints.new("CHILD_OF")
        con.target = rig_obj
        con.subtarget = "hand.R"
        con.inverse_matrix = GRIP_LOCAL
        apply_pose(rig_obj, POSE_LIB["aim"])
        bpy.ops.wm.save_as_mainfile(filepath=out)
        size = os.path.getsize(out) / 1024.0
        print(f"[gen_soldier] wrote {out} ({size:.0f} KB)")


main()
