# Multiplayer revamp: per-player campaigns in co-op

Status: implemented (2026-11-05). Replaces plan assumption A7 ("the host's campaign IS the
campaign") and answers GDD §12.1 #3 ("are rosters and credits shared?"): **no — every player
brings their own campaign.**

## 1. Decisions (from the design grilling, 2026-11-05)

| Topic | Decision |
|---|---|
| Save | Each player's co-op roster is their **solo campaign save** (`user://campaign.json`). No separate co-op profile. |
| Squad | Each player brings **1–2** soldiers from their own roster. Squad total ≥ 2, ≤ 8. |
| Players | Up to **4** (Steam lobby `MAX_MEMBERS = 4`). |
| Gear in | Each soldier's attachments, ammo and grenades come from **their owner's** stash / stock. |
| Loot | Banks into the save of **whoever's soldier carried it out**. Gear handed to a partner's soldier stays with that soldier's owner. |
| Payout | Split **evenly** among every player in the deployment, including wiped or disconnected ones. |
| Scaling | Enemies and payout scale with squad size (factor `max(1, soldiers / 4)`). |
| Client save side effects | `missions_played + 1`, recruit and contract boards re-roll, game-over check applies (and can wipe the save). |
| Trust | Friends-only lobbies; the host trusts the data clients send, and clients trust the host's reports. |
| Hubs | Everyone runs their **full hub on their own save** at the same time, then readies up. |
| Contracts | From the **host's board**. Clients vote, the host picks, and Launch needs everyone Ready. |
| Visibility | Players see partners' picked soldiers and partners' full rosters (read-only). Lobby chat. Credits/stash stay private. |
| Leader powers | Host can **kick** (lobby only, never mid-mission) and **pause** for everyone. The host cannot abort a mission or override picks. |
| Control | Players command **only their own soldiers**. |
| Client drops | Can **rejoin mid-mission**. Meanwhile the host drives their soldiers. If the mission ends first, the host keeps a **pending report** and delivers it next time that player connects. |
| Pending soldiers | Locked on the player's save ("deployed with <host>"). The rest of the save plays on. A **Write off** button books them lost. |
| Host crash / quit | **Host-resume**: the host's save keeps the mission's round checkpoint; reloading offers Resume. Absent clients are driven by the host and get pending reports. |
| Joining | Steam **friend invites** and a **friends' lobbies list**. A lobby-ID field stays as a `--dev`-only fallback. |
| Debrief | Your own full debrief plus a short **party summary** (partners' soldiers' fates). |

### Defaults settled during implementation

- A save already **mid-solo-mission** cannot reach the hub (the interrupted mission is booked as
  lost first, as before), so it can never be in co-op at the same time.
- A pending report that arrives **after** a write-off is ignored. The client acks it so the host
  drops it.
- **Votes are advisory**. The host sees the counts and picks.
- **Pause** freezes the scene tree on every peer, both turn mode and the exploration clock. Only
  the host can pause or resume for everyone. Everyone else's Esc menu is a local overlay that
  does not pause.
- **Locked (pending) soldiers still count** for the game-over check: they are not dead yet.
- **Solo** quitting mid-mission is unchanged (ironman: the squad is lost). Only a **co-op host's**
  quit is resumable.

## 2. Architecture

### 2.1 Identity

Peer ids change on every connection, so ownership and reports are keyed by a **player key**: the
Steam ID as a string (`"local"` when Steam is unavailable). `CoopPlayers` keeps a host-authoritative
table, broadcast to all: `peer_id → {key, name, color}`. A client sends `hello(key, name)` on connect.

- `PlayerUnit.owner_key` is set at spawn from the deployment record's `owner`.
- `owner_peer_id` is derived from the key on every peer (`CoopPlayers.peer_of(key)`), and
  re-derived when a player drops (→ host) or rejoins (→ them).

### 2.2 The lobby (`CoopLobby` autoload, `scripts/net/coop_lobby.gd`)

Host-authoritative state, broadcast whole on every change (small: four players):

```
members: key -> {name, peer, ready, picks, grenades, roster, vote}
board:   the host's contract offers (dicts), selected index
phase:   "hub" | "mission"
mission: {mission_id, owners: [keys]}   (while phase == "mission")
paused:  bool
```

Client → host: `hello`, `set_picks(picks, grenades, roster)`, `set_ready`, `vote`, `chat`.
Host → all: `table`, `chat_line`, `paused`. Host → one: `kicked`. The deployment, `rejoin` and
`report` RPCs live on `Campaign`, and the snapshot request and reply on the mission scene.

The engine-free rules live in `CoopRules` (`scripts/net/coop_rules.gd`, tested by
`tools/test_coop_campaign.gd`): launch blockers, deployment merge, report split, payout share,
scaling.

### 2.3 Deployment

Each player's hub builds a **pick package** from their own save
(`CampaignState.make_pick(record_ids, grenade_counts)`): their records with loadouts clamped to
**their** stash, their grenade allotment clamped to **their** stock, and their stash and ammo
unlocks. The host merges the packages (`CoopRules.merge_deployment`):

```
records:   [... each record dict carries "owner": key]
grenades:  [...]
owners:    {key: {name, attachments, ammo}}
offer, deck, spawn_seed
scale:     max(1, soldiers / 4)
coop:      {mission_id, host_key, host_name, players: [keys]}
```

Every peer then books its **own** soldiers on its **own** save
(`CampaignState.begin_coop(deployment, my_key)`):

- **Host**: `in_mission` as before, plus `coop: {mission_id, …}`, which makes it resumable
  rather than an ironman loss.
- **Client**: an entry in the new `away` list, `{mission_id, host_key, host_name, records,
  grenades}`. The listed soldiers are locked until a report or a write-off clears the entry.
  `in_mission` stays free.

Grenades leave the owner's stock at launch, as in solo.

### 2.4 In the mission

- Units spawn as before (deterministic on every peer from the deployment), each owned by its
  record's `owner`.
- Extra spawn tiles are found around the insertion spawns when the squad exceeds the deck's 4
  (breadth-first, same order on every peer).
- **Scaling**: horde sizes and the contract payout are multiplied by `scale`. The map generator is
  untouched, so the board's deck preview is the deck you get.
- **Loadout**: each peer fits its own soldiers from its own stash (`deployment.owners[my_key]`).
  No more host/client share split.
- **Esc menu** (`MissionMenu`) on every peer: Resume / Settings / Leave.
  - The host also gets **Pause for everyone**.
  - A client's **Leave** drops them, and their soldiers go pending.
  - A co-op host's **Leave** saves the checkpoint and quits (resumable).
  - Solo **Leave** is ironman (squad lost).

### 2.5 The mission snapshot (`MissionSnapshot`, `scripts/net/mission_snapshot.gd`)

One serializer serves both **rejoin** (live, sent over the wire) and **host-resume** (the
round-start checkpoint, on disk at `user://coop_mission.json`). It is a delta on top of the
deterministic base board, so it never re-describes what every peer already builds from the
deployment:

| Section | What |
|---|---|
| `turn` | round number, mode, step clock, last combat round, active unit |
| `journal` | every mid-mission spawn in order (nest spawn, worm shed, dev spawn) and every cover hit, replayed through the same code that did them the first time |
| `units` | per unit by node name: the replicated property set (`Unit.REPLICATED`) plus owner key, record id, grenades, injuries, weapon, alert state, horde/worm specifics |
| `gone` | implied: any unit on the rebuilt board that the snapshot does not list is removed (boarded mercs, dissolved worms) |
| `aboard` | units already on a ship |
| `hangars` | each hangar's rules snapshot, discovery per crew, retired crews, door-gun HP |
| `loot` | every container's and pile's contents |
| `objective` | terminal progress, item flown out |
| `world` | hivemind escalation, security-network salvage |

**Fidelity.** Rejoin is exact for everything the client draws, since the synchronizers keep
streaming afterwards. Host-resume restarts **the round that was in progress**, from its start:

- The checkpoint is written at every round start.
- AI plans, squad blackboards, merc job progress, reaction tracks and in-flight animations are
  rebuilt fresh.
- Everything that decides a debrief survives a resume: who is alive, where, with what, aboard
  what, the objective, and the loot.

### 2.6 Rejoin

1. A dropped client relaunches (or stays in their hub). Their save shows the soldiers as
   "deployed with <host>".
2. They join the host's lobby (invite or friends' list) and say `hello(key)`.
3. The host is in phase `mission` and the key is in `mission.owners`, so it sends
   `rejoin(deployment)`. The client accepts only if its save is still away on that mission.
4. The client loads the mission scene in rejoin mode, builds the base board, and asks for the
   live snapshot. The host captures it, adds the client to `ready_peers` (so every later event is
   ordered after the snapshot), and sends it. The client applies it, skips the loadout, and
   reports ready.
5. The host makes every unit visible to the client and hands the client's soldiers back to
   them.

A lobby member who is **not** in the running mission waits in their own hub ("party on a
mission").

### 2.7 Reports and pending delivery

At mission end the host builds the full report (every soldier carries `owner`) and splits it
(`CoopRules.split_report`): one report per player. Each has:

- that player's soldiers and benched entries,
- `payout_divisor` (the player count),
- the `party` lines,
- the `mission_id`.

The host books its own. Every other player's report goes into the host save's `pending_reports`
first and is then sent. A client applies one only if its `mission_id` matches an `away` entry,
then acks. The ack deletes it from `pending_reports`. On every `hello` the host re-sends that
key's pending reports, so a client who was gone at the end gets theirs next time they connect
to that host.

`apply_report` on the client: pays `payout / payout_divisor`, banks the loot its own soldiers
carried, `missions_played + 1`, re-rolls the boards, runs the game-over check, and clears the
`away` entry.

### 2.8 Host-resume

The host's save holds `in_mission.coop` and the checkpoint file. On load, campaign select offers
**Resume co-op mission** (or **Write off**: the host's own soldiers are booked lost, and clients
write theirs off on their side).

Resume:
1. Opens a lobby in phase `mission` (when Steam is up).
2. Loads the mission scene in resume mode: base board, apply the checkpoint, every soldier
   driven by the host until its owner rejoins.
3. Continues with `TurnManager.resume_mission`.

## 3. UI

- **Title**: Play / Credits. Co-op moved into the hub, because you need your save loaded to bring
  soldiers.
- **Hub → Co-op tab**:
  - Not in a lobby: **Host co-op**, a **Friends' lobbies** list (Join) with Refresh, and a
    `--dev` lobby-ID field. The list shows every Steam friend playing the game: "<name>'s
    lobby" with Join, or "playing, no open lobby". The lobby comes from Steam's "game played"
    info, else from the host's `connect` rich presence, which is the more reliable of the two.
    It refreshes on Steam's presence pushes and every 4 s while the tab is on screen.
  - In a lobby:
    - Members, each with color, ready mark, picked soldiers and a **View roster** toggle
      (read-only roster).
    - **Kick** (host only).
    - **Invite friends** (Steam overlay).
    - Chat, the color row, **Leave lobby**.
- **Contracts tab** in a lobby: clients see the host's board with **Vote** and the vote counts;
  the host selects, and sees the votes too.
- **Deploy tab** in a lobby: pick 1–2 soldiers and their grenades. Clients get **Ready /
  Unready**. The host gets **Launch** (blocker text until everyone is ready and a contract is
  selected).
- **Roster tab**: pending soldiers show "Deployed with <host>" and a **Write off** button per
  away mission.
- **Debrief**: a **Party** section listing partners' soldiers and their fates.
- **Mission**: an Esc menu (`MissionMenu`) and a "PAUSED BY HOST" banner.

## 4. Files

New:
- `scripts/net/coop_lobby.gd` (autoload `CoopLobby`): the party table, votes, Ready, launch, kick,
  pause, chat; hands rejoins and owed reports to `Campaign`.
- `scripts/net/coop_rules.gd`: launch blocker, deployment merge, report split (engine-free).
- `scripts/net/mission_snapshot.gd`: capture, apply, and the spawn/cover journal.
- `scripts/net/coop_panel.gd`: the hub's Co-op tab.
- `scripts/mission_menu.gd`: the in-mission Esc menu and the host-pause banner.
- `scripts/net/coop_bot.gd` (dev only): a headless stand-in player for the smoke runs.
- `tools/test_coop_campaign.gd`, `tools/test_mission_snapshot.gd`, `tools/coop_smoke.sh`.

Changed:
- `campaign_state.gd`: `away`, `pending_reports`, `make_pick`, `pick_blocker`, `begin_coop`,
  `apply_report` (share, party lines, mission id), `write_off`, save v2 (v1 migrates).
- `campaign.gd`: co-op launch, report split/delivery/ack, rejoin, checkpoint, resume,
  `--save-slot`.
- `campaign_economy.gd`: co-op squad limits, `squad_scale`, `scaled_payout`.
- `steam_lobby.gd`: 4 members, invites, `join_requested`, `+connect_lobby`, friends' lobbies,
  rich presence, kick, and the dev ENet lobby.
- `coop_players.gd`: player keys and names (`hello`).
- `main.gd`: owner keys, extra spawn tiles, scaling, rejoin and resume modes, round checkpoints,
  `quit_mission`.
- `unit.gd` (`REPLICATED`), `player_unit.gd` (`owner_key`).
- `turn_manager.gd`: `resume_mission`.
- `extraction_manager.gd`: `capture` / `restore`.
- `hud.gd`: a two-column squad feed when the squad is bigger than four.
- `front_end.gd`, `hub_menu.gd`, `debrief_menu.gd`, `host_join_menu.gd`.
- Spawn and cover sites journalled: `nest_unit.gd`, `worm_unit.gd`, `dev_spawn.gd`,
  `grid_manager.gd`.
- Mission broadcasts on scene nodes, and loot contents, go only to peers in the mission
  (`SteamLobby.ready_peers`): `main.gd`, `unit.gd`, `player_unit.gd`, `nest_unit.gd`,
  `worm_unit.gd`, `loot_manager.gd`.

## 5. Testing

Unit tests (`godot --headless --path . --script res://tools/<test>.gd`):
- `test_coop_campaign.gd`: pick packages and clamping, launch blockers, the merged deployment,
  booking out (host `in_mission` vs guest `away`), locks, the report split, the payout share
  (wiped players included), loot to the carrier's owner, applying once only, pending reports
  (replace, survive the file, ack), write-off and a late report after it, game over with locked
  soldiers, v1 → v2 migration, scaling.
- `test_mission_snapshot.gd`: on a real contract deck built through `main.tscn`, play changes (a
  soldier hurt, injured, moved, rotated, out of grenades; a hostile killed, another alerted; a
  crate looted into a pile; cover hit; a hangar found; the hivemind roused; a nest spawn; a unit
  off the board; a soldier aboard). Then capture, check the file round trip, rebuild the board from
  the deployment, apply, recapture, and compare everything, as a resuming host and again as a
  rejoining client.
- The existing `test_campaign.gd` and `test_coop_players.gd` still pass, and so do the `--auto` /
  `--auto-campaign=N` smoke runs (solo is unchanged).

End to end, headless, on one machine (`GODOT=<console exe> tools/coop_smoke.sh all`): two or three
game instances over the dev ENet lobby, each on its own save slot, driven by `CoopBot`.
- `basic`: host and guest. Lobby, picks, Ready, launch, rounds, extract. Each save books its own
  soldiers; the guest's carried valuables are sold into the guest's save; the host's owed report
  is delivered and acked.
- `three`: host and two guests (six soldiers, so the 1.5x scaling).
- `rejoin`: the guest leaves in round 2, rejoins, is handed its soldiers back, and gets its report.
- `resume`: the host saves and quits in round 2 (checkpoint written). Relaunched, it resumes; the
  guest, retrying in its hub, is brought back in, and both saves book the mission.

Manual co-op testing on one machine: run two windowed instances with `--dev --save-slot=a
--player-key=a` and `--dev --save-slot=b --player-key=b`. Use the Co-op tab's "LAN lobby (dev)".

**Needs a human with Steam (two accounts or two machines; Spacewar 480 supports it):** the overlay
invite and accepting it, the friends' lobby list, rich-presence "Join game", and a real session
over Steam relay. Everything past the transport is the same code the ENet smoke runs exercise.

## 6. Known limits

- **Resume fidelity**: the round in progress restarts from its start. AI plans, squad
  blackboards, merc job progress, suppression links and reaction tracks are rebuilt fresh.
  Positions, health, injuries, packs, ammo, awareness, hangars, loot, cover, objective, aboard and
  the round are all exact.
- **A lobby member who joins while the party is out** waits in their own hub. Mission traffic on
  scene nodes is not sent to them, but the autoloads' broadcasts (turn and clock numbers, the
  combat log) still reach their idle `TurnManager`. That's harmless: the next mission start resets
  it.
- **Pending reports are held by the host's save**. A player who never reconnects to that host
  keeps their soldiers locked until they press Write off.
