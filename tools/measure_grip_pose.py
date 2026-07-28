"""Measure what aperture each hand is actually gripping, and where.

Two questions, one measurement.

1. DO THE FINGERS NEED RE-POSING AT ALL? The Mixamo source clips are rifle
   animations, so their hands are already curled around an imagined weapon. If
   that imagined grip is close to ours there is nothing to fix, and rewriting
   good mocap fingers procedurally would only make them worse. This reports the
   radius the existing pose actually encloses.

2. WHERE IS THE GRIP AXIS? The rifle's pistol grip has to sit on the line the
   fist closes around. That line, expressed in right-hand bone space, is what
   grip_offset / grip_rotation in character_base.tscn have to deliver -- they are
   currently zero, which puts the trigger at the wrist BONE ORIGIN rather than
   in the fist.

Everything is reported in HAND-BONE space, so it should be near-constant across
clips: tools/build_anims.py pins both hands rigidly to the weapon, and fingers
that drift between clips would mean the lock is not doing its job.

Run headless:
    blender -b -P tools/measure_grip_pose.py -- --glb assets/soldier_mixamo.glb
"""

import argparse
import math
import sys

import bpy
from mathutils import Matrix, Vector

FINGERS = ("Thumb", "Index", "Middle", "Ring", "Pinky")

# Clips where both hands are on the weapon -- the same set build_anims.py locks.
LOCKED = ("idle-loop", "run-loop", "aim_hold-loop", "overwatch_hold-loop",
          "crouch_idle-loop", "run_stop", "stand_to_crouch", "crouch_to_stand",
          "shoot_recoil")


def log(msg):
    print(f"[grip_pose] {msg}")


def bind(arm, act):
    ad = arm.animation_data or arm.animation_data_create()
    ad.action = act
    if hasattr(ad, "action_slot") and ad.action_slot is None:
        slots = getattr(act, "slots", None)
        if slots:
            ad.action_slot = slots[0]


def fit_circle(pts2d):
    """Least-squares circle through 2D points -> (cx, cy, r).

    Linear form: a point (x,y) on a circle satisfies
        x^2 + y^2 = 2*cx*x + 2*cy*y + (r^2 - cx^2 - cy^2)
    which is linear in (cx, cy, k), so it solves in closed form with no
    iteration and no starting guess.
    """
    n = len(pts2d)
    if n < 3:
        return 0.0, 0.0, 0.0
    sx = sum(p[0] for p in pts2d)
    sy = sum(p[1] for p in pts2d)
    sxx = sum(p[0] * p[0] for p in pts2d)
    syy = sum(p[1] * p[1] for p in pts2d)
    sxy = sum(p[0] * p[1] for p in pts2d)
    sxz = sum(p[0] * (p[0] ** 2 + p[1] ** 2) for p in pts2d)
    syz = sum(p[1] * (p[0] ** 2 + p[1] ** 2) for p in pts2d)
    sz = sum(p[0] ** 2 + p[1] ** 2 for p in pts2d)
    m = Matrix(((2 * sxx, 2 * sxy, sx), (2 * sxy, 2 * syy, sy), (2 * sx, 2 * sy, n)))
    try:
        sol = m.inverted() @ Vector((sxz, syz, sz))
    except ValueError:
        return 0.0, 0.0, 0.0
    cx, cy, k = sol
    r2 = k + cx * cx + cy * cy
    return cx, cy, math.sqrt(max(r2, 0.0))


def hand_frame(arm, side, scale):
    """Grip axis, centre and enclosed radius for one hand, in HAND-BONE space.

    Uses each bone's HEAD only. pose_bone.tail is unusable on a glTF-imported
    rig: the importer leaves bones disconnected with synthesized lengths, so
    RightHand reports a length of 457 units against an 11-unit wrist-to-knuckle,
    and Index1.tail lands nowhere near Index2.head where it belongs.

    Each finger is fitted SEPARATELY. A single fit across the four fingertips is
    degenerate: the fingers are separated mainly ALONG the knuckle line, so
    projecting that direction out collapses them onto one point and the circle
    through it is unbounded (this measured a 2.4 metre grip before the fix).
    One finger's own joints, projected the same way, curl properly around the
    held object and pin the circle.
    """
    pb = arm.pose.bones
    root = pb[f"{side}Hand"]
    inv = root.matrix.inverted()

    need = [f"{side}Hand{f}{i}" for f in FINGERS for i in (1, 2, 3, 4)]
    missing = [n for n in need if n not in pb]
    if missing:
        raise SystemExit(f"rig is missing finger bones: {missing[:6]}")

    idx_mcp = inv @ pb[f"{side}HandIndex1"].head
    pky_mcp = inv @ pb[f"{side}HandPinky1"].head
    axis = pky_mcp - idx_mcp
    if axis.length < 1e-9:
        raise SystemExit(f"{side}: index and pinky knuckles coincide")
    axis = axis.normalized()
    u = axis.orthogonal().normalized()
    v = axis.cross(u).normalized()

    # The thumb opposes the others rather than curling with them, so it is
    # measured but excluded from the consensus centre.
    per = {}
    for f in FINGERS:
        joints = [inv @ pb[f"{side}Hand{f}{i}"].head for i in (1, 2, 3, 4)]
        origin = sum(joints, Vector((0, 0, 0))) / len(joints)
        flat = [((j - origin).dot(u), (j - origin).dot(v)) for j in joints]
        cx, cy, r = fit_circle(flat)
        resid = [abs(math.hypot(p[0] - cx, p[1] - cy) - r) for p in flat]
        per[f] = {
            "radius": r * scale,
            "centre": (origin + u * cx + v * cy) * scale,
            "resid": (sum(resid) / len(resid)) * scale,
        }

    curled = [per[f] for f in ("Index", "Middle", "Ring", "Pinky")]
    centre = sum((c["centre"] for c in curled), Vector((0, 0, 0))) / len(curled)
    return {
        "axis": axis,
        "centre": centre,
        "radius": sum(c["radius"] for c in curled) / len(curled),
        "resid": sum(c["resid"] for c in curled) / len(curled),
        "per": per,
        "span": (pky_mcp - idx_mcp).length * scale,
    }


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--glb", default="assets/soldier_mixamo.glb")
    p.add_argument("--clips", default="")
    args = p.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    scale = arm.matrix_world.to_scale().x
    log(f"armature {arm.name!r}, object scale {scale}")

    want = args.clips.split(",") if args.clips else LOCKED
    acts = [a for a in bpy.data.actions if a.name in want]
    if not acts:
        raise SystemExit(f"none of {want} in {[a.name for a in bpy.data.actions]}")

    for side in ("Right", "Left"):
        print(f"\n=== {side} hand, in {side}Hand bone space (mm) ===")
        print("  clip                  radius  resid   centre (x, y, z)"
              "         axis")
        rows = []
        for act in sorted(acts, key=lambda a: a.name):
            bind(arm, act)
            lo, hi = (int(round(x)) for x in act.frame_range)
            bpy.context.scene.frame_set((lo + hi) // 2)
            bpy.context.view_layer.update()
            d = hand_frame(arm, side, scale)
            rows.append(d)
            c, ax = d["centre"], d["axis"]
            print(f"  {act.name:20s} {d['radius']*1000:6.1f} "
                  f"{d['resid']*1000:6.1f}   "
                  f"({c.x*1000:+6.1f},{c.y*1000:+6.1f},{c.z*1000:+6.1f})  "
                  f"({ax.x:+.2f},{ax.y:+.2f},{ax.z:+.2f})")
        rad = [r["radius"] for r in rows]
        cen = [r["centre"] for r in rows]
        mean_c = sum(cen, Vector((0, 0, 0))) / len(cen)
        drift = max((c - mean_c).length for c in cen)
        print(f"  knuckle span {rows[0]['span']*1000:.1f} mm")
        print(f"  -> radius {min(rad)*1000:.1f}..{max(rad)*1000:.1f} mm "
              f"(mean {sum(rad)/len(rad)*1000:.1f}), "
              f"centre drift across clips {drift*1000:.1f} mm")
        print("     per finger (mid clip): " + ", ".join(
            f"{f} {rows[0]['per'][f]['radius']*1000:.0f}" for f in FINGERS))

    print("\nWeapon surfaces to compare against (tools/import_rifle.py):")
    print("  pistol grip : 27.1 mm median radius, 123 mm long, 10.4 deg rake")
    print("  handguard   : 16.5 mm half-width, 66 mm tall -> ~18 mm equivalent radius")


if __name__ == "__main__":
    main()
