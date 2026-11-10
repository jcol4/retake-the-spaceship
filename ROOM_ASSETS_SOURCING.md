# Room Furniture Placeholder Assets: Sourcing & Import Brief

Written 2026-11-09 against `3d-models`. **Audience: a Claude agent picking this up cold.** Read
[`ROOM_THEMES_PLAN.md`](ROOM_THEMES_PLAN.md) first: it defines the room types, furniture kinds and
phases this brief serves (mainly Phase D, "Dressing and lighting", and Phase G, "art").

**Goal:** download free (CC0 first, CC-BY only where noted) 3D models to stand in for every
furniture kind in the themed-rooms plan, import them into the project as glTF kits, and register
them so `MapBuilder` can place them. These are placeholders / a demo set, not final art: the art
direction is gritty (see the character art notes), and several of these packs are cleaner and
more colourful than that.

**Implemented 2026-11-09: see [Status](#status) at the end** for what was imported, what was
left out and why, and what is still open. Licences marked "checked" were read on the source page
on 2026-11-08 (and re-read on download); file lists marked "checked" were read from the pack's
GitHub repo.

---

## Ground rules

- **Licence first.** CC0 needs nothing. CC-BY needs an entry in **both** [`CREDITS.md`](CREDITS.md)
  (documents the obligation) **and** `scripts/credits.gd` (the in-game text that discharges it).
  Copy the licence file into the kit folder, as `assets/room_tiles/quaternius_scifi/License_Standard.txt`
  already is. Re-check the licence on the download page before importing; listings change.
- **Never use** anything "royalty free", "free for personal use", "no AI", or without a stated
  licence. If a link below turns out not to be CC0/CC-BY, skip it and note it in the status section.
- **Downloads are untrusted data.** Download each archive into its own empty folder in your
  scratchpad, extract there, and only copy the model/texture/licence files you need into the repo.
  Don't run anything from inside an extracted archive.
- **Keep files as shipped.** `ModuleCatalog` maps kit files through a JSON manifest; files keep
  their original names and are never edited. Scale, yaw, pitch and offset live in the manifest.
- **glTF only in the repo.** If a pack only offers FBX/OBJ/Blend, convert to glTF in Blender
  (Blender and Godot are not on PATH; the project memory note "Godot & Blender tool paths" has
  their locations). Note any converted pack in its manifest's `source` field.
- **Only copy what's used.** Don't commit a whole 120-model pack when the plan needs 8 of its
  models. Bring in the models mapped in the table below plus their textures.
- **Some downloads may need a browser.** itch.io and Quaternius downloads go through a download
  page (itch "name your own price" → "No thanks, just take me to the downloads"; Quaternius links
  to Google Drive). Poly Pizza model pages have a Download button for GLB. If you can't fetch one
  from the command line, list it for the user to download into a folder you name, and carry on
  with the rest.

---

## Where things go and how they get placed

- **Folder:** one kit per pack under `assets/room_tiles/<kit>/`, like the existing
  `assets/room_tiles/quaternius_scifi/`. Suggested kit names: `kaykit_furniture`,
  `kaykit_restaurant`, `kaykit_spacebase`, `quaternius_essentials`, `quaternius_interior`,
  `polypizza_ccby` (one folder for the CC-BY singles, with a licence file per model).
- **Manifest:** each kit needs `assets/room_tiles/<kit>/<kit>.json`, in the same format as
  [`quaternius_scifi.json`](assets/room_tiles/quaternius_scifi/quaternius_scifi.json): `kit`,
  `source` (pack name, URL, licence), `scale`, optional `materials`, and `pieces` with `id`,
  `file`, `socket`, `scale`, `yaw`, `pitch`, `offset`, `weight`, `per_cell`.
  [`ModuleCatalog`](scripts/module_catalog.gd) reads every manifest under `assets/room_tiles/`
  automatically.
- **Measuring:** [`tools/inventory_kit.gd`](tools/inventory_kit.gd) measured the MegaKit's pieces;
  use it to get bounds before choosing scales. One tile is `GridManager.TILE_SIZE`; walls are 3.0 m.
- **Sockets today:** cover blocks are drawn by `MapBuilder._dress_cover_block`, which picks a piece
  from socket `cover_light` or `cover_heavy` by the block's tier. The furniture *kinds* in the
  plan (`bunk`, `mess_table`, `lab_bench`…) don't exist in code yet; Phase D.1 adds a `kind` to
  each obstacle.
  - **If Phase D.1 is not built yet:** use one socket per kind anyway, named `furniture_<kind>`
    (e.g. `furniture_bunk`), so the pieces are ready the moment `kind` lands. They won't appear in
    game until then. Optionally add the best-looking generic pieces to `cover_light`/`cover_heavy`
    so they show up now.
  - **If D.1 is built:** `_dress_cover_block` should pick from `furniture_<kind>`, falling back to
    `cover_light`/`cover_heavy`, then to the tinted box.
- **Verify** by rendering a deck (see the `run` skill / `tools/preview_map.gd` and the existing
  screenshot tools under `tools/`) and checking each kind reads at XCOM camera distance.

---

## Sources

### Already in the repo (use first)

**Quaternius Modular Sci-Fi MegaKit, Standard tier**: CC0 (checked). In
`assets/room_tiles/quaternius_scifi/glTF/`. Only walls, floors, doors, lamps and three cover pieces
are mapped today. Unused props worth mapping: `Props/Prop_Computer`, `Props/Prop_AccessPoint`,
`Props/Prop_Chest`, `Props/Prop_ItemHolder`, `Props/Prop_Fan_Small`, `Props/Prop_Vent_*`,
`Props/Prop_Cable_*`, `Props/Prop_PipeHolder`, `Columns/Column_Pipes`, `Columns/Column_MetalSupport`,
`Platforms/Platform_Rails_*`, `Platforms/Door_Frame_Square_Blocked`, `Platforms/Door_Frame_SquareTall`,
`Platforms/Door_DarkMetal`, `Decals/*`.
- Pack page: https://quaternius.com/packs/modularscifimegakit.html

### CC0 packs to download

| Pack | Licence | Download | What to take |
|---|---|---|---|
| **KayKit Furniture Bits** | CC0 (checked) | Repo zip: https://github.com/KayKit-Game-Assets/KayKit-Furniture-Bits-1.0/archive/refs/heads/main.zip · page: https://kaylousberg.itch.io/furniture-bits | `bed_single_A`, `bed_single_B`, `bed_double_A`, `couch`, `armchair`, `cabinet_medium`, `cabinet_small`, `shelf_A_big`, `shelf_B_large`, `table_medium`, `table_medium_long`, `table_low`, `chair_A`, `lamp_standing`, `rug_rectangle_A` (file list checked) |
| **KayKit Restaurant Bits** | CC0 (checked) | Repo zip: https://github.com/KayKit-Game-Assets/KayKit-Restaurant-Bits-1.0/archive/refs/heads/main.zip · page: https://kaylousberg.itch.io/restaurant-bits | `kitchencounter_straight_A`, `kitchencounter_sink`, `kitchencounter_outercorner`, `stove_multi`, `oven`, `fridge_A`, `fridge_B`, `extractorhood`, `dishrack_plates`, `kitchentable_A_large`, `kitchentable_B_large`, `table_round_A`, `chair_A`, `chair_B`, `chair_stool`, `crate`, `crate_potatoes` (file list checked) |
| **KayKit Space Base Bits** | CC0 (checked) | Repo zip: https://github.com/KayKit-Game-Assets/KayKit-Space-Base-Bits-1.0/archive/refs/heads/main.zip · page: https://kaylousberg.itch.io/space-base-bits | `cargo_A_stacked`, `cargo_B_stacked`, `cargo_A_packed`, `containers_A`–`containers_D`, `structure_low`, `structure_tall` (file list checked) |
| **Quaternius Sci-Fi Essentials Kit** | CC0 (checked), glTF included | https://quaternius.com/packs/scifiessentialskit.html · https://quaternius.itch.io/sci-fi-essentials-kit | Animated screens, crates, computer/console props, weapon models for armory racks. Same style as the MegaKit: **highest priority**. Contents not listed on the page; inventory after download. |
| **Quaternius Ultimate House Interior Pack** | CC0 (checked) | https://quaternius.com/packs/ultimatehomeinterior.html | Toilet, bathroom sink, bathtub, kitchen pieces. Its toilet is also on Poly Pizza: https://poly.pizza/m/WAu50yGFVt (CC0, checked). Check formats; convert to glTF if needed. |
| **Quaternius Ultimate Furniture Pack** | CC0 (checked) | https://quaternius.com/packs/ultimatefurniture.html | Beds, chairs, tables (alternative to KayKit). Page lists FBX/OBJ/Blend only: convert. |
| **Quaternius Ultimate Modular Sci-Fi Pack** | CC0 (checked) | https://quaternius.com/packs/ultimatemodularscifi.html | Older sci-fi interior kit with props. Contents not checked: inventory and take any consoles, machinery, pods, lockers. |
| **Quaternius Scifi Pod** | CC0 (checked) | https://poly.pizza/m/hedSWVZx9E | Specimen tank / cryo pod stand-in (tagged as a pillar; check it reads as a pod). |
| **Quaternius Survival Pack** | CC0 (checked) | https://quaternius.com/packs/survival.html | First-aid props for the medbay. Contents not checked. |
| **Kenney Furniture Kit** | CC0 (checked) | https://kenney.nl/assets/furniture-kit · mirror: https://opengameart.org/content/furniture-kit | Contents and formats not shown on the page; tagged bed/table/chair, and OpenGameArt says it includes kitchen and bathroom pieces. Inventory, take any shower, toilet, sink, locker. |
| **Kenney Space Station Kit** | CC0 (checked) | https://kenney.nl/assets/space-station-kit · mirror: https://kenney-assets.itch.io/ | Tagged sci-fi interior. Contents not checked: inventory for consoles, beds, lockers, machinery. |
| **Kenney Modular Space Kit** | CC0 (checked) | https://kenney.nl/assets/modular-space-kit | Probably structural only; low priority. |

Kenney's download button is JavaScript-driven; if it can't be fetched, add it to the user's
manual-download list. Kenney asks for (but doesn't require) credit; adding "Kenney.nl" to
`scripts/credits.gd` is a courtesy, not an obligation.

### CC-BY fill-ins (only for gaps the CC0 packs leave)

Each needs `CREDITS.md` + `scripts/credits.gd` entries with author, title, licence and link.

| Model | Author | Licence | Link | Use |
|---|---|---|---|---|
| Ultimate Interior Props Pack | Zsky | CC BY (page text says 4.0, metadata links 3.0: credit as CC BY 4.0 and link both) | https://poly.pizza/bundle/Ultimate-Interior-Props-Pack-9KfkK2H0ve | **Bunk Bed** (no CC0 bunk found), Gymmat, Barbell, Dumbell, Punching Bag, Large/Medium Wardrobe (lockers) |
| server rack | Jeremy Eyring | CC BY 3.0 (checked) | https://poly.pizza/m/6ijQclm8jxw | Server room |
| Lab Table | Ali12 | CC BY 3.0 (checked) | https://poly.pizza/m/NyeiCAto3N | Labs |

### Unchecked leads (check licence on the model page before use)

Poly Pizza search pages don't show licences; open `https://poly.pizza/m/<id>` to check.
- Lockers: "Locker" J-Toastie `/m/aGmZ4jQD2y`, "Open Locker" J-Toastie `/m/AT7YLkpg6n`, "TT - A lot of red lockers" `/m/3jGb44V-Ske`
- Bathroom: "Toilet" Kenney `/m/QsQdZcnTsI`, "Bathroom Sink" Kenney `/m/iUz9JXhDE1`, "Bathtub" Quaternius `/m/wrOzCX3k48`
- Lab: "Microscope" `/m/q9zNs4U5NG`, "Lab Equipment" `/m/fSWYfMERNak`, test tubes `/m/cXYIYXO9mVP`, `/m/1F33UFXOEau`, beaker `/m/a6fAmpBmWHM`
- Sci-fi: Quaternius "Scifi Computer" `/m/U0xmt6tUlL`, "Scifi Container" `/m/22FBVK7m9c`, "Scifi Crate" `/m/bPeXlVjwCH`; "Sci Fi Engine" Dipper98 `/m/xkgtgFIHIJ`, "Sci Fi Wall Power Cell" Dipper98 `/m/GzgXYpEvEM`, "Scifi Canister" Nick Slough `/m/OzcIJxCDpO`
- Search pages: https://poly.pizza/search/hospital · /search/locker · /search/toilet · /search/lab · /search/sci%20fi

### Floor textures (per-room floor tints, plan D.5)

- ambientCG (CC0): https://ambientcg.com: search "Tiles", "MetalPlates", "Linoleum", "DiamondPlate"
- Poly Haven (CC0): https://polyhaven.com/textures
Take 1K resolution only. Medical: white tile/linoleum. Engineering: diamond plate. Quarters: dark
linoleum/carpet. Command: dark metal panels.

---

## Furniture kind → model mapping

Kinds and tiers come from `ROOM_THEMES_PLAN.md` D.2/D.3: **light** = low, destructible; **heavy** =
tall, blocks sight. Pick the first available source; "Blender" means no free model was found and a
simple model should be built (or kitbashed from the listed parts) later. Note those in the status
section rather than building them unless asked.

| Kind (suggested socket) | Tier | Rooms | First choice | Fallback |
|---|---|---|---|---|
| `furniture_bunk` | light | Bunk room, brig | Zsky Bunk Bed (CC-BY) | Two KayKit `bed_single_A` stacked |
| `furniture_bed` | light | Cabins, captain's quarters | KayKit `bed_double_A`, `bed_single_B` | Quaternius Ultimate Furniture bed |
| `furniture_locker` | heavy | Locker room, bunk rooms, armory | Kenney / Space Station locker if present | KayKit `cabinet_medium`; Zsky wardrobe (CC-BY) |
| `furniture_toilet` | light | Bathroom block | Quaternius Toilet (CC0) | Kenney toilet |
| `furniture_sink` | light | Bathroom block | Quaternius / Kenney bathroom sink | KayKit `kitchencounter_sink` |
| `furniture_shower` | heavy | Bathroom block | Kenney Furniture Kit if it has one | **Blender** (stall from wall panels) |
| `furniture_washer` | heavy | Laundry | **Blender** | KayKit `fridge_B` retinted white |
| `furniture_mess_table` | light | Mess | KayKit `kitchentable_A_large`, `table_medium_long` | KayKit `table_round_A` |
| `furniture_chair` | (dressing) | Mess, lounge, bridge | KayKit `chair_A`, `chair_stool` | — |
| `furniture_galley` | heavy | Galley | KayKit `kitchencounter_*`, `stove_multi`, `oven`, `fridge_A`, `extractorhood` | — |
| `furniture_couch` | light | Lounge, cabins | KayKit `couch`, `armchair`, `table_low` | — |
| `furniture_gym` | light | Gym | Zsky Gymmat, Barbell, Punching Bag (CC-BY) | KayKit `table_low` |
| `furniture_med_bed` | light | Medbay, ICU | **Blender** | KayKit `bed_single_A` retinted white |
| `furniture_surgery` | light | Surgery | **Blender** (operating table) | KayKit `table_medium` + MegaKit `Prop_Light_Floor` |
| `furniture_monitor` | (dressing) | Medbay, ICU, labs | MegaKit `Prop_Computer` | Sci-Fi Essentials screen |
| `furniture_lab_bench` | light | Lab, clean room | Ali12 Lab Table (CC-BY) | KayKit `table_medium_long` + MegaKit `Prop_Computer` |
| `furniture_specimen_tank` | heavy | Specimen hold, cryo | Quaternius Scifi Pod (CC0) | MegaKit `Column_Hollow` |
| `furniture_morgue` | heavy | Morgue | **Blender** (drawer wall) | MegaKit `Prop_Chest` stacked 2 high |
| `furniture_machinery` | heavy | Engine room, life support | MegaKit `Column_Pipes`, `Prop_Fan_Small`; KayKit `structure_tall` | MegaKit `Prop_Crate4` |
| `furniture_console` | light | Bridge, comms, navigation, security | MegaKit `Prop_Computer`; Sci-Fi Essentials screens | Quaternius "Scifi Computer" |
| `furniture_server_rack` | heavy | Server room | Jeremy Eyring server rack (CC-BY) | MegaKit `Prop_Crate4` with computer texture |
| `furniture_weapon_rack` | heavy | Armory | MegaKit `Prop_ItemHolder` + Sci-Fi Essentials guns | KayKit `shelf_B_large` |
| `furniture_workbench` | light | Fabrication shop | KayKit `table_medium_long` + MegaKit `Prop_Computer` | — |
| `furniture_cell_bars` | heavy | Brig | MegaKit `Door_Frame_Square_Blocked`, `Platform_Rails_*` | — |
| `furniture_crate` | light/heavy | Storage closets, cargo | MegaKit `Prop_Crate3/4`, `Prop_Chest` (already mapped) | KayKit `crate` |
| `furniture_cargo` | heavy | Cargo, hangars | KayKit `cargo_A_stacked`, `containers_A`–`D` | MegaKit `Prop_Crate4` |
| `hazard_fuel_tank` | light | Fuel storage, engine room | MegaKit `Prop_Barrel_Large` tinted red | — |
| `hazard_gas` | light | Galley, labs | Nick Slough "Scifi Canister" if CC0/CC-BY | MegaKit `Prop_Barrel_Large` scaled 0.6, yellow |
| `hazard_panel` | light | Engineering, corridors | MegaKit `Prop_AccessPoint` | — |
| `terminal` | (interactable) | Bridge, security station | MegaKit `Prop_AccessPoint`; Sci-Fi Essentials screen | — |
| `power_switch` | (interactable) | Engineering control | MegaKit `Prop_AccessPoint` | — |
| `elevator_door` | (wall) | Elevator lobbies | MegaKit `Door_Frame_SquareTall` + `Door_DarkMetal` | — |

---

## Suggested order of work

1. KayKit Furniture, Restaurant and Space Base (direct GitHub zips, file lists known).
2. Map the unused MegaKit props already in the repo (no download).
3. Quaternius Sci-Fi Essentials (best style match; may need a manual download).
4. Bathroom set: Quaternius House Interior / Kenney Furniture Kit.
5. CC-BY fill-ins, with credits entries in the same commit.
6. Kenney Space Station Kit and Quaternius Ultimate Modular Sci-Fi: inventory, take what fills gaps.
7. Floor textures.

Commit per pack (`assets: add <pack> placeholder furniture (CC0)`), each with its manifest and
licence file, so a bad pack can be reverted alone.

---

## Status

Done 2026-11-09 on `3d-models`. Every kind in the mapping table has at least one piece; 162
placeholder pieces in 37 sockets, 43 of them photoscanned Poly Haven props (a second pass for a
grittier, more realistic set; they outweigh the stylised kits in every socket they share).
**D.1/D.6 are implemented:** themed room layouts now draw furniture and hazards from these
sockets, filtered by kind, footprint and cover tier. Older generic cover keeps its fallback path.

Phase G also adds five original models in `assets/room_tiles/ship_furniture/`: bunk, mess table,
lab bench, server rack and machinery/engine block. Their manifest gives these industrial models
higher selection weight within matching sockets. `tools/make_room_furniture.py` is the reproducible
Blender source; no third-party assets or licence obligations were added for this kit.
`tools/test_kit_coverage.gd` validates the original models alongside the imported placeholders.

| Pack | Downloaded | Imported | Manifest | Credits needed | Notes |
|---|---|---|---|---|---|
| KayKit Furniture Bits | Yes (GitHub zip) | 15 models + atlas | `kaykit_furniture.json`, 20 pieces | No | Natural scale 0.75 (2 KayKit units = 1 tile). |
| KayKit Restaurant Bits | Yes (GitHub zip) | 17 models + atlas | `kaykit_restaurant.json`, 17 pieces | No | Counters stretched to 1 tile at 0.95 m; the long table stretched to the 1x3 rows of D.2. |
| KayKit Space Base Bits | Yes (GitHub zip) | 9 models + atlas | `kaykit_spacebase.json`, 7 pieces | No | `containers_A`–`D` are flat (0.2 units), so they are stacked three high as cargo. |
| MegaKit unused props | n/a | n/a | 22 `mk_*` pieces in `quaternius_scifi.json` | No | Left out after the gallery: `Prop_Fan_Small` (skinned; renders far smaller than its mesh bounds), `Column_MetalSupport` (a flat plate), `Platform_Rails_*` (ramp railings; cell bars are three stacked `Prop_Rail_4` instead), `Decals/*` (the manifest's decal materials are opaque; decals need alpha-scissor support in `ModuleCatalog._build_material` first). `Door_Frame_Square_Blocked` reads as a solid wall, so it is `mk_cell_sealed`, not the bars. |
| Quaternius Sci-Fi Essentials | Yes (itch.io, Standard) | 18 models; prop/gun textures only | `quaternius_essentials.json`, 26 pieces | No | Trim textures are byte-identical to the MegaKit's, so its manifest points at `quaternius_scifi/Textures/` instead of shipping a second copy. The Standard glTF set has no separate screens: desks stand in for consoles. Its blue tarp crates are tinted down in the cover sockets. |
| Quaternius House Interior | **No** | | | | Google Drive answers "Quota exceeded" for every file (even License.txt). Not needed: Kenney Furniture Kit covered toilet, sink, shower, washer and bunk. |
| Quaternius Ultimate Furniture | **No** | | | | Drive quota, as above. Not needed: KayKit covers beds, chairs and tables. |
| Quaternius Ultimate Modular Sci-Fi | **No** | | | | Drive quota, as above. Since found as a direct CC0 download on OpenGameArt (https://opengameart.org/content/lowpoly-modular-sci-fi-environments, `ultimate_modular_sci-fi_-_feb_2021.zip`), but not imported: it is as stylised as the MegaKit, and the second pass went for grittier art. FBX/OBJ/Blend only. |
| Quaternius Scifi Pod | Yes (Poly Pizza GLB) | Yes | `polypizza_cc0.json` | No | Reads as a white pod-pillar; fine as a specimen tank. |
| Quaternius Survival | **No** | | | | Drive quota. Not needed: Sci-Fi Essentials `Prop_HealthPack` is the medbay first-aid prop. |
| Kenney Furniture Kit | Yes (kenney.nl) | 8 `.glb` | `kenney_furniture.json`, 8 pieces | No (courtesy) | `bedBunk` (CC0) replaces the CC-BY Zsky bunk; `shower`/`showerRound` and `washerDryerStacked` fill two of the "Blender" gaps. |
| Kenney Space Station Kit | Yes (kenney.nl) | 7 `.glb` + colormap | `kenney_spacestation.json`, 7 pieces | No (courtesy) | Cartoony; consoles, wall displays and a wall switch, as fallbacks. It has no lockers or machinery worth taking. |
| Extra CC0 singles (Poly Pizza) | Yes | Quaternius "Toilet", "Scifi Computer"; Dipper98 "Sci Fi Engine", "Sci Fi Wall Power Cell" | `polypizza_cc0.json` | No | From the unchecked leads, licences checked on each page: CC0. The engine is a 3x2 machinery piece; the power cell is the electrical-panel hazard; the computer is a CC0 server rack. |
| Zsky Interior Props | Yes (4 models) | Punching Bag, Barbell, Gymmat, Dumbell | `polypizza_ccby.json` | **Yes: done** | Bunk Bed and wardrobes not taken: CC0 bunk (Kenney) and locker (Sci-Fi Essentials) found. Model pages say CC BY 3.0, bundle page 4.0: credited as 4.0 with both licences linked. |
| Jeremy Eyring server rack | Yes | Yes (+3 PNGs Godot extracts) | `polypizza_ccby.json` | **Yes: done** | |
| Ali12 Lab Table | Yes | Yes | `polypizza_ccby.json` | **Yes: done** | |
| Nick Slough Scifi Canister | Yes | Yes | `polypizza_ccby.json` | **Yes: done** | CC BY 3.0 (checked); the gas-canister hazard. |
| Floor textures | Yes (ambientCG, 1K JPG) | Tiles107, DiamondPlate003, Carpet012, MetalPlates004 | `floors/floor_{medical,engineering,quarters,command}.tres` | No | Not kit pieces, so no manifest. World triplanar, one repeat per tile. Nothing uses them until D.5. |
| **Poly Haven** (second pass) | Yes (API, 1k glTF) | 40 photoscanned props, one folder each | `polyhaven.json`, 42 pieces | No (courtesy) | CC0. Real-world metres, so most keep scale 1 (`steel_frame_shelves_01` is authored at 10x). Medical bed (rusted iron frame), treatment chair, lab benches with microscope or chemistry set, metal desks (one with a radio as a comms console), tool carts and a vice bench, generator, aircon, welding cart, drill press, fuel drums and jerrycans, propane/LPG cylinders, electrical cabinets, a fuse box as the power switch, steel racks, military crates, stools, armchair, and dressing (medical box, extinguisher, trash cans, hand truck, security camera, ammo cans). 1.5k-50k tris per model; ~100 MB of textures in LFS. Weighted 2-4 against the stylised kits' 1-3. |
| OpenGameArt hospital bed | Yes | Converted `.blend` → `.glb` in Blender | `opengameart_ccby.json` | **Yes: done** | "Small Hospital Bed", TiZiana / qubodup, CC BY 3.0. Its licence file carries the author's moral-rights note; see `CREDITS.md`. |

Credits: the CC BY entries are in `CREDITS.md` and `scripts/credits.gd` (in-game "Art" section);
each CC BY `.glb` also has a `<name>.LICENSE.txt` beside it.

### What was built besides assets

- **`ModuleCatalog` manifest features**, documented in its header: `parts` (several models drawn
  as one piece; the morgue, workbench, elevator door and weapon racks are kitbashed this way),
  `tint`/`paint` (recolour; the brief's "tinted red", "retinted white"), texture paths given as
  full `res://` paths, and `emission` maps.
- **Furniture convention**, in every new manifest's notes: origin at the footprint centre on the
  floor, long side along X, front +Z; each piece has `footprint` (tiles) and `tier` (light, heavy,
  dressing, clutter, wall, door). D.6 can pick by kind and filter by footprint and tier.
- **`tools/test_kit_coverage.gd`** now checks every furniture piece against its footprint and
  tier, and that every kind in the mapping table has a piece. 1,414 checks pass.
- **`tools/room_kit_gallery.gd`** renders every furniture socket from the tactical camera's angle
  with footprints outlined: the check this brief asks for, repeatable after any art swap.
- Sockets not in the mapping table: `furniture_galley_hood` (wall-mounted above a stove),
  `terminal_wall` (the existing `terminal` socket is a floor prop capped at 1.1 m, so the wall
  access point got its own), and dressing sockets `dressing_floor`, `dressing_wall`,
  `dressing_clutter`, `dressing_weapon` with `rooms` tags.

### Pieces per socket

| Socket | Pieces (tier) |
|---|---|
| `cover_light` / `cover_heavy` (new only) | `qe_crate_light`, `qe_tarp_light` / `qe_crate_heavy`, `qe_tarp_heavy` |
| `furniture_bunk` | `kf_bunk` |
| `furniture_bed` | `ph_iron_bed`, `kk_bed_single_a`, `kk_bed_single_b`, `kk_bed_double_a` |
| `furniture_locker` | `qe_locker`, `qe_locker_pair`, `kk_cabinet_stack`, `kk_cabinet_small_stack` |
| `furniture_toilet` | `kf_toilet`, `kf_toilet_square`, `pp_toilet` |
| `furniture_sink` | `kf_sink`, `kf_sink_square` |
| `furniture_shower` | `kf_shower`, `kf_shower_round` |
| `furniture_washer` | `kf_washer_dryer` |
| `furniture_mess_table` | `kr_mess_table_a`, `kr_mess_table_b_long` (1x3), `kr_mess_table_round`, `kk_table_long`, `kk_table_square` |
| `furniture_chair` | `ph_metal_stool`, `ph_metal_stool_low`, `ph_school_chair`, `kk_chair`, `kr_chair_a`, `kr_chair_b`, `kr_stool`, `qe_chair` |
| `furniture_galley` | `kr_counter`, `kr_counter_sink`, `kr_counter_corner`, `kr_stove` (light); `kr_oven`, `kr_fridge_a`, `kr_fridge_b` (heavy) |
| `furniture_galley_hood` | `kr_extractor_hood` (wall) |
| `furniture_couch` | `ph_armchair`, `kk_couch`, `kk_armchair`, `kk_coffee_table` |
| `furniture_gym` | `pb_punching_bag`, `pb_barbell`, `kk_gym_bench` |
| `furniture_med_bed` | `og_hospital_bed`, `ph_iron_bed_med`, `kk_med_bed_white` (stand-in) |
| `furniture_surgery` | `ph_treatment_chair`, `kk_surgery_table` (stand-in) |
| `furniture_monitor` | `mk_monitor`, `kst_display_wall`, `kst_display_wall_wide` |
| `furniture_lab_bench` | `ph_lab_bench_microscope`, `ph_lab_bench_chemistry`, `pb_lab_table` (1x3), `kk_lab_bench` |
| `furniture_specimen_tank` | `pp_scifi_pod`, `mk_specimen_column` |
| `furniture_morgue` | `mk_morgue_drawers` (stand-in) |
| `furniture_machinery` | `pp_engine` (3x2), `ph_welding_cart`, `mk_pipe_column`, `mk_crate_machine`, `kb_structure_tall` (heavy); `ph_generator`, `ph_aircon`, `ph_drill_press`, `mk_pipe_rack`, `kb_structure_low` (light) |
| `furniture_console` | `ph_desk`, `ph_comms_desk`, `mk_console`, `qe_desk_medium`, `qe_desk_small`, `qe_desk_l`, `kst_computer`, `kst_computer_screen`, `kst_computer_wide`, `kst_computer_system` |
| `furniture_server_rack` | `pb_server_rack`, `pp_scifi_computer` |
| `furniture_weapon_rack` | `ph_rack_ammo`, `ph_steel_shelves`, `qe_rack_thin`, `qe_rack_wide` (shelves with guns as parts) |
| `furniture_workbench` | `ph_vice_bench`, `ph_tool_cart`, `ph_storage_cart`, `qe_workbench`, `kk_workbench` |
| `furniture_cell_bars` | `mk_cell_bars` (stacked railings), `mk_cell_sealed` |
| `furniture_crate` | `ph_military_crates`, `ph_wooden_crates`, `ph_plastic_totes`, `ph_steel_shelves_narrow`, `ph_metal_rack_store`, `mk_crate_store_light`, `mk_crate_store_heavy`, `mk_chest_store`, `qe_crate_store_light`, `qe_crate_store_heavy`, `qe_tarp_store_light`, `kr_crate`, `kr_crate_potatoes`, `kb_cargo_packed` |
| `furniture_cargo` | `ph_wooden_crate_stack`, `kb_cargo_a_stacked`, `kb_cargo_b_stacked`, `kb_containers_abc`, `kb_containers_dba`, `qe_cargo_long`, `qe_cargo_tarp_long`, `mk_cargo_crate` |
| `hazard_fuel_tank` | `ph_fuel_drum`, `ph_fuel_drums`, `ph_jerrycans`, `mk_fuel_barrels` (four, tinted red), `qe_fuel_barrel` |
| `hazard_gas` | `ph_gas_cylinders`, `ph_lpg_pair`, `pb_gas_canister`, `mk_gas_barrels` (three, tinted yellow), `qe_gas_barrel` |
| `hazard_panel` | `ph_utility_box`, `ph_utility_box_wide`, `pp_power_cell` |
| `terminal_wall` | `mk_terminal_wall` |
| `power_switch` | `ph_fuse_box`, `mk_power_switch`, `kst_wall_switch` |
| `elevator_door` | `mk_elevator_door` (frame + two dark-metal leaves) |
| `dressing_floor` / `dressing_wall` / `dressing_clutter` / `dressing_weapon` | lamp, dish rack, ammo boxes, tool chest, extinguisher, trash cans, hand truck / shelves, wall medkit, security camera / rug, gym mat, dumbbells, vents, cables, medical box, cardboard box, ammo cans / rifle, pistol, weapon holder (MegaKit holder + rifle) |

### Open questions for the designer

- **Tall light furniture.** `kf_bunk` (1.6 m), `kr_counter_sink` (tap to 1.7 m),
  `pb_punching_bag` (1.8 m) and `ph_treatment_chair` (1.5 m) are light tier but stand well above
  light-cover height; each carries a `tall` reason and the test lets them through. D.3 says light
  pieces are low: either accept these, or make bunks heavy.
- **Style.** KayKit and Kenney pieces are bright and toy-like beside the MegaKit (see the brief's
  intro). The Sci-Fi Essentials and Poly Haven pieces match the gritty direction; Poly Haven's are
  weighted to win wherever they share a socket. Poly Haven is Earth-realistic (wooden crates,
  school chair): grimy, not sci-fi.
- **Scale.** Poly Haven props are true size, so a generator or gas bottle is small inside a 1.5 m
  cover block. If D.6 wants each block to read as full cover, give those kinds a cluster (as the
  fuel and gas pieces already are) rather than scaling a prop up.

**Still needs Blender or a manual download:** operating table and morgue drawer wall. Stand-ins:
the Poly Haven treatment chair (surgery) and two MegaKit chests stacked (morgue). The medical bed is
covered now (OpenGameArt hospital bed, Poly Haven iron bed frame). Sketchfab has CC BY models of
both, below.

**Manual downloads for the user** (optional; nothing is blocked on them). Sketchfab serves
downloads only to a logged-in account, so these could not be fetched by script. All are CC BY
(credit required; checked 2026-11-09) and downloadable. On each page choose Download → glTF, and
save the zips, unopened, into `C:\Users\jpcol\Downloads\sketchfab_medical\`; an agent then imports
them as a `sketchfab_ccby` kit with credits, the same way as the Poly Pizza CC BY models.

| Kind | Model (author, faces) | Page |
|---|---|---|
| Operating table | Hospital Bed (cobblegames, 5.5k): padded table on a pedestal | https://sketchfab.com/3d-models/hospital-bed-02ab679ff3f24018a8bcaf30b3b2cd47 |
| Operating table | C Arm Neurosurgery Operating Table (INGSOC1984, 9.2k) | https://sketchfab.com/3d-models/c-arm-neurosurgery-operating-table-f92ebb77ec8249f8bb53cb9f256f55cc |
| Morgue drawer wall | Morgue Body Storage (JanStrydom, 4k) | https://sketchfab.com/3d-models/morgue-body-storage-1d81efc4d3e84abe8d20c413a1018730 |
| Morgue drawer wall | morgue refrigerator (ahmagh2e, 26k, 12 MB) | https://sketchfab.com/3d-models/morgue-refrigerator-12mb-3d582d8eabed42619ace30ab639c6e66 |
| Morgue / surgery | Autopsy table (windofglass, 0.9k) | https://sketchfab.com/3d-models/autopsy-table-c56bae8cd45747fda74e2f0180f494a0 |
| Medical bed | Hospital Bed (loxfear, 4k): old iron bed | https://sketchfab.com/3d-models/hospital-bed-f8c13a19e84343e7b644c19f7b9488d3 |
| Gurney | OLD Hospital Stretcher (shubham_mishra, 0.9k); PS1 Horror Hospital Gurney (JanStrydom, 1.7k) | https://sketchfab.com/3d-models/old-hospital-stretcher-f6f350bf2c754644a69dac2ac21e1230 · https://sketchfab.com/3d-models/ps1-horror-hospital-gurney-7fce61ac484343959e25208bc75c08ff |
| Monitor | Bed Curtain and Vital Signs Monitor (EDIIIC, 8.8k); Medical Console (OliverTriplett, 3.3k); IV Stand and Bag (Somar52, 3.8k) | https://sketchfab.com/3d-models/bed-curtain-and-vital-signs-monitor-295ed50eeaa249e8bbeed7b305d3da71 · https://sketchfab.com/3d-models/medical-console-89065e109790417191467cfececf2c7c · https://sketchfab.com/3d-models/iv-stand-and-bag-a93a8e70ecd2459c99e7812c6e09b88c |
| Toilet / sink | Filthy Prison Toilet (mark-peters, 3.7k); Filthy Metal Sink (mark-peters, 18.6k) | https://sketchfab.com/3d-models/filthy-prison-toilet-4096px2-b8bdb85f59a44a8ea4b0783c8d22f373 · https://sketchfab.com/3d-models/filthy-metal-sink-4096px2-dcd2b91f54014e95bd488e12f0d54d61 |
| Locker | Metal Cabinet (berkgedik, 0.5k): worn steel locker | https://sketchfab.com/3d-models/metal-cabinet-low-poly-1053729ad9d24d71a578622251f76deb |
| Bunk | Metal Bunk Bed (grimaudk, 4.4k) | https://sketchfab.com/3d-models/metal-bunk-bed-9c05091f02074a908120600e5dbbf5d8 |
| Washer | HL2 Inspired laundry machine 3 (kidney_02, 7.9k) | https://sketchfab.com/3d-models/hl2-inspired-laundry-machine-3-2c2fb960c66743d19e6459cfe95de1ac |
| Server rack | Server Rack (Spellkaze, 0.7k) | https://sketchfab.com/3d-models/server-rack-62f6779cb7e448b19aaf58544c3c7218 |
| Hazard panel | Electrical Control Panel sci-fi (aleksfotoart, 3.9k) | https://sketchfab.com/3d-models/electrical-control-panel-sci-fi-c0dfab99f2c34b4aa76e895362608677 |
| Cell bars | Prison cell door (Rivaldragon, 1.5k); jail (Cell) (Badboy17Aiden, 2.2k) | https://sketchfab.com/3d-models/prison-cell-door-f8148fab4dc44903b9644170edf0e58c · https://sketchfab.com/3d-models/jail-cell-ddc41a6835374fd7aa4574e93e0590ca |
| Mess table | School Cafeteria Table (avot, 8k): bench table | https://sketchfab.com/3d-models/school-cafeteria-table-e0a0be3011da4e19963467d20daeaf61 |
| Clutter | PSX Industrial Pack (Tomitos_, 8.6k): pipes, drums, crates, a container | https://sketchfab.com/3d-models/psx-industrial-pack-12cb749961974f94a4063e67dafb2d76 |

Paid but CC0 (cheap, PS1-style gritty, cover every medical gap): **PSX Hospital Pack** by Wildenza,
~90 assets incl. a GLB, from $5.99 (https://wildenza.itch.io/psx-hospital-pack), and **Abandoned
Asylum** by Codyanka, from €1 (https://codyanka.itch.io/asylum). Buy one and drop it in the same
folder to have it imported.

Looked at and **not used**: Atomic Realm's and Madduck's free itch.io hospital packs (own licences
that forbid redistributing the files: this repo is public), samgauths' Hospital Room pack and
Retro Assets Library's PSX Med Pack (no licence stated), every CGTrader/RenderHub/Fab result
(paid, "royalty free"), Poly Pizza's hospital results (whole rooms or buildings).
