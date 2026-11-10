# Plots & Parcels: Authored Deck Layout Plan

**Status: experimental opt-in.** The user's later request supersedes D2's default:
procedural generation is the default again. The Contracts screen's **Map gen**
checkbox chooses procedural maps when checked and authored plots/parcels when
unchecked. Authored contracts use available playable plots. See
`PLOTS_PARCELS_PROGRESS.md` for the implemented behavior and validation.

Written 2026-11-09 on branch `3d-models`. **Audience: whoever implements this (an agent or a
developer), and the teammate who will author content with the editor.** It replaces procedural
deck layout with an XCOM 2-style system: hand-authored **plots** (deck shells) with **slots**
that are filled at mission start by hand-authored **parcels** (room interiors). A Godot editor
plugin is the authoring tool for both.

Read before starting: `ROOM_THEMES_PLAN.md` and `ROOM_THEMES_PROGRESS.md` (the room-type, zone
and condition systems this builds on), and `ROOM_ASSETS_SOURCING.md` (the furniture catalog).

---

## Decisions

| # | Topic | Decision |
|---|---|---|
| D1 | Plot source | Plots are hand-authored: hull, spines, corridors, slots and door sockets. |
| D2 | Old generator | `DeckLayout` stays behind a **dev toggle only**. Plots always build the deck in play. |
| D3 | Slot ↔ parcel match | A slot is tagged with a **zone** (or HANGAR) and a size. Any parcel of that zone and size whose sockets match can fill it. `RoomTypes` caps and required types still apply. |
| D4 | Doors | The **plot owns door sockets** on slot edges. A parcel lists the edge positions where it can accept a door. The assembler picks only parcel/rotation pairs that accept every socket on the slot. |
| D5 | Sizes | The **creator enters any dimensions** for a parcel or slot. Matching is exact: w×h, or h×w when rotated. |
| D6 | Transforms | Parcels can rotate (90° steps) and mirror. |
| D7 | Parcel contents | Floor/interior walls/doors, furniture with cover, extra cover edges, spawns, loot, lights, alarms, hazards, switches/terminals. |
| D8 | Variety | Pieces can be **optional**, with a % chance **per room condition** (intact/ransacked/barricaded/overrun), and can belong to **pick-one groups**. Conditions stay. |
| D9 | Spawns | Generic markers by default (the mission's faction decides the unit). A marker can be pinned to a specific `MapData.Spawn`. |
| D10 | Placement | Gameplay pieces snap to tiles with 90° rotation and use the catalog footprint. Dressing/clutter can be offset, rotated freely and stacked. |
| D11 | Wall pieces | Wall-mounted pieces **stay flush on the wall they were placed against**, through every rotation and mirror. |
| D12 | Lights | A light tool in both modes: presets plus advanced overrides, per-condition %, zone power, light-level heatmap. |
| D13 | Corridors | Plot mode can place pieces/lights/markers directly in corridors, spines and hangar aprons. |
| D14 | Plot choice | The contract's primary zone and deck size choose among plots that have that zone. When none fits, that is an authoring gap: the test reports it. No fallback to the generator. |
| D15 | Format | `.tres` Resources, `maps/plots/*.tres` and `maps/parcels/<zone>/*.tres`. |
| D16 | Tool | One `EditorPlugin` in `addons/deck_editor/`, plot mode and parcel mode. Teammate uses the full repo and Godot 4.7.2 and commits through git. |
| D17 | Validation | The editor **warns only** and always saves. `tools/test_parcels.gd` fails on hard errors. |
| D18 | Starter content | One **hangar parcel** and one **bunk room parcel**, plus one minimal test plot to place them in. |

**Out of scope:** raised platforms and stairs in plots or parcels; co-op determinism and
save-version work (see "Known follow-ups" at the end).

---

## Phase 1: Data model

New `class_name` Resources in `scripts/deck/`. Run `godot --headless --path . --import` after
adding them (see the class_name gotcha in `ROOM_THEMES_PROGRESS.md`).

### Shared pieces

```gdscript
class_name DeckPiece extends Resource       # one placed catalog piece
@export var piece_id: StringName            # ModuleCatalog id; exact piece, no hash pick
@export var cell: Vector2i                  # top-left of footprint, local tile coords
@export var rot: int                        # 0..3 quarter turns
@export var wall_side: int = -1             # MapData.Side it is flush against, or -1 (D11)
@export var offset: Vector3                 # dressing only: sub-tile offset in metres
@export var yaw_deg: float                  # dressing only: free rotation
@export var stack_on: int = -1              # dressing only: index of piece it sits on
@export var cover_override: int = -1        # MapData.Cover, or -1 = from catalog tier
@export var chance: PackedFloat32Array = [1, 1, 1, 1]   # per RoomTypes.Condition (D8)
@export var group: StringName               # pick-one group, "" = none

class_name DeckLight extends Resource       # D12
@export var preset: int                     # OVERHEAD, MONITOR, FLICKER, WALL_LAMP, ALARM
@export var cell: Vector2i
@export var wall_side: int = -1             # wall lamp / alarm: flush wall (D11)
@export var overrides: Dictionary           # any LightSource export: light_range, intensity,
                                            # light_color, flicker_min/max, beam_pitch,
                                            # spot_angle, casts_shadows...
@export var use_room_color := true          # colour from RoomTypes.light_of(type)
@export var chance: PackedFloat32Array = [1, 1, 1, 1]
@export var group: StringName

class_name DeckMarker extends Resource      # D9 spawns, loot, objectives
@export var kind: int                       # ENEMY, PATROL, NEST_SPOT, LOOT, PLAYER, PAD
@export var cell: Vector2i
@export var pinned_spawn: int = -1          # MapData.Spawn when pinned
@export var loot_table: StringName          # LOOT only; "" = room type's table
@export var ramp_side: int                  # PAD only (hangar)
@export var chance: PackedFloat32Array = [1, 1, 1, 1]
@export var group: StringName
```

`DeckPiece` covers hazards, switches and terminals as well; they are catalog pieces with a
`hazard_*`/`power_switch`/`terminal*` socket.

### Parcel

```gdscript
class_name ParcelData extends Resource
@export var display_name: String
@export var zone: int                       # RoomTypes.Zone, or ZONE_HANGAR
@export var room_type: StringName           # RoomTypes key, e.g. &"bunk_room"
@export var size: Vector2i                  # creator-entered (D5); includes the slot's
                                            # inner tiles only, NOT the plot's boundary walls
@export var terrain: PackedByteArray        # size.x*size.y; FLOOR, WALL, DOOR (interior only)
@export var sockets_ok: Array[Vector3i]     # (edge Side, index along edge, width) it accepts
@export var cover_edges: Dictionary         # Vector3i(x, z, side) -> MapData.Cover
@export var pieces: Array[DeckPiece]
@export var lights: Array[DeckLight]
@export var markers: Array[DeckMarker]
@export var allow_mirror := true
@export var weight := 1.0                   # selection weight among matching parcels
@export var tags: PackedStringArray         # free text, e.g. "barricaded-friendly"
```

### Plot

```gdscript
class_name PlotData extends Resource
@export var display_name: String
@export var deck_size: int                  # CampaignEconomy.DeckSize
@export var size: Vector2i                  # must equal DECK_DIMENSIONS[deck_size]
@export var terrain: PackedByteArray        # hull, spines, corridors, slot boundary walls
@export var corridor_rects: Array[Rect2i]   # becomes MapData.corridors (+ SPINE type)
@export var slots: Array[PlotSlot]
@export var pieces: Array[DeckPiece]        # corridor/hangar-apron dressing (D13)
@export var lights: Array[DeckLight]
@export var markers: Array[DeckMarker]
@export var cover_edges: Dictionary

class_name PlotSlot extends Resource
@export var rect: Rect2i                    # inner tiles; the boundary wall is plot terrain
@export var zone: int                       # RoomTypes.Zone or ZONE_HANGAR
@export var sockets: Array[Vector3i]        # (Side, index, width) doors on this slot's edge
@export var required_type: StringName       # optional: force a room type (set pieces)
```

A **socket** is a door opening in the slot's boundary wall: side, position along that edge,
and width (normally `MapGenerator.Config.entrance_width` = 2). The plot draws the boundary
wall; the assembler punches DOOR tiles at each socket.

### MapData additions

`MapData` today stores obstacles as `[Rect2i, tier, kind, hp_scale]` and lets `MapBuilder`
pick the model by hash; lights are a per-cell `Fixture` enum. Authored content needs more:

- `obstacles` entries gain optional `piece_id` and `rot` (index 4 and 5). `MapBuilder.
  _dress_cover_block` uses `piece_id` when present and skips the hash pick.
- `dressing: Array` of `[piece_id, world_transform]` for non-gameplay pieces (D10).
- `light_specs: Dictionary` `Vector3i -> {preset, overrides, wall_side}`. `Cell.fixture`
  stays the source of truth for gameplay and ASCII; `light_specs` only adds parameters, so
  ASCII decks and the old generator are unchanged.
- `wall_pieces: Array` of `[piece_id, cell, wall_side]` for wall-mounted pieces that take no
  floor tile (terminal_wall, dressing_wall, wall_light).

---

## Phase 2: Assembly (`PlotAssembler`)

`scripts/deck/plot_assembler.gd`, called from `MapGenerator._run` instead of `DeckLayout`
when `Config.deck_source == PLOT` (default). `Config.deck_source = GENERATED` is the dev
toggle (D2); expose it in `GameSettings` debug options and on `test_map.gd`'s command line.

Steps, all drawing from the generator's `_rng` (so a seed gives one deck):

1. **Choose plot** (D14): plots whose `deck_size` matches and that have at least one slot of
   the contract's primary zone; weight equally. None: push an error, return a failed layout.
2. **Stamp plot**: terrain, corridors (typed CORRIDOR/SPINE), plot pieces/lights/markers/cover.
3. **Fill slots**: a constraint search over slots.
   - Candidates per slot: parcels with the same zone, size equal under one of the 8
     transforms (4 rotations × mirror if `allow_mirror`), and whose transformed `sockets_ok`
     contain every socket on the slot.
   - `required_type` slots are filled first. Then `RoomTypes.ZONE_REQUIRED` types are
     satisfied, then the rest by weight. Respect `RoomTypes.cap_of`. Backtrack on a dead
     end; give up after N attempts and report which slot had no candidate.
4. **Stamp each parcel** through its transform (below), then record the room:
   `MapData.rooms`, `set_room_type(room, parcel.room_type)`.
5. **Hangars**: a HANGAR slot's parcel must have one PAD marker; call `MapData.add_hangar`
   with the transformed pad centre and ramp side, then check `hangar_problem()`.
6. **Conditions**: `RoomDressing.roll_conditions` as today. Then resolve optional entries:
   for each group pick one member by weight, then keep each entry with
   `chance[condition]`. This happens after the condition roll, so the chances can depend on it.
7. **Markers → spawns**: generic ENEMY markers resolve through the mission's faction, the
   same way `_place_faction_enemies` does today; pinned markers write their `Spawn`
   directly. Insertion-safe clearing (`_rooms_near_insertion`) still runs.
8. Keep the tail of `_run`: loot (LOOT markers first, then `_place_loot` tops up), room
   keys, objectives, mercs, `resolve_stairs`.

`RoomDressing.place` is **not** called for parcel rooms. The `ransacked` jitter, `overrun`
worm seeding and `barricaded` crates in `RoomDressing` move behind a flag. Authors reproduce
those effects with per-condition chances. The `overrun` worm seeding stays procedural.

### Transform rules (D6, D11)

One function, `ParcelTransform.apply(local: Vector2i, size, rot, mirror) -> Vector2i`, used
by both the assembler and the editor preview, so they cannot disagree.

- Footprint rect: transform both corners, re-normalise.
- Piece rotation: `rot' = (rot + slot_rot) % 4`; mirroring flips the rotation's handedness.
  **Never use a negative scale**: it flips normals. A mirrored asymmetric piece is drawn
  rotated, not mirrored. It reads slightly differently, which is acceptable.
- `Side` values rotate with the parcel: `side' = (side + slot_rot) % 4`, and mirroring swaps
  EAST↔WEST (mirror is about the local X axis).
- **Wall flush (D11):** a piece with `wall_side >= 0` is placed so that its back face lies
  exactly on the boundary between its cell and the cell on `wall_side'`. Its dressing
  `offset` is split into along-wall and out-of-wall components; the out-of-wall component
  is clamped to 0 (flush). Its catalog `+Z` faces away from the wall. The assembler asserts
  the neighbour cell on `wall_side'` is WALL; if a door socket opened it, the piece is
  dropped and a warning is logged. The validator already flags this at authoring time, so
  this branch should not happen in practice.
- Lights with `wall_side` (wall lamps, alarms) follow the same rule; `beam_pitch` tilts
  along the transformed -Z.

### Catalog additions

`ModuleCatalog` manifests gain a per-piece `"mount": "floor" | "wall"` (default floor;
`terminal_wall`, `dressing_wall`, `wall_light`, `power_switch` and `furniture_monitor` are
wall). The editor reads it to decide whether a placed piece takes a `wall_side`. Also
add a `"gameplay": false` flag for `dressing_*`/`*_clutter` sockets (D10).

---

## Phase 3: Editor plugin (`addons/deck_editor/`)

A **main-screen plugin** ("Deck Editor" tab beside 2D/3D/Script), so it gets a full canvas.

### Layout

- **Left: canvas.** A top-down tile grid drawn in a `Control` (`_draw`), zoom and pan.
  Pieces are drawn as footprint rectangles with an icon, a facing arrow and wall-flush tick.
  Lights as glowing dots with a radius ring. Markers as letters (E, P, L…).
- **Right: 3D preview** (`SubViewport`). A **Preview** button (and auto on save) builds the
  parcel/plot through `PlotAssembler` + `MapBuilder` exactly as the game does, with a
  condition picker and a "reroll optionals" button so authors see each variant.
- **Bottom: palette.** Catalog pieces grouped by socket, with thumbnails rendered once into
  `res://.godot/deck_editor_thumbs/` (cache only, not committed).
- **Inspector:** Godot's own inspector edits the selected `DeckPiece`/`DeckLight`/
  `DeckMarker` sub-resource, so `chance`, `group` and light overrides need no custom UI.
  Add a custom `EditorInspectorPlugin` for `chance` that shows four labelled sliders
  (Intact / Ransacked / Barricaded / Overrun).

### Parcel mode

- **New parcel:** dialog for name, zone, room type (filtered by zone), **width and depth**
  (D5). Room type's suggested `short`/`long` range is shown as a hint, not enforced.
- **Tools** (keyboard shortcut in brackets):
  - Paint terrain [T]: floor, interior wall, interior door.
  - Place piece [P]: click to place the palette selection; [R] rotate; snaps by footprint.
    For a wall-mount piece, the cursor snaps to the nearest wall edge and sets `wall_side`.
    Hold Alt for free placement of dressing (D10): offset and yaw, click onto another piece
    to stack.
  - Light [L]: preset dropdown (Overhead, Monitor, Flicker, Wall lamp, Alarm). Wall lamp and
    alarm snap to walls like wall pieces (D12).
  - Marker [M]: enemy, patrol, nest spot, loot, player, pad (hangar only). Pin to a unit in
    the inspector.
  - Cover edge [C]: click a tile boundary to cycle none/light/heavy.
  - Door sockets [D]: click edge positions to toggle "a door may open here" (`sockets_ok`).
  - Select [S]: box select, move, delete, duplicate; set `group` on a selection.
- **Overlays** (toggles): light-level heatmap (computed with the same falloff as
  `LightingManager`, with a powered/unpowered switch), walk lanes, cover edges, sockets.
- **Undo/redo** through `EditorUndoRedoManager` for every edit.

### Plot mode

- **New plot:** deck size (Small/Medium/Large) sets the dimensions from
  `CampaignEconomy.DECK_DIMENSIONS`.
- Tools: paint hull/floor/wall [T], corridor rect [K] (CORRIDOR or SPINE), slot rect [Q]
  with zone dropdown and optional required type, door socket on a slot edge [D], plus the
  same piece/light/marker/cover tools for corridors and hangar aprons (D13).
- **Fill preview:** "Assemble with seed N" runs the full assembler and shows the result in
  the preview, with each slot labelled with the parcel it got. A slot with no candidate is
  drawn red with the reason ("no MEDICAL 6×8 parcel accepts a door at N:3").

### Validation (D17: warn only)

Shown in a dock list; clicking a warning selects the offending tile. Saving always works.
Shared with the test (Phase 4) through `scripts/deck/deck_validator.gd`.

Parcel checks: floor connected; every `sockets_ok` tile walkable and not blocked within one
tile; a wall-mount piece has a wall behind it and does not sit on a `sockets_ok` position;
pieces overlap or overhang; spawn/loot marker on an occupied tile; each pick-one group
has at least two members; a tile fully dark at intact and powered; a hangar parcel has
exactly one PAD and passes `MapData.hangar_problem`; the parcel matches no slot in any plot
(info only).

Plot checks: every slot has at least one candidate parcel under some transform; required
zones per deck reachable (`RoomTypes.ZONE_REQUIRED`); every slot has at least one socket;
hull closed; corridors connected; at least one HANGAR slot.

---

## Phase 4: Tests

- `tools/test_parcels.gd` (headless): loads every parcel and plot, runs `DeckValidator`,
  and **fails on hard errors** (anything that would break play: blocked socket, unreachable
  floor, missing pad, unfillable slot). Assembles each plot with 50 seeds per condition mix,
  asserts all slots are filled, every room is reachable from insertion, and no spawn is
  placed on an obstacle.
- `tools/test_parcel_transform.gd`: all 8 transforms on asymmetric fixtures; wall-flush
  pieces stay flush and face away from the wall; round-trip of `Side` rotations.
- `tools/test_map_roundtrip.gd`: unchanged; ASCII decks don't use parcels.
- Existing tests that call `MapGenerator.generate` with no config get `deck_source =
  GENERATED` explicitly where they measure generator behaviour.

---

## Phase 5: Starter content (D18)

1. **Hangar parcel** `maps/parcels/hangar/hangar_standard.tres`: zone HANGAR, sized to the
   current generator's bays (measure a few `DeckLayout` hangars first, roughly 14×12). PAD
   marker with ramp side, wreck cover using the existing hangar wreck pieces, crates,
   overhead lights, two optional extra wrecks at different chances per condition, sockets on
   the inward edge.
2. **Bunk room parcel** `maps/parcels/habitation/bunk_room_a.tres`: zone HABITATION, type
   `bunk_room`, 8×10 (inside the type's 6–8 × 8–10 range). Rows of `furniture_bunk`,
   lockers flush against one wall, a `terminal_wall`, two overheads + one flicker, a loot
   marker, one generic enemy marker, sockets on both short edges. Ransacked/barricaded
   variants through per-condition chances on a few bunks and a crate barricade group.
3. **Test plot** `maps/plots/test_small.tres`: Small deck, two HANGAR slots and a few
   HABITATION slots sized for the bunk room, two spines, so both parcels can be assembled
   and played. Not a shipping plot.

The teammate then builds out parcels for the remaining zones. The test (Phase 4) reports
which plot slots still lack candidates, which doubles as the authoring to-do list.

---

## Order of work

1 data model → 2 assembler (fed by hand-built `.tres` from a script) → 4 transform test →
5.1/5.2/5.3 starter content, assembled and played → 3 plugin, parcel mode → plugin, plot
mode → validator/overlays → full `test_parcels.gd`. The assembler comes before the plugin so
the plugin's preview has a working backend from day one.

## Known follow-ups (out of scope here)

- **Co-op determinism:** the assembler draws from `MapGenerator._rng`, so peers building
  from the seed match as long as both have the same parcel files. Nothing else is planned.
- **Saved contract offers** (`contract_offer.gd`) store a seed that now means a different
  deck. `CampaignState.SAVE_VERSION` is not bumped in this plan.
- **Raised platforms and stairs** are not supported in plots or parcels.
- `furniture_*` sockets with one model only (e.g. `furniture_morgue`) give authors no choice;
  the palette shows them anyway.
