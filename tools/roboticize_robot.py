"""Makes the security robot's Mixamo clips read as a machine, not a person.

    blender -b assets/sec_robot_v3.blend -P tools/roboticize_robot.py [-- --only walk,idle] [--force]

The clips come from human motion capture (tools/retarget_mixamo_robot.py), so
they carry everything that says "person": breathing, a weight-shifting hip,
overlap down the spine, a head that nods along with the body. This pass strips
those and puts mechanical motion in their place. Each clip is processed once and
tagged (`roboticized` on the action); re-running skips tagged clips unless
--force, because the punch's time remap is not idempotent. Re-retarget a clip
first, then run this again.

  idle        Everything frozen at its first frame -- no breathing, no sway --
              and the life moved into the head: a sensor SCAN, the head panning
              in snaps between holds. Lengthened to IDLE_FRAMES so the scan is
              unhurried (unit_visual.gd's POSE_DURATION reads the new length).
  walk        Hip bob cut to WALK_BOB of itself and lowered rather than raised
              (so the IK legs can always still reach their feet), side sway and
              pelvic turn removed, spine/neck/clavicles held still, feet kept
              flat with no heel-toe roll, and a short hip DIP on each footfall
              for weight.
  hook_punch  MOVE-HOLD timing: the clip is re-timed into holds joined by fast,
              constant-speed moves (guard, snap back, coiled hold, strike, held
              extension, retract). Changes when the fist connects -- STRIKE_AT
              in unit_visual.gd is set from PUNCH_STRIKE_FRAME below.
  all three   The head is STABILISED: it holds one armature-space orientation
              while the body moves under it (a gimbal-mounted camera), and in the
              punch stays locked on the target through the wind-up.

get_hit and die are left alone.
"""
import math
import sys
import argparse
import bpy
from mathutils import Matrix, Quaternion, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--only", default="", help="comma-separated subset of: idle,walk,hook_punch")
ap.add_argument("--force", action="store_true", help="process clips already tagged roboticized")
ap.add_argument("--rig", default="Armature")
args = ap.parse_args(argv)

rig = bpy.data.objects[args.rig]
PB = rig.pose.bones
sc = bpy.context.scene
TAG = "roboticized"

# ---- tuning ------------------------------------------------------------------
IDLE_FRAMES = 48  # keys; 47 intervals = 3.9 s at 12 fps (last key == first)
# Head scan, degrees of yaw (+ = robot's left) at idle frames. Between two
# entries the head HOLDS the first value; the move to the next happens over the
# last SCAN_MOVE frames before it. So: hold ahead, snap left, hold, sweep right,
# hold, return.
SCAN_KEYS = [(1, 0.0), (14, 28.0), (28, -28.0), (40, 0.0)]
SCAN_MOVE = {14: 2, 28: 3, 40: 2}

WALK_BOB = 0.2          # fraction of the hip's vertical travel that survives
FOOTFALL_DIP = (0.03, 0.012)  # extra hip drop on the contact frame and the one after
CONTACT_EPS = 0.004     # an IK foot within this of its lowest height is planted

# Punch re-time: (output frame, source frame). Consecutive pairs with the same
# source frame are holds; different ones are linear moves. 27 frames in and out,
# so the clip's length and its POSE_DURATION are unchanged.
PUNCH_MAP = [
    (1, 1), (3, 1),       # guard
    (6, 10),              # snap back to full wind-up
    (10, 10),             # coiled hold
    (12, 15),             # strike: two frames to full extension
    (17, 15),             # hold extended
    (21, 27),             # retract
    (27, 27),             # guard
]
PUNCH_STRIKE_FRAME = 12  # where the fist stops dead -> STRIKE_AT = 11 / 26

STILL = ["spine_1", "chest", "neck", "clav.L", "clav.R"]


# ---- helpers -----------------------------------------------------------------
def sample(action, t):
    """Every bone's matrix_basis with `action` evaluated at (fractional) frame t."""
    rig.animation_data.action = action
    fi = int(math.floor(t))
    sc.frame_set(fi, subframe=t - fi)
    return {pb.name: pb.matrix_basis.copy() for pb in PB}


def apply_basis(B):
    for pb in PB:
        pb.matrix_basis = B[pb.name]
    bpy.context.view_layer.update()


def read_basis():
    return {pb.name: pb.matrix_basis.copy() for pb in PB}


def set_arm(name, rot, loc):
    """Pose bone `name` to an armature-space rotation/location, children follow."""
    m = rot.to_matrix().to_4x4()
    m.translation = loc
    PB[name].matrix = m
    bpy.context.view_layer.update()


def quat_mean(qs):
    ref = qs[0]
    acc = Quaternion((0, 0, 0, 0))
    for q in qs:
        q = q.copy()
        q.make_compatible(ref)
        acc.w += q.w; acc.x += q.x; acc.y += q.y; acc.z += q.z
    return acc.normalized()


def mean_basis(frames, name):
    locs = [f[name].to_translation() for f in frames]
    rot = quat_mean([f[name].to_quaternion() for f in frames])
    m = rot.to_matrix().to_4x4()
    m.translation = sum(locs, Vector()) / len(locs)
    return m


def yaw(deg):
    return Quaternion((0, 0, 1), math.radians(deg))


def write_action(name, frames):
    """Replaces action `name` with one keyed on every frame from `frames`."""
    old = bpy.data.actions.get(name)
    new = bpy.data.actions.new(name + "__robot")
    new.use_fake_user = True
    rig.animation_data.action = new
    prevq = {}
    for k, B in enumerate(frames):
        for pb in PB:
            loc, q, _ = B[pb.name].decompose()
            if pb.name in prevq:
                q.make_compatible(prevq[pb.name])
            prevq[pb.name] = q
            pb.rotation_mode = 'QUATERNION'
            pb.location, pb.rotation_quaternion, pb.scale = loc, q, Vector((1, 1, 1))
            for path in ("location", "rotation_quaternion", "scale"):
                pb.keyframe_insert(path, frame=1 + k, group=pb.name)
    if old is not None:
        old.user_remap(new)
        bpy.data.actions.remove(old)
    new.name = name
    new.use_frame_range = True
    new.frame_start, new.frame_end = 1, len(frames)
    new[TAG] = True
    print(f"[roboticize] {name}: {len(frames)} frames")


def frames_of(action):
    f0, f1 = (int(round(x)) for x in action.frame_range)
    return [sample(action, f) for f in range(f0, f1 + 1)]


def arm_matrix(name):
    return PB[name].matrix.copy()


# ---- idle --------------------------------------------------------------------
def scan_angle(f):
    for (fa, a), (fb, b) in zip(SCAN_KEYS, SCAN_KEYS[1:]):
        if fa <= f <= fb:
            move = SCAN_MOVE.get(fb, 2)
            start = fb - move
            if f <= start:
                return a
            return a + (b - a) * (f - start) / move
    return SCAN_KEYS[-1][1] if f >= SCAN_KEYS[-1][0] else SCAN_KEYS[0][1]


def do_idle(act):
    base = sample(act, act.frame_range[0])
    apply_basis(base)
    head = arm_matrix("head")
    head_rot, head_loc = head.to_quaternion(), head.translation.copy()
    out = []
    for f in range(1, IDLE_FRAMES + 1):
        apply_basis(base)
        set_arm("head", yaw(scan_angle(f)) @ head_rot, head_loc)
        out.append(read_basis())
    write_action(act.name, out)


# ---- walk --------------------------------------------------------------------
def do_walk(act):
    src = frames_of(act)
    n = len(src)
    # armature-space reads of the raw clip
    hip, feet, heads = [], {"L": [], "R": []}, []
    for B in src:
        apply_basis(B)
        hip.append(arm_matrix("hip"))
        heads.append(arm_matrix("head").to_quaternion())
        for sd in feet:
            feet[sd].append(arm_matrix("IK-foot." + sd))
    zs = [m.translation.z for m in hip]
    zmin = min(zs)
    xmean = sum(m.translation.x for m in hip) / n
    hip_rot = quat_mean([m.to_quaternion() for m in hip])
    head_rot = quat_mean(heads)
    still = {b: mean_basis(src, b) for b in STILL}

    # feet: the rotation and height of a planted foot
    plant = {}
    for sd, ms in feet.items():
        low = min(range(n), key=lambda i: ms[i].translation.z)
        plant[sd] = (ms[low].to_quaternion(), ms[low].translation.z)

    # footfall frames: planted now, airborne the frame before (cyclic; last == first)
    dip = [0.0] * n
    for sd, ms in feet.items():
        z0 = plant[sd][1]
        for i in range(n - 1):
            prev = (i - 1) % (n - 1)
            if ms[i].translation.z - z0 < CONTACT_EPS and ms[prev].translation.z - z0 >= CONTACT_EPS:
                for j, d in enumerate(FOOTFALL_DIP):
                    dip[(i + j) % (n - 1)] += d
                print(f"[roboticize] walk: {sd} footfall at frame {i + 1}")
    dip[n - 1] = dip[0]

    out = []
    for i, B in enumerate(src):
        B = {k: v.copy() for k, v in B.items()}
        B.update({b: m.copy() for b, m in still.items()})
        apply_basis(B)
        z = zmin + WALK_BOB * (zs[i] - zmin) - dip[i]
        set_arm("hip", hip_rot, Vector((xmean, hip[i].translation.y, z)))
        for sd in feet:
            q0, z0 = plant[sd]
            loc = feet[sd][i].translation.copy()
            loc.z = max(loc.z, z0)
            set_arm("IK-foot." + sd, q0, loc)
        set_arm("head", head_rot, arm_matrix("head").translation)
        out.append(read_basis())
    write_action(act.name, out)


# ---- punch -------------------------------------------------------------------
def punch_source_time(f):
    for (oa, sa), (ob, sb) in zip(PUNCH_MAP, PUNCH_MAP[1:]):
        if oa <= f <= ob:
            return sa + (sb - sa) * (f - oa) / (ob - oa)
    return PUNCH_MAP[-1][1]


def do_punch(act):
    first = sample(act, act.frame_range[0])
    apply_basis(first)
    head_rot = arm_matrix("head").to_quaternion()
    out = []
    for f in range(1, PUNCH_MAP[-1][0] + 1):
        apply_basis(sample(act, punch_source_time(f)))
        set_arm("head", head_rot, arm_matrix("head").translation)
        out.append(read_basis())
    write_action(act.name, out)


# ---- main ----------------------------------------------------------------------
JOBS = {"idle": do_idle, "walk": do_walk, "hook_punch": do_punch}
only = [s for s in args.only.split(",") if s] or list(JOBS)
active = rig.animation_data.action.name if rig.animation_data.action else None
for name in only:
    act = bpy.data.actions.get(name)
    if act is None:
        print(f"[roboticize] no action {name!r}, skipped")
        continue
    if act.get(TAG) and not args.force:
        print(f"[roboticize] {name} already roboticized, skipped (--force to redo)")
        continue
    JOBS[name](act)
if active and active in bpy.data.actions:
    rig.animation_data.action = bpy.data.actions[active]
sc.frame_set(1)
bpy.ops.wm.save_mainfile()
