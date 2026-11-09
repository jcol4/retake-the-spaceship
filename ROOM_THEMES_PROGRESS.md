# Themed Rooms: Implementation Progress & Handoff

Written 2026-11-09 on branch `3d-models`. **Audience: an agent picking this up cold.** The
spec is [`ROOM_THEMES_PLAN.md`](ROOM_THEMES_PLAN.md) (phases A–G, decisions table). This file
records what is done, what is half-done in the working tree, and what is left, with the code
locations and gotchas found along the way. Read the plan first, then this.

The user asked for the whole room plan to be implemented. Work goes phase by phase in the
plan's order, each phase tested and committed (local commits only; nothing pushed).

---

## Environment and tooling (read before running anything)

- **Godot 4.7.2** (console build, not on PATH):
  `C:/Users/jpcol/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe`
  (the folder is literally named `...win64.exe`).
- **Blender 5.2**: `C:/Program Files/Blender Foundation/Blender 5.2/blender.exe`. There is no
  system Python; use Blender's: `.../Blender 5.2/5.2/python/bin/python.exe -I`.
- Headless test: `godot --headless --path . --script res://tools/test_<name>.gd`. Parse check:
  `godot --headless --path . --check-only --script res://scripts/<file>.gd`.
- **After adding a new `class_name`, run `godot --headless --path . --import` once**, or every
  script that names the class fails with "Could not find type".
- A `--script` tool compiles before autoloads register, so a tool cannot reference a class
  that reaches an autoload. `ContractOffer` → `Contract` → `GridManager` fails in a tool. Tools
  use `MapGenerator`, `MapData`, `MapAscii`, `RoomTypes` and `DeckLayout` only.
- Windowed renders (gallery, screenshots) open at 3440x1440 whatever `--resolution` says (the
  game's settings autoload). Headless renders nothing.
- A safety check blocks `rm` on paths built from shell variables (`rm "$OUT"/*`). Write to new
  folders instead, or use literal paths.
- `CRLF will be replaced by LF` warnings on `.gd` files are harmless (`.gitattributes` pins LF).

---

## Done and committed

### Room furniture assets (precursor, see `ROOM_ASSETS_SOURCING.md` "Status")

162 placeholder pieces in 37 sockets (`furniture_<kind>`, `hazard_*`, `dressing_*`,
`terminal_wall`, `power_switch`, `elevator_door`) across kits under `assets/room_tiles/`. Each
piece has a `footprint` (tiles) and a `tier` (light/heavy/dressing/clutter/wall/door). The
furniture convention: origin at the footprint centre on the floor, long side along X, front +Z.
`ModuleCatalog` supports `parts`, `tint`/`paint`, `emission`, and `res://` file paths into
other kits. `tools/test_kit_coverage.gd` checks every piece (1,414 checks pass) and
`tools/room_kit_gallery.gd` renders them. **None of the furniture sockets is drawn yet**: that
is plan D.6, below. Floor materials for D.5: `assets/room_tiles/floors/floor_{medical,engineering,quarters,command}.tres`.

### Phase A, commit `6ac46391` (all tests pass)

- `scripts/room_types.gd` (`RoomTypes`): every room type in the plan's zone tables, with
  `short`/`long` size ranges, `cap`, `doors` (ANY/ONE/TWO_PLUS), `near` neighbour weights,
  `layout` (furniture arrangement enum for D.2), `light` (D.5 colour), `floor` (D.5 floor key),
  `loot` (F.2 table key), `home` (F.1 factions: `&"aliens"`, `&"robots"`, `&"mercs"`) and
  `locked` (E.3). Append-only enums `Zone` (HABITATION, MEDICAL, ENGINEERING, COMMAND, CARGO,
  UTILITY, NONE) and `Condition` (INTACT, RANSACKED, BARRICADED, OVERRUN). Structural types:
  `CORRIDOR`, `SPINE`, `HANGAR`, `GENERIC`. `ZONE_REQUIRED` / `ZONE_OPTIONAL` per zone. Helpers:
  `info`, `display_name`, `zone_of`, `layout_of`, `light_of`, `floor_of`, `loot_of`,
  `is_home_of`, `is_locked`, `doors_of`, `cap_of`, `neighbour_weight` (symmetric), `types_in`.
  Sizes the plan did not give are my estimates, to be tuned once reroll rates are measured.
- `MapData`: `room_types: Array[StringName]` and `room_conditions: Array[int]` parallel to
  `rooms`, kept the right length by `ensure_room_types()` (called by `compute_rooms`, the
  generator and `add_hangar`, which types the bay HANGAR). Helpers: `room_type`,
  `room_condition`, `room_type_at`, `set_room_type`, `rooms_of_type`, `room_zone`.
- `MapAscii`: `[rooms]` section, one line per room, `x,z type [condition]`, keyed by any cell
  of the room (it survives `compute_rooms` re-deriving indices). Encoded by each room's top-left
  cell in (z, x) order, so files written that way round-trip byte-identical. GENERIC/INTACT
  rooms, corridors and bays are not written.
- `tools/test_map_roundtrip.gd`: `_check_room_types` covers the above.

---

## Phases B + C: complete and verified

Continued in Codex on 2026-11-09. The inherited layout has now been executed and
fixed and verified. These changes form the local B+C commit. Nothing has been pushed.
The next implementation task is Phase D.

### Implementation

- `scripts/deck_layout.gd`: seeded primary/secondary profiles, flank hangars with
  inward-facing ramps, two two-tile spines with cross-corridors, typed rooms,
  suites, neighbour scoring, caps, utility filler, door rules and compatible loops.
  Rooms open directly onto a spine; the themed path uses this connected geometry
  instead of running the old MST router over it. The MST path remains available
  through `Config.themed_rooms = false`.
- Small is 72x48/Mixed/0.72 room scale; Medium is 84x56; Large is 96x64.
  Mixed bands reserve frontage for the galley/mess and reactor; their spines do
  not jog, so the reactor always has the necessary middle-band depth.
- Berthing suites retain their minimum members when optional members are shed:
  two bunks and a bathroom per suite (one bunk on Mixed). A missing suite triggers
  a reroll, just like a missing required room. Primary Habitation requires two
  suites on Medium and three on Large; secondary Habitation requires one.
- `MapGenerator` no longer retains a `DeckLayout` that in turn retains the
  generator: the reference cycle leaked every generated map. Failed layouts skip
  dressing before the next deterministic attempt.
- Second spine doors search other legal positions when the initial heuristic
  overlaps the first door. Door links count physical openings, including two
  openings onto the same spine.
- `MapData`: profile fields, zone bands, `zone_at`, `profile_name`, and explicit
  doorway topology. Explicit D cells separate internal suite rooms.
- `MapAscii`: optional `[topology]` / `doors` for fully marked themed entrances.
  It bypasses the old whole-deck bulkhead heuristic, which incorrectly sliced
  generated room interiors and hangar pads. Older files keep their old inferred
  topology and byte-identical round trips. Typed room identity survives exports;
  connected spine/cross-corridor floor can re-derive as one passage region.
- `ContractOffer`: rolls profiles from the campaign RNG and saves primary and
  secondary in offers and deployment descriptors. `TestMap.build_deck` forwards
  both. The board displays the advertised profile; old offers default to seeded
  profile selection. Objective-specific profile bias remains Phase F.4.
- `preview_map.gd`: `MAP_TYPES=1` prints a unique glyph per type, a legend and the
  profile/attempt. Overrides: `MAP_MIXED`, `MAP_SCALE`, `MAP_PRIMARY`,
  `MAP_SECONDARY`, `MAP_THEMED=0` for the old generator, plus the existing dimension overrides. Zone values are the
  `RoomTypes.Zone` enum (Habitation 0, Medical 1, Engineering 2, Command 3, Cargo 4).
- GDD sections 7.2, 7.7 and 10.4 describe the implemented layout and new sizes.

### Verification

`tools/test_room_themes.gd` checks every required room, berthing suite counts,
caps, two spines across the hull, hangar-to-spine openings, all room/hangar
reachability, bunk-to-bathroom paths confined to Habitation and passages, fuel
connections, door counts, deterministic regeneration, and typed-room round trips.
The default is 500 seeds for Mixed plus each of the eight valid wing pairings on
Medium and Large: 8,500 cases total, with a second generation of each seed.

Environment controls:

- `ROOM_THEME_SEEDS`: seeds per pairing (default 500).
- `ROOM_THEME_WIDTH`: 72, 84 or 96 to select a size.
- `ROOM_THEME_PROFILE`: e.g. `0,1` to select a primary/secondary pairing.
- `ROOM_THEME_LAYOUT_ONLY=1`: disables furniture, loot and merc placement for the
  B/C geometry sweep. Fully dressed decks are covered separately.

Final verification (all passed):

- **8,500 layout-only cases:** 500 Mixed seeds plus 500 seeds for each of the eight
  valid wing pairings on both Medium and Large. Every case was generated twice
  for determinism. Typed-room round trips were checked on the first three seeds
  of each pairing.
- **340 fully dressed cases:** 20 seeds per size/pairing with all cover, loot and
  encounter placement enabled, including required suites and room reachability.
- **300-seed hangar fuzz** on the final generator: pass.
- **Kit coverage:** all authored decks and 50 generated decks, built twice: pass.
- **Integration:** objectives, merc extraction, exploration, room visibility,
  map round trips, mission snapshots, campaign and co-op campaign: pass.
- Campaign includes **32 saved offers** regenerated from their deployment
  descriptors, with advertised profiles and supported objectives preserved.
- Project import, final test parse check and `git diff --check`: pass.

Layout-only reroll measurements (500 seeds per row):

| Width | Primary / secondary | Seeds rerolled | Total retries |
|---|---|---:|---:|
| 72 | Mixed | 132/500 | 171 |
| 84 | Habitation / Medical | 320/500 | 848 |
| 84 | Habitation / Command | 279/500 | 699 |
| 84 | Medical / Habitation | 343/500 | 1099 |
| 84 | Medical / Command | 13/500 | 13 |
| 84 | Engineering / Command | 8/500 | 8 |
| 84 | Engineering / Cargo | 2/500 | 2 |
| 84 | Command / Habitation | 339/500 | 1206 |
| 84 | Command / Engineering | 31/500 | 32 |
| 96 | Habitation / Medical | 80/500 | 94 |
| 96 | Habitation / Command | 98/500 | 125 |
| 96 | Medical / Habitation | 83/500 | 99 |
| 96 | Medical / Command | 5/500 | 5 |
| 96 | Engineering / Command | 4/500 | 4 |
| 96 | Engineering / Cargo | 3/500 | 3 |
| 96 | Command / Habitation | 94/500 | 112 |
| 96 | Command / Engineering | 7/500 | 8 |

Medium decks containing Habitation need the most retries. Every tested seed returned a valid layout
within its 32-reroll budget. These rates are a Phase G tuning item; the generator preserves
the required berthing suites instead of silently dropping them.

The pinned visibility regression explicitly uses its original 60x40 unthemed
layout and old hangar thresholds; its fixed coordinates describe an MST crossing.

Temporary logs are in the user's temp directory: `room_themes_72.log`,
`room_<width>_<primary>_<secondary>.log`, `room_themes_dressed.log`, and
`test_<name>_rooms_final.log`. The full sweep can be reproduced using the controls
above; filtering by size and pairing allows independent concurrent runs.

---

## Not started: Phases D, E, F, G

Where each hooks in, from what I read:

- **D.1 obstacle kind:** `data.obstacles` entries `[Rect2i, tier]` → `[Rect2i, tier, kind]`.
  Writers: `MapGenerator._place_piece` / `_place_one_cover_block`, `MapAscii._parse_obstacles` /
  `encode_obstacles` (old files default to `&"crate"`; keep byte-identical round-trips for files
  without a kind). Readers: `MapBuilder` (around line 275, `for entry: Array in data.obstacles`),
  `GridManager`.
- **D.2 layouts:** replace `_place_room_cover` for typed rooms with an arrangement per
  `RoomTypes.layout_of(type)`. Keep a tile of clearance to walls and between pieces. Map layout
  to obstacle kind to the furniture socket names in `ROOM_ASSETS_SOURCING.md`'s mapping table
  (e.g. mess → `mess_table` 1x3 light; bunks → `bunk` 1x2 light; server rows → `server_rack`
  heavy; machinery → `machinery` 2x2/3x2 heavy).
- **D.3 tiers:** light is low and destructible, heavy is tall and blocks sight; same rules as
  today's cover blocks.
- **D.4 conditions:** roll per room (intact 20 / ransacked 50 / barricaded 15 / overrun 15)
  into `data.room_conditions`. `[rooms]` already stores them. Overrun means worm mass
  (`data.worm_counts`) and damaged cover; barricaded means cover at doors plus a loot bonus.
- **D.5 lighting:** `MapBuilder` lights come from fixtures (`Fixture.OVERHEAD` etc.) and
  `LightingManager`. Tint by `RoomTypes.light_of(type)`. Floors: `MapBuilder._build_floors`
  (around line 467, MultiMesh per kit floor piece). Per-room floor material from
  `RoomTypes.floor_of` → `assets/room_tiles/floors/floor_*.tres`.
- **D.6:** `MapBuilder._dress_cover_block` (around line 848) picks
  `_catalog.pick("cover_heavy"/"cover_light", hash)`. Make it pick from `furniture_<kind>`
  first, filtered by the piece's `footprint`/`tier` (an `accept` callable on
  `ModuleCatalog.pick`), then the cover sockets, then the box. Furniture pieces are one wrapper
  per footprint (origin at its centre); cover pieces are one per cell.
- **D.7 hazards:** an exploding low-HP cover block (radius 2, about a frag grenade's damage,
  chains, enemy-triggerable). See `cover_block.gd`, `GridManager.register_cover_block`, and the
  grenade damage code in `combat.gd`.
- **D.8 noise:** multiply movement noise by zone (`data.zone_at`) where noise reaches
  `SecurityNetwork.report_noise` and alien `hear_noise`.
- **D.9:** room name in the hover tooltip once the room has been seen (`hud.gd`,
  `_room_under_cursor`).
- **E (power, locked doors, terminals):** doors today are plain openings (`Terrain.DOOR`, no
  door entity), so locked rooms need a door object. There is no keycard item.
  `terminal_prop.gd` and Contract HOLD terminals exist. `security_network.gd` handles robots.
  Dark zones need sight at about 60% and red emergency lighting.
- **F (spawns, loot, services, objectives):**
  - Spawns: `MapGenerator._place_spawns` (alien ENEMY glyph; `AlienPresets.FODDER_ONLY`
    turns these into hordes in `main.gd` `_spawn_hordes`), `_place_mercs`, and robot spawns.
  - Loot: `ItemPresets.roll_container(rng)`. **Missing items:** medkits, stims, keycards,
    research data, specimens, scrap, armour patches. Only valuables, gear, objective items and
    salvage exist (see `item_presets.gd` header).
  - Objectives: `Contract.make` (`_retrieve_candidates`, `_nest_candidates`,
    `_terminal_candidates`).
  - Insertion: `gen._insertion`, picked at random today.
  - Contract screen: `ContractOffer.describe()`, `hub_menu.gd`.
- **G:** playtesting and art; mostly for the designer.

---

## Decisions I made that the plan left open (confirm or change)

- Room sizes not in the plan's table, the CARGO zone's room list (`cargo_hold`, storage
  closets), and CARGO placed aft in the band order.
- Small decks shrink rooms (`room_scale` 0.72) rather than hangars, so the engine room fits a
  12-deep middle band.
- Suites are runs of rooms sharing one-tile walls along a spine. A suite's ONE-door member
  (cold store) uses only its internal door. Other ONE-door members (laundry, captain's quarters)
  use an internal door when part of a suite, or a spine door when placed alone.
  Phase E must place their keycards outside the rooms they unlock.
- Internal and loop doors are corridor regions of their own, matching `compute_rooms`.
- On themed decks, spawn safety is the rooms within 14 walked tiles of the insertion square.
