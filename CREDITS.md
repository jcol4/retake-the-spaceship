# Credits

The text players actually see lives in `scripts/credits.gd`, which the main
menu's Credits button draws — that is the copy a licence requiring attribution
is satisfied by. **This file documents the obligations; that file discharges
them.** Adding an asset that needs crediting means editing both.

## Third-party assets

### Audio

**ZapSplat** — https://www.zapsplat.com

Licence: ZapSplat Standard (free tier). Attribution is **required**. The wording
ZapSplat asks for is:

> Sound effects obtained from https://www.zapsplat.com

Files:

| File | ZapSplat ID | Original filename |
| --- | --- | --- |
| `assets/audio/sfx/weapons/rifle_fire_01.wav` | 62798 | `zapsplat_warfare_machine_gun_powerful_burst_designed_001_62798.wav` |

The Standard licence also forbids redistributing the sounds as sounds (i.e.
shipping them inside the game is fine; committing them to a public repo as
downloadable assets is the grey area). This repo is public — if that becomes a
concern, the fix is a ZapSplat Gold subscription, which drops both the
attribution requirement and the redistribution restriction.

**Kenney — Interface Sounds** — https://kenney.nl/assets/interface-sounds

Licence: CC0 1.0 (public domain). No attribution required, so nothing is added
to `scripts/credits.gd`; the licence text ships beside the files as
`assets/audio/sfx/ui/License.txt`. Renamed, otherwise unmodified:

| File | Original filename |
| --- | --- |
| `assets/audio/sfx/ui/ui_confirm.ogg` | `Audio/switch_007.ogg` |
| `assets/audio/sfx/ui/ui_denied.ogg` | `Audio/drop_002.ogg` |

### Room tiles

**Quaternius — Modular Sci-Fi MegaKit (Standard)** — https://quaternius.com

Licence: CC0 1.0 (public domain). No attribution required, so nothing is added
to `scripts/credits.gd`; the licence text ships beside the kit as
`assets/room_tiles/quaternius_scifi/License_Standard.txt`.

Files: `assets/room_tiles/quaternius_scifi/glTF/` (original names) and the
`Textures/` it uses, mapped to sockets by `quaternius_scifi.json`.

### Placeholder furniture (ROOM_ASSETS_SOURCING.md)

**CC BY: attribution required.** Each is credited in `scripts/credits.gd`
("Art"), with title, author, source and licence. All are used unmodified (the
manifests scale them at load time; nothing recolours them).

| Model | Author | Licence | Source | File |
| --- | --- | --- | --- | --- |
| server rack | Jeremy Eyring | CC BY 3.0 | https://poly.pizza/m/6ijQclm8jxw | `assets/room_tiles/polypizza_ccby/server_rack.glb` (+ the three `server_rack_*.png` Godot extracts from it) |
| Lab Table | Ali12 | CC BY 3.0 | https://poly.pizza/m/NyeiCAto3N | `assets/room_tiles/polypizza_ccby/Lab_Table.glb` |
| Scifi Canister | Nick Slough | CC BY 3.0 | https://poly.pizza/m/OzcIJxCDpO | `assets/room_tiles/polypizza_ccby/Scifi_Canister.glb` |
| Punching Bag | Zsky | CC BY (see note) | https://poly.pizza/m/4VgbuuhY8j | `assets/room_tiles/polypizza_ccby/Punching_Bag.glb` |
| Barbell | Zsky | CC BY (see note) | https://poly.pizza/m/AX5jGlJZlk | `assets/room_tiles/polypizza_ccby/Barbell.glb` |
| Gymmat | Zsky | CC BY (see note) | https://poly.pizza/m/gHLnNRu37P | `assets/room_tiles/polypizza_ccby/Gymmat.glb` |
| Dumbell | Zsky | CC BY (see note) | https://poly.pizza/m/hOBP8R1z1f | `assets/room_tiles/polypizza_ccby/Dumbell.glb` |
| Small Hospital Bed | TiZiana (original, CC BY 2.0), edits by qubodup | CC BY 3.0 | https://opengameart.org/content/small-hospital-bed | `assets/room_tiles/opengameart_ccby/hospital_bed_small.glb` |

The hospital bed is the one file not used as shipped: OpenGameArt offers it
only as a `.blend`, so it was exported to `.glb` in Blender (geometry and
texture unchanged), which the in-game credit says. Its pack licence,
`hospital_bed_small.LICENSE.txt`, also carries the author's moral-rights note:
she objects to her models being used for racism, war promotion, cruelty to
animals, propaganda, pornography or encouraging unethical behaviour. A
sci-fi tactics game is not among those as written, but if the game's framing
ever moves toward them, swap this bed out.

Zsky's models come from the Ultimate Interior Props Pack
(https://poly.pizza/bundle/Ultimate-Interior-Props-Pack-9KfkK2H0ve), whose page
text says CC BY 4.0 while each model page links CC BY 3.0. They are credited as
CC BY 4.0 and the in-game line links both licences, which satisfies either.
Each `.glb` has a `<name>.LICENSE.txt` beside it recording author, page and
licence. Licence texts: https://creativecommons.org/licenses/by/3.0/ and
https://creativecommons.org/licenses/by/4.0/.

**CC0: no attribution required** (credited in `scripts/credits.gd` as a
courtesy). Licence files ship beside each kit.

| Source | Licence | Where |
| --- | --- | --- |
| KayKit Furniture Bits, Restaurant Bits, Space Base Bits (Kay Lousberg) | CC0 | `assets/room_tiles/kaykit_*/LICENSE.txt` |
| Quaternius Sci-Fi Essentials Kit (Standard) | CC0 | `assets/room_tiles/quaternius_essentials/License_Standard.txt` |
| Kenney Furniture Kit, Space Station Kit | CC0 | `assets/room_tiles/kenney_*/License.txt` |
| Quaternius "Scifi Pod", "Toilet", "Scifi Computer"; Dipper98 "Sci Fi Engine", "Sci Fi Wall Power Cell" (Poly Pizza) | CC0 | `assets/room_tiles/polypizza_cc0/*.LICENSE.txt` |
| ambientCG Tiles107, DiamondPlate003, Carpet012, MetalPlates004 | CC0 | `assets/room_tiles/floors/LICENSE.txt` |
| Poly Haven: 40 photoscanned props (authors per model in the licence file) | CC0 | `assets/room_tiles/polyhaven/LICENSE.txt` |

### Weapons

| Asset | Licence | Where |
| --- | --- | --- |
| "Service Pistol" by Mateusz Sadek (Poly Haven, polyhaven.com/a/service_pistol): the sidearm, refitted by `tools/build_pistol.py` | CC0 | `art_src/guns/pistol.blend`, `assets/models/guns/pistol.glb` |

## Outstanding

- [ ] `assets/title_page.png` is still unreferenced by any scene or script. The
      Credits button hangs off `HostJoinMenu`, which is the de facto main menu;
      if a proper title screen is ever built from that art, the button moves
      with it.
