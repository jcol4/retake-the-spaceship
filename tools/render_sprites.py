"""Renders a rigged Blender character into the flat sprite sheet the game loads.

Four modes:

    # Build a .blend with the camera and lights already correct, to animate into.
    blender.exe -b -P tools/render_sprites.py -- --setup art_src/merc.blend

    # Render an animated .blend out to assets/sprites/.
    blender.exe -b art_src/merc.blend -P tools/render_sprites.py -- --variant merc

    # Export where the gun's lamp sits on each frame, rendering NOTHING.
    blender.exe -b art_src/merc_anim.blend -P tools/render_sprites.py -- \
        --variant merc --markers --poses idle

    # Render the muzzle flash on its own, oversized, overlay layer.
    blender.exe -b art_src/merc_anim.blend -P tools/render_sprites.py -- \
        --variant merc --flash

The MARKER export is seconds rather than minutes and never touches a PNG, because
the marker's position is a projection of a known point through a known camera
rather than something to be searched for in an image. Re-run it whenever the rig
moves; re-render only when the ART moves. See MARKER_MATERIAL.

The output filenames are the load-bearing part: `build_sprite_frames.gd` collects
`[layer]_[variant]_[pose]_[dir]_[frame].png` into one `SpriteFrames` per layer,
so this script's only real contract with the game is that it writes those names
into `assets/sprites/`.

Everything is rendered into a SINGLE `body` layer. Gear swaps therefore mean
re-rendering a character rather than reassigning a layer, which is the trade the
flattened path takes in exchange for correct self-occlusion between the rifle,
the arms and the torso -- and it is what Fallout did too.

The one exception is the muzzle flash, which is its own `flash` layer for a
reason that is about FRAMING rather than gear: it does not fit in the body's
canvas. See FLASH_LAYER.
"""

import argparse
import json
import math
import os
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

## Pixels of slack added below the lowest geometry when reporting the NO-CLIP
## anchor (the one nothing ever falls below).
##
## That anchor is measured from GEOMETRY, but the thing that must not fall below
## the floor is the lowest opaque PIXEL, and antialiasing puts those roughly a
## pixel outside the silhouette. Two covers it, and erring low is free there: an
## anchor a hair below the feet lifts the sprite by a hair.
##
## It is NOT applied to the grounded anchor `report_anchor` actually recommends,
## which is a mean and is meant to cut into the silhouette a little.
ANCHOR_SAFETY_PX = 2

## The pose whose feet define where the ground is, when the variant has one.
##
## Idle is what is on screen almost all of the time, so it is idle that must look
## planted; a mid-stride walk frame reaching lower is a frame nobody reads as
## floating. See `report_anchor`.
GROUNDING_POSE = "idle"

# --- The camera contract -----------------------------------------------------
#
# These four numbers are shared with the game and must not drift from it.
# `camera_rig.gd` fixes the in-game camera at this pitch and this yaw, and
# `unit_visual.gd` derives every sprite's scale and pivot from CANVAS_HEIGHT.

## atan(1/sqrt(2)) = 35.264 degrees. At this pitch a world-space square projects
## to a 2:1 diamond, which is the proportion the whole art set is drawn against.
## Mirrors `camera_rig.gd` PITCH.
PITCH = math.atan(1.0 / math.sqrt(2.0))

## Mirrors `camera_rig.gd` START_YAW. The camera DOES rotate in game, but only
## in quarter turns (`camera_rig.gd` SNAP_STEP), so it is only ever at this yaw
## plus a multiple of 90 degrees -- and a quarter turn moves the eight direction
## buckets by exactly two whole steps. Every facing the player can see is
## therefore one of the eight rendered here, seen at this yaw, which is what
## lets the key light be fixed in world space below.
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
## THIS IS NOT `UnitVisual.foot_anchor`, and tying the two together was a
## mistake worth naming. This margin exists so the canvas does not CLIP a
## forward foot; the anchor says where the art's feet are, so the game can stand
## it on a floor. Setting the anchor to 1 - FLOOR_MARGIN / CANVAS_HEIGHT puts it
## on the world origin, and the origin is NOT the lowest point of the art: a
## planted forward foot projects below it, measured at 36 px for this character.
## The sprite is a vertical billboard writing depth, so those 36 px land beneath
## the floor mesh and get occluded -- feet visibly sunk into the ground.
##
## Nor can the anchor sit at the LOWEST PIXEL across every pose, which is what
## this file used to say and what left every character floating. Which row the
## feet reach is a function of the FACING -- the tilted camera projects a foot
## planted toward the viewer lower than the same foot planted across -- so the
## global minimum is one frame of one facing of one pose, and anchoring there
## hangs all the others that many pixels in the air. Measured on the merc: idle
## bottoms out at row 8 facing south and row 32 facing west, and the minimum over
## every pose is row 6, so seven facings out of eight floated.
##
## `report_anchor` measures the mean over the idle facings instead. FLOOR_MARGIN
## only has to be large enough that no pose clips the bottom edge; it is not an
## input to the anchor at all.
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

## Z rotation, in degrees, at which the character faces DIRECTIONS[0]. Every
## facing is this plus 45 degrees per bucket, so it is the single number the
## whole direction mapping hangs off.
##
## A CONSTANT, and it has to be. This used to read `character.rotation_euler.z`
## at startup, on the reasoning that the scene's authored rotation is the natural
## zero -- but that property is not a stable reading. Blender evaluates the saved
## active action when the file loads, and an action carrying object-level
## transform keys (see mute_object_transform_curves) drives this very property.
## So the base angle silently became "whichever action the artist last had open",
## and clearing the action does not undo it: the evaluated value sticks.
##
## The failure that cost an afternoon: `run` drives the object to 540 degrees and
## the authored rest is 810, so rendering `run` from a file saved on `run` put
## every run frame 270 degrees from where the same script had put `idle`. Same
## script, same .blend, different answer, no error, and the only symptom is a
## character that sprints sideways. Muting was already in place and did not help
## -- it stops the action fighting the turntable DURING a render, but the base
## was already wrong before the first frame.
##
## NOT 0, because REST_FACING_IS_BLENDER_PLUS_Y describes the modelling
## convention rather than this rig: the character was posed facing screen-SE to
## make it easier to model, so the whole set needs turning back onto bucket 0
## before the 45-degree steps start.
##
## 90 is what the SHIPPED art for every pose except `run` is aimed at. `run` is
## the exception and is currently 2 buckets (90 degrees) from it -- see the
## warning below before re-rendering it.
##
## An upstream fix to the .blend was tried (re-authoring the `run` action at the
## same facing as the rest of the rig) and did NOT hold -- a re-render still came
## out rotated, confirmed against a moving unit in game, not just the PNGs. So
## the correction below stays live; do not delete it on the strength of a .blend
## edit alone, only on the strength of a moving unit on screen.
##
## This value can only be settled IN THE GAME. Four have been tried: 0 from the
## axis convention, 90 from the .blend's stored rotation, then 135 and 180 from
## reading rendered frames at full resolution. Every one of them produced a
## sprite set that looked entirely reasonable laid out on a contact sheet.
##
## That is the trap worth remembering: eight facings of a character are
## self-consistent at ANY base, so a wrong one is invisible in the art. It shows
## up only when a unit walks east and its sprite runs north-east. Judge this
## against a MOVING UNIT on screen, never against the PNGs, and never re-derive
## it from the axis convention -- this rig is posed facing screen-SE, so
## REST_FACING_IS_BLENDER_PLUS_Y describes the pipeline's intent and not this
## .blend.
##
## Re-aiming needs no re-render. Renaming every file's direction one bucket
## (ne->e, n->ne, nw->n, w->nw, sw->w, s->sw, se->s, e->se) is byte-identical to
## +45 here; the reverse (ne->n, n->nw, ...) is -45. Seconds, not 40 minutes.
##
## Poses whose action is authored at a different facing get their correction
## here (see POSE_BUCKET_ZERO), so re-rendering them needs no special handling.
BUCKET_ZERO_DEGREES = 90.0

## Per-VARIANT bases, for a character built in a different .blend from the merc.
##
## The base is a fact about a RIG, not about the pipeline -- it says which way
## the artist happened to point the model -- so a second character has no reason
## to share the merc's.
##
## `brawler` (zombie_anim.blend) is 180. Reading it off the model is what got
## this wrong the first time and is worth recording: the mesh measures deeper
## toward +Y than -Y (nose and toes protrude forward), which says it faces
## Blender +Y and therefore needs no correction. That measurement is of the mesh
## in WORLD space, and the armature it hangs off carries a stored 180-degree
## rotation -- which this renderer OVERWRITES with the bucket angle. So the
## model does face +Y as saved, and does not once the turntable has set the
## rotation the render actually uses.
##
## Settled the only way it can be, by looking at rendered frames rather than at
## the rig: the PROFILE facings are the ones that read unambiguously. `e` came
## out striding screen-LEFT and `w` screen-RIGHT -- exactly swapped, which is
## four buckets, which is this 180. A hunched figure's front and back are
## genuinely hard to tell apart head-on, so `n` and `s` are the wrong frames to
## judge this from; `e` and `w` are not.
##
## Everything BUCKET_ZERO_DEGREES says about how to judge this value applies here
## unchanged: eight facings are self-consistent at any base, so a wrong one is
## invisible in the PNGs and shows up only as a unit that walks east while its
## sprite shambles north-east. Judge it on a MOVING UNIT, and re-aim by renaming
## files one bucket rather than by re-rendering.
VARIANT_BUCKET_ZERO = {
    "brawler": 180.0,
    # worm_anims.blend: the Z rotation that points the head (the spiked +Y end)
    # along Blender +Y, MEASURED off the rest mesh -- its tail-to-head axis sits
    # 5.3 deg anticlockwise of +Y with the rig at 25.5. The rig also lies ~93 deg
    # about X (the bone chain was built upright and laid flat), which the
    # turntable leaves alone since it only ever writes Z. Not yet judged on a
    # moving unit, and a wrong bucket is cheap to fix (rename files, do not
    # re-render).
    "worm": 20.2,
    # The three worm PILES (art_src/worm_pile_*.blend, built by
    # tools/build_worm_piles.py) inherit the single worm's base, and that is a
    # fact about how they are made rather than a convenience: every instance in
    # a pile IS a copy of that armature, carrying the same laid-flat rest
    # orientation the 20.2 was measured against. What turns is the `WormPile`
    # Empty they are parented to, which has no orientation of its own.
    #
    # Unlike the nest, a pile MOVES, so its buckets have to be right rather than
    # merely self-consistent -- judge these on a mass crossing a room, not on a
    # still, exactly as the note above says for the worm.
    "worm_clutch": 20.2,
    "worm_knot": 20.2,
    "worm_tide": 20.2,
    # The nest (art_src/worm_spawn_scaled.blend) takes the shared default, and
    # that is a DECISION rather than an omission. A nest never moves and never
    # turns, so it has no facing to get wrong: all eight buckets are the same
    # object seen from eight sides, and any base produces a self-consistent set.
    # What the base picks is merely which way the body happens to lie on the
    # deck. Rename files a bucket at a time if you want it lying differently --
    # there is nothing here a re-render could fix.
    #
    # It still needs all eight: the camera snaps in quarter turns
    # (`camera_rig.gd` SNAP_STEP), so even a motionless prop is seen from four
    # yaws, and a unit's sprite direction is its yaw MINUS the camera's.
    "nest": BUCKET_ZERO_DEGREES,
}

## Per-pose overrides, keyed by variant then pose, for an action posed at a
## different facing from the rest of ITS OWN rig. Values are DELTAS from the
## variant's base, so they compose with VARIANT_BUCKET_ZERO instead of silently
## re-stating it.
##
## `run` is authored a quarter turn ANTICLOCKWISE of every other action in
## merc_anim.blend, so it needs 90 degrees clockwise on top of the base to line
## up with them. That is a fact about the rig, not about the renderer -- the
## rotation lives in the pose, which is why muting object-transform curves never
## revealed it and why the root bone measures identical to `idle`.
##
## Encoded rather than left as a note, because the alternative is a landmine:
## re-rendering `run` would silently produce art 2 buckets off from every other
## pose, and that is exactly the failure this file already warns is invisible in
## its own output.
##
## An attempt was made to fix this upstream instead -- rotate the `run` action in
## the .blend to match the others and delete this entry, which is still the
## cleaner fix in principle. It did not work: a re-render off the "fixed" .blend
## still came out rotated when checked against a moving unit in game. Whatever
## was edited was not the thing actually driving the discrepancy, so the
## correction stays here until a re-render is verified in-game, not just as a
## static PNG.
POSE_BUCKET_ZERO = {
    "merc": {"run": 90.0},
}

## Which ACTION a pose is rendered from, where the two differ. Keyed by variant
## then pose.
##
## The zombie is animated to exactly two actions and is not going to grow more:
## its `melee` is the idle stance, by direction -- the swing reads from the
## lunge the unit makes to reach its target, not from the drawing. Aliasing it
## here rather than leaving `melee` unrendered is what makes that a DECISION.
## Left unrendered, `build_sprite_frames.gd` fills the gap with `_pick`'s last
## resort -- literally the first texture it scanned -- so the attack would play
## whatever facing happened to sort first, and would change the day a pose is
## added. Eight renders buys a `melee/<dir>` that is right in every facing.
POSE_ACTION = {
    "brawler": {"melee": "idle"},
    # `overwatch_hold` is the pose name the game plays; `overwatch` is the
    # Blender action it is now drawn from -- a 32-frame scanning-stance cycle
    # replacing the old placeholder-length hold. See LOOP_TIME below for why
    # the duration is derived rather than a round number.
    #
    # `throw_grenade` is the pose name; `grenade` is what the action was
    # actually named when authored (merc_anim.blend has no `throw_grenade`
    # action at all, so left unaliased this pose would silently never render).
    #
    # `hit_react`/`hit_react_low` likewise: the flinch was authored as `get_hit`
    # and `get_hit_low`.
    #
    # `downed` is the collapse the game plays when HP hits zero, authored as
    # `die`. `dead` needs no alias: it is the one-frame corpse unit_visual.gd
    # holds for good once `downed` has played out.
    "merc": {"overwatch_hold": "overwatch", "throw_grenade": "grenade",
             "hit_react": "get_hit", "hit_react_low": "get_hit_low",
             "downed": "die"},
    # The worm has three actions and no attack: its bite plays the idle thrash,
    # by decision, the way the brawler's swing plays its stance. Its third
    # action, `just emerged`, is not wired to any pose yet.
    "worm": {"idle": "worm idle", "walk": "walking", "melee": "worm idle"},
    # The piles render TWO poses and no more, and both absences are decisions.
    #
    # No `melee`: a mass has no attack action. It attacks by walking through the
    # tile you are standing on (WormUnit._trample_along), so the trample IS the
    # walk cycle and a separate swing would be art for a thing that never
    # happens.
    #
    # No `downed`: a mass shrinks rather than dies. Damage removes whole worms,
    # so it only ever reaches zero HP from a count of one -- which is a worm, and
    # the worm has no death art by decision either.
    "worm_clutch": {"idle": "worm idle", "walk": "walking"},
    "worm_knot": {"idle": "worm idle", "walk": "walking"},
    "worm_tide": {"idle": "worm idle", "walk": "walking"},
}

## Frames to sample for a pose, overriding the duration-derived count. Keyed by
## variant then pose.
##
## Two different jobs, and both are per-variant by nature:
##
##   1. A pose whose action is a PLACEHOLDER. The zombie's `idle` is a 25-frame
##      T-pose that exists to hang a length off, not to be watched, so sampling
##      the 24 frames its 2.0 s duration asks for would ship 24 copies of one
##      drawing. 1 frame says "this pose is a still", and costs nothing in
##      timing -- see LOOP_TIME.
##   2. A cycle whose frame count must divide its footfalls. `walk` is drawn as
##      32 Blender frames with contacts on 1 and 17, so an even sample lands
##      both on a frame and an odd one puts the second contact between two.
VARIANT_FRAMES = {
    "brawler": {"idle": 1, "melee": 1, "walk": 16},
    # The corpse is a still by design -- one drawing of the body where `die`
    # left it, held for the rest of the mission.
    "merc": {"dead": 1},
    # `walking` is drawn as 24 frames at 12 fps; sampled at the soldier's 1.4 s
    # walk it would come out 17 and drop every third drawing.
    "worm": {"walk": 24},
    # `walk` matches the single worm's 24 for the same reason it does there --
    # the action is drawn as 24 frames at 12 fps and resampling drops drawings.
    #
    # `idle` is CUT to 12 where the worm renders the full 24, and the cut is
    # affordable here for a reason the worm's own idle does not have: a pile's
    # instances are phase-shifted against each other (build_worm_piles.py), so
    # the motion a viewer reads is sixteen worms out of step rather than the
    # detail of any one cycle. Halving it halves the file count on the three
    # heaviest variants in the project.
    "worm_clutch": {"walk": 24, "idle": 12},
    "worm_knot": {"walk": 24, "idle": 12},
    "worm_tide": {"walk": 24, "idle": 12},
}


def bucket_zero(pose, variant):
    """Degrees at which `pose` faces bucket 0, for this variant's rig."""
    base = VARIANT_BUCKET_ZERO.get(variant, BUCKET_ZERO_DEGREES)
    return base + POSE_BUCKET_ZERO.get(variant, {}).get(pose, 0.0)


def source_action(pose, variant):
    """The Blender action `pose` is rendered from. Usually the same name."""
    return POSE_ACTION.get(variant, {}).get(pose, pose)

# --- Poses -------------------------------------------------------------------
#
# Blender actions are matched to these by name. An action named `idle` becomes
# the `idle` pose; anything not on this list is ignored, and any pose with no
# action is simply not rendered -- `build_sprite_frames.gd` falls back to the
# nearest pose that does exist, so a half-animated character still runs.
POSES = [
    "idle", "run", "walk", "overwatch_hold", "aim_hold",
    "begin_shoot", "fire_shoot", "end_shoot",
    "run_stop", "melee",
    "reload", "throw_grenade", "interact", "hit_react", "downed", "dead",
    "alert_scream", "idle_fidget",
    # Cover variants -- a unit posed as using the cover on its tile edge. Each is
    # optional: `build_sprite_frames.gd` emits them only where art exists, and
    # `unit_visual.gd` falls back to the plain pose everywhere else, so drawing
    # `idle_low` alone is a complete and shippable step.
    #
    # There is no `fire_shoot_low`, deliberately: `begin_shoot_low` is the step
    # OUT of cover, so by the time rounds leave the barrel the character is in
    # the open and the standing kick is the correct art.
    "idle_low", "begin_shoot_low", "end_shoot_low", "hit_react_low",
    "idle_high", "begin_shoot_high", "end_shoot_high",
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
    # 32 Blender frames at SAMPLE_FPS (12) -- the merc's `overwatch` action is
    # drawn to exactly this length, so the duration is stated as that division
    # rather than a rounder number that would sample to a different count.
    "overwatch_hold": 32 / 12.0, "aim_hold": 1.6,
    "idle_low": 2.4, "idle_high": 2.4,
}
DEFAULT_LOOP_TIME = 1.6

## Copied from `build_sprite_frames.gd` ONE_SHOT_TIME.
ONE_SHOT_TIME = {
    ## Must equal unit_visual.gd RAISE_TIME, BURST_CADENCE and SETTLE_TIME.
    ## See build_sprite_frames.gd.
    "begin_shoot": 0.45, "fire_shoot": 0.11, "end_shoot": 0.20,
    ## Must equal unit_visual.gd COVER_RAISE_TIME and COVER_SETTLE_TIME.
    "begin_shoot_low": 0.75, "end_shoot_low": 0.45,
    "begin_shoot_high": 0.75, "end_shoot_high": 0.45,
    # throw_grenade and interact are Blender frames / SAMPLE_FPS, so every
    # authored frame renders 1:1 -- see unit_visual.gd GRENADE.
    "melee": 1.20, "reload": 3.75, "throw_grenade": 37 / 12.0,
    "interact": 30 / 12.0,
    # 7 Blender frames at 12 fps -- see unit_visual.gd HIT_REACT.
    "hit_react": 7 / 12.0, "hit_react_low": 7 / 12.0,
    # The merc's `die` action: 12 Blender frames at 12 fps.
    "downed": 12 / 12.0, "alert_scream": 2.80,
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

# --- The muzzle marker -------------------------------------------------------
#
# A locator sphere parented (through the rifle) to the armature's `weapon` bone,
# whose only job is to say WHERE ON THE CANVAS the gun's lamp sits in each frame
# of each facing. `unit_visual.gd` reads the exported table and puts the
# flashlight glow there, so the glow tracks the drawn muzzle as the rifle sways
# rather than sitting at a fixed offset that is only ever right in one pose.
#
# IT IS NEVER RENDERED, and that is not left to the .blend to remember:
# `hide_marker` forces hide_render on before any frame is shot. A marker that
# reached the film would bake a magenta blob into the art, and stripping it back
# out afterwards DOES NOT WORK -- Cycles antialiases, so the sphere's edge pixels
# are magenta/background BLENDS that no exact-colour match catches, and painting
# over the middle just leaves a magenta fringe around whatever was painted. The
# position is read from the OBJECT instead (see marker_uv), which is exact,
# subpixel, and costs no render at all.
#
# Hiding it also keeps it out of `renderable_meshes`, so it can never skew the
# `foot_anchor` measurement by being the lowest thing on screen.
#
# Identified by MATERIAL first, because the material name is the part that says
# what the object is FOR -- an artist renaming the mesh should not break this.
MARKER_MATERIAL = "gun_loc"
MARKER_OBJECT = "Sphere"

## The muzzle marker's partner: a second locator further back along the bore, so
## that the two TOGETHER give the barrel's AXIS rather than just a point on it.
##
## One marker cannot do this, and not for want of trying: under the ortho camera
## a canvas position genuinely cannot be lifted back to a 3D direction, because
## depth is precisely the information the projection discards. Two points on the
## bore line is the cheapest honest way to recover it, and it is a MEASUREMENT of
## where the gun actually points rather than an inference about it.
##
## Matched on either name or material, so a duplicate of the muzzle sphere works
## as-is once renamed -- no material wrangling required.
REAR_MARKER_OBJECT = "BarrelRear"
REAR_MARKER_MATERIAL = "gun_loc_rear"

## Bore axis used when no rear marker exists yet: the rifle model's own local
## axis. Measured at yaw -15.7 deg, pitch -15.4 deg off the character's facing,
## which behaves the way a bore line should -- but it is the axis the MESH was
## BUILT on, not a point on the barrel that anybody placed, so it is a stand-in.
## It prints as one, loudly, every run.
FALLBACK_BORE_OBJECT = "AssaultRifle2_1"
FALLBACK_BORE_AXIS = (1.0, 0.0, 0.0)

## Written next to the sprites and keyed by the same `<pose>_<direction>` names
## the game's SpriteFrames use, so the Godot-side lookup is the animation name
## the sprite is ALREADY playing rather than a re-derivation of pose and facing.
MARKER_FILENAME = "muzzle_%s.json"


# --- The muzzle flash overlay ------------------------------------------------
#
# The flash is a LAYER OF ITS OWN, rendered by `--flash`, and the reason is
# framing rather than tidiness. `muzzle_%s.json` puts the barrel tip 29 px from
# the top edge of the 256 px canvas facing NW and 36 px from the side facing NE,
# so a flash reaching more than about 0.3 m past the muzzle is CUT OFF -- on a
# different edge for every facing.
#
# Rendering that one frame of the BODY layer on a bigger canvas does not work:
# `unit_visual.gd` `_apply_frame_scale` sizes a layer once, from the first frame
# it finds, so a single oversized PNG in body_<variant>.tres would be drawn at
# the body's pixel_size -- too big and off its pivot. Enlarging the canvas for
# every frame instead means re-rendering every pose of every variant, and then
# moving CANVAS_HEIGHT and the scenes' `canvas_height` together.
#
# A separate layer costs neither. It renders through the SAME camera at the SAME
# centre with the ortho extent and the resolution both multiplied by
# FLASH_CANVAS_SCALE, so metres-per-pixel is unchanged and the registration is
# the fraction identity in `build_camera`. Eight images, and the body art is
# never touched.
FLASH_LAYER = "flash"

## The pose the flash belongs to, and the one frame of it the flash is drawn on.
##
## ONE frame because that is what a muzzle flash IS: at 0.11 s over two drawings
## the flash is gone before the second one. Every other frame of the pose still
## gets a file -- see write_blank for why a shorter animation is not the same
## thing as a blank frame.
FLASH_POSE = "fire_shoot"
FLASH_FRAME = 0

## How many times bigger the flash canvas is than the body's. 2 gives 5.12 m
## across 512 px: 2.56 m of clearance from the centre in every direction against
## the ~0.3 m the body canvas leaves, and it costs nothing, because this pass
## renders 8 images where a variant renders several hundred.
##
## Raise it if a flash still clips; the game needs no edit when you do, because
## `layer_canvas_scale` on the character scene is the only place the number is
## written down and `unit_visual.gd` derives the anchor from it.
FLASH_CANVAS_SCALE = 2

## Identified by MATERIAL first, for the same reason the muzzle marker is: the
## material name is the part that says what the object is FOR, so renaming the
## mesh does not break the render.
##
## The merc's flash is found by NAME today -- its materials are the two the
## shading needed (`Muzzle Side`, `Muzzle Face`), neither of which names the
## object's job. Giving it a `muzzle_flash` material as well is what would make
## the name free to change; until then `--flash-object` is the escape hatch.
FLASH_MATERIAL = "muzzle_flash"
FLASH_OBJECT = "muzzle_flash"


def _by_material_or_name(material, name):
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        if any(m and m.name == material for m in obj.data.materials):
            return obj
    return bpy.data.objects.get(name)


def find_rear_marker(explicit=None):
    """The locator further back along the bore, or None if none exists yet."""
    if explicit:
        obj = bpy.data.objects.get(explicit)
        if obj is None:
            sys.exit("--rear-marker-object %r not found in the .blend" % explicit)
        return obj
    return _by_material_or_name(REAR_MARKER_MATERIAL, REAR_MARKER_OBJECT)


def find_marker(explicit=None, exclude=None):
    """The locator on the muzzle, whose screen position gets exported.

    `exclude` keeps a rear marker DUPLICATED from the muzzle sphere -- and so
    still carrying the muzzle's material -- from being picked up as the muzzle
    itself, which is the obvious way to make this second marker and therefore
    the one that has to work.
    """
    if explicit:
        obj = bpy.data.objects.get(explicit)
        if obj is None:
            sys.exit("--marker-object %r not found in the .blend" % explicit)
        return obj
    for obj in bpy.data.objects:
        if obj.type != "MESH" or obj is exclude:
            continue
        if any(m and m.name == MARKER_MATERIAL for m in obj.data.materials):
            return obj
    found = bpy.data.objects.get(MARKER_OBJECT)
    return None if found is exclude else found


def hide_marker(marker, role="muzzle"):
    """Keeps the locator off the film. See MARKER_MATERIAL for why this matters."""
    if marker is None:
        return
    if not marker.hide_render:
        marker.hide_render = True
        print("[render_sprites] %r is the %s marker -- hidden from renders "
              "(it is a locator, not art)" % (marker.name, role))


def marker_world(marker):
    """`marker`'s centre in world space, on the currently evaluated frame.

    Uses the evaluated bounding-box centre rather than the object's origin, so a
    marker whose origin was left off-centre still reports its middle. Under the
    ortho camera a sphere projects to a circle centred on exactly that point,
    which is what makes a sphere a good marker in the first place.
    """
    evaluated = marker.evaluated_get(bpy.context.evaluated_depsgraph_get())
    local_centre = sum((Vector(corner) for corner in evaluated.bound_box),
                       Vector()) / 8.0
    return evaluated.matrix_world @ local_centre


def marker_uv(scene, camera, marker):
    """Where `marker` sits on the canvas this frame, as (u, v) in 0..1.

    ORIGIN IS TOP-LEFT, matching how an image is indexed everywhere the game
    touches one; `world_to_camera_view` measures up from the bottom, so v is
    flipped here rather than in Godot.
    """
    ndc = world_to_camera_view(scene, camera, marker_world(marker))
    return ndc.x, 1.0 - ndc.y


def bore_vector(marker, rear, fallback):
    """Unit vector down the barrel this frame, in WORLD space.

    Two markers on the bore line when they exist, because that is a measurement
    of where the gun points. The model's own axis otherwise, which is a guess --
    see FALLBACK_BORE_OBJECT.
    """
    if rear is not None:
        return (marker_world(marker) - marker_world(rear)).normalized()
    if fallback is None:
        return None
    basis = fallback.evaluated_get(
        bpy.context.evaluated_depsgraph_get()).matrix_world.to_3x3()
    return (basis @ Vector(FALLBACK_BORE_AXIS)).normalized()


def _unturn(v, dir_index):
    """Undoes the TURNTABLE for `dir_index`, leaving the unit's own frame.

    Only the 45-degree bucket step is removed, NOT the whole object rotation,
    and the difference is the entire subtlety here. `bucket_zero` also contains
    the authoring correction -- which way the artist happened to point the model
    -- and at bucket 0 that correction has ALREADY done its job: the character
    is facing Blender +Y, which is Godot -Z, which is yaw zero for every unit in
    the game. So bucket 0's world frame IS the unit frame, and each further
    bucket is just 45 degrees on top of it.

    Undoing `character.matrix_world` instead is the obvious-looking thing and is
    wrong twice over: it takes out the authoring correction that must stay in
    (yaw came out 90 degrees off), and it drags in the armature's own transform,
    which put the muzzle at 1.676 m when it is really at 1.144 m.
    """
    return Matrix.Rotation(-math.radians(45.0 * dir_index), 3, "Z") @ v


def to_unit_point(world_point, dir_index):
    """A world point as an offset in the unit's own frame, in Godot's axes.

    The same in every facing, because the turntable is exactly what `_unturn`
    removes -- so this depends only on the animation frame, turning 8 directions
    x N frames of data into N.
    """
    return _godot_axes(_unturn(world_point, dir_index))


def to_unit_direction(world_vector, dir_index):
    """A world direction in the unit's own frame, in Godot's axes."""
    return _godot_axes(_unturn(world_vector, dir_index).normalized())


def _godot_axes(v):
    """Blender (Z-up, +Y forward) -> Godot (Y-up, -Z forward).

    The same convention DIRECTIONS is built on: Blender +Y is Godot -Z and
    Blender +Z is Godot +Y, so a character facing Blender +Y comes out facing
    Godot -Z, which is bucket 0.
    """
    return [round(v.x, 6), round(v.z, 6), round(-v.y, 6)]


def _clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.cameras, bpy.data.lights):
        for item in block:
            if item.users == 0:
                block.remove(item)


def build_camera(scene, canvas_scale=1.0):
    """Creates (or re-aims) the one orthographic camera every frame is shot from.

    Placed so the WORLD ORIGIN lands FLOOR_MARGIN metres above the bottom edge
    of the frame, which is where `UnitVisual.foot_anchor` says it is. Get the two
    out of step and every character floats or sinks by the difference.

    `canvas_scale` multiplies the ortho extent WITHOUT moving the camera, so an
    enlarged canvas grows about the same centre and a world point that sat at
    fraction f of the standard canvas sits at 0.5 + (f - 0.5) / canvas_scale of
    this one. That identity is what lets the muzzle-flash layer be rendered on a
    bigger frame and still register with the body art -- see FLASH_LAYER, and
    `unit_visual.gd` `_layer_anchor`, which is the same arithmetic read back.
    """
    cam_data = bpy.data.cameras.get("SpriteCam") or bpy.data.cameras.new("SpriteCam")
    cam_data.type = "ORTHO"
    # ortho_scale is the extent across the LARGER image dimension. The render is
    # square, so this is the canvas height directly -- times `canvas_scale`,
    # which is the ONE thing an enlarged canvas changes about this camera.
    cam_data.ortho_scale = CANVAS_HEIGHT * canvas_scale

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
    #
    # NOT multiplied by `canvas_scale`, deliberately: this offset is what fixes
    # where the origin sits in the STANDARD canvas, and scaling it too would
    # slide the enlarged canvas rather than grow it, breaking the fraction
    # identity the docstring rests on.
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


def configure_render(scene, canvas_scale=1.0):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 128
    scene.render.resolution_x = int(RESOLUTION * canvas_scale)
    scene.render.resolution_y = int(RESOLUTION * canvas_scale)
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


def frame_count(pose, variant):
    """How many frames to sample for `pose`, from its in-game duration."""
    override = VARIANT_FRAMES.get(variant, {}).get(pose)
    if override:
        # NOT clamped to MIN_FRAMES: 1 is a legitimate answer here and is the
        # whole point of the override for a placeholder pose.
        return max(1, override)
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


def _character_channelbags(action, character):
    """Channelbags in `action` whose slot is the one driving `character`.

    Blender 4.4 made Actions LAYERED: one Action can carry fcurves for several
    datablocks at once, partitioned into channelbags by SLOT, rather than
    exposing one flat `action.fcurves` list the way older Blenders did (that
    property is simply gone in 5.2 -- iterating `action.fcurves` now raises
    AttributeError). A channelbag belonging to some other object's slot is not
    this pipeline's business even when it shares the action; only the slot
    `character.animation_data.action_slot` points at is.
    """
    slot = character.animation_data.action_slot if character.animation_data else None
    if slot is None:
        return []
    return [cb for layer in action.layers for strip in layer.strips
            for cb in getattr(strip, "channelbags", ())
            if cb.slot_handle == slot.handle]


def mute_object_transform_curves(action, character):
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
    for cb in _character_channelbags(action, character):
        for fcurve in cb.fcurves:
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


def renderable_meshes():
    """Every mesh that actually reaches the film.

    All of them, not just the character's body: the rifle is a separate object
    and a lowered muzzle can be the lowest thing on screen. `GroundReference` is
    excluded for free, since it is hide_render.
    """
    return [o for o in bpy.context.scene.objects
            if o.type == "MESH" and not o.hide_render]


def unlink_missing_images():
    """Drops image textures whose file cannot be found, loudly.

    Cycles renders a missing image as solid MAGENTA, and it would be baked into
    every frame of every facing. Unlinking the node instead lets the shader fall
    back to its own base colour: plainly placeholder art, not plausibly wrong
    art. In memory only -- the .blend is never written -- and printed every run,
    so grey sprites are never mistaken for finished ones. Pack the texture into
    the .blend (File > External Data > Pack Resources) and re-render to fix.
    """
    for material in bpy.data.materials:
        if material.node_tree is None:
            continue
        for node in material.node_tree.nodes:
            image = getattr(node, "image", None)
            if node.type != "TEX_IMAGE" or image is None or image.packed_file:
                continue
            if os.path.exists(bpy.path.abspath(image.filepath)):
                continue
            for link in list(node.outputs[0].links) + list(node.outputs[1].links):
                material.node_tree.links.remove(link)
            print("[render_sprites] *** MISSING TEXTURE %r (%s) on material %r -- "
                  "rendering UNTEXTURED. Pack it into the .blend and re-render. ***"
                  % (image.name, image.filepath, material.name))


def lowest_point_on_screen(scene, camera, meshes):
    """Lowest normalised screen height of any rendered vertex this frame.

    0.0 is the bottom edge of the film, 1.0 the top. Evaluated rather than raw,
    so armature deformation counts -- the whole question is where the FEET end
    up once the pose is applied.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    lowest = 1.0
    for obj in meshes:
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        matrix = evaluated.matrix_world
        for vertex in mesh.vertices:
            y = world_to_camera_view(scene, camera, matrix @ vertex.co).y
            if y < lowest:
                lowest = y
        evaluated.to_mesh_clear()
    return lowest


def report_anchor(lowest_by_facing):
    """Prints the `UnitVisual.foot_anchor` these renders actually need.

    `lowest_by_facing` maps (pose, direction) to the lowest normalised screen
    height any vertex reached across that facing's frames.

    Printed rather than left to be derived because deriving it is what went
    wrong twice: the obvious formula, 1 - FLOOR_MARGIN / CANVAS_HEIGHT, anchors
    on the WORLD ORIGIN, and a planted forward foot projects below that. The
    sprite is a depth-writing billboard, so anything below the anchor is under
    the floor mesh and gets occluded -- feet sunk into the ground.

    Anchoring on the other extreme, the lowest pixel over every frame, is what
    this printed before and it is the reason every character floated. The row
    the feet reach is a function of the FACING: the camera is tilted, so a foot
    planted toward the viewer projects lower than the same foot planted across
    it, and on the merc that is a 24 px spread across idle's eight buckets. The
    minimum is one facing's answer; using it hangs the other seven that far off
    the floor.

    So: the MEAN over the grounding pose's facings, which puts the average foot
    on the floor and lets the facings that reach lowest push a toe under it.
    Under the floor reads as planted; above it reads as flying. The no-clip
    minimum is still printed, because it is the number to check a nest or a worm
    against -- a low, sprawling body like the worm is nearly all depth, and a
    vertical billboard turns depth into height, so the mean would bury it.

    This is a property of the poses, not of the pipeline, so it moves whenever
    the art does and there is no constant that can stand in for it.
    """
    origin_row = FLOOR_MARGIN / CANVAS_HEIGHT * RESOLUTION
    rows = {key: ndc * RESOLUTION for key, ndc in lowest_by_facing.items()}
    if not rows:
        print("[render_sprites] no frames rendered -- no anchor to report")
        return

    low_row = min(rows.values())
    safe_row = max(0.0, low_row - ANCHOR_SAFETY_PX)
    no_clip = 1.0 - safe_row / RESOLUTION

    # The grounding pose if it was rendered, every pose if it was not -- a
    # --only-poses run still gets an answer, just a narrower one.
    grounding = [row for (pose, _), row in rows.items() if pose == GROUNDING_POSE]
    label = GROUNDING_POSE
    if not grounding:
        grounding = list(rows.values())
        label = "all rendered poses"
    mean_row = sum(grounding) / len(grounding)
    anchor = 1.0 - mean_row / RESOLUTION

    print("[render_sprites] lowest pixel: row %.1f of %d (world origin is row "
          "%.0f, so the art reaches %.1f px BELOW it)"
          % (low_row, RESOLUTION, origin_row, origin_row - low_row))
    print("[render_sprites] %s feet span rows %.1f to %.1f across %d facings, "
          "mean %.1f" % (label, min(grounding), max(grounding), len(grounding),
                         mean_row))
    if low_row <= 0.0:
        print("[render_sprites] *** CLIPPED: the pose runs off the bottom of the "
              "canvas. Raise FLOOR_MARGIN (now %.2f m) and re-render. ***"
              % FLOOR_MARGIN)
    elif low_row < ANCHOR_SAFETY_PX + 2:
        print("[render_sprites] WARNING: only %.1f px of floor margin left. A "
              "longer pose will clip -- consider raising FLOOR_MARGIN." % low_row)
    print("[render_sprites] SET UnitVisual.foot_anchor = (0.5, %.8f)" % anchor)
    print("[render_sprites]   (grounded: the mean over %s, so the facings that "
          "reach lowest sink %.0f px into the floor -- that is intended)"
          % (label, mean_row - min(grounding)))
    print("[render_sprites]   no-clip alternative (0.5, %.8f) never sinks and "
          "floats up to %.0f px; use it only for a LOW, SPRAWLING body whose "
          "silhouette is mostly depth, like the worm"
          % (no_clip, max(grounding) - safe_row))
    print("[render_sprites]   (measured over the frames rendered THIS run; "
          "render every facing to get the number the character actually needs)")


def poses_to_do(variant, only_poses=None):
    """The poses this run will walk, and a note about the ones it cannot."""
    actions = {a.name: a for a in bpy.data.actions}
    # Matched through the alias table, so a pose drawn from another pose's
    # action (POSE_ACTION) counts as present.
    todo = [p for p in POSES if source_action(p, variant) in actions]
    if only_poses:
        todo = [p for p in todo if p in only_poses]
    missing = [p for p in POSES if source_action(p, variant) not in actions]
    if missing:
        print("[render_sprites] no action for: %s (will fall back in Godot)"
              % ", ".join(missing))
    if not todo:
        sys.exit("No actions matched a pose name. Rename your actions to: %s"
                 % ", ".join(POSES))
    return todo


def iter_pose_frames(variant, character, todo, directions):
    """Walks every (pose, direction, frame) a render writes, in that same order.

    SHARED by the render pass and the marker export, and that sharing is the
    point: entry N of a marker track has to be the frame in `..._N.png`, and the
    only way to guarantee it is for one piece of code to decide what the frames
    ARE. Two loops kept in step by hand would drift the first time a sampling
    rule changed, and the symptom -- a glow that lags the barrel by a frame --
    is subtle enough to be lived with rather than noticed.

    Yields (pose, direction, frame_index) with the scene already evaluated on
    that frame, so a caller can render it or measure it.
    """
    actions = {a.name: a for a in bpy.data.actions}
    for pose in todo:
        action = actions[source_action(pose, variant)]
        character.animation_data.action = action
        # Per POSE, not once per run: an action authored at a different facing
        # needs its own zero (POSE_BUCKET_ZERO).
        original_rotation = math.radians(bucket_zero(pose, variant))
        muted = mute_object_transform_curves(action, character)
        count = frame_count(pose, variant)
        looping = pose in LOOP_TIME
        frames = sample_frames(action, count, looping)

        for direction in directions:
            # Angle comes from the position in DIRECTIONS, not from the position
            # in the list being walked, so a subset never reassigns anyone's
            # bucket.
            dir_index = DIRECTIONS.index(direction)
            # The character turns; the camera and the world-fixed key do not.
            character.rotation_euler.z = original_rotation + math.radians(45.0 * dir_index)

            for frame_index, blender_frame in enumerate(frames):
                # Belt and braces on top of the muting: frame_set re-evaluates
                # everything, so ANY mechanism that drives this object's
                # transform -- a driver, an NLA strip, a constraint -- would
                # silently collapse all eight facings into one. Cheap to check,
                # and the failure is invisible in the output otherwise.
                bpy.context.scene.frame_set(int(round(blender_frame)),
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

                yield pose, direction, frame_index

        for fcurve in muted:
            fcurve.mute = False

        print("[render_sprites] %s: %d frames x %d directions"
              % (pose, len(frames), len(directions)))


def render_variant(variant, out_dir, character, only_poses=None, directions=None):
    scene = bpy.context.scene
    configure_render(scene)
    build_camera(scene)

    os.makedirs(out_dir, exist_ok=True)

    if character.animation_data is None:
        character.animation_data_create()

    todo = poses_to_do(variant, only_poses)
    # A locator, not art. Forced off the film before the first frame -- see
    # MARKER_MATERIAL for why stripping it out afterwards is not an option.
    hide_marker(find_marker())
    # Same reason, one object further: the flash is art, but it is art for a
    # DIFFERENT layer, and the body canvas is too small to hold it.
    hide_flash(find_flash())
    unlink_missing_images()

    # NOT read from the character -- see BUCKET_ZERO_DEGREES for the bug that
    # caused. Printed because it is the one number that silently re-aims every
    # sprite in the game, and a render log that does not state it cannot be used
    # to tell two renders apart after the fact.
    print("[render_sprites] bucket 0 (%s) renders at %.1f deg; each bucket +45"
          % (DIRECTIONS[0], VARIANT_BUCKET_ZERO.get(variant, BUCKET_ZERO_DEGREES)))
    for pose in sorted(POSE_BUCKET_ZERO.get(variant, {})):
        print("[render_sprites]   except %r, authored at a different facing: "
              "%.1f deg" % (pose, bucket_zero(pose, variant)))
    for pose, action_name in sorted(POSE_ACTION.get(variant, {}).items()):
        print("[render_sprites]   %r is rendered from the %r action"
              % (pose, action_name))
    written = 0
    meshes = renderable_meshes()
    # Kept per (pose, facing) rather than as one running minimum: the anchor is a
    # mean ACROSS facings, and a single number cannot be un-collapsed later.
    lowest_by_facing = {}

    for pose, direction, frame_index in iter_pose_frames(
            variant, character, todo, directions or GAME_DIRECTIONS):
        name = "body_%s_%s_%s_%d.png" % (variant, pose, direction, frame_index)
        scene.render.filepath = os.path.join(out_dir, name)
        # Measured before the render, on the same evaluated pose the render is
        # about to shoot. Costs a vertex loop against a Cycles frame, which is
        # nothing, and saves reading 500 PNGs back.
        key = (pose, direction)
        lowest_by_facing[key] = min(
            lowest_by_facing.get(key, 1.0),
            lowest_point_on_screen(scene, scene.camera, meshes))

        bpy.ops.render.render(write_still=True)
        written += 1

    # Left facing bucket 0 of the SHARED base, not of whichever pose happened to
    # be rendered last. Cosmetic -- the .blend is never written -- but a tidier
    # state to hand back, and it no longer depends on the loop variable.
    character.rotation_euler.z = math.radians(
        VARIANT_BUCKET_ZERO.get(variant, BUCKET_ZERO_DEGREES))
    print("[render_sprites] wrote %d images to %s" % (written, out_dir))
    report_anchor(lowest_by_facing)
    print("[render_sprites] now run build_sprite_frames.gd with SF_VARIANT=%s "
          "SF_LAYERS=body" % variant)


def _mean_direction(vectors):
    """The average of unit vectors, renormalised. Empty gives Godot forward."""
    if not vectors:
        return [0.0, 0.0, -1.0]
    total = Vector((0.0, 0.0, 0.0))
    for v in vectors:
        total += Vector(v)
    if total.length < 1e-9:
        return [0.0, 0.0, -1.0]
    total.normalize()
    return [round(total.x, 6), round(total.y, 6), round(total.z, 6)]


def export_markers(variant, out_dir, character, marker, rear=None,
                   fallback=None, only_poses=None, directions=None):
    """Writes where the muzzle marker lands on the canvas, frame by frame.

    NO RENDERING HAPPENS HERE. The marker's screen position is a projection of a
    known point through a known camera, so it is `world_to_camera_view` and a
    matrix multiply -- seconds for a whole pose set, against the tens of minutes
    the equivalent Cycles bake costs. That is also why this is safe to re-run
    whenever the rig moves: it never touches the PNGs.

    Keyed `<pose>_<direction>` because that is exactly the SpriteFrames
    animation name `unit_visual.gd` will be playing when it needs the answer, so
    the lookup is the string it already has rather than a pose and a facing
    reassembled at runtime.
    """
    scene = bpy.context.scene
    configure_render(scene)
    camera = build_camera(scene)
    hide_marker(marker)
    hide_marker(rear, "rear bore")
    if rear is None:
        print("[render_sprites] *** no rear bore marker (%r / material %r). "
              "Falling back to %r's local axis, which is a GUESS at where the "
              "barrel points -- add a second locator on the bore line to "
              "measure it instead. ***"
              % (REAR_MARKER_OBJECT, REAR_MARKER_MATERIAL, FALLBACK_BORE_OBJECT))

    if character.animation_data is None:
        character.animation_data_create()

    todo = poses_to_do(variant, only_poses)
    walked = directions or GAME_DIRECTIONS
    tracks = {}
    bore = {}
    for pose, direction, frame_index in iter_pose_frames(
            variant, character, todo, walked):
        u, v = marker_uv(scene, camera, marker)
        track = tracks.setdefault("%s_%s" % (pose, direction), [])
        # Appended in the generator's order, which IS the frame order, so the
        # index this lands at is the `_%d` in the matching PNG's name.
        assert len(track) == frame_index, (
            "marker track for %s_%s went out of order at %d"
            % (pose, direction, frame_index))
        track.append([round(u, 6), round(v, 6)])

        # Recorded on ONE facing only: these are the character's own local
        # space, which the turntable rotates along with the character, so all
        # eight directions would write identical values. See to_godot_point.
        if direction != walked[0]:
            continue
        entry = bore.setdefault(pose, {"muzzle": [], "direction": []})
        bucket = DIRECTIONS.index(direction)
        entry["muzzle"].append(to_unit_point(marker_world(marker), bucket))
        aim = bore_vector(marker, rear, fallback)
        entry["direction"].append(
            to_unit_direction(aim, bucket) if aim else [0.0, 0.0, -1.0])

    # The cycle MEAN, for the rules to aim by. The per-frame directions above
    # are what the drawn beam sways along; LightingManager must not use them,
    # because it recomputes on discrete triggers (move, toggle, turn start) and
    # never per frame -- so a swaying gameplay cone would sample whichever
    # animation frame happened to be showing when a unit moved, and two
    # identical moves could light different tiles. A stable direction keeps
    # detection reproducible; the residual disagreement with the drawn beam is
    # under 3 degrees, which is sub-tile at any range the cone reaches.
    for entry in bore.values():
        entry["mean_direction"] = _mean_direction(entry["direction"])

    document = {
        "variant": variant,
        # Recorded for the reader's benefit only: the canvas coordinates are
        # NORMALISED, so the game derives pixels from whatever the loaded
        # texture actually measures and a resolution change costs no re-export.
        "resolution": RESOLUTION,
        "canvas_height": CANVAS_HEIGHT,
        "marker": marker.name,
        "rear_marker": rear.name if rear else None,
        # Says out loud whether `bore` was measured off two locators or guessed
        # from the rifle's own axis, so a reader never has to infer which.
        "bore_source": "markers" if rear else "model-axis (APPROXIMATE)",
        "origin": "top-left",
        "axes": "godot",
        "frames": tracks,
        "bore": bore,
    }
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, MARKER_FILENAME % variant)
    with open(path, "w") as handle:
        json.dump(document, handle, indent=1, sort_keys=True)
    print("[render_sprites] wrote %d marker tracks to %s"
          % (len(tracks), path))


def find_flash(explicit=None):
    """The muzzle-flash object, or None if this .blend has not got one yet."""
    if explicit:
        obj = bpy.data.objects.get(explicit)
        if obj is None:
            sys.exit("--flash-object %r not found in the .blend" % explicit)
        return obj
    return _by_material_or_name(FLASH_MATERIAL, FLASH_OBJECT)


def _flash_subtree(flash):
    """`flash` and everything parented under it.

    Walked rather than assumed, because a flash is as likely to be a cone plus a
    glow card plus a few sparks as it is to be one mesh, and hiding half of it
    would be a silent half-render.
    """
    keep = {flash}
    changed = True
    while changed:
        changed = False
        for obj in bpy.context.scene.objects:
            if obj not in keep and obj.parent in keep:
                keep.add(obj)
                changed = True
    return keep


def hide_flash(flash):
    """Keeps the muzzle flash out of the BODY render.

    It lives in the same .blend and hangs off the weapon bone, so it is in shot
    for `fire_shoot` unless something says otherwise. Baked into the body layer
    it would be stuck inside the 2.56 m canvas and clipped on every facing --
    the entire thing the separate layer exists to avoid -- and it would then be
    drawn a second time the moment the overlay layer was switched on.

    Same doctrine as `hide_marker`: what does and does not reach the film is
    decided HERE, not left to whatever the .blend was last saved with.
    """
    if flash is None:
        print("[render_sprites] no muzzle flash object found (%r material, else "
              "%r) -- fine if this character has none"
              % (FLASH_MATERIAL, FLASH_OBJECT))
        return
    for obj in _flash_subtree(flash):
        obj.hide_render = True
    print("[render_sprites] %r is the muzzle flash -- hidden from the body "
          "render; --flash draws it on its own layer" % flash.name)


def hide_all_but_flash(flash):
    """Takes every mesh except the flash off the film.

    The character is HIDDEN, not removed, and that distinction is the whole
    trick: the flash hangs off the weapon bone, so the armature still has to be
    posed by the action and turned through the eight facings for the flash to
    land where the barrel actually is. Hiding the meshes leaves the rig doing
    exactly that and renders none of it.

    Lights and the world are left alone. An emissive flash does not need them,
    but a flash that is textured rather than emissive does, and which one the art
    is is not this pass's business.
    """
    kept = _flash_subtree(flash)
    hidden = 0
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj in kept:
            continue
        if not obj.hide_render:
            obj.hide_render = True
            hidden += 1
    print("[render_sprites] flash pass: %r kept (+%d parented to it), "
          "%d other meshes hidden" % (flash.name, len(kept) - 1, hidden))


def write_blank(path, size, scene):
    """A fully transparent PNG, for the frames of the pose the flash is NOT on.

    Written rather than skipped, and the reason is timing. `build_sprite_frames`
    derives playback speed as frames / duration, so a one-frame flash and a
    two-frame body would be handed the same 0.11 s and run at different rates;
    `unit_visual.gd` starts every layer in the same engine frame on the
    assumption that they then stay in step. Equal frame counts is what that
    assumption actually rests on, so the flash keeps the body's count and spends
    the frames it does not need on nothing.
    """
    image = bpy.data.images.new("flash_blank", size, size, alpha=True)
    # Regenerates the buffer: `images.new` makes an OPAQUE black image, which
    # would composite as a black square over the character rather than as
    # nothing at all.
    image.generated_color = (0.0, 0.0, 0.0, 0.0)
    image.alpha_mode = "STRAIGHT"
    # save_render rather than save, so the file is written through the scene's
    # own image settings -- the same RGBA PNG the renders come out as.
    image.save_render(filepath=path, scene=scene)
    bpy.data.images.remove(image)


def check_flash_turns(character, flash, variant):
    """Fails loudly if the flash does not turn with the character.

    The eight facings are made by ROTATING the character between renders, so an
    object that is not parented into the rig does not turn with it: every facing
    renders the flash in the same place, and the output is eight plausible PNGs
    of which seven have the flash nowhere near the barrel. This is the same
    failure `mute_object_transform_curves` guards the body against, it is just
    as invisible after the fact -- right file count, right names, right-looking
    images -- and it is the first thing a flash added to a .blend gets wrong,
    because a mesh added at the barrel in one pose LOOKS finished.
    """
    scene = bpy.context.scene
    action = bpy.data.actions[source_action(FLASH_POSE, variant)]
    character.animation_data.action = action
    muted = mute_object_transform_curves(action, character)
    frames = sample_frames(action, frame_count(FLASH_POSE, variant),
                           FLASH_POSE in LOOP_TIME)
    blender_frame = frames[FLASH_FRAME]
    zero = math.radians(bucket_zero(FLASH_POSE, variant))

    # A QUARTER turn, not a whole one: two buckets apart is far enough that no
    # plausible flash lands in the same world spot twice, and close enough that
    # the check costs two frame_sets.
    seen = []
    for bucket in (0, 2):
        character.rotation_euler.z = zero + math.radians(45.0 * bucket)
        scene.frame_set(int(round(blender_frame)),
                        subframe=float(blender_frame % 1.0))
        seen.append(marker_world(flash))
    for fcurve in muted:
        fcurve.mute = False

    if (seen[0] - seen[1]).length > 1e-4:
        return
    sys.exit(
        "[render_sprites] %r does not turn with %r: two facings apart it is "
        "still at (%.3f, %.3f, %.3f). It is not parented into the rig, so all "
        "eight facings would render it IDENTICALLY -- seven of them with the "
        "flash hanging in the air away from the barrel. Parent it to the "
        "weapon bone, or to the rifle, which already is, and re-place it "
        "there: its keys are in world space now and become local to the "
        "parent." % (flash.name, character.name, seen[0].x, seen[0].y, seen[0].z))


def render_flash(variant, out_dir, character, flash, directions=None):
    """Renders the muzzle flash alone, on the enlarged canvas, for ONE frame.

    Writes `flash_<variant>_fire_shoot_<dir>_<n>.png` across the eight facings:
    the flash on FLASH_FRAME, a transparent frame everywhere else in the pose.
    A minute or so against the tens of minutes a variant takes, which is the
    point of the split -- a flash can be re-authored and re-rendered as often as
    it takes without a single frame of the body art being touched.
    """
    scene = bpy.context.scene
    configure_render(scene, FLASH_CANVAS_SCALE)
    build_camera(scene, FLASH_CANVAS_SCALE)
    os.makedirs(out_dir, exist_ok=True)

    if character.animation_data is None:
        character.animation_data_create()

    action = source_action(FLASH_POSE, variant)
    if not any(a.name == action for a in bpy.data.actions):
        sys.exit("[render_sprites] no %r action in this .blend -- the flash is "
                 "rendered from the same action as the body's %r pose, so "
                 "there is nothing to sample."  % (action, FLASH_POSE))

    # Before a single Cycles frame is spent, and before the scene is touched --
    # the failure this catches produces a complete, correct-looking set of files.
    check_flash_turns(character, flash, variant)
    hide_all_but_flash(flash)
    unlink_missing_images()

    size = int(RESOLUTION * FLASH_CANVAS_SCALE)
    written = 0
    blanks = 0
    # `iter_pose_frames` rather than a loop of its own, for the reason given in
    # its docstring: frame N of this layer has to be the same instant as frame N
    # of the body, and one piece of code deciding what the frames ARE is the only
    # thing that guarantees it.
    for pose, direction, frame_index in iter_pose_frames(
            variant, character, [FLASH_POSE], directions or GAME_DIRECTIONS):
        path = os.path.join(out_dir, "%s_%s_%s_%s_%d.png"
                            % (FLASH_LAYER, variant, pose, direction, frame_index))
        if frame_index != FLASH_FRAME:
            write_blank(path, size, scene)
            blanks += 1
            continue
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        written += 1

    print("[render_sprites] wrote %d flash frames and %d blank frames to %s"
          % (written, blanks, out_dir))
    report_flash_layer(variant)


def report_flash_layer(variant):
    """Prints what the character scene has to be told, and nothing it can get wrong.

    ONE number goes in the scene -- the scale -- because the canvas height and
    the anchor are both derived from it in `unit_visual.gd`. A second
    hand-measured anchor is exactly the kind of thing that ends up disagreeing
    with the first and putting the flash half a head off the barrel.
    """
    scale = float(FLASH_CANVAS_SCALE)
    print("[render_sprites] flash canvas: %.2f m across %d px = %.1f mm per "
          "pixel, the same as the body's"
          % (CANVAS_HEIGHT * scale, int(RESOLUTION * FLASH_CANVAS_SCALE),
             CANVAS_HEIGHT / RESOLUTION * 1000))
    print("[render_sprites] on the character scene: add &\"%s\" to `layers` "
          "LAST, so it draws in front of the body, and set "
          "layer_canvas_scale = {&\"%s\": %g}"
          % (FLASH_LAYER, FLASH_LAYER, scale))
    print("[render_sprites] canvas_height and foot_anchor stay as they ARE -- "
          "this layer's own are derived: canvas_height x %g, and foot_anchor y "
          "-> 0.5 + (y - 0.5) / %g (the merc's 0.93359375 becomes %.9f)"
          % (scale, scale, 0.5 + (0.93359375 - 0.5) / scale))
    print("[render_sprites] now run build_sprite_frames.gd with SF_VARIANT=%s "
          "SF_LAYERS=%s" % (variant, FLASH_LAYER))


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
    print("[render_sprites] SET UnitVisual.canvas_height = %.2f on the character "
          "scene. foot_anchor is NOT derived from FLOOR_MARGIN and not from any "
          "single frame either -- a render prints it, as the mean foot row over "
          "the %r facings. The world origin (row %d) sits ABOVE the feet, so "
          "anchoring there sinks the character to the knee; the lowest row over "
          "all frames sits below every foot but one, so anchoring there floats "
          "it."
          % (CANVAS_HEIGHT, GROUNDING_POSE,
             round(FLOOR_MARGIN / CANVAS_HEIGHT * RESOLUTION)))


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
    parser.add_argument("--markers", action="store_true",
                        help="export muzzle marker positions only, rendering "
                             "nothing. Seconds, not minutes -- and it leaves "
                             "the PNGs untouched.")
    parser.add_argument("--marker-object",
                        help="muzzle locator; defaults to the mesh using the "
                             "%r material, else %r" % (MARKER_MATERIAL, MARKER_OBJECT))
    parser.add_argument("--rear-marker-object",
                        help="second locator further back along the bore, which "
                             "is what turns the muzzle POINT into a barrel "
                             "AXIS; defaults to %r or the %r material"
                             % (REAR_MARKER_OBJECT, REAR_MARKER_MATERIAL))
    parser.add_argument("--flash", action="store_true",
                        help="render the muzzle-flash OVERLAY layer only: one "
                             "frame of %s across the eight facings, on a canvas "
                             "%dx the body's so the flash cannot clip. Ignores "
                             "--poses; the pose is fixed." % (FLASH_POSE, FLASH_CANVAS_SCALE))
    parser.add_argument("--flash-object",
                        help="the flash mesh; defaults to the object using the "
                             "%r material, else %r" % (FLASH_MATERIAL, FLASH_OBJECT))
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

    if args.markers:
        rear = find_rear_marker(args.rear_marker_object)
        marker = find_marker(args.marker_object, exclude=rear)
        if marker is None:
            sys.exit("No muzzle marker found. Add a mesh using the %r material, "
                     "or pass --marker-object <name>." % MARKER_MATERIAL)
        export_markers(args.variant, os.path.abspath(args.out),
                       find_character(args.character), marker, rear,
                       bpy.data.objects.get(FALLBACK_BORE_OBJECT), only, dirs)
        return

    if args.flash:
        flash = find_flash(args.flash_object)
        if flash is None:
            sys.exit("No muzzle flash found. Give the flash object the %r "
                     "material, name it %r, or pass --flash-object <name>."
                     % (FLASH_MATERIAL, FLASH_OBJECT))
        render_flash(args.variant, os.path.abspath(args.out),
                     find_character(args.character), flash, dirs)
        return

    render_variant(args.variant, os.path.abspath(args.out),
                   find_character(args.character), only, dirs)


if __name__ == "__main__":
    main()
