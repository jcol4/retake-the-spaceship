"""Exports the hangar's ships -- the squad's dropship and the bay's wrecks --
from Quaternius' Spaceship Pack (Jan 2018, CC0) to the .glbs the game draws.

    blender.exe -b -P tools/export_ships.py

Writes assets/models/ships/<name>.glb for every entry in SHIPS. The pack's
.blends are read and never written, so every wreck is rebuilt from the intact
ship each run: the damage below is the whole recipe.

Every ship is normalised the same way before it is written, so the game needs
no per-model tuning (ShipModel.fit does the rest):

  * nose along Blender +Y, which glTF's Y-up turns into Godot -Z. The pack's
    ships point their cockpits at -Y, so each is given a half turn.
  * centred on the origin across, belly at z = 0 (a wreck's at WRECK_SINK).
  * materials renamed to M_ship_* / M_wreck_* and recoloured: the pack's pure
    white reads as a hole in the hangar's dark kit. Colours are LINEAR, as
    Blender holds them: 0.2 shows in game as a mid grey, not a dark one.

Sizes are left as the pack has them. MapBuilder and Dropship fit each model to
the space the rules reserve for it, so a deck's footprints never depend on a
model's scale.

A WRECK is the intact ship with a wing sheared off, the nose crumpled, a seeded
dent over every vertex, a nose-down pitch and a roll, sunk into the deck. The
pitch is what gives the flat fighters the height a wreck needs: MapData.wrecks
are full-height sight blockers, and a model lying flat at 1 m would draw as
cover a unit could see over while the rules say it cannot.
"""

import math
import os

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

PACK_DIR = os.path.join("art_src", "ships", "Spaceship Pack - Jan 2018", "Blends")
OUT_DIR = os.path.join("assets", "models", "ships")

# name -> (source .blend, "dropship" or a wreck recipe).
# A wreck recipe: which wing goes (+1 the ship's right, -1 its left), where
# across the half-span it breaks, where along the length the nose breaks
# (0 = middle, 0.5 = tip), the pitch and roll in degrees, and the dent seed.
SHIPS = {
    "dropship": ("Spaceship3.blend", "dropship"),
    "wreck_a": ("Spaceship.blend", dict(wing=1, wing_at=0.45, nose_at=0.32, pitch=-22.0, roll=8.0, seed=1)),
    "wreck_b": ("Spaceship2.blend", dict(wing=-1, wing_at=0.4, nose_at=0.3, pitch=-20.0, roll=-10.0, seed=2)),
    "wreck_c": ("Spaceship4.blend", dict(wing=1, wing_at=0.35, nose_at=0.3, pitch=-24.0, roll=12.0, seed=3)),
    "wreck_d": ("Spaceship5.blend", dict(wing=-1, wing_at=0.5, nose_at=0.34, pitch=-18.0, roll=-7.0, seed=4)),
}

# How far a wreck's lowest point sits below the deck, in the pack's metres:
# the crumpled nose is buried, not resting on the floor.
WRECK_SINK = 0.25
# A dent's reach, as a fraction of the ship's largest dimension, and how many
# dents fit in a metre.
DENT = 0.02
DENT_FREQUENCY = 0.8

# Pack material -> (game material, base colour, metallic, roughness).
SHIP_MATERIALS = {
    "White": ("M_ship_hull", (0.2, 0.21, 0.22), 0.0, 0.6),
    "Black": ("M_ship_glass", (0.03, 0.035, 0.04), 0.2, 0.2),
    "Orange": ("M_ship_trim", (0.85, 0.45, 0.12), 0.1, 0.6),
}
WRECK_MATERIALS = {
    "White": ("M_wreck_hull", (0.07, 0.065, 0.06), 0.0, 0.9),
    "Black": ("M_wreck_glass", (0.02, 0.02, 0.02), 0.1, 0.6),
    "Orange": ("M_wreck_trim", (0.28, 0.1, 0.04), 0.1, 0.95),
}


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, (blend, recipe) in SHIPS.items():
        bpy.ops.wm.open_mainfile(filepath=os.path.abspath(os.path.join(PACK_DIR, blend)))
        obj = [o for o in bpy.data.objects if o.type == 'MESH'][0]
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        bm.transform(obj.matrix_world)
        # Nose from -Y to +Y (Godot -Z).
        bm.transform(Matrix.Rotation(math.pi, 4, 'Z'))
        if recipe == "dropship":
            _ground(bm, 0.0)
            _recolour(obj, SHIP_MATERIALS)
        else:
            _wreck(bm, recipe)
            _ground(bm, -WRECK_SINK)
            _recolour(obj, WRECK_MATERIALS)
        bm.to_mesh(obj.data)
        bm.free()
        obj.matrix_world = Matrix.Identity(4)
        obj.name = name
        for other in [o for o in bpy.data.objects if o is not obj]:
            bpy.data.objects.remove(other)
        out = os.path.abspath(os.path.join(OUT_DIR, name + ".glb"))
        bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_yup=True,
            export_apply=True, export_cameras=False, export_lights=False)
        print("export_ships: wrote", out)


def _bounds(bm):
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    for v in bm.verts:
        lo = Vector(map(min, lo, v.co))
        hi = Vector(map(max, hi, v.co))
    return lo, hi


## Centres across and lengthwise, and puts the lowest point at `floor_z`.
def _ground(bm, floor_z):
    lo, hi = _bounds(bm)
    shift = Vector((-(lo.x + hi.x) / 2.0, -(lo.y + hi.y) / 2.0, floor_z - lo.z))
    bm.transform(Matrix.Translation(shift))


def _wreck(bm, r):
    lo, hi = _bounds(bm)
    centre = (lo + hi) / 2.0
    half = (hi - lo) / 2.0
    # The wing, sheared off at a slant rather than square.
    _cut(bm, Vector((centre.x + r["wing"] * half.x * r["wing_at"], centre.y, centre.z)),
        Vector((r["wing"], 0.35, 0.15)))
    # The nose, crumpled at a downward slant into the deck.
    _cut(bm, Vector((centre.x, centre.y + half.y * r["nose_at"] * 2.0, centre.z)),
        Vector((0.25, 1.0, -0.45)))
    # Dented by a noise field over position, not per vertex: the pack's meshes
    # are flat-shaded with a vertex per face corner, and corners that share a
    # position must move together or the faces tear apart.
    offset = Vector((r["seed"] * 17.3, r["seed"] * 5.1, r["seed"] * 11.7))
    reach = DENT * max(hi - lo)
    for v in bm.verts:
        v.co += noise.noise_vector(v.co * DENT_FREQUENCY + offset) * reach
    # Nose down about X, then the roll about the length.
    bm.transform(Matrix.Rotation(math.radians(r["roll"]), 4, 'Y')
        @ Matrix.Rotation(math.radians(r["pitch"]), 4, 'X'))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)


## Removes everything on `normal`'s side of the plane through `point` and
## caps the break, so the hull reads as torn rather than hollow.
def _cut(bm, point, normal):
    normal = normal.normalized()
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    res = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=point, plane_no=normal, clear_outer=True)
    edges = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
    if edges:
        bmesh.ops.holes_fill(bm, edges=edges, sides=0)


def _recolour(obj, table):
    for slot in obj.material_slots:
        if slot.material is None or slot.material.name not in table:
            continue
        new_name, colour, metallic, roughness = table[slot.material.name]
        mat = bpy.data.materials.new(new_name)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (*colour, 1.0)
        bsdf.inputs["Metallic"].default_value = metallic
        bsdf.inputs["Roughness"].default_value = roughness
        slot.material = mat


main()
