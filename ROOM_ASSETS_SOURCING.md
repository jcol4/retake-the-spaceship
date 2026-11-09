# Room Furniture Placeholder Assets: Sourcing & Import Brief

Written 2026-11-09 against `3d-models`. **Audience: a Claude agent picking this up cold.** Read
[`ROOM_THEMES_PLAN.md`](ROOM_THEMES_PLAN.md) first: it defines the room types, furniture kinds and
phases this brief serves (mainly Phase D, "Dressing and lighting", and Phase G, "art").

**Goal:** download free (CC0 first, CC-BY only where noted) 3D models to stand in for every
furniture kind in the themed-rooms plan, import them into the project as glTF kits, and register
them so `MapBuilder` can place them. These are placeholders / a demo set, not final art: the art
direction is gritty (see the character art notes), and several of these packs are cleaner and
more colourful than that.

Nothing below has been downloaded yet. Licences marked "checked" were read on the source page on
2026-11-08; file lists marked "checked" were read from the pack's GitHub repo.

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

Update this section as you go.

| Pack | Downloaded | Imported | Manifest | Credits needed | Notes |
|---|---|---|---|---|---|
| KayKit Furniture Bits | | | | No | |
| KayKit Restaurant Bits | | | | No | |
| KayKit Space Base Bits | | | | No | |
| MegaKit unused props | n/a | n/a | | No | |
| Quaternius Sci-Fi Essentials | | | | No | |
| Quaternius House Interior | | | | No | |
| Quaternius Ultimate Furniture | | | | No | |
| Quaternius Ultimate Modular Sci-Fi | | | | No | |
| Quaternius Scifi Pod | | | | No | |
| Quaternius Survival | | | | No | |
| Kenney Furniture Kit | | | | No (courtesy) | |
| Kenney Space Station Kit | | | | No (courtesy) | |
| Zsky Interior Props | | | | **Yes** | |
| Jeremy Eyring server rack | | | | **Yes** | |
| Ali12 Lab Table | | | | **Yes** | |
| Floor textures | | | | No | |

**Still needs Blender (no free model found):** shower stall, washing machine, medical bed,
operating table, morgue drawer wall.

**Manual downloads for the user:** (list here any link you couldn't fetch, with the folder to put
it in)
