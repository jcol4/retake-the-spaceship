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

## Outstanding

- [ ] `assets/title_page.png` is still unreferenced by any scene or script. The
      Credits button hangs off `HostJoinMenu`, which is the de facto main menu;
      if a proper title screen is ever built from that art, the button moves
      with it.
