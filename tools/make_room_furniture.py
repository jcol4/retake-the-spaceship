"""Rebuild original room furniture: blender -b --python tools/make_room_furniture.py.

Dimensions are metres; exported origins are footprint centres on the floor.
No downloaded art, textures, lights, physics, or cameras are embedded.
"""
from pathlib import Path
import json
import bpy

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets' / 'room_tiles' / 'ship_furniture'
OUT.mkdir(parents=True, exist_ok=True)


def material(name, color, metal=0.0, glow=0.0):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    node = mat.node_tree.nodes.get('Principled BSDF')
    node.inputs['Base Color'].default_value = (*color, 1)
    node.inputs['Metallic'].default_value = metal
    node.inputs['Roughness'].default_value = 0.48
    if glow:
        node.inputs['Emission Color'].default_value = (*color, 1)
        node.inputs['Emission Strength'].default_value = glow
    return mat


STEEL = material('gunmetal', (0.12, 0.17, 0.20), .7)
FRAME = material('edge_metal', (0.27, 0.33, 0.35), .6)
CREAM = material('ceramic', (0.64, 0.70, 0.68), .15)
BLUE = material('mattress_blue', (0.10, 0.25, 0.32))
AMBER = material('warning_amber', (0.72, 0.39, 0.08), .3)
CYAN = material('status_cyan', (0.10, 0.72, 0.85), .2, 2.5)
RED = material('status_red', (0.9, 0.15, 0.08), .2, 1.5)


def cube(name, center, size, mat, bevel=.025):
    # Author as X / depth / height, with front at Blender -Y (Godot +Z).
    x, y, z = center
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, -y, z))
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    mod = obj.modifiers.new('manufactured_edges', 'BEVEL')
    mod.width = bevel
    mod.segments = 2
    bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def bunk():
    for x in (-1.28, 1.28):
        for y in (-.51, .51):
            cube('upright', (x,y,.56), (.09,.09,1.12), FRAME)
    for z in (.25,.78):
        cube('bed_frame', (0,0,z), (2.62,1.12,.10), STEEL)
        cube('mattress', (0,0,z+.10), (2.40,.96,.13), BLUE, .04)
        cube('pillow', (-.91,0,z+.18), (.42,.87,.10), CREAM, .035)
        cube('safety_rail', (0,-.5,z+.26), (2.56,.055,.055), FRAME)
    for z in (.18,.41,.64,.87):
        cube('ladder_rung', (1.28,.59,z), (.10,.27,.045), AMBER, .01)


def mess_table():
    cube('table_top', (0,0,.92), (4.20,1.18,.12), CREAM)
    cube('rim', (0,0,.85), (4.28,1.24,.05), STEEL)
    for x in (-1.45,1.45):
        cube('pedestal', (x,0,.41), (.21,.22,.82), STEEL)
        cube('foot', (x,0,.04), (.60,1.10,.08), FRAME)
    for x in (-1.2,0,1.2):
        cube('tray_mark', (x,.30,.986), (.53,.35,.012), BLUE, .008)


def lab_bench():
    cube('plinth', (0,0,.05), (2.62,1.14,.10), STEEL)
    cube('cabinet', (0,0,.47), (2.60,1.12,.84), CREAM)
    cube('work_surface', (0,0,.93), (2.76,1.24,.12), FRAME)
    for x in (-.85,0,.85):
        cube('door_seam', (x,.568,.47), (.025,.015,.66), STEEL, .004)
        cube('handle', (x+.17,.60,.60), (.24,.06,.035), STEEL, .008)
    cube('instrument', (-.70,-.25,1.065), (.60,.45,.15), STEEL)
    cube('screen', (-.70,-.25,1.15), (.45,.32,.02), CYAN, .005)
    for x in (.5,.8,1.1):
        cube('sample_vial', (x,-.22,1.08), (.13,.13,.20), CYAN, .03)


def server_rack():
    cube('base', (0,0,.07), (2.72,1.20,.14), STEEL)
    cube('cabinet', (0,0,.90), (2.60,1.10,1.66), FRAME)
    for x in (-.85,0,.85):
        for z in (.28,.54,.80,1.06,1.32,1.58):
            cube('blade', (x,.57,z), (.72,.08,.18), STEEL, .012)
            for i in range(4):
                cube('vent', (x-.22+i*.12,.617,z), (.055,.012,.10), FRAME, .002)
            cube('status', (x+.29,.62,z), (.035,.015,.075), CYAN, .003)


def engine():
    cube('foundation', (0,0,.09), (4.22,2.72,.18), FRAME)
    cube('engine_core', (0,0,.72), (3.75,1.80,1.15), STEEL, .09)
    for x in (-1.6,-1.15,-.7,-.25,.2,.65,1.1,1.55):
        cube('cooling_fin', (x,0,.88), (.12,2.15,1.30), FRAME)
    for y in (-1.13,1.13):
        cube('power_rail', (0,y,.53), (3.88,.19,.23), AMBER)
        cube('energy_strip', (0,y,.72), (3.66,.09,.08), CYAN, .008)
    cube('control_head', (-1.7,0,1.49), (.65,.85,.25), AMBER)
    cube('status', (-1.7,.44,1.49), (.43,.02,.10), RED, .005)


specs = [('bunk', bunk, [2,1], 'light'), ('mess_table', mess_table, [3,1], 'light'),
         ('lab_bench', lab_bench, [2,1], 'light'), ('server_rack', server_rack, [2,1], 'heavy'),
         ('machinery', engine, [3,2], 'heavy')]
pieces = []
for name, build, footprint, tier in specs:
    # Only reset this temporary Blender scene; never remove workspace files.
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    build()
    bpy.ops.object.select_all(action='SELECT')
    bpy.context.view_layer.objects.active = bpy.context.selected_objects[0]
    bpy.ops.object.join()
    bpy.context.scene.cursor.location = (0,0,0)
    bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
    bpy.context.object.name = 'Ship_' + name
    bpy.ops.export_scene.gltf(filepath=str(OUT / (name + '.glb')), export_format='GLB', use_selection=True)
    pieces.append(dict(id='ship_' + name, file=name + '.glb', socket='furniture_' + name,
                       footprint=footprint, tier=tier, weight=8))
(OUT / 'ship_furniture.json').write_text(json.dumps(dict(kit='ship_furniture',
    source='Original procedural models authored for this project; tools/make_room_furniture.py.',
    scale=[1,1,1], materials={}, pieces=pieces), indent=2) + '\n', encoding='utf-8')
print('Built five original furniture models in', OUT)
