# Mixamo animation pipeline + higher-fidelity characters

*Written 2026-07-27. Supersedes §4 (run animation rework) and §5 (animation
tooling) of `character-art-plan.md`. The model-fidelity phases of that document
(§3 Phase A–F) survive intact and are orthogonal to this.*

---

## 0. The core idea

Right now the mesh, the rig, and every animation are all produced by one script
against one bespoke skeleton. That couples them: any proportion change
invalidates the poses, and every new clip is hand-authored joint angles.

The plan is to **standardise on the Mixamo skeleton (`mixamorig`) as the
project's rig contract.** Once the game character is skinned to that skeleton:

- Any Mixamo clip drops straight on, no retargeting layer.
- The mesh can be replaced later — procedural, purchased, sculpted — and every
  animation still works, as long as the new mesh is skinned to the same rig.

Fidelity and animation become independent problems. That is the actual win here.

---

## 1. Three sub-problems

| # | Problem | Where it's solved |
|---|---|---|
| A | Get Mixamo clips into Godot as one reusable AnimationLibrary | Blender merge script → single GLB |
| B | Get a good-looking mesh onto the `mixamorig` skeleton | Model source decision (§4) |
| C | Rewire game code that assumed the old rig and old clip timings | `unit_visual.gd`, `character_base.tscn`, `unit.gd` |

C is the one that's easy to underestimate. See §6.

---

## 2. Phase 0 — de-risking spike (do this first, ~1 hour)

Do **not** start on the real character. Take a throwaway Mixamo character and
two clips, and push them all the way to a unit moving in-game. The point is to
discover the format friction cheaply. Known unknowns to settle here:

1. **FBX scale.** Mixamo FBX exports in centimetres — 100× too big. Blender
   import needs an explicit 0.01 scale + apply.
2. **Colons in bone names.** Bones are `mixamorig:Hips`. Godot animation track
   paths are themselves colon-delimited (`Skeleton3D:BoneName`). Verify whether
   Godot's glTF importer sanitises this, or whether the Blender script should
   strip the `mixamorig:` prefix on both character and clips. **Recommendation:
   strip it** — costs three lines, removes the question, and gives clean
   NodePaths (`RightHand`). Keep the rest of the Mixamo names as-is (`Spine1`,
   `LeftArm`) so Godot's BoneMap auto-detect still recognises the scheme if it's
   ever needed.
3. **Loop flags.** Mixamo clips arrive unlooped. Godot's importer honours a
   name suffix convention for loops; confirm which, else set loop per clip in
   the import dock and save the `.import` file.
4. **Multiple actions in one GLB.** Confirm Blender's glTF exporter in "actions"
   mode emits one Godot Animation per action, and that `dump_glb.gd` sees them
   all.
5. **Bind pose vs. rest.** Confirm the character's rest pose after import matches
   what the clips expect (no exploded skeleton).

Exit criterion: a Mixamo character in `main.tscn` playing an idle and a run,
verified with `dump_glb.gd`.

### 2.1 Phase 0 results — RUN 2026-07-27, all five settled

Character `Ch35` (T-Pose.fbx) + Rifle Idle / Rifle Run / Rifle Aiming Idle.
Built by `tools/build_anims.py`, verified in Godot 4.7.1, previewed with
`tools/preview_anim.gd`.

1. **Scale — non-issue.** Blender's FBX importer leaves the armature *object* at
   scale 0.01 but world dimensions come out at 1.829 m. Correct through export
   and import; no manual scaling needed. Don't "fix" the 0.01 — applying it
   would rescale the bone-local location channels and break every clip.
2. **Colons — stripped, and worth it.** 65 bones, `mixamorig:` removed on both
   character and clips. Godot's Skeleton3D shows clean `Hips` / `Spine1` /
   `RightHand`. Bone sets matched exactly (`missing=0 surplus=0`) across all
   three clips, which is the green light for the whole approach.
3. **Loop flags — the `-loop` suffix works.** Godot's glTF importer strips the
   suffix and sets `loop_mode=1`. No `.import` editing needed for looping clips.
4. **Multi-action export — ACTIONS mode is a trap.** It silently exported 2 of 3
   clips, dropping whichever action was assigned as active. Blender 4.4 moved
   actions to a slotted system and an action lifted off a deleted armature has no
   slot binding. **Fix: one NLA track per action, `export_animation_mode=
   "NLA_TRACKS"`.** This is the single most important finding — the failure mode
   is silent, and the build log was reporting success.
5. **Bind pose — clean.** Run cycle renders correct contact/passing/push-off
   with no skeleton explosion or mesh tearing.

**Later finding — Mixamo's prefix is not stable.** Most clips use
`mixamorig:`, but some downloads come back as **`mixamorig1:`**. `mixamorig:` is
not a substring of `mixamorig1:`, so the original literal string strip left those
bones prefixed. Every track in eight clips then pointed at a bone the character
did not have — and they imported, exported, and played, moving nothing. The
prefix is now a regex (`mixamorig\d*:`), and a clip whose tracks name unknown
bones is a **hard build error**, not a warning. Third silent-success failure of
this pipeline; the pattern is clear enough that new checks should default to
fatal.

**Bonus finding — root motion, measured.** `Rifle Run` was downloaded without
In Place and carries **2.891 m of forward hip travel over its 0.667 s cycle =
4.34 m/s**. Two consequences:

- `build_anims.py` now measures and reports net horizontal Hips travel on every
  clip, and `--strip-root` removes it by subtracting the linear trend (keeping
  sway and per-frame acceleration). A silently-travelling clip can't happen
  again.
- **4.34 m/s is within 4% of `unit.gd`'s existing `MOVE_SPEED = 4.5`.** §6.4's
  foot-skate constraint is therefore very nearly satisfied for free at the
  current speed. This directly contradicts `character-art-plan.md` §4.2's
  proposal to drop to 2.4 m/s — that number was derived for a hand-authored
  cycle that no longer exists. Anyone wanting the slower, weightier gait now
  needs a different *clip*, not a different speed.

Two pieces of infrastructure fell out of the spike:

- `tools/preview_anim.gd` — renders N evenly spaced frames of a clip as one
  horizontal strip, loading a GLB directly without booting the game. This is
  `character-art-plan.md` §5.1's "single most important missing tool", built.
- `project.godot` gained `[filesystem] import/blender/enabled=false`. Godot's
  native `.blend` importer needs an editor setting that cannot be set headless,
  so it errored on every `assets/*.blend` and **aborted the entire import queue**
  — leaving new `.glb` files unimported with no error naming them. Cost about
  twenty minutes to find; worth knowing about.
- `art_src/` (with `.gdignore`) now holds source FBX. The character FBX alone is
  142 MB and Godot was scanning it as an importable asset.

---

## 3. The asset pipeline (steady state)

```
Mixamo web  ──►  *.fbx (per clip)  ──►  tools/build_anims.py  ──►  assets/soldier.glb
                                              (Blender, headless)          │
assets/<character>.fbx (skinned, mixamorig) ──┘                            ▼
                                                              Godot AnimationPlayer
```

### 3.1 Download settings on Mixamo

Per clip, these matter:

- **Format:** FBX Binary (.fbx).
- **Skin: "Without Skin"** for every animation — you already have the mesh, and
  this makes each file ~100 KB instead of ~10 MB. Download **with** skin exactly
  once, for the character itself.
- **In Place: ON** for all locomotion (`run`, `walk`, `crouch_walk`). Units are
  moved by grid code; root motion would fight it and cause drift.
  - **Exception: death and hit-reaction.** These genuinely displace the body.
    In-Place on a death makes it slide back under its own feet. Download these
    *without* In Place and accept the offset, or bake the hip translation in the
    Blender step. Decide when you see them.
- **FPS: 30.** 60 doubles file size for detail Godot resamples away anyway.
- **Keyframe reduction: none.** Reduction eats the sharp contact frames, which
  is exactly the "weight" read `character-art-plan.md` §4.1 is chasing.

### 3.2 `tools/build_anims.py` (new)

Headless Blender, following the existing `tools/*.py` conventions:

1. Import `assets/character_rigged.fbx` (scale 0.01, apply). This is the base
   armature + mesh.
2. Strip the `mixamorig:` prefix from every bone.
3. For each `assets/anims/*.fbx`:
   - import (armature only, no mesh),
   - strip prefix on the imported armature so bone names match,
   - lift its action, rename to the **game clip name** (`run`, `aim_hold`, …)
     via a `CLIP_MAP` dict at the top of the file,
   - assign to the base armature, set `use_fake_user = True`,
   - delete the imported armature.
4. Apply per-clip edits declared in a table: trim ranges (see `shoot_recoil`,
   §5), loop flags, playback speed.
5. Export `assets/soldier.glb` with animation mode = Actions.

The `CLIP_MAP` dict is the whole point — it's the one place the Mixamo catalog
name meets the game's clip name, so re-sourcing a clip is a one-line change.

> **Superseded 2026-07-28 by §10.** `CLIP_MAP` and every other per-clip table
> now live inside a `Profile`, one per character, selected with `--profile`. The
> claim above survives intact — it is still one place per character — but the
> dict is no longer at module scope.

Everything stays reproducible from a checked-in command, matching how the rest
of `tools/` works. The Mixamo *downloads* are the one manual step; commit the
FBX files so a rebuild never needs the website.

---

## 4. Getting a higher-fidelity mesh onto that rig

Four routes, roughly ascending in effort and ceiling.

### Option 1 — Mixamo's own character roster
Free, ~70 characters, already skinned to `mixamorig`, textured, game-budget
poly counts. **Zero rigging work.**

- **For:** Instant. Perfect for Phase 0, and a genuine fallback.
- **Against:** Generic style. Nothing in the roster matches the gas-mask /
  olive-pouch / red-lens operative direction. Silhouette recognisability was the
  whole point of that art brief.

### Option 2 — Auto-rig the soldier you already have
You already built `assets/soldier_character_only_tpose.blend` — which is
*precisely* the input Mixamo's auto-rigger wants. Export the mesh to FBX, upload,
place the rig markers, download back a `mixamorig`-skinned version.

- **For:** Keeps the art direction and every hour spent in `gen_soldier.py`.
  Cheapest path to "Mixamo animations on *our* character."
- **Against:**
  - The auto-rigger works best on one connected mesh. The generated model is
    dozens of separate prisms; needs a `join` pass first, and floating pouches
    may get odd weights. Budget cleanup time.
  - **Does not increase fidelity by itself.** It's the boxy model on a better
    skeleton. Fidelity still has to come from `character-art-plan.md` Phase A–D
    (bevels, dome helmet, UV + AO bake) — which this unblocks, since you'd no
    longer be re-authoring animations after each proportion change.
  - Introduces a manual web step into a fully-scripted pipeline. Mitigate by
    committing the returned rigged FBX as a source artifact, so rebuilds are
    still one command.

### Option 3 — Free third-party model, re-rigged
Sketchfab (filter to CC0/CC-BY + downloadable), Quaternius, KayKit, itch.io.
Sci-fi soldiers exist at genuinely higher fidelity than anything generated code
will produce.

- **For:** Biggest fidelity jump per hour spent.
- **Against:** Licence diligence is on you and must be tracked per asset.
  Quality is wildly uneven. Most aren't `mixamorig`, so they need the same
  auto-rig trip as Option 2, or Godot's `BoneMap` + `SkeletonProfileHumanoid`
  retargeting. Finding one that matches the art brief is a search problem with
  no guaranteed hit.

### Option 4 — Build it properly *(CHOSEN, 2026-07-27)*
MakeHuman (free) for a clean humanoid base body → model the gear on top in
Blender → auto-rig via Mixamo → texture with the Phase C AO/grime bake.

- **For:** Highest ceiling. Hits the art brief exactly, because you authored it.
- **Against:** Real modelling time, and the honest limit from
  `character-art-plan.md` §7 still applies — I can generate convincing AO,
  grime and edge wear procedurally, but I can't hand-paint or source photo
  textures.

### Decision

**Phase 0 spike uses Option 1** (a throwaway Mixamo roster character — it is
purely a format test, and using anything else wastes the cheapness). **The real
character is Option 4.**

Consequence worth stating plainly: this is the longest of the four routes. The
sequencing in §9 is built so that the animation pipeline lands and works
*first*, on a stand-in body — so the MakeHuman modelling work happens against a
game that already animates correctly, rather than blocking it.

### 4.1 Option 4, concretely

**Use MPFB2 (MakeHuman Plugin For Blender), not standalone MakeHuman.**
Rationale: you already have portable Blender 4.5.12, MPFB2 runs the whole
MakeHuman system inside it as an addon, and it skips a separate ~500 MB
application install — which matters at 2.3 GB free. It also keeps the body
generation inside the same Blender scripting environment the rest of `tools/`
already uses.

Steps:

1. **Base body.** MPFB2 → generate a humanoid, dial proportions toward the brief
   (heavier, broader than default; the operative reads as bulky). Export a
   mid-density mesh — the highest subdivision level is for film, not this.
2. **Gear on top.** Model helmet, mask + snout + filter disc, vest, pouches,
   knee/elbow pads, boots, holster in Blender as separate objects over the body.
   This is where `character-art-plan.md` §1.2's shape corrections get built for
   real instead of approximated with prisms.
   - Delete or hide the body geometry underneath fully-covering gear before
     export — hidden interior faces cost tris and confuse the AO bake.
3. **Join + T-pose.** Join to a single mesh, arms out. `tools/make_tpose.py`
   already encodes what a valid T-pose means for this character; reuse its
   angles as the target.
4. **Auto-rig.** Export FBX → Mixamo auto-rigger → download back skinned to
   `mixamorig`. MPFB2's own rig options (Default / Game engine / Rigify) are
   *not* Mixamo-named, so don't rig in MPFB2 — go through the auto-rigger and
   let it own the skeleton. This is the single most important constraint in the
   whole plan: **the skeleton must come from Mixamo, not from anywhere else.**
5. **Texture.** UV unwrap, then `character-art-plan.md` Phase C — AO bake in
   Cycles, procedural grime, edge wear, panel lines.

Licensing: the MakeHuman base mesh and MPFB2's bundled assets are CC0. Record
this in `docs/asset-licences.md` alongside the Mixamo terms (§7).

Risk specific to this route: **auto-rigger weight quality on a heavily
gear-layered mesh.** Bulky rigid props (helmet, pouches, knee caps) skinned by
an automatic solver will smear across joints. Expect a weight-painting cleanup
pass, and consider keeping genuinely rigid props as separate objects weighted
1.0 to a single bone rather than letting the solver blend them.

---

## 5. Clip mapping

Game clips (from `unit_visual.gd`) against Mixamo search terms. **Names are
search hints, not verified catalogue entries** — confirm while browsing.

| Game clip | Mixamo search | Notes |
|---|---|---|
| `idle` | "rifle idle" | Loop. |
| `run` | "rifle run" | Loop, In Place. Stride must be measured — see §6.4. |
| `run_stop` | "rifle run to stop" | One-shot settle on arrival, NOT a loop. **In Place is mandatory here, not optional** — see below. |
| `crouch_idle` | "crouch idle" / "crouching" | Rifle-holding variant may not exist; may need an upper-body blend. |
| `overwatch_hold` | "rifle aiming idle" | Loop. |
| `aim_hold` | "rifle aiming idle" | Can be the same clip as overwatch. |
| `shoot_recoil` | "firing rifle" | **Needs trimming.** Mixamo ships a continuous firing loop; the code wants one ~0.13 s kick replayed per round. Cut a single recoil in the Blender step. |
| `reload` | "reloading" | |
| `melee` | "rifle butt" / "kick" | Currently an alien-only guess at 0.55 s. |
| `throw_grenade` | "throw" | |
| `interact` | "button push" / "picking up" | |
| `hit_react` | "hit reaction" | Has translation — see §3.1. |
| `downed` | "death from front" / "dying" | Has translation. Must hold its last frame; `play_action` already handles this. |

### 5.0 Sourced 2026-07-27 — 13 clips, 2 gaps

Built and verified in Godot. `CLIP_MAP` in `tools/build_anims.py` is the record;
this is the summary.

| Clip | Source | Length | Notes |
|---|---|---|---|
| `idle` | Rifle Idle | 10.67s | loop |
| `run` | Rifle Run **In Place** | 0.70s | loop, no root motion |
| `crouch_idle` | Idle Crouching | 2.13s | loop |
| `aim_hold` + `overwatch_hold` | Rifle Aiming Idle | 3.13s | loop; one source, two clips |
| `run_stop` | Rifle Run To Stop | 1.50s | travelled 2.82m, stripped `hold` |
| `stand_to_crouch` | Stand To Crouch | 1.53s | |
| `crouch_to_stand` | Crouch To Standing With Rifle | 1.13s | |
| `shoot_recoil` | Firing Rifle | 0.37s | **trimmed** from 1.17s, see §5.4 |
| `reload` | Reloading | 3.33s | |
| `throw_grenade` | Toss Grenade | 3.23s | |
| `hit_react` | Hit Reaction | 0.47s | |
| `downed` | Dying | 4.43s | travels 0.34m, deliberately kept |

**Still missing — `interact`.** No suitable Mixamo clip found. `unit_visual.gd`
handles it: `play_action` falls back to a timer of `FALLBACK_TIME` length and the
unit holds its stance, which is exactly the behaviour that existed before any of
this. Revisit when browsing Mixamo for something else — search terms to try are
"button push", "picking up".

**`melee` — sourced 2026-07-28, on the swarm, not the soldier.** It was always
alien-side; §10 built the alien. The soldier still has no melee clip and does not
need one, since nothing in `player_unit.gd` swings.

Two clip lengths are much longer than the placeholders they replace: `reload`
3.33s vs a 1.20s stand-in, `downed` 4.43s vs 0.80s. Turn pacing will feel
noticeably slower. That is a game-feel judgement to make on screen, not a bug.

### 5.4 `shoot_recoil` — why it is trimmed

"Firing Rifle" is **one shot with a long settle**, not a burst loop. Measured by
dumping per-frame right-hand displacement: the kick runs f4–f13, peaks at f8,
and the remaining 23 frames are low-amplitude drift.

That mattered more than it looks. `unit_visual.gd` replays this clip from frame 0
once per round on a 0.11s cadence, and the source clip opens with **three dead
frames** before the kick starts. Untrimmed, those three frames are the only part
a burst would ever reach — the weapon would not visibly move during sustained
fire, and nothing would have errored.

`TRIM` in `build_anims.py` keeps f4–f14 and shifts to frame 1, giving a 0.333s
clip that opens on the kick. Any future firing clip needs the same check: **a
clip that starts with a wind-up is silently wrong under replay.**

Gaps to expect: `overwatch_hold` and `interact` were the predicted misses.
`overwatch_hold` was solved by pointing it at the same source as `aim_hold` —
overwatch *is* a held aim, and `CLIP_MAP` now accepts a tuple of target names for
exactly this.

### 5.1 Why `run_stop` must be In Place at source

`--strip-root` removes root motion by subtracting the **linear** trend between
the first and last key. That is correct for a cyclic run, where forward velocity
is roughly constant across the loop.

A deceleration clip is the opposite: it travels fast at the start and stops at
the end. Subtracting a straight line from a decelerating curve leaves the
character drifting *forward* early in the clip and *backward* late in it — a
visible slide in both directions, worse than the problem it solves. So
`--strip-root` is not a fallback for this clip.

If Mixamo does not offer In Place for the stop clip, the alternative is to play
it during the final tile step and let its own root motion carry that last
metre — real work, and a different shape of change from everything else here.
Check the checkbox exists before assuming this clip is cheap.

### 5.3 Turn clips — wanted, but NOT the same shape of job

Turning is the one remaining animation gap where facing changes visibly cheat:
`face_toward` tweens `rotation:y` over 0.18s with the feet planted, so the whole
body pivots as a rigid object. Mixamo turn clips would fix that. They are also
**materially harder to wire than everything above**, and worth understanding
before downloading.

**The blocker: turn clips carry root *rotation*.** Every clip so far needed root
*translation* removed, which `--strip-root` does. A turn clip rotates the
character through its Hips quaternion instead. If the clip rotates 90° and
`face_toward` also tweens 90°, the unit ends up 180° off. So one of two things
has to happen:

1. **Strip the rotation drift** in `build_anims.py`, the same way translation is
   stripped, and let `face_toward` keep owning the yaw. Consistent with the rest
   of the pipeline, and handles arbitrary angles. Costs a new
   quaternion-unwinding routine — fiddlier than the translation case, which is
   plain subtraction.
2. **Let the clip own the rotation** and stop tweening. Simpler, but only lands
   on the clip's authored angle, so arbitrary target angles don't work.

(1) is the right answer, and it is a real piece of work rather than a
`CLIP_MAP` line.

**Second issue: authored angle vs. requested angle.** A clip authored for 90°
played across a 30° turn crosses the feet three times further than the body
rotates. Mitigation is to trigger turn clips only above a threshold (~60°) and
keep the existing snap below it, scaling tween duration by
`delta / authored_angle`.

**What to download when the time comes:** rifle-holding **left and right 90°**
turns, plus **180°** if it exists. Left and right must be separate clips — a
mirrored 90° is not the same motion, and picking by `sign(delta)` is the whole
selection logic.

Recommendation: do this *after* the MakeHuman character lands. It is polish on a
system that currently works, and it is the only item here that needs new
machinery rather than new data.

### 5.5 In-game swap — done 2026-07-27, with one open problem

`character_base.tscn` now instances `soldier_mixamo.glb`. The unit renders at
correct scale, animates, and the flashlight works. Run it with:

```
godot --path . --script res://tools/screenshot.gd -- --auto   # SHOT_CLOSEUP/SHOT_SIDE
godot --path .                                                # or just play it
```

**Scale compensation.** The `Rig` node carries scale 0.01 with bones in
centimetres, so everything parented to a bone inherits it. `_debug_aim.gd`'s
solve originally orthonormalized the mount basis, which threw that scale away
and rendered the rifle at 1/100 size. It now uses the raw inverse, which carries
the 100x back, and expresses the grip offset in the skeleton's centimetres. This
is why `character_base.tscn`'s mount basis has values around 88 and 98 rather
than around 1 — deliberate, not a corrupted matrix.

**RESOLVED 2026-07-27 — see §5.6.** The drift below is what the fixed
single-bone mount produced; it is kept as the measurement that motivated the
two-bone mount.

| Clip | Barrel pitch | Barrel yaw |
|---|---|---|
| `aim_hold` | −0.0° | +0.0° |
| `crouch_idle` | −1.4° | −18.8° |
| `run` | +21.2° | −88.6° |
| `idle` | +43.0° | −72.0° |

This is the risk called out in §8 as "mocap hands aren't consistent", now
measured. Mixamo clips are separate takes with no rifle in the actor's hand, so
wrist roll varies between them. `aim_hold` and `crouch_idle` agree; `idle` and
`run` do not.

It is **not only cosmetic** — the flashlight rides the muzzle, and which tiles it
lights drives alien detection (Sec 5.2). A 43°-up flashlight in idle changes
what the unit can see.

Options, cheapest first:

1. **Per-clip corrective offsets** — a table of small `Transform3D` nudges keyed
   by clip, applied to the mount. Data, not machinery; `_debug_aim.gd` can
   generate the entries by solving each clip in turn. Recommended.
2. **Solve on the clip that matters most** and accept error elsewhere. `idle` is
   the most-seen pose, but `aim_hold` is the one where the barrel direction is
   load-bearing for shots.
3. **Constrain the hand in Blender** at build time, forcing a consistent grip
   across every clip. Most correct, most work.

### 5.6 Facing, grip and aim — fixed 2026-07-27

Three problems that turned out to be two causes.

**1. The model faced backwards.** Measured shoulder-forward in `idle` was
`(+0.01, +1.00)` — the mesh faced **+Z**, and Godot (and all the unit code)
uses **−Z**. Mixamo authors facing −Y in Blender, which glTF maps to +Z.

Fixed with a 180° yaw on the `soldier` node in `character_base.tscn`. The
movement and aim code needed **no changes** — `_step_to` already turned toward
each tile and `face_toward` was already awaited before shooting. They only
looked wrong because the mesh was reversed.

The correction belongs at the asset boundary, not as a sign flip in
`_yaw_toward`: every consumer of facing (LOS, the flashlight cone) reads the
unit node rather than the mesh, so negating downstream would spread one asset
quirk across gameplay. It also has to sit on `soldier` and not `Visual`, because
the weapon mount hangs off the skeleton below and must inherit it.

**2. The rifle was mounted to one bone.** A `BoneAttachment3D` on the right hand
takes barrel direction entirely from that bone's roll, and Mixamo clips are
separate mocap takes with no rifle in the actor's hand — hence the 43° spread.

Replaced with `scripts/weapon_mount.gd`, which derives the weapon transform from
**both** hands: right hand supplies position, the vector to the left hand
supplies barrel direction, and the right hand's +X axis supplies roll (measured:
`dot(world_up) = +0.948` against `+0.610` for the next best candidate axis).
Grip-to-handguard is a real, stable feature of any rifle pose, so it survives
mocap variance that one wrist does not.

Two consequences worth knowing:

- The hand gap is **not** constant — 0.468 m in `aim_hold`, 0.320 m in `idle`.
  A rigid rifle cannot pin both hands, so the right hand wins on position and
  the left only steers. The left hand slides along the handguard by up to
  ~0.15 m, which is within a handguard's length and reads as normal handling.
- Because the mount writes `global_transform`, the Rig node's 0.01 scale no
  longer needs compensating in the scene. The 100x mount basis is gone and the
  rifle is plain identity.

**3. Mixamo's aim does not point along the character's forward.** The
grip-to-handguard axis in `aim_hold` sat **31.6° to the character's left**, so
with `face_toward` turning the unit at the target every shot would have left the
barrel 31.6° off.

Fixed at build time by `ROOT_YAW` in `build_anims.py`, which yaws the Hips
quaternion for `aim_hold`/`overwatch_hold`. This is not a fudge: a bladed rifle
stance genuinely has the body turned relative to the aim line, so rotating the
body until the weapon lines up with forward is the anatomically correct reading.
`aim_hold` now measures **pitch +1.0, yaw +0.0** while still being held in both
hands.

The sign was determined empirically — the first attempt doubled the error to
−63.2° instead of cancelling it. Re-verify with `tools/_debug_aim.gd` after any
change here.

**Flashlight decoupled.** `idle` and `run` still hold the rifle 85° and 80°
across the body — that is the mocap carry position and it looks right. But a
muzzle-parented light then sprays sideways while the unit plainly faces
forward, contradicting the tiles `lighting_manager.gd` says are lit.
`scripts/aimed_light.gd` sets `top_level` and re-imposes the unit's orientation
each frame, so the beam still leaves the barrel but always agrees with the
simulation.

### 5.2 Arrival settle — wiring (done 2026-07-27)

`UnitVisual.play_stance_exit(action, next)` plays a one-shot bridging the current
stance into the next one. `unit.gd`'s `move_along` calls it with
`RUN_STOP -> IDLE` on arrival.

Two properties worth preserving if this is ever refactored:

- **A missing clip costs zero time.** It falls through to `set_stance(next)`,
  which is byte-for-byte the old behaviour. That is why this could ship before
  the clip was sourced.
- **Grid state settles before the animation plays.** The unit owns its
  destination tile from the instant it arrives, so the settle is purely
  cosmetic and no gameplay code waits on it. Only `moved` is emitted late, on
  purpose — that signal means "done moving", and mid-settle it is not.

---

## 6. Code impact — the underestimated part

### 6.1 `scenes/character_base.tscn`
- `RifleMount.bone_name`: `"hand.R"` → `"RightHand"`, and `bone_idx` changes.
- **The solved grip `Transform3D` on line 30 must be re-solved.** The long
  comment there explains why it can't be derived by hand — that reasoning still
  holds, and the new skeleton's hand-bone axes are different again. Re-run
  `tools/_debug_aim.gd` against the new `aim_hold` clip.
- The `Muzzle` offset is rifle-local and survives unchanged.
- The rifle pose in Mixamo's rifle clips is a *particular* grip. Solve against
  `aim_hold` as before, then eyeball `reload` and `run` — if the rifle detaches
  visibly in those, the answer is a second mount or a small per-clip offset, not
  a re-solve.

### 6.2 `scripts/unit_visual.gd`
- `FALLBACK_TIME` durations: remeasure against real clip lengths.
- `FOOTSTEP_OFFSET` / `FOOTSTEP_GAP`: hard-coded to the 0.667 s generated run
  loop. Must be remeasured off the Mixamo run.
- `RAISE_TIME` / `BURST_CADENCE` / `SETTLE_TIME`: tuned around a 0.13 s authored
  kick. Retune once `shoot_recoil` is trimmed.
- Clip-name constants: keep them. `CLIP_MAP` in the build script renames Mixamo
  actions to these, so this file shouldn't need to learn any Mixamo vocabulary.

### 6.3 `tools/gen_soldier.py`
Roughly lines 580–750+ are pose and action authoring — that all retires. Mesh
generation stays and remains the Phase A–D workspace. This is a large, clean
deletion, but do it *after* the Mixamo clips are confirmed working, not before.

### 6.4 `scripts/unit.gd` — foot skate
The §4.2 constraint from `character-art-plan.md` doesn't go away, it inverts:
stride is now fixed by the Mixamo clip, so `MOVE_SPEED` must be derived from it
rather than chosen.

```
MOVE_SPEED = stride_per_step × 2 / cycle_time
```

Measure stride off the imported clip. If the resulting speed plays badly, drive
`anim.speed_scale` from actual speed instead — same fallback as before.

> **Updated 2026-07-28 (§10.4).** `MOVE_SPEED` is now `@export var move_speed`,
> per unit rather than per game, because two characters cannot share one derived
> speed. The soldier's stays 4.5. The fallback above is no longer hypothetical:
> the swarm needed *both*, since its clip is authored at 0.32 m/s and no single
> number satisfies the clip and the turn pacing at once.

### 6.5 Obsoleted tooling
`tools/add_ik_controls.py`, `tools/bake_run_ik.py`, `tools/verify_ik_controls.py`,
`tools/verify_run_ik.py` — Mixamo clips are already foot-planted by mocap, so the
IK rig has no remaining job. Recommend deleting rather than maintaining;
they're recoverable from git. `dump_glb.gd` and `screenshot.gd` stay valuable.

---

## 7. Licensing

Mixamo is free with an Adobe account, and its characters and animations are
usable royalty-free in commercial projects. The restriction that matters: you
can't redistribute the animation files *as animation assets*. Shipping them
baked into a game is exactly the intended use. Any Option 3 third-party model
needs its own licence recorded — start a `docs/asset-licences.md` the moment the
first one lands.

---

## 8. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Auto-rigger smears weights across the gear-layered MakeHuman mesh | High | Join to one mesh first; weight-paint cleanup pass; keep rigid props single-bone-weighted (§4.1) |
| MakeHuman route is long, and blocks nothing else if sequenced right | Medium | §9 lands the animation pipeline on a stand-in body first |
| Mixamo clip set doesn't cover `overwatch_hold` / `interact` | Medium | Hold a frame of a neighbouring clip |
| Rifle grip drifts across clips (mocap hands aren't consistent) | Medium | Solve against `aim_hold`; per-clip offset if needed |
| Manual web download step breaks reproducibility | Low | Commit the FBX files; rebuild never touches the website |
| Mixamo's animation style (grounded modern-military mocap) fights the "hunched, lumbering, weighty" brief | Medium | Real tension — mocap gives realism, not stylisation. Partly recoverable via `speed_scale` and a spine offset layer. Judge it once it's on screen. |
| **Disk space: 2.3 GB free on C:** | Medium | FBX clips are small (~100 KB without skin), but Blender temp files aren't. Clear space before starting. |

---

## 9. Order of work

The animation pipeline lands first, on a stand-in body. The MakeHuman character
then drops into a game that already animates correctly — so modelling time never
blocks gameplay work, and the mesh swap at step 7 is a one-file change.

1. **Phase 0 spike** (§2) — throwaway Mixamo roster character, two clips,
   in-game. Settles all five format unknowns.
2. `tools/build_anims.py` with a two-entry `CLIP_MAP`.
3. Download the full clip set (§5); expand `CLIP_MAP`; trim `shoot_recoil`.
4. Re-solve the rifle mount (§6.1); retune timings (§6.2, §6.4). **Against the
   stand-in.** Everything gameplay-facing now works.
5. Delete the retired animation authoring (§6.3) and IK tooling (§6.5).
6. **MakeHuman character build** (§4.1) — body, gear, T-pose, auto-rig, texture.
   Runs in parallel with nothing else being blocked.
7. Swap the mesh in. Re-solve the rifle mount once more (proportions changed);
   re-derive `move_speed` only if stride changed, which it shouldn't — same
   clips, same skeleton.
8. **The swarm** (§10) — second character, entirely additive. Off the critical
   path above, and it validated §0's thesis before the MakeHuman work starts.

Note that steps 4 and 7 both re-solve the rifle mount. That's expected and cheap:
`tools/_debug_aim.gd` regenerates the line. It is not duplicated work, it's the
cost of the mount being solved rather than derived.

---

## 10. The swarm — second character, same pipeline (done 2026-07-28)

The zombie fodder of `SwarmUnit`, built from `art_src/T-Pose-Zombie.fbx` (Mixamo
`Ch10`) plus seven clips in `art_src/anims/swarm_anims/`. Run it with:

```
blender -b -P tools/build_anims.py -- --profile swarm --strip-root
godot --headless --path . --import
```

**The thesis in §0 held.** The whole point of standardising on `mixamorig` was
that a second character would be data, not work. Bone sets matched exactly
(`missing=0 surplus=0`, 65 bones) on every clip against a character downloaded
separately, months apart, from the same site. No retargeting layer, no BoneMap,
no clip-by-clip fixing. The build script needed a refactor to hold two
characters' worth of tables, and after that the swarm was a `Profile` literal.

### 10.1 Profiles — why the tables moved

`CLIP_MAP`, `LOOPING`, `TRIM`, `STRIP_MODE`, `ROOT_YAW` and `SUPPORT_LOCKED` were
module-level, which was correct for one character and actively dangerous for two.
Every one of them holds a number **measured against a specific body**: the −31.6°
aim yaw is where a rifle sits in a bladed stance, and the support lock is a rifle
grip solved on a rifle-carrying skeleton. Applied to a zombie that holds nothing,
they would have exported, imported and played, moving the wrong things — this
pipeline's signature failure. They are now fields on a `Profile`, selected by
`--profile`, so a correction cannot reach a character it was not measured on.

The soldier rebuilds byte-for-byte in behaviour after the refactor: 13 clips, same
lengths, same yaw, same per-clip support-lock displacements as §5.0 recorded.

### 10.2 Clips

| Game clip | Source | Length | Notes |
|---|---|---|---|
| `idle` | Zombie Idle | 4.37s | loop |
| `idle_fidget` | Zombie Agonizing | 6.17s | **trimmed** from 11.63s, see §10.7 |
| `run` | Zombie Walk | 4.07s | loop, In Place at source |
| `melee` | Zombie Neck Bite | 1.23s | **trimmed** from 4.17s, see §10.3 |
| `alert_scream` | Zombie Scream | 2.83s | new clip, no soldier counterpart |
| `hit_react` | Zombie Reaction Hit | 2.03s | |
| `downed` | Zombie Death | 3.00s | travels 1.015m, deliberately kept (in-tile) |

**`Zombie Turn` is downloaded and deliberately unmapped.** Measured, it yaws the
Hips 110° over 3.0s. That is root *rotation*, which `--strip-root` does not
touch — the open problem of §5.3, needing the quaternion-unwinding pass that
still does not exist. `face_toward` also tweens its own yaw in 0.18s, so playing
this as-is would leave the unit 110° off. Nothing regressed by leaving it out:
turning still snaps, exactly as it did before.

Everything else the soldier has, the swarm simply does not: no crouch, no aim, no
reload, no grenade, no `run_stop`, no shoot. All of them degrade correctly
already — `_play` guards on `has_animation`, and `play_stance_exit` falls through
to a hard cut at zero time cost.

### 10.3 The bite had to be trimmed, for the same reason `shoot_recoil` did

`melee_at` **awaits** the animation before damage lands, so an untrimmed 4.17s
bite is 4.17s of turn time per claw — against `FALLBACK_TIME`'s 0.55s guess, and
multiplied by however many fodder are in the room.

Measured by dumping the head's per-frame displacement: **11 dead lead-in frames**,
the reach opens the arms at f12, the lunge runs f20–f28 peaking at 2.60 m/s of
head speed, contact lands ~f28 — and then **43 frames (1.4s) of plateau** where
the head does not move, followed by 1.5s of returning to rest.

`TRIM` keeps f12–f48: reach, lunge, bite. 1.20s. The recovery is handed to
`unit_visual.gd`'s 0.15s stance blend rather than animated, which is a real
trade — a fast spring back to idle rather than a hand-off — and reads as vicious
on fodder. Revisit by splicing f12–f40 onto f84–f126 if it ever looks cheap;
that needs `TRIM` to accept a list of ranges, which it does not today.

The dead lead-in is the point worth carrying forward. **Every Mixamo clip is a
complete performance with a wind-up, and this game replays only the front of
them.** Two clips out of nineteen have now needed the same cut.

One consequence: the full bite returns to where it started and has no net travel,
but the trimmed window ends mid-lunge and so carries 0.338m of real forward
travel. That travel *is* the lunge, so `strip_mode` pins it to `"none"` — without
that, a build run with `--strip-root` would quietly flatten the attack into a
step on the spot.

### 10.4 Speed — the measurement contradicted the estimate

`Zombie Walk` ships In Place, so there is no root travel to read. The authored
ground speed is still recoverable: the planted foot slides backward under the
body at exactly that speed. Measured off the toe tracks, **0.32 m/s** — and one
foot never leaves the floor at all, because it is a drag, not a step.

0.32 m/s is unplayable as a turn pace: 4.7s per 1.5m tile, ~28s for one swarm
unit to spend 2 AP walking. So the honest answer is that this clip cannot both
look right and pace right, and the gap gets split:

- `Unit.MOVE_SPEED` became `@export var move_speed`, and the swarm scene sets
  **1.5 m/s** — a third of the soldier's 4.5, so the fodder still visibly reads
  as outrunnable, which is its whole design purpose. Cosmetic only: the tile
  budget and AP economy never see it, so no value here can affect balance.
- `UnitVisual.run_speed_scale` (new, default 1.0, swarm 2.0) plays the RUN stance
  at double rate, halving the residual skate to ~2.3×. A 2.0s shamble cycle still
  reads as a lurch.

What is left is hidden by the clip itself: with one foot permanently dragging, a
sliding planted foot *is* the animation. Zombie locomotion tolerates skate that
a soldier's run would not, which is lucky, because a soldier's run is exactly
what §6.4 had to solve properly.

`run_speed_scale` applies to RUN and nothing else on purpose. Every other clip's
authored timing is its content, and the game already awaits its real length —
scaling those would desynchronise animation from turn pacing.

### 10.5 The scream needed a new hook

Nothing in the codebase played an animation off an awareness change. `alert_scream`
fires from `EnemyUnit._set_state` on leaving `UNAWARE` by **either** channel —
spotting a player, or catching a flashlight beam — because both mean "it has
noticed", which is what the player needs to read. `ALERT → COMBAT` deliberately
does not re-fire: that is one creature narrowing down a stimulus it is already
reacting to, and screaming twice over one contact reads as a bug.

**Not awaited**, like the `DOWNED` collapse, and for a sharper reason: this is
reached from `_on_lighting_changed`, which runs once per tile in the *middle* of a
player unit's walk. Awaiting it would freeze the player halfway down a corridor
for 2.8s. Nothing downstream depends on the clip finishing.

Known cosmetic edge: `play_action` blocks stance changes while it runs, so a
scream still playing when the swarm's own activation begins will have it slide
while screaming. It needs the scream to fire in the last moments of the player's
turn to happen at all, and it self-corrects in under 2.8s.

### 10.6 Facing — measured, and it did not need correcting

`tools/_debug_facing.gd` now takes `FACING_SCENE` / `FACING_MODEL` / `FACING_CLIPS`
from the environment, so it can measure a raw GLB *before* any scene yaw. (Pass
`FACING_MODEL=.` when the scene root is the model. Not the empty string —
PowerShell deletes an env var assigned `""`, which silently falls back to the
default and reports every bone at the origin. That cost ten minutes.)

All six clips face +Z, so the same 180° correction as the soldier, on the model
node in `swarm_unit.tscn`. It was worth measuring rather than assuming, because
the swarm clips carry a per-clip Hips yaw baseline the soldier's do not (−19° on
most, +23° on the walk) and might have needed individual `ROOT_YAW` entries.

They do not. After the 180°, the residual is −29° to +5° on the feet against +5°
to +20° on the shoulders — straddling zero, averaging ~+4°. That spread is a
hunched zombie's feet and shoulders pointing different ways, which is the
animation, not an error. And unlike `aim_hold`, where 31.6° of body twist put a
rifle barrel off-target and off-flashlight, **nothing on this character has to
point anywhere precisely**. Correcting per clip would be fitting noise.

### 10.7 Idle variation — a third kind of clip

`Zombie Agonizing` became `idle_fidget`, played at a random 12–35s interval while
the IDLE stance holds. It is worth writing down because it did not fit either of
the two categories `unit_visual.gd` had.

**Not a stance:** it ends, and hands back. **Not an action either** — and that is
the load-bearing part. `play_action` sets `_action`, which makes `set_stance`
record-but-not-play until the one-shot finishes. That is correct for a reload,
where the game is awaiting the clip anyway. It is disastrous for a fidget: IDLE
is the *default* stance, so a 6-second fidget would routinely be in flight when a
move order arrived, and the unit would slide to its destination still convulsing.

So `_fidget_loop` calls `anim.play` directly and never touches `_action`. Any
real stance change cuts the fidget off mid-frame and wins outright, which is the
priority a decoration should have. The loop then checks `current_animation ==
IDLE_FIDGET` before handing back — testing the *clip* and not the stance is what
makes the interruption safe, because anything that took over has already called
`play()` itself and the hand-back correctly becomes a no-op.

The gap is rolled fresh each time rather than fixed. With several units on
screen a constant interval would have a whole nest convulsing in lockstep, and
nothing reads as scripted faster than that.

**Trimmed 11.63s → 6.13s**, by the same measurement as the bite: per-10-frame
upper-body speed shows the convulsion running f1–f171 at 0.2–0.89 m/s and then
falling off a cliff to 0.06–0.15 m/s for the remaining *six seconds*. That tail
is a low-amplitude standing sway — indistinguishable from the idle loop it is
about to return to, so playing it means six seconds where the zombie is busy
doing what it would be doing anyway.

The cost is stated rather than hidden: the full clip's last frame matches its
first to within 0.000 m on every bone, and cutting the tail ends it 0.13 m from
idle's pose instead of 0.065 m. Across `STANCE_BLEND` that is 0.87 m/s of travel,
inside the range the clip itself moves at, so it reads as motion rather than a
snap. And unlike `melee` or `shoot_recoil`, **nothing awaits this clip**, so a
larger blend has no gameplay consequence whatever.

Costs nothing for any other character: `_maybe_start_fidget` returns immediately
when the model has no `idle_fidget`, and `_instant` (headless) disables it
outright. Verified — a 45s watch on a player unit logs `idle` once and nothing
else.

Deliberately *not* gated on awareness state. A zombie writhing while it chases
you is arguably odd, but `UnitVisual` is driven by intent and knows nothing about
`AlertState`, and teaching it would put gameplay logic in the wrong file. If it
looks wrong on screen, the gate belongs in `EnemyUnit`, not here.

### 10.8 Verifying something that fires on a random timer

Neither existing tool could check this. `--auto` runs headless, and headless sets
`Unit._instant`, which disables self-driven animation *on purpose* — so the smoke
test would have reported the unit sitting in one clip forever and looked like a
bug in the thing being tested. `screenshot.gd` catches one instant, and a fidget
with a 12–35s gap is not reliably at that instant.

`tools/_debug_anim_watch.gd` boots the real game windowed and logs every
animation change on one unit for N seconds:

```
WATCH_GROUP=enemy_units WATCH_NAME=Swarm WATCH_SECONDS=70 \
  godot --path . --script res://tools/_debug_anim_watch.gd
```

The run that confirmed this: fidget at 34.21s and 52.50s, each lasting 6.17s to
the frame and handing back to `idle`, with a 12.1s gap — the bottom of the
declared range. It reads the AnimationPlayer off `UnitVisual.anim` rather than a
node path, so it works on any character.

### 10.9 Smaller things

- `scenes/swarm_unit.tscn` assembles the model directly rather than getting a
  `character_base.tscn` equivalent. That scene exists to carry the soldier's
  two-bone weapon mount, muzzle, flashlight and beam; a zombie has none of them,
  and there is one swarm body, so another layer of indirection would buy nothing.
- `flashlight_path`, `muzzle_path` and `aim_pitch_path` are written out as empty
  rather than left at their soldier-shaped defaults. They would resolve to null
  either way; writing them says "this unit has none" rather than "someone forgot".
- `build_anims.py` now **fails the build** if any clip in a profile's `looping`
  set was not produced. Looping clips are the stances, `_play` guards every call
  with `has_animation`, and so a missing stance does not error — the unit just
  stands in the rig's T-pose forever. Fatal by default, per §2.1's conclusion.
- `UnitVisual.setup` gained a `has_animation` guard on its one unguarded `play`.
- `tools/screenshot.gd` takes `SHOT_GROUP` and `SHOT_NAME`, because
  `enemy_units` holds both alien types and the group alone no longer identifies a
  character.
- The collision capsule grew from the placeholder's 1.2m to 1.8m to match the
  model. Gameplay-neutral: LOS and lighting occlusion both query layer 1 map
  geometry, and unit bodies are layer 2 with mask 0, so nothing raycasts it.
