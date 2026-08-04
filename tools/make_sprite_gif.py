"""Animate a rendered pose into one looping GIF per direction, for review.

  blender.exe -b -P tools/make_sprite_gif.py -- --variant merc --pose idle --out out

A 2 s breath cycle cannot be judged from stills, and the frame most likely to be
wrong -- the seam where the last frame meets the first -- is exactly the one a
contact sheet cannot show. This exists to look at that seam.

REVIEW ONLY. Nothing here feeds the game; `build_sprite_frames.gd` reads the
PNGs. The GIFs are disposable.

WHY A GIF ENCODER LIVES IN THIS REPO
------------------------------------
This machine has no ffmpeg, no ImageMagick, and no PIL, and Blender writes no
GIF container. Rather than add a dependency for a review artefact, the format is
written directly: GIF89a is a header, a palette, and LZW, and the whole thing is
about a hundred lines. numpy comes bundled with Blender and does the palette.

Frames are composited onto an opaque background rather than kept transparent:
GIF alpha is one bit, so a soft antialiased sprite edge would fringe. The
background matches the dark grey the game is mostly played in.
"""

import argparse
import os
import sys

import bpy
import numpy as np

RESOLUTION = 256
BACKGROUND = np.array([0.09, 0.10, 0.12], dtype=np.float32)

## Mirrors render_sprites.GAME_DIRECTIONS -- the eight the game actually reads.
DIRECTIONS = ["ne", "n", "nw", "w", "sw", "s", "se", "e"]

## Seconds one cycle occupies IN GAME. Mirrors build_sprite_frames.gd LOOP_TIME
## and ONE_SHOT_TIME, and the duplication is the same trade those files already
## make -- see the note at the top of build_sprite_frames.gd.
##
## The delay is derived from these rather than fixed, because frame count is a
## free art choice: the game plays a pose over its duration however many frames
## it was drawn in, so a 4-frame run and an 8-frame run both take 0.666 s. A
## hardcoded per-frame delay would show a 4-frame run at HALF SPEED, which is
## exactly the wrong thing to hand someone judging a cycle's cadence.
LOOP_TIME = {
    "run": 2 * 0.333, "walk": 1.4, "idle": 2.0,
    "crouch_idle": 1.6, "overwatch_hold": 1.6, "aim_hold": 1.6,
}
ONE_SHOT_TIME = {
    "melee": 1.20, "reload": 1.20, "throw_grenade": 1.00, "interact": 1.00,
    "hit_react": 0.47, "downed": 0.80, "alert_scream": 2.80,
}
DEFAULT_TIME = 1.6


def delay_centiseconds(pose, frame_count):
    """Per-frame delay in centiseconds -- the only unit GIF offers.

    Rounded to a whole centisecond, and clamped at 2: browsers silently rewrite
    delays under 0.02 s to 0.1 s, which would make a fast pose play five times
    too slow rather than slightly too fast.
    """
    duration = LOOP_TIME.get(pose, ONE_SHOT_TIME.get(pose, DEFAULT_TIME))
    return max(2, round(duration / max(1, frame_count) * 100.0))

PALETTE_SIZE = 256


def load_frames(src, variant, pose, direction):
    """Every frame for one direction, composited over BACKGROUND, top-down."""
    frames = []
    index = 0
    while True:
        path = os.path.join(src, "%s_%s_%s_%s_%d.png"
                            % ("body", variant, pose, direction, index))
        if not os.path.exists(path):
            break
        img = bpy.data.images.load(os.path.abspath(path))
        w, h = img.size
        # Blender hands back rows bottom-up; GIF wants them top-down.
        rgba = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)[::-1]
        bpy.data.images.remove(img)
        alpha = rgba[..., 3:4]
        frames.append(rgba[..., :3] * alpha + BACKGROUND * (1.0 - alpha))
        index += 1
    return frames


def median_cut(pixels, count):
    """Palette + per-pixel index, in one pass.

    Median cut rather than a fixed colour cube because the sprite is a smooth
    skin-tone gradient against flat grey -- a uniform cube spends most of its
    entries on colours the image never uses and visibly bands the one it does.

    The split assigns indices for free: every pixel already knows its box, so
    there is no nearest-colour search afterwards.
    """
    boxes = [np.arange(len(pixels))]
    while len(boxes) < count:
        # Split whichever box spans the most colour -- that is where banding
        # would otherwise show.
        widest, axis, extent = -1, 0, -1.0
        for i, box in enumerate(boxes):
            if len(box) < 2:
                continue
            block = pixels[box]
            spread = block.max(axis=0) - block.min(axis=0)
            if spread.max() > extent:
                widest, axis, extent = i, int(spread.argmax()), float(spread.max())
        if widest < 0:
            break
        box = boxes.pop(widest)
        order = box[np.argsort(pixels[box][:, axis], kind="stable")]
        boxes.append(order[: len(order) // 2])
        boxes.append(order[len(order) // 2:])

    palette = np.zeros((count, 3), dtype=np.uint8)
    indices = np.zeros(len(pixels), dtype=np.uint8)
    for i, box in enumerate(boxes):
        if len(box) == 0:
            continue
        palette[i] = np.clip(pixels[box].mean(axis=0), 0, 255).astype(np.uint8)
        indices[box] = i
    return palette, indices


def lzw_encode(indices, min_code_size):
    """GIF's LZW variant: LSB-first packing, code width growing 9 -> 12."""
    clear_code = 1 << min_code_size
    end_code = clear_code + 1

    out = bytearray()
    bit_buffer = 0
    bit_count = 0

    def emit(code, width):
        nonlocal bit_buffer, bit_count
        bit_buffer |= code << bit_count
        bit_count += width
        while bit_count >= 8:
            out.append(bit_buffer & 0xFF)
            bit_buffer >>= 8
            bit_count -= 8

    table = {}
    next_code = end_code + 1
    code_width = min_code_size + 1
    emit(clear_code, code_width)

    prefix = None
    for value in indices:
        value = int(value)
        if prefix is None:
            prefix = value
            continue
        key = (prefix, value)
        if key in table:
            prefix = table[key]
            continue
        emit(prefix, code_width)
        table[key] = next_code
        next_code += 1
        if next_code > (1 << code_width):
            code_width += 1
        # 12 bits is the format's ceiling: reset and start the table over.
        if code_width > 12:
            emit(clear_code, 12)
            table.clear()
            next_code = end_code + 1
            code_width = min_code_size + 1
        prefix = value

    if prefix is not None:
        emit(prefix, code_width)
    emit(end_code, code_width)
    if bit_count:
        out.append(bit_buffer & 0xFF)
    return bytes(out)


def write_gif(path, frames, width, height, delay_cs):
    palette, indices = median_cut(
        np.concatenate([f.reshape(-1, 3) for f in frames]) * 255.0, PALETTE_SIZE)
    per_frame = indices.reshape(len(frames), height * width)

    with open(path, "wb") as fh:
        fh.write(b"GIF89a")
        # Logical screen descriptor. 0xF7 = global colour table, 256 entries.
        fh.write(width.to_bytes(2, "little") + height.to_bytes(2, "little"))
        fh.write(bytes([0xF7, 0, 0]))
        fh.write(palette.tobytes())
        # NETSCAPE2.0 is the only way to say "loop forever" in this format.
        fh.write(b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00")

        for frame in per_frame:
            # Graphic control extension: disposal 1 (leave in place), no
            # transparency -- every frame is fully opaque and full-size.
            fh.write(b"\x21\xF9\x04\x04")
            fh.write(delay_cs.to_bytes(2, "little") + b"\x00\x00")
            fh.write(b"\x2C\x00\x00\x00\x00")
            fh.write(width.to_bytes(2, "little") + height.to_bytes(2, "little"))
            fh.write(b"\x00\x08")
            data = lzw_encode(frame, 8)
            for start in range(0, len(data), 255):
                chunk = data[start:start + 255]
                fh.write(bytes([len(chunk)]) + chunk)
            fh.write(b"\x00")
        fh.write(b"\x3B")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(prog="make_sprite_gif")
    parser.add_argument("--variant", required=True)
    parser.add_argument("--pose", required=True)
    parser.add_argument("--src", default="assets/sprites")
    parser.add_argument("--out", default="out")
    parser.add_argument("--directions", default=",".join(DIRECTIONS))
    parser.add_argument("--delay-cs", type=int, dest="delay_cs",
                        help="override per-frame delay in centiseconds")
    parser.add_argument("--prefix", default="",
                        help="filename prefix, for keeping variants side by side")
    args = parser.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    for direction in args.directions.split(","):
        frames = load_frames(args.src, args.variant, args.pose, direction)
        if not frames:
            print("[gif] no frames for %s -- skipped" % direction)
            continue
        height, width, _ = frames[0].shape
        delay_cs = args.delay_cs or delay_centiseconds(args.pose, len(frames))
        path = os.path.join(args.out, "%s%s_%s_%s.gif"
                            % (args.prefix, args.variant, args.pose, direction))
        write_gif(path, frames, width, height, delay_cs)
        print("[gif] %s: %d frames, %dx%d, %d ms/frame, cycle %.2f s -> %s (%.0f KB)"
              % (direction, len(frames), width, height, delay_cs * 10,
                 delay_cs * len(frames) / 100.0, path,
                 os.path.getsize(path) / 1024.0))


if __name__ == "__main__":
    main()
