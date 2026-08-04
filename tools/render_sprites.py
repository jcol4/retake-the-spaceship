"""Renders a rigged Blender character into the flat sprite sheet the game loads.

Two modes:

    # Build a .blend with the camera and lights already correct, to animate into.
    blender.exe -b -P tools/render_sprites.py -- --setup art_src/merc.blend

    # Render an animated .blend out to assets/sprites/.
    blender.exe -b art_src/merc.blend -P tools/render_sprites.py -- --variant merc

The output filenames are the load-bearing part: `build_sprite_frames.gd` collects
`[layer]_[variant]_[pose]_[dir]_[frame].png` into one `SpriteFrames` per layer,
so this script's only real contract with the game is that it writes those names
into `assets/sprites/`.

Everything is rendered into a SINGLE `body` layer. Gear swaps therefore mean
re-rendering a character rather than reassigning a layer, which is the trade the
flattened path takes in exchange for correct self-occlusion between the rifle,
the arms and the torso -- and it is what Fallout did too.
"""

import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

# --- The camera contract -----------------------------------------------------
#
# These four numbers are shared with the game and must not drift from it.
# `camera_rig.gd` fixes the in-game camera at this pitch and this yaw, and
# `unit_visual.gd` derives every sprite's scale and pivot from CANVAS_HEIGHT.

## atan(1/sqrt(2)) = 35.264 degrees. At this pitch a world-space square projects
## to a 2:1 diamond, which is the proportion the whole art set is drawn against.
## Mirrors `camera_rig.gd` PITCH.
PITCH = math.atan(1.0 / math.sqrt(2.0))

## Mirrors `camera_rig.gd` START_YAW. The camera no longer rotates in game, so
## this is the ONLY yaw anything is ever seen from -- which is exactly what lets
## the key light be fixed in world space below.
YAW = math.radians(45.0)

## World height of the full rendered image, in metres. NOT the character's
## height: a 1.92 m character in a 2.56 m canvas leaves headroom for a raised
## rifle or a grenade wind-up, which a canvas cut to the character would clip.
## Must equal `UnitVisual.canvas_height` on the character's scene, or every
## sprite comes out the wrong size.
CANVAS_HEIGHT = 2.56

## The character's real world height, used only to report the resulting in-game
## framing. Kept here because that framing is the thing every art judgement is
## made against, and it is not obvious from CANVAS_HEIGHT alone.
CHARACTER_HEIGHT = 1.92

## `Camera3D.size` on the in-game rig -- the vertical world extent on screen.
##
## THE FORESHORTENING IS THE POINT OF THIS CONSTANT. An upright figure seen at
## PITCH does not occupy CHARACTER_HEIGHT of screen; it occupies
## CHARACTER_HEIGHT * cos(PITCH) = 1.568 m, because the camera is looking down at
## it. `character-art-plan.md` puts a 1.92 m character at 16% of viewport height
## at size 12, but that arithmetic omits the cosine -- it was accurate for the
## PLACEHOLDER, which is drawn filling its canvas and so was never foreshortened
## by anything. Rendered art at size 12 reads 13.1%, not 16%.
##
## 10.5 is what puts it back in the 15% the reference framing asks for, and it is
## the right lever rather than enlarging the canvas: growing CANVAS_HEIGHT would
## draw characters ABOVE true world scale, and they have to stand in doorways and
## behind crates that are modelled at true scale.
GAME_CAMERA_SIZE = 10.5

## Metres of floor kept BELOW the world origin, and the reason the origin is no
## longer on the bottom edge of the frame.
##
## THE FLOOR IS NOT A HORIZONTAL LINE IN THIS FRAME. Under the tilted ortho
## camera a floor point (x, y, 0) sits at screen height -0.4082x + 0.4082y, so
## the bottom edge corresponds to the floor DIAGONAL y = x running toward the
## camera, and everything on its near side is off-frame. A character straddles
## the origin, so whichever foot is forward clips: measured at 8.4 px of 256 for
## a standing rest pose and 19.1 px at a 0.45 m run stride, on a character only
## ~157 px tall. Placing the origin exactly on the bottom edge -- which is what
## sliding the camera by CANVAS_HEIGHT / 2 did -- guarantees this.
##
## 0.45 m, revised up from 0.25 after measuring real poses rather than the rest
## stance the first estimate came from. The authored idle plants its lead foot
## far enough forward to reach within 1 px of the edge at 0.25, and the run
## stride went 5.2 px PAST it -- a stride displaces the lead foot along the same
## screen-down diagonal, so the two costs add rather than overlapping.
##
## Still cheap: the canvas had 0.90 m of dead space above the head, and this
## spends half of it, leaving ~50 px of headroom for a raised rifle.
##
## `UnitVisual.foot_anchor` MUST equal 1 - FLOOR_MARGIN / CANVAS_HEIGHT, or every
## character floats by this many metres. See `report_framing`.
FLOOR_MARGIN = 0.45

## Square, so that the horizontal half-extent is also 1.28 m -- comfortably wider
## than any arm span or rifle. Square also means a canvas rotation could never
## move the pivot, which is the property `UnitVisual.CANVAS` is square for.
##
## 256 makes 1 px = 1 cm exactly. Drop it to 96 or 128 for visibly chunky
## Fallout-scale pixels: the game derives `pixel_size` from the PNG's height, so
## resolution is a free choice here and needs no change on the Godot side.
RESOLUTION = 256

# --- Directions --------------------------------------------------------------
#
# Eight facings, and the order matters: it is the array `unit_visual.gd` indexes
# by direction bucket. Bucket 0 is up-right on screen and the index rises
# anticlockwise, so at 45-degree steps the set reads ne, n, nw, w, sw, s, se, e.
#
# The mapping to Blender is fixed by the axis convention Godot imports under
# (Blender +Y -> Godot -Z, Blender +Z -> Godot +Y). A character modelled facing
# Blender +Y is therefore facing Godot -Z, which is bucket 0. Each subsequent
# bucket is another +45 degrees about Blender +Z.
DIRECTIONS = ["ne", "n", "nw", "w", "sw", "s", "se", "e"]

## What actually gets rendered, and it is ALL of DIRECTIONS.
##
## The game reads eight buckets: `unit_visual.gd` DIRECTIONS and
## `build_sprite_frames.gd` DIRECTIONS are the same eight, `GridManager.STEPS`
## has eight entries, and `Unit._yaw_toward` snaps to 45 degrees. Every PNG this
## writes is therefore read by something.
##
## Kept as a separate name from DIRECTIONS rather than collapsed into it: they
## are different things that currently coincide. DIRECTIONS is the
## index-to-angle TABLE -- `ne` is bucket 0 and each entry is another 45 degrees
## about Blender +Z -- and the angle for a direction is found by its index there.
## This is the SUBSET being rendered, which `--directions` narrows for a quick
## look at one facing.
GAME_DIRECTIONS = list(DIRECTIONS)

## The character is rotated and the camera and lights are NOT. That is the whole
## reason the camera lost its rotation: with one fixed viewpoint, a world-fixed
## key light relights a unit as it turns, at 8 renders per pose rather than the
## 64 a rotatable camera would have needed.
REST_FACING_IS_BLENDER_PLUS_Y = True

# --- Poses -------------------------------------------------------------------
#
# Blender actions are matched to these by name. An action named `idle` becomes
# the `idle` pose; anything not on this list is ignored, and any pose with no
# action is simply not rendered -- `build_sprite_frames.gd` falls back to the
# nearest pose that does exist, so a half-animated character still runs.
POSES = [
    "idle", "run", "walk", "crouch_idle", "overwatch_hold", "aim_hold",
    "shoot_recoil", "run_stop", "stand_to_crouch", "crouch_to_stand", "melee",
    "reload", "throw_grenade", "interact", "hit_react", "downed",
    "alert_scream", "idle_fidget",
]

## Seconds one cycle of each looping stance occupies in game. Copied from
## `build_sprite_frames.gd` LOOP_TIME, and used here only to decide how many
## frames to sample: the game derives playback speed as frames/duration, so a
## pose drawn in 6 frames and the same pose drawn in 12 still take exactly this
## long. Frame count is a quality dial, not a timing one.
##
## `run` is the one that is forced rather than chosen -- `unit_visual.gd` emits a
## footstep every 0.333 s, so a two-step cycle must occupy 0.666 s.
LOOP_TIME = {
    "run": 2 * 0.333,
    "walk": 1.4,
    "idle": 2.0,
    "crouch_idle": 1.6, "overwatch_hold": 1.6, "aim_hold": 1.6,
}
DEFAULT_LOOP_TIME = 1.6

## Copied from `build_sprite_frames.gd` ONE_SHOT_TIME.
ONE_SHOT_TIME = {
    "melee": 1.20, "reload": 1.20, "throw_grenade": 1.00, "interact": 1.00,
    "hit_react": 0.47, "downed": 0.80, "alert_scream": 2.80,
}
DEFAULT_ONE_SHOT_TIME = 0.4

## Frames per second the poses are SAMPLED at. Deliberately low: Fallout's
## critters ran around this rate, and the chunky cadence is as much of the period
## read as the palette is. Costs nothing to raise -- see LOOP_TIME on why frame
## count never affects timing.
SAMPLE_FPS = 12.0

## Overridable with --fps, because the chunkiness of a cycle is an ART decision
## and this is the only dial that sets it. Lowering it costs nothing in timing:
## the game derives playback speed as frames/duration, so a run drawn in 4 frames
## and one drawn in 8 both still occupy LOOP_TIME.
##
## Prefer rates that divide a cycle into an EVEN number of frames. A two-step run
## puts its foot contacts on frame 0 and frame N/2, so an odd N lands the second
## contact between frames and the cadence limps: 0.666 s at 9 fps is 6 frames
## (contacts 0 and 3) and at 6 fps is 4 (contacts 0 and 2), but at 8 fps it is 5
## and there is no frame 2.5.

## `run` must sample to a whole number of frames or the second footplant lands
## off-cycle: 0.666 s at 12 fps is 8 frames, and frame 0 and frame 4 are the two
## contacts. `unit_visual.gd` FOOTSTEP_OFFSET is 0.0 precisely because a drawn
## cycle starts on a contact.
MIN_FRAMES = 2


def _clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.cameras, bpy.data.lights):
        for item in block:
            if item.users == 0:
                block.remove(item)


def build_camera(scene):
    """Creates (or re-aims) the one orthographic camera every frame is shot from.

    Placed so the WORLD ORIGIN lands FLOOR_MARGIN metres above the bottom edge
    of the frame, which is where `UnitVisual.foot_anchor` says it is. Get the two
    out of step and every character floats or sinks by the difference.
    """
    cam_data = bpy.data.cameras.get("SpriteCam") or bpy.data.cameras.new("SpriteCam")
    cam_data.type = "ORTHO"
    # ortho_scale is the extent across the LARGER image dimension. The render is
    # square, so this is the canvas height directly.
    cam_data.ortho_scale = CANVAS_HEIGHT

    cam = bpy.data.objects.get("SpriteCam")
    if cam is None:
        cam = bpy.data.objects.new("SpriteCam", cam_data)
        scene.collection.objects.link(cam)
    cam.data = cam_data

    # A Blender camera looks down its own local -Z. rotation_euler.x = 90deg
    # therefore looks horizontally; subtracting the pitch tips it down by exactly
    # that much. rotation_euler.z is the world yaw.
    cam.rotation_euler = (math.pi / 2.0 - PITCH, 0.0, YAW)

    # Local axes AFTER that rotation: -Z is the view direction, +Y is screen up.
    basis = cam.rotation_euler.to_matrix()
    view_dir = basis @ Vector((0.0, 0.0, -1.0))
    screen_up = basis @ Vector((0.0, 1.0, 0.0))

    # Back off along the view direction (distance is irrelevant under ortho, but
    # the character must be inside the clip range), then slide UP the screen by
    # half a canvas LESS the floor margin. Sliding the camera up moves the
    # content down, so this drops the world origin to FLOOR_MARGIN metres above
    # the bottom edge rather than onto it -- see FLOOR_MARGIN for why the
    # difference matters.
    distance = 10.0
    cam.location = ((-view_dir * distance)
                    + (screen_up * (CANVAS_HEIGHT / 2.0 - FLOOR_MARGIN)))
    cam_data.clip_start = 0.1
    cam_data.clip_end = distance * 3.0

    scene.camera = cam
    return cam


def build_lights(scene):
    """A key/fill/rim set, FIXED IN WORLD SPACE.

    This is the half of the pipeline that the camera losing its rotation paid
    for. Because there is now exactly one viewpoint, a light that is fixed in the
    ship's world genuinely relights a character as it turns -- a unit facing into
    the key is lit differently from one facing away, at no extra art cost.

    Kept fairly flat and heavily ambient-supported on purpose: the sprites are
    drawn UNSHADED in game and tinted by their tile's `light_value`, so whatever
    is baked here is competing with the room lighting rather than adding to it.
    Strong directional shading would fight the tint and read as wrong in a dark
    corridor.
    """
    specs = [
        # (name, type, energy, euler, size)
        ("SpriteKey", "AREA", 220.0, (math.radians(55), 0.0, math.radians(20)), 4.0),
        ("SpriteFill", "AREA", 60.0, (math.radians(70), 0.0, math.radians(200)), 6.0),
        ("SpriteRim", "AREA", 120.0, (math.radians(105), 0.0, math.radians(135)), 3.0),
    ]
    for name, kind, energy, euler, size in specs:
        data = bpy.data.lights.get(name) or bpy.data.lights.new(name, kind)
        data.type = kind
        data.energy = energy
        data.size = size
        obj = bpy.data.objects.get(name)
        if obj is None:
            obj = bpy.data.objects.new(name, data)
            scene.collection.objects.link(obj)
        obj.data = data
        obj.rotation_euler = euler
        # Positioned by aiming from a fixed radius, so the eulers above read as
        # directions rather than as coordinates.
        basis = obj.rotation_euler.to_matrix()
        obj.location = (basis @ Vector((0.0, 0.0, 1.0))) * 6.0

    scene.world = scene.world or bpy.data.worlds.new("SpriteWorld")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        # Ambient does most of the form-reading work here, for the reason in the
        # docstring: baked directional shading fights the in-game light tint.
        bg.inputs[0].default_value = (0.28, 0.30, 0.34, 1.0)
        bg.inputs[1].default_value = 0.9


def configure_render(scene):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 128
    scene.render.resolution_x = RESOLUTION
    scene.render.resolution_y = RESOLUTION
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    # No colour management surprises: the palette pass downstream expects the
    # values it was rendered with, not a filmic remap of them.
    scene.view_settings.view_transform = "Standard"


def find_character(explicit=None):
    """The object rotated through the 8 facings -- the armature, or its root.

    Rotating the ARMATURE rather than each mesh is what keeps a multi-object
    character (body + rifle + webbing) turning as one piece.
    """
    if explicit:
        obj = bpy.data.objects.get(explicit)
        if obj is None:
            sys.exit("--character %r not found in the .blend" % explicit)
        return obj
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE" and o.parent is None]
    if len(armatures) == 1:
        return armatures[0]
    if not armatures:
        sys.exit("No root armature found. Pass --character <object name>.")
    sys.exit("Several root armatures (%s). Pass --character <object name>."
             % ", ".join(o.name for o in armatures))


def frame_count(pose):
    """How many frames to sample for `pose`, from its in-game duration."""
    if pose in LOOP_TIME or pose not in ONE_SHOT_TIME:
        duration = LOOP_TIME.get(pose, DEFAULT_LOOP_TIME)
    else:
        duration = ONE_SHOT_TIME.get(pose, DEFAULT_ONE_SHOT_TIME)
    return max(MIN_FRAMES, round(duration * SAMPLE_FPS))


def sample_frames(action, count, looping):
    """The Blender frame numbers to render for one action.

    A LOOPING action must not render both its first and last frame: they are the
    same pose, and shipping both makes the cycle stutter for one frame every
    time round. So a loop samples across a half-open interval and a one-shot
    samples across a closed one.
    """
    start, end = action.frame_range
    if count == 1:
        return [start]
    span = end - start
    if looping:
        return [start + span * (i / count) for i in range(count)]
    return [start + span * (i / (count - 1)) for i in range(count)]


def mute_object_transform_curves(action):
    """Silences any OBJECT-level transform channels on `action`, and says so.

    The eight facings are produced by rotating the character object between
    renders. An action that also animates that object's own transform therefore
    fights the turntable -- and wins, because `frame_set` re-evaluates the action
    after the rotation has been set. The result is eight IDENTICAL renders with
    no error anywhere: correct file count, correct names, plausible images, one
    facing. That silence is why this guard exists rather than a comment telling
    you not to do it.

    Object-level keys land in a pose action easily: anything keyed while in
    Object Mode with the armature selected goes here rather than onto a bone.
    Nothing this pipeline needs is ever expressed that way -- the character is
    placed by the game, not by the clip -- so muting is always the right call.

    Returns the curves muted, so the caller can restore them; the .blend is never
    written, but the same action may be rendered again in one run.
    """
    muted = []
    for fcurve in action.fcurves:
        path = fcurve.data_path or ""
        if path.startswith("pose.bones"):
            continue
        if path in ("location", "rotation_euler", "rotation_quaternion", "scale"):
            if not fcurve.mute:
                fcurve.mute = True
                muted.append(fcurve)
    if muted:
        print("[render_sprites] %r animates the OBJECT transform (%s) -- muted "
              "for rendering, or every direction would come out identical"
              % (action.name, ", ".join(sorted({f.data_path for f in muted}))))
    return muted


def render_variant(variant, out_dir, character, only_poses=None, directions=None):
    scene = bpy.context.scene
    configure_render(scene)
    build_camera(scene)

    os.makedirs(out_dir, exist_ok=True)

    if character.animation_data is None:
        character.animation_data_create()

    actions = {a.name: a for a in bpy.data.actions}
    todo = [p for p in POSES if p in actions]
    if only_poses:
        todo = [p for p in todo if p in only_poses]
    missing = [p for p in POSES if p not in actions]
    if missing:
        print("[render_sprites] no action for: %s (will fall back in Godot)"
              % ", ".join(missing))
    if not todo:
        sys.exit("No actions matched a pose name. Rename your actions to: %s"
                 % ", ".join(POSES))

    original_rotation = character.rotation_euler.z
    written = 0

    for pose in todo:
        action = actions[pose]
        character.animation_data.action = action
        muted = mute_object_transform_curves(action)
        count = frame_count(pose)
        looping = pose in LOOP_TIME
        frames = sample_frames(action, count, looping)

        for direction in (directions or GAME_DIRECTIONS):
            # Angle comes from the position in DIRECTIONS, not from the position
            # in the list being rendered, so rendering a subset never reassigns
            # anyone's bucket.
            dir_index = DIRECTIONS.index(direction)
            # The character turns; the camera and the world-fixed key do not.
            character.rotation_euler.z = original_rotation + math.radians(45.0 * dir_index)

            for frame_index, blender_frame in enumerate(frames):
                # Belt and braces on top of the muting: frame_set re-evaluates
                # everything, so ANY mechanism that drives this object's
                # transform -- a driver, an NLA strip, a constraint -- would
                # silently collapse all eight facings into one. Cheap to check,
                # and the failure is invisible in the output otherwise.
                scene.frame_set(int(round(blender_frame)),
                                subframe=float(blender_frame % 1.0))
                expected = original_rotation + math.radians(45.0 * dir_index)
                if abs(character.rotation_euler.z - expected) > 1e-6:
                    sys.exit(
                        "[render_sprites] %r drives %s's rotation: after "
                        "frame_set it reads %.1f deg, not the %.1f deg this "
                        "direction needs. Every facing would render identical. "
                        "Remove the object-level animation from the action."
                        % (pose, character.name,
                           math.degrees(character.rotation_euler.z),
                           math.degrees(expected)))

                name = "body_%s_%s_%s_%d.png" % (variant, pose, direction, frame_index)
                scene.render.filepath = os.path.join(out_dir, name)
                bpy.ops.render.render(write_still=True)
                written += 1

        for fcurve in muted:
            fcurve.mute = False

        print("[render_sprites] %s: %d frames x %d directions"
              % (pose, len(frames), len(directions or GAME_DIRECTIONS)))

    character.rotation_euler.z = original_rotation
    print("[render_sprites] wrote %d images to %s" % (written, out_dir))
    print("[render_sprites] now run build_sprite_frames.gd with SF_VARIANT=%s "
          "SF_LAYERS=body" % variant)


def setup(path):
    """Writes a .blend containing the camera, the lights and nothing else.

    This is the file to model and animate into. It deliberately ships no
    character: the point is that the camera and the light rig are already exactly
    right, so the art can be judged against the real framing from the first
    render rather than after a round trip.
    """
    _clear_scene()
    scene = bpy.context.scene
    configure_render(scene)
    build_camera(scene)
    build_lights(scene)
    scene.render.fps = int(SAMPLE_FPS)

    # A floor plane purely as a modelling reference for where the feet go -- it
    # is excluded from renders, since a sprite must composite onto the game's
    # own floor and a baked ground would be wrong the moment a unit stands on
    # stairs.
    bpy.ops.mesh.primitive_plane_add(size=4.0, location=(0.0, 0.0, 0.0))
    floor = bpy.context.active_object
    floor.name = "GroundReference"
    floor.hide_render = True

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(path))
    print("[render_sprites] wrote %s" % path)
    report_framing()
    print("[render_sprites] ground plane sits on the BOTTOM EDGE of frame; "
          "model the character %.2f m tall standing at the world origin"
          % CHARACTER_HEIGHT)
    print("[render_sprites] name your actions: %s" % ", ".join(POSES))


def report_framing():
    """Prints the numbers every art judgement is made against.

    Worth printing rather than commenting because the interesting one -- how much
    of the screen a character actually occupies -- is a product of four constants
    and a cosine, and is easy to believe wrong.
    """
    apparent = CHARACTER_HEIGHT * math.cos(PITCH)
    px = apparent / CANVAS_HEIGHT * RESOLUTION
    print("[render_sprites] camera: ortho %.2f m, pitch %.3f deg, yaw %.0f deg, %d px"
          % (CANVAS_HEIGHT, math.degrees(PITCH), math.degrees(YAW), RESOLUTION))
    print("[render_sprites] scale: %.1f mm per pixel" % (CANVAS_HEIGHT / RESOLUTION * 1000))
    print("[render_sprites] a %.2f m character projects to %.3f m (x cos pitch) "
          "= %d px tall in a %d px canvas"
          % (CHARACTER_HEIGHT, apparent, round(px), RESOLUTION))
    print("[render_sprites] in game at Camera3D.size %.1f that is %.1f%% of "
          "viewport height" % (GAME_CAMERA_SIZE, apparent / GAME_CAMERA_SIZE * 100.0))
    headroom = CANVAS_HEIGHT - apparent - FLOOR_MARGIN
    print("[render_sprites] floor margin below the origin: %.2f m (%d px); "
          "headroom above the head: %.2f m (%d px)"
          % (FLOOR_MARGIN, round(FLOOR_MARGIN / CANVAS_HEIGHT * RESOLUTION),
             headroom, round(headroom / CANVAS_HEIGHT * RESOLUTION)))
    print("[render_sprites] SET UnitVisual.foot_anchor = (0.5, %.4f) and "
          "canvas_height = %.2f on the character scene"
          % (1.0 - FLOOR_MARGIN / CANVAS_HEIGHT, CANVAS_HEIGHT))


def main():
    # Declared up front because the --fps help text reads it below, and Python
    # rejects a `global` that follows any use of the name in the same scope.
    global SAMPLE_FPS

    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(prog="render_sprites")
    parser.add_argument("--setup", metavar="BLEND",
                        help="write a camera/light .blend to animate into, then exit")
    parser.add_argument("--variant", help="sprite variant name, e.g. merc")
    parser.add_argument("--out", default="assets/sprites")
    parser.add_argument("--character", help="object to rotate; defaults to the root armature")
    parser.add_argument("--poses", help="comma-separated subset to render")
    parser.add_argument("--fps", type=float,
                        help="sampling rate, default %g; lower is chunkier and "
                             "does not change in-game timing" % SAMPLE_FPS)
    parser.add_argument("--directions",
                        help="comma-separated subset; defaults to all eight the "
                             "game reads (%s)" % ",".join(GAME_DIRECTIONS))
    args = parser.parse_args(argv)

    if args.setup:
        setup(args.setup)
        return
    if not args.variant:
        sys.exit("--variant is required (or use --setup)")

    if args.fps:
        SAMPLE_FPS = args.fps
        print("[render_sprites] sampling at %g fps" % SAMPLE_FPS)

    only = set(args.poses.split(",")) if args.poses else None
    dirs = args.directions.split(",") if args.directions else None
    if dirs:
        bad = [d for d in dirs if d not in DIRECTIONS]
        if bad:
            sys.exit("unknown direction(s): %s (pick from %s)"
                     % (", ".join(bad), ", ".join(DIRECTIONS)))
    render_variant(args.variant, os.path.abspath(args.out),
                   find_character(args.character), only, dirs)


if __name__ == "__main__":
    main()
