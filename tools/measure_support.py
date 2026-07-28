"""Measure the SUPPORT anchor: the left hand's pose relative to the right hand.

Weapon models hang off a BoneAttachment3D on the right hand, so a weapon's local
space is rigidly tied to that bone. The support (left) hand therefore has to be
described in right-hand space -- that is the one number every weapon in the
roster has to build its handguard around (weapon-art-plan.md Sec 4).

Two things matter and only one of them is the mean:

  * the mean position, which is where the handguard centre goes, and
  * the envelope across every frame of every weapon-holding clip, which is how
    LONG the handguard has to be. Stock Mixamo clips breathe, recoil and bounce;
    the hand is not nailed to one point. A handguard sized to the mean alone
    would show the hand sliding off it during the run cycle.

Usage:

    blender -b -P tools/measure_support.py -- --glb assets/soldier_mixamo.glb

Add --all to include every action rather than just the weapon-holding ones, or
--csv <path> to dump per-frame samples for plotting.
"""

import math
import os
import re
import sys

import bpy
from mathutils import Quaternion, Vector

# The clips whose grip is taken as authoritative when deriving the lock target.
#
# The roster splits into three clusters by hand separation: aim/overwatch at
# ~466 mm, these three at ~400 mm, and idle/run/crouch_idle at ~317-343 mm. This
# middle cluster wins on three counts -- three independently authored clips agree
# on it to within 3 mm, ~400 mm is anatomically right for a rifle grip, and being
# the median it asks the smallest correction of the two outer clusters.
REFERENCE_CLIPS = ("shoot_recoil", "stand_to_crouch", "crouch_to_stand")

# Clips that hold the weapon in both hands. Anything else (Dying, Hit Reaction,
# Toss Grenade) either drops the support hand or lets go entirely, so including
# them would blow the envelope out with frames no weapon has to satisfy.
#
# Matched case-insensitively as substrings against the action name, so this
# works on both Mixamo's catalogue names ("Rifle Aiming Idle") and the game clip
# names build_anims.py renames them to ("aim_hold").
WEAPON_HOLDING = (
    "rifle", "aim", "fire", "shoot", "idle", "run", "crouch", "reload",
    "overwatch", "stand",
)

# Clips deliberately excluded even though they may match above -- the support
# hand leaves the weapon partway through, so their frames are not a constraint.
#
# `reload` is the notable one: the support hand comes off the handguard to fetch
# a magazine, so including it would blow the envelope out by ~400 mm with frames
# no weapon geometry could ever satisfy. Reload animations are per-weapon and
# deferred anyway (weapon-art-plan.md Sec 8).
NOT_HOLDING = (
    "dying", "death", "hit reaction", "hit_react", "grenade", "toss", "downed",
    "reload",
)

HAND_R = re.compile(r"^(mixamorig\d*:)?(right ?hand|hand\.r)$", re.I)
HAND_L = re.compile(r"^(mixamorig\d*:)?(left ?hand|hand\.l)$", re.I)


def log(msg):
    print(f"[measure_support] {msg}")


def find_armature():
    arms = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not arms:
        raise SystemExit("no armature in the file")
    if len(arms) > 1:
        log(f"warning: {len(arms)} armatures, using {arms[0].name!r}")
    return arms[0]


def find_hands(arm_obj):
    right = left = None
    for pb in arm_obj.pose.bones:
        if HAND_R.match(pb.name):
            right = pb
        elif HAND_L.match(pb.name):
            left = pb
    if right is None or left is None:
        names = sorted(b.name for b in arm_obj.pose.bones)
        raise SystemExit(
            f"could not find both hand bones (right={right}, left={left}).\n"
            f"bones present: {names}")
    return right, left


def is_holding(name):
    low = name.lower()
    if any(x in low for x in NOT_HOLDING):
        return False
    return any(x in low for x in WEAPON_HOLDING)


def sample_action(arm_obj, right, left, action):
    """Left hand in right-hand space, once per frame.

    Returns [(frame, offset_vector_metres, separation_metres)].

    Everything goes through matrix_world. pose_bone.matrix alone is in
    armature-OBJECT space, and a Mixamo import carries a 0.01 object scale, so
    raw bone matrices come out in centimetres. Worse, the object scale cancels
    exactly in `R.matrix.inverted() @ L.matrix` -- the result is silently 100x
    and looks like a plausible set of numbers rather than like an error.

    `separation` is the plain distance between the hands. It is invariant to the
    right hand's orientation, so it is the honest test of whether the clips
    treat the weapon as a rigid object: two hands on one rifle cannot change
    their distance apart, whatever the rest of the body is doing.
    """
    if arm_obj.animation_data is None:
        arm_obj.animation_data_create()
    arm_obj.animation_data.action = action

    start, end = (int(round(x)) for x in action.frame_range)
    scene = bpy.context.scene
    mw = arm_obj.matrix_world
    out = []
    for f in range(start, end + 1):
        scene.frame_set(f)
        wr = mw @ right.matrix
        wl = mw @ left.matrix
        delta = wl.translation - wr.translation
        # Normalized so the right hand's own scale does not leak into the offset.
        basis = wr.to_3x3().normalized()
        rot = (basis.inverted() @ wl.to_3x3().normalized()).to_quaternion()
        out.append((f, basis.inverted() @ delta, delta.length, rot))
    return out


def mean_quat(quats):
    """Average unit quaternions by sign-aligning to the first, then normalising.

    Valid because every sample here is a small perturbation of the same grip
    orientation -- the cheap linear average is indistinguishable from a proper
    Riemannian mean at this spread, and it has no convergence behaviour to
    debug. `angle_max` in the caller is the check that the assumption held.
    """
    ref = quats[0]
    acc = Quaternion((0.0, 0.0, 0.0, 0.0))
    for q in quats:
        q = q.copy()
        if q.dot(ref) < 0.0:  # q and -q are the same rotation; pick one lobe
            q.negate()
        acc += q
    acc.normalize()
    return acc


def summarize(label, samples):
    pts = [p for _, p, _, _ in samples]
    seps = [s for _, _, s, _ in samples]
    quats = [q for _, _, _, q in samples]
    n = len(pts)
    mean = sum(pts, Vector((0.0, 0.0, 0.0))) / n
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    # Worst-case distance of any single frame from the mean -- a single number
    # for "how far does the hand wander", independent of axis.
    radius = max((p - mean).length for p in pts)
    qm = mean_quat(quats)
    angle_max = max(math.degrees(qm.rotation_difference(q).angle) for q in quats)
    return {
        "label": label, "n": n, "mean": mean,
        "lo": lo, "hi": hi, "spread": hi - lo, "radius": radius,
        "sep_mean": sum(seps) / n, "sep_lo": min(seps), "sep_hi": max(seps),
        "quat": qm, "angle_max": angle_max, "samples": samples,
    }


def fmt(v):
    return f"({v.x * 1000:+7.1f}, {v.y * 1000:+7.1f}, {v.z * 1000:+7.1f})"


def report(rows, overall):
    print()
    print("  Left hand in RIGHT-HAND bone space, millimetres")
    print("  " + "-" * 86)
    print(f"  {'clip':<20} {'frames':>6}  {'mean (x, y, z)':>26}  {'wander':>7}"
          f"  {'separation':>18}  {'ang':>5}")
    print("  " + "-" * 86)
    for r in sorted(rows, key=lambda r: r["label"]):
        sep = (f"{r['sep_mean'] * 1000:.0f} "
               f"[{r['sep_lo'] * 1000:.0f}-{r['sep_hi'] * 1000:.0f}]")
        print(f"  {r['label']:<20} {r['n']:>6}  {fmt(r['mean']):>26}  "
              f"{r['radius'] * 1000:>6.1f}  {sep:>18}  {r['angle_max']:>4.0f}")
    print("  " + "-" * 86)
    sep = (f"{overall['sep_mean'] * 1000:.0f} "
           f"[{overall['sep_lo'] * 1000:.0f}-{overall['sep_hi'] * 1000:.0f}]")
    print(f"  {'ALL':<20} {overall['n']:>6}  {fmt(overall['mean']):>26}  "
          f"{overall['radius'] * 1000:>6.1f}  {sep:>18}")
    print()
    print("  'separation' is the plain hand-to-hand distance. Two hands gripping one")
    print("  rigid weapon cannot change it -- so its spread across clips is the test")
    print("  of whether a single fixed SUPPORT anchor is achievable at all.")
    print()

    print("  Envelope across every weapon-holding frame:")
    print(f"    min      {fmt(overall['lo'])}")
    print(f"    max      {fmt(overall['hi'])}")
    print(f"    spread   {fmt(overall['spread'])}")
    print()

    # Per-clip disagreement is the thing that decides whether one fixed anchor
    # is viable at all: if two clips' means are far apart, no single handguard
    # position satisfies both and the clip set needs revisiting.
    means = [r["mean"] for r in rows]
    worst = 0.0
    pair = ("", "")
    for i, a in enumerate(rows):
        for b in rows[i + 1:]:
            d = (a["mean"] - b["mean"]).length
            if d > worst:
                worst, pair = d, (a["label"], b["label"])
    print(f"  Largest disagreement between two clip means: {worst * 1000:.1f} mm")
    print(f"    ({pair[0]} vs {pair[1]})")
    print()

    span = max(overall["spread"].x, overall["spread"].y, overall["spread"].z)
    print("  Suggested handguard length: "
          f"{span * 1000:.0f} mm envelope + ~90 mm hand width "
          f"= {span * 1000 + 90:.0f} mm minimum")
    print()

    # Paste-ready constants for build_anims.py's support-hand lock. Derived from
    # REFERENCE_CLIPS rather than from all clips: averaging in the 466 mm and
    # 317 mm outliers would produce a target no clip actually uses.
    ref = [r for r in rows if r["label"] in REFERENCE_CLIPS]
    if len(ref) != len(REFERENCE_CLIPS):
        found = sorted(r["label"] for r in ref)
        print(f"  (reference clips {REFERENCE_CLIPS} -> only found {found}; "
              f"skipping target derivation)")
        return

    samples = [s for r in ref for s in r["samples"]]
    target = summarize("TARGET", samples)
    q = target["quat"]
    print("  " + "=" * 74)
    print(f"  LOCK TARGET, derived from {', '.join(REFERENCE_CLIPS)}")
    print("  " + "=" * 74)
    print(f"    separation      {target['sep_mean'] * 1000:.1f} mm "
          f"[{target['sep_lo'] * 1000:.1f}-{target['sep_hi'] * 1000:.1f}]")
    print(f"    agreement       {target['radius'] * 1000:.1f} mm positional, "
          f"{target['angle_max']:.1f} deg angular")
    print()
    print("    Paste into tools/build_anims.py:")
    print()
    print(f"    SUPPORT_OFFSET = Vector(({target['mean'].x:.6f}, "
          f"{target['mean'].y:.6f}, {target['mean'].z:.6f}))")
    print(f"    SUPPORT_ROTATION = Quaternion(({q.w:.6f}, {q.x:.6f}, "
          f"{q.y:.6f}, {q.z:.6f}))")
    print()


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--glb" not in argv:
        raise SystemExit(
            "usage: blender -b -P tools/measure_support.py -- --glb <path.glb>")
    glb = argv[argv.index("--glb") + 1]
    include_all = "--all" in argv

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)
    log(f"loaded {glb}")

    arm_obj = find_armature()
    right, left = find_hands(arm_obj)
    log(f"armature {arm_obj.name!r}, hands {right.name!r} / {left.name!r}")

    actions = list(bpy.data.actions)
    if not actions:
        raise SystemExit("no actions in the file -- nothing to sample")
    log(f"{len(actions)} actions present")

    rows, all_samples, skipped = [], [], []
    for act in actions:
        if not include_all and not is_holding(act.name):
            skipped.append(act.name)
            continue
        samples = sample_action(arm_obj, right, left, act)
        if not samples:
            continue
        rows.append(summarize(act.name, samples))
        all_samples += samples

    if skipped:
        log(f"skipped (support hand not on the weapon): {', '.join(sorted(skipped))}")
    if not rows:
        raise SystemExit("no weapon-holding actions matched")

    overall = summarize("ALL", all_samples)
    report(rows, overall)

    if "--csv" in argv:
        path = argv[argv.index("--csv") + 1]
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as fh:
            fh.write("clip,frame,x,y,z,separation\n")
            for act in actions:
                if not include_all and not is_holding(act.name):
                    continue
                for f, p, sep in sample_action(arm_obj, right, left, act):
                    fh.write(f"{act.name},{f},{p.x:.6f},{p.y:.6f},{p.z:.6f},"
                             f"{sep:.6f}\n")
        log(f"wrote {path}")


if __name__ == "__main__":
    main()
