"""Minimal reader for ASCII FBX 6100, which Blender's importer refuses outright.

Only the parts needed to get a static prop mesh in: per-Model local transform,
vertex positions, polygon indices, and UVs. No skinning, no animation, no
cameras -- an FBX 6100 file that needs those is better converted than parsed.

Arrays in this format wrap across lines with no continuation marker, so the
reader consumes following lines until one starts a new key or closes the block.
"""

import re

NUM = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
KEY = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_ ]*):")
PROP = re.compile(r'^\s*Property:\s*"([^"]+)"')
MODEL = re.compile(r'^\s*Model:\s*"Model::([^"]+)",\s*"([^"]+)"\s*\{')


def _floats(s):
    return [float(m.group()) for m in NUM.finditer(s)]


def _ints(s):
    return [int(m.group()) for m in re.finditer(r"-?\d+", s)]


def _gather(lines, i):
    """Return (payload, next_index) for an array starting on line i."""
    parts = [lines[i].split(":", 1)[1]]
    j = i + 1
    while j < len(lines):
        s = lines[j].strip()
        if not s or KEY.match(lines[j]) or s.startswith(("}", "{")):
            break
        parts.append(s)
        j += 1
    return " ".join(parts), j


def parse(path):
    """-> list of dicts: name, verts, polys, uvs, translation, rotation, scale."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    meshes = []
    i = 0
    while i < len(lines):
        m = MODEL.match(lines[i])
        # The file lists every Model twice: once with data under Objects, once
        # as a bare stub under Relations. Depth tracking would be overkill --
        # the stub simply has no Vertices, and is dropped at the end.
        if not m or m.group(2) != "Mesh":
            i += 1
            continue
        name = m.group(1)
        cur = {"name": name, "verts": [], "polys": [], "uvs": None,
               "uv_index": None, "translation": (0.0, 0.0, 0.0),
               "rotation": (0.0, 0.0, 0.0), "scale": (1.0, 1.0, 1.0)}
        depth = 1
        i += 1
        while i < len(lines) and depth > 0:
            line = lines[i]
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                i += 1
                break
            p = PROP.match(line)
            if p:
                key = p.group(1)
                if key == "Lcl Translation":
                    cur["translation"] = tuple(_floats(line.split('"A+"')[-1])[-3:])
                elif key == "Lcl Rotation":
                    cur["rotation"] = tuple(_floats(line.split('"A+"')[-1])[-3:])
                elif key == "Lcl Scaling":
                    cur["scale"] = tuple(_floats(line.split('"A+"')[-1])[-3:])
                i += 1
                continue
            k = KEY.match(line)
            if k:
                key = k.group(1).strip()
                if key == "Vertices":
                    payload, i = _gather(lines, i)
                    cur["verts"] = _floats(payload)
                    continue
                if key == "PolygonVertexIndex":
                    payload, i = _gather(lines, i)
                    cur["polys"] = _ints(payload)
                    continue
                if key == "UV":
                    payload, i = _gather(lines, i)
                    cur["uvs"] = _floats(payload)
                    continue
                if key == "UVIndex":
                    payload, i = _gather(lines, i)
                    cur["uv_index"] = _ints(payload)
                    continue
            i += 1
        if cur["verts"]:
            meshes.append(cur)
    return meshes


def faces_of(polys):
    """FBX marks the last index of each polygon by storing it as ~n (negative)."""
    faces, cur = [], []
    for idx in polys:
        if idx < 0:
            cur.append(-idx - 1)
            faces.append(tuple(cur))
            cur = []
        else:
            cur.append(idx)
    return faces


def to_blender(path, collection=None):
    """Build the parsed meshes as Blender objects. Returns the object list."""
    import bpy
    from mathutils import Euler

    made = []
    for d in parse(path):
        vs = d["verts"]
        coords = [(vs[k], vs[k + 1], vs[k + 2]) for k in range(0, len(vs), 3)]
        faces = faces_of(d["polys"])
        me = bpy.data.meshes.new(d["name"])
        me.from_pydata(coords, [], faces)
        me.validate()

        if d["uvs"] and d["uv_index"]:
            uvs = d["uvs"]
            layer = me.uv_layers.new(name="UVMap")
            for loop_i, uv_i in enumerate(d["uv_index"]):
                if loop_i >= len(layer.data) or uv_i * 2 + 1 >= len(uvs):
                    break
                layer.data[loop_i].uv = (uvs[uv_i * 2], uvs[uv_i * 2 + 1])

        obj = bpy.data.objects.new(d["name"], me)
        (collection or bpy.context.collection).objects.link(obj)
        obj.location = d["translation"]
        obj.rotation_euler = Euler([r * 3.14159265358979 / 180.0
                                    for r in d["rotation"]], "XYZ")
        obj.scale = d["scale"]
        made.append(obj)
    return made
