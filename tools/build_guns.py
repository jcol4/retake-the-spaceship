"""Builds the five primary weapons as swappable guns, each a copy of the rifle.

  blender.exe -b -P tools/build_guns.py                    # any not yet built
  blender.exe -b -P tools/build_guns.py -- --force smg lmg # rebuild these

The .blends this writes are the guns' SOURCE from then on -- open and edit them
by hand like any model. An existing file is skipped, so a re-run never eats
those edits; --force throws them away and rebuilds from the code below.

Each gun starts as a copy of art_src/guns/rifle.blend -- its materials, its
`grip_support` (the left hand's IK target) and its `muzzle_flash` marker -- and
has the rifle's mesh replaced by one built here, then is saved as
art_src/guns/<gun>.blend for tools/export_models.py --gun <gun>.

THE GRIP CONTRACT (gun space: +Y down the barrel, +Z up, origin = trigger hand)
-----------------------------------------------------------------------------
The merc's animations were made holding the rifle, and its arms are baked to
it, so every gun here keeps the rifle's hand-contact geometry exactly:
  * the pistol grip and trigger group come from ONE function, `lower_group`;
  * the bore sits at BORE_Z, the rifle's;
  * a handguard (or pump) covers SUPPORT_Y with its underside near SUPPORT_Z,
    where the rifle's was, because `grip_support` -- copied unchanged -- is where
    the left hand closes;
  * `muzzle_flash` keeps its rotation and scale and only slides along Y to the
    new muzzle, so the flash and flashlight sit on every barrel's tip.
What changes between guns is everything the hands do not touch.

No optics, rails or other attachments: those are loadout add-ons and will be
mounted on top. The guns are plain prisms and tubes with a small bevel, sized
for a character that fills a few dozen pixels on screen.
"""

import math
import os
import sys

import bmesh
import bpy

SOURCE = "art_src/guns/rifle.blend"
OUT_DIR = "art_src/guns"
SOURCE_GUN = "rifle"

BORE_Z = 0.084
## Where the rifle's handguard was: the left hand closes around this span.
SUPPORT_Y = (0.27, 0.43)
SUPPORT_Z = 0.052


class Builder:
    """Accumulates parts into one bmesh. Profiles are (y, z) side outlines
    extruded across X, so a part is drawn the way it reads from the side."""

    def __init__(self, materials):
        self.bm = bmesh.new()
        self.mat = {m.name: i for i, m in enumerate(materials)}

    def _faces(self, faces, mat):
        index = self.mat[mat]
        for f in faces:
            f.material_index = index

    def prism(self, pts, hw, mat, x=0.0):
        """Side profile `pts` extruded from x-hw to x+hw."""
        bm = self.bm
        a = [bm.verts.new((x - hw, y, z)) for y, z in pts]
        b = [bm.verts.new((x + hw, y, z)) for y, z in pts]
        faces = [bm.faces.new(a[::-1]), bm.faces.new(b)]
        n = len(pts)
        for i in range(n):
            j = (i + 1) % n
            faces.append(bm.faces.new((a[i], a[j], b[j], b[i])))
        self._faces(faces, mat)

    def box(self, y0, y1, z0, z1, hw, mat, x=0.0, chamfer=0.0):
        c = chamfer
        if c:
            pts = [(y0 + c, z0), (y1 - c, z0), (y1, z0 + c), (y1, z1 - c),
                   (y1 - c, z1), (y0 + c, z1), (y0, z1 - c), (y0, z0 + c)]
        else:
            pts = [(y0, z0), (y1, z0), (y1, z1), (y0, z1)]
        self.prism(pts, hw, mat, x)

    def _tube(self, ring, n, mat):
        bm = self.bm
        r0 = [bm.verts.new(ring(0, i)) for i in range(n)]
        r1 = [bm.verts.new(ring(1, i)) for i in range(n)]
        faces = [bm.faces.new(r0[::-1]), bm.faces.new(r1)]
        for i in range(n):
            j = (i + 1) % n
            faces.append(bm.faces.new((r0[i], r0[j], r1[j], r1[i])))
        self._faces(faces, mat)

    def tube_y(self, y0, y1, r0, mat, z=BORE_Z, r1=None, x=0.0, segs=12):
        """A cylinder (or cone, with r1) along the barrel axis."""
        r1 = r0 if r1 is None else r1
        step = 2 * math.pi / segs

        def ring(end, i):
            r = (r0, r1)[end]
            return (x + r * math.cos(i * step), (y0, y1)[end], z + r * math.sin(i * step))
        self._tube(ring, segs, mat)

    def tube_x(self, y, z, x0, x1, r, mat, segs=16):
        """A cylinder across the gun -- a drum, a hinge pin."""
        step = 2 * math.pi / segs

        def ring(end, i):
            return ((x0, x1)[end], y + r * math.cos(i * step), z + r * math.sin(i * step))
        self._tube(ring, segs, mat)

    def to_mesh(self, mesh):
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        self.bm.to_mesh(mesh)
        self.bm.free()


# --- Shared: what the hands touch ---------------------------------------------


def lower_group(b, grip_mat="MainDark"):
    """Pistol grip, trigger guard and trigger: the right hand's whole world,
    identical on every gun. Measured off the rifle."""
    b.prism([(0.030, 0.004), (0.095, 0.004), (0.058, -0.088), (0.046, -0.094),
             (-0.004, -0.094), (-0.010, -0.086)], 0.016, grip_mat)
    b.box(0.050, 0.172, -0.038, -0.030, 0.007, "DarkMetal")          # guard bottom
    b.box(0.164, 0.174, -0.034, 0.004, 0.007, "DarkMetal")           # guard front
    b.prism([(0.118, 0.0), (0.128, 0.0), (0.124, -0.024), (0.114, -0.022)],
            0.003, "Metal")                                          # trigger


def vents(b, y0, y1, z0, z1, hw, count, mat="MainDark"):
    """Slots along a handguard's sides: a row of shallow dark boxes standing
    just proud of the surface, which reads as cut-outs at game distance."""
    pitch = (y1 - y0) / count
    for i in range(count):
        ya = y0 + i * pitch + pitch * 0.2
        b.box(ya, ya + pitch * 0.6, z0, z1, hw, mat)


# --- The five guns -------------------------------------------------------------
# Each returns the muzzle's Y. Barrel length order is deliberate: battle rifle
# longest, LMG second, then shotgun, assault rifle, SMG.


def assault_rifle(b):
    """A futuristic AK: angular receiver with a raised dust cover, deep curved
    magazine, slotted handguard under a gas tube, slant brake, skeleton stock."""
    b.prism([(-0.07, 0.0), (0.26, 0.0), (0.26, 0.098), (0.21, 0.112),
             (-0.02, 0.114), (-0.07, 0.100)], 0.021, "Main")
    b.prism([(-0.065, 0.095), (0.205, 0.095), (0.205, 0.118), (0.0, 0.128),
             (-0.065, 0.113)], 0.017, "MainDark")                     # dust cover
    b.box(0.0, 0.18, 0.040, 0.049, 0.0215, "MainLight")              # accent line
    b.box(0.085, 0.165, 0.068, 0.090, 0.0218, "DarkMetal")           # ejection port
    b.box(0.20, 0.25, 0.060, 0.070, 0.026, "Metal")                  # selector lever

    # Curved magazine: both edges sweep forward as it drops.
    front, back = [], []
    steps = 8
    for i in range(steps + 1):
        t = i / steps
        z = -0.215 * t
        sweep = 0.085 * t ** 1.5
        back.append((0.150 + sweep, z))
        front.append((0.222 + sweep * 0.92, z))
    b.prism(back + front[::-1], 0.012, "MainDark")
    b.box(0.150, 0.230, -0.020, 0.004, 0.015, "Main")                # mag well lip

    lower_group(b)

    b.box(0.255, 0.450, SUPPORT_Z, 0.110, 0.027, "Main", chamfer=0.012)
    vents(b, 0.285, 0.425, 0.072, 0.088, 0.0275, 4)
    b.box(0.270, 0.440, 0.108, 0.138, 0.017, "MainDark", chamfer=0.008)  # upper guard
    b.tube_y(0.440, 0.525, 0.009, "Metal", z=0.124)                  # gas tube
    b.box(0.505, 0.535, 0.074, 0.134, 0.012, "DarkMetal", chamfer=0.006)  # gas block
    b.tube_y(0.440, 0.660, 0.0085, "Metal")
    b.tube_y(0.645, 0.712, 0.0135, "DarkMetal", r1=0.0115)          # slant brake
    b.box(0.665, 0.700, 0.094, 0.099, 0.004, "MainDark")             # brake port

    b.prism([(-0.07, 0.100), (-0.07, 0.082), (-0.275, 0.074), (-0.275, 0.098)],
            0.016, "Main")                                           # top bar
    b.prism([(-0.07, 0.030), (-0.07, 0.006), (-0.265, -0.050), (-0.265, -0.026)],
            0.016, "Main")                                           # lower strut
    b.box(-0.300, -0.265, -0.060, 0.100, 0.019, "MainDark", chamfer=0.008)  # butt
    return 0.712


def battle_rifle(b):
    """Bulky and long: a tall, wide receiver, a short straight 7.62 box
    magazine, a thick handguard and the longest barrel, ending in a big brake."""
    b.prism([(-0.09, -0.010), (0.29, -0.010), (0.29, 0.128), (-0.06, 0.134),
             (-0.09, 0.118)], 0.025, "Main")
    b.box(-0.045, 0.245, 0.126, 0.146, 0.020, "MainDark", chamfer=0.006)   # top cover
    b.box(0.070, 0.180, 0.076, 0.100, 0.0255, "DarkMetal")                # ejection port
    b.box(0.200, 0.240, 0.088, 0.104, 0.010, "Metal", x=0.034)            # charging handle
    b.box(-0.060, 0.040, 0.030, 0.042, 0.0255, "MainLight")               # side panel

    # Short straight magazine, a slight forward cant.
    b.prism([(0.160, -0.008), (0.242, -0.008), (0.256, -0.112), (0.174, -0.112)],
            0.016, "MainDark")
    b.box(0.168, 0.262, -0.124, -0.110, 0.018, "Main")                    # baseplate

    lower_group(b)

    b.box(0.285, 0.535, 0.044, 0.132, 0.033, "Main", chamfer=0.014)
    vents(b, 0.310, 0.520, 0.076, 0.096, 0.0335, 5)
    b.tube_y(0.530, 0.800, 0.0115, "Metal")
    b.box(0.530, 0.555, 0.066, 0.104, 0.017, "DarkMetal", chamfer=0.005)  # barrel nut
    b.box(0.795, 0.870, 0.064, 0.104, 0.017, "DarkMetal", chamfer=0.006)  # muzzle brake
    for y in (0.808, 0.828, 0.848):
        b.box(y, y + 0.010, 0.070, 0.098, 0.0175, "MainDark")             # brake ports

    b.prism([(-0.09, 0.124), (-0.300, 0.112), (-0.300, -0.072), (-0.275, -0.078),
             (-0.190, -0.034), (-0.09, 0.0)], 0.022, "Main")
    b.box(-0.325, -0.298, -0.080, 0.118, 0.023, "MainDark", chamfer=0.008)  # butt pad
    b.box(-0.250, -0.120, 0.112, 0.132, 0.018, "MainDark", chamfer=0.006)   # cheek riser
    return 0.870


def lmg(b):
    """The biggest: a deep receiver under a hinged feed cover, a drum magazine,
    a heavy finned barrel (second longest) and a large stock."""
    b.prism([(-0.11, -0.022), (0.31, -0.022), (0.31, 0.130), (0.29, 0.145),
             (-0.08, 0.150), (-0.11, 0.132)], 0.032, "Main")
    b.box(-0.065, 0.205, 0.145, 0.172, 0.028, "MainDark", chamfer=0.008)  # feed cover
    b.tube_x(0.205, 0.158, -0.030, 0.030, 0.011, "Metal")                 # cover hinge
    b.box(0.060, 0.190, 0.070, 0.098, 0.0325, "DarkMetal")                # ejection port
    b.box(-0.080, 0.040, 0.020, 0.034, 0.0325, "MainLight")               # side panel

    # Drum: clear of the trigger guard, below the support hand.
    b.box(0.180, 0.270, -0.050, -0.020, 0.030, "Main")                    # mag well
    b.tube_x(0.225, -0.112, -0.048, 0.048, 0.082, "MainDark", segs=20)
    b.tube_x(0.225, -0.112, -0.053, 0.053, 0.050, "DarkMetal", segs=16)   # drum caps

    lower_group(b)

    b.box(0.305, 0.520, 0.042, 0.140, 0.036, "Main", chamfer=0.016)
    vents(b, 0.330, 0.505, 0.080, 0.104, 0.0365, 4)
    b.tube_y(0.515, 0.760, 0.0135, "Metal")
    for y in (0.540, 0.580, 0.620, 0.660, 0.700):
        b.tube_y(y, y + 0.018, 0.0175, "DarkMetal")                       # cooling fins
    b.tube_y(0.750, 0.810, 0.016, "DarkMetal", r1=0.014)                  # flash hider

    b.prism([(-0.11, 0.140), (-0.335, 0.120), (-0.335, -0.082), (-0.305, -0.088),
             (-0.180, -0.036), (-0.11, -0.010)], 0.028, "Main")
    b.box(-0.360, -0.332, -0.090, 0.124, 0.029, "MainDark", chamfer=0.010)  # butt pad
    return 0.810


def smg(b):
    """Compact: a slim receiver, a skinny stick magazine, a short handguard, a
    stub barrel and a collapsed wire stock."""
    b.prism([(-0.050, 0.004), (0.245, 0.004), (0.245, 0.104), (0.215, 0.114),
             (-0.030, 0.114), (-0.050, 0.100)], 0.017, "Main")
    b.box(0.070, 0.150, 0.070, 0.090, 0.0175, "DarkMetal")                # ejection port
    # Cocking handle on the side, not a tube on top: anything along the top
    # reads as an optic, and optics are loadout attachments.
    b.box(0.180, 0.240, 0.084, 0.096, 0.004, "MainDark", x=0.019)         # handle slot
    b.box(0.222, 0.236, 0.082, 0.098, 0.008, "Metal", x=0.026)            # cocking handle

    b.box(0.155, 0.205, -0.030, 0.006, 0.013, "Main")                     # mag well
    b.prism([(0.163, -0.028), (0.195, -0.028), (0.214, -0.205), (0.182, -0.205)],
            0.0085, "MainDark")                                           # stick mag
    b.box(0.178, 0.218, -0.214, -0.203, 0.010, "Main")                    # baseplate

    lower_group(b)

    b.box(0.245, 0.435, 0.046, 0.106, 0.021, "MainDark", chamfer=0.010)
    vents(b, 0.265, 0.420, 0.068, 0.082, 0.0215, 3, "Main")
    b.tube_y(0.430, 0.495, 0.008, "Metal")
    b.tube_y(0.490, 0.525, 0.0115, "DarkMetal")                           # muzzle nut

    for z in (0.090, 0.030):
        for x in (-0.012, 0.012):
            b.tube_y(-0.215, -0.045, 0.0045, "Metal", z=z, x=x, segs=8)   # stock rods
    b.box(-0.235, -0.212, -0.030, 0.108, 0.020, "MainDark", chamfer=0.008)  # butt plate
    return 0.525


def shotgun(b):
    """A pump gun: receiver, plain barrel with a sighting rib over a tube
    magazine, a ribbed sliding forend where the left hand goes, wood furniture."""
    b.prism([(-0.060, 0.0), (0.240, 0.0), (0.240, 0.112), (-0.030, 0.118),
             (-0.060, 0.100)], 0.021, "Main")
    b.box(0.060, 0.170, 0.066, 0.094, 0.0215, "DarkMetal")                # ejection port
    b.box(0.150, 0.235, 0.004, 0.018, 0.0215, "MainDark")                 # loading port

    lower_group(b, grip_mat="DarkWood")

    b.tube_y(0.240, 0.735, 0.0125, "Metal")
    b.box(0.240, 0.725, 0.095, 0.101, 0.0045, "DarkMetal")                # vent rib
    b.tube_y(0.240, 0.650, 0.0115, "DarkMetal", z=0.054)                  # tube magazine
    b.tube_y(0.650, 0.680, 0.0130, "Metal", z=0.054)                      # mag cap
    b.box(0.615, 0.640, 0.044, 0.098, 0.011, "DarkMetal")                 # barrel clamp

    b.box(0.270, 0.440, 0.028, 0.084, 0.026, "DarkWood", chamfer=0.012)   # pump
    for y in (0.290, 0.320, 0.350, 0.380, 0.410):
        b.box(y, y + 0.012, 0.036, 0.076, 0.0265, "MainDark")             # pump grooves

    b.prism([(-0.060, 0.104), (-0.290, 0.086), (-0.290, -0.072), (-0.270, -0.078),
             (-0.160, -0.032), (-0.060, -0.002)], 0.020, "DarkWood")
    b.box(-0.310, -0.288, -0.080, 0.090, 0.021, "MainDark", chamfer=0.008)  # recoil pad
    return 0.735


GUNS = {
    "assault_rifle": assault_rifle,
    "battle_rifle": battle_rifle,
    "lmg": lmg,
    "smg": smg,
    "shotgun": shotgun,
}


def build(name, make):
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(SOURCE))
    gun = bpy.data.objects[SOURCE_GUN]
    old = gun.data
    mesh = bpy.data.meshes.new(name)
    for m in old.materials:
        mesh.materials.append(m)
    b = Builder(mesh.materials)
    muzzle_y = make(b)
    b.to_mesh(mesh)
    gun.data = mesh
    bpy.data.meshes.remove(old)
    gun.name = name

    bevel = gun.modifiers.new("bevel", "BEVEL")
    bevel.width = 0.0018
    bevel.segments = 1
    bevel.limit_method = "ANGLE"

    muzzle = bpy.data.objects["muzzle_flash"]
    loc = muzzle.location.copy()
    loc.y = muzzle_y
    muzzle.location = loc

    path = os.path.abspath(os.path.join(OUT_DIR, name + ".blend"))
    bpy.ops.wm.save_as_mainfile(filepath=path)
    print("[guns] %s: %d faces, muzzle y %.3f -> %s" % (name, len(mesh.polygons), muzzle_y, path))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    force = "--force" in argv
    names = [a for a in argv if a != "--force"]
    for name in names or GUNS:
        path = os.path.join(OUT_DIR, name + ".blend")
        if os.path.exists(path) and not force:
            print("[guns] %s exists -- skipped (hand edits are kept; --force rebuilds)" % path)
            continue
        build(name, GUNS[name])


if __name__ == "__main__":
    main()
