"""Bakes the muzzle flash in assets/gun_vfx.blend to the .glb the game draws.

    blender.exe -b assets/gun_vfx.blend -P tools/bake_muzzle_flash.py

The flash's look lives entirely in its two node materials (`Muzzle Face`, the
star at the muzzle, and `Muzzle Side`, the lance of crossed planes): noise and
gradients through colour ramps into an Emission / Transparent mix. glTF carries
none of that -- a procedural node tree exports as a flat material -- so each
material is BAKED, with Cycles, to one RGBA texture:

  * RGB -- what the Emission shader's Color input sees (the colour ramp feeding
    it), at strength 1.
  * A   -- the Mix Shader's factor: how much of the emission is there at all.

Every input is a function of UV only, so the bake is exact rather than an
approximation. The mesh is exported as it is authored, with each material
swapped for a plain image material, to assets/vfx/muzzle_flash.glb. The game
(scripts/muzzle_flash.gd) draws those textures as light.

The per-material Emission strength is written to the sidecar
assets/vfx/muzzle_flash.json, so the game keeps Blender's balance between the
star and the lance. The .blend is never written; everything here is in memory.
"""

import json
import os

import bpy
import numpy as np

OUT_DIR = os.path.join("assets", "vfx")
OUT_NAME = "muzzle_flash"
FLASH_OBJECT = "muzzle_flash"
BAKE_SIZE = 256


def _find(nodes, kind):
    return next((n for n in nodes if n.type == kind), None)


def _source(socket):
    """The output socket feeding `socket` -- what the bake has to capture."""
    if not socket.is_linked:
        raise RuntimeError("%s is not driven by anything" % socket.name)
    return socket.links[0].from_socket


def _bake_socket(mat, socket, image):
    """Bakes whatever `socket` outputs across UV space into `image`, by
    temporarily routing it through a strength-1 Emission straight to the
    output and baking EMIT. Returns the pixels as an HxWx4 float array."""
    tree = mat.node_tree
    out = _find(tree.nodes, 'OUTPUT_MATERIAL')
    old = _source(out.inputs['Surface'])
    probe = tree.nodes.new('ShaderNodeEmission')
    probe.inputs['Strength'].default_value = 1.0
    tree.links.new(socket, probe.inputs['Color'])
    tree.links.new(probe.outputs['Emission'], out.inputs['Surface'])
    target = tree.nodes.new('ShaderNodeTexImage')
    target.image = image
    tree.nodes.active = target
    bpy.ops.object.bake(type='EMIT', margin=4)
    tree.links.new(old, out.inputs['Surface'])
    tree.nodes.remove(probe)
    tree.nodes.remove(target)
    return np.array(image.pixels[:], dtype=np.float32).reshape(
        BAKE_SIZE, BAKE_SIZE, 4)


def _to_srgb(linear):
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(linear <= 0.0031308, linear * 12.92,
                    1.055 * np.power(linear, 1.0 / 2.4) - 0.055)


def bake_material(obj, mat):
    """Returns (RGBA image in sRGB, emission strength) for one material."""
    tree = mat.node_tree
    mix = _find(tree.nodes, 'MIX_SHADER')
    emission = _find(tree.nodes, 'EMISSION')
    if mix is None or emission is None:
        raise RuntimeError("%s is not an Emission/Transparent mix" % mat.name)
    scratch = bpy.data.images.new("bake_scratch", BAKE_SIZE, BAKE_SIZE,
                                  float_buffer=True)
    scratch.colorspace_settings.name = 'Linear Rec.709'
    colour = _bake_socket(mat, _source(emission.inputs['Color']), scratch)
    mask = _bake_socket(mat, _source(mix.inputs[0]), scratch)
    bpy.data.images.remove(scratch)

    rgba = np.empty_like(colour)
    rgba[..., :3] = _to_srgb(colour[..., :3])
    # The factor came through a colour ramp as grey; any channel is it.
    rgba[..., 3] = np.clip(mask[..., 0], 0.0, 1.0)
    # Named for the file Godot extracts it to: muzzle_flash_<this>.png.
    image = bpy.data.images.new(mat.name.lower().replace("muzzle ", ""),
                                BAKE_SIZE, BAKE_SIZE, alpha=True)
    # Already encoded above; tagged so nothing converts it again.
    image.colorspace_settings.name = 'Non-Color'
    image.pixels[:] = rgba.ravel()
    image.pack()
    return image, float(emission.inputs['Strength'].default_value)


def _image_material(name, image):
    """A plain material the glTF exporter understands: the baked texture as
    base colour and alpha. How it is DRAWN is decided in game."""
    mat = bpy.data.materials.new(name)
    tree = mat.node_tree
    bsdf = _find(tree.nodes, 'BSDF_PRINCIPLED')
    tex = tree.nodes.new('ShaderNodeTexImage')
    tex.image = image
    tree.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    tree.links.new(tex.outputs['Alpha'], bsdf.inputs['Alpha'])
    mat.surface_render_method = 'BLENDED'
    return mat


def main():
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 16
    obj = bpy.data.objects[FLASH_OBJECT]
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    baked = {}
    strengths = {}
    for mat in [m for m in obj.data.materials if m]:
        # The bake writes into the active image node of EVERY material on the
        # object; the others get a throwaway so only `mat`'s result is read.
        decoys = []
        for other in obj.data.materials:
            if other and other != mat:
                node = other.node_tree.nodes.new('ShaderNodeTexImage')
                node.image = bpy.data.images.new("decoy", 8, 8)
                other.node_tree.nodes.active = node
                decoys.append((other, node))
        baked[mat.name], strengths[mat.name] = bake_material(obj, mat)
        for other, node in decoys:
            img = node.image
            other.node_tree.nodes.remove(node)
            bpy.data.images.remove(img)
        print("[bake_muzzle_flash] baked %s (strength %.1f)" % (mat.name, strengths[mat.name]))

    # Same slot order and names as authored, so the game can tell star from lance.
    for i, mat in enumerate(obj.data.materials):
        if mat:
            name = mat.name
            mat.name = name + " (procedural)"
            obj.data.materials[i] = _image_material(name, baked[name])

    os.makedirs(OUT_DIR, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=os.path.join(OUT_DIR, OUT_NAME + ".glb"),
        export_format='GLB',
        use_selection=True,
        export_animations=False,
        export_image_format='AUTO',
        export_apply=True,
    )
    with open(os.path.join(OUT_DIR, OUT_NAME + ".json"), "w") as f:
        json.dump({"emission_strength": strengths}, f, indent=2)
        f.write("\n")
    print("[bake_muzzle_flash] wrote %s/%s.glb" % (OUT_DIR, OUT_NAME))


main()
