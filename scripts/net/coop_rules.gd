class_name CoopRules
extends RefCounted
## The rules of per-player co-op (MULTIPLAYER_PLAN.md) as pure functions on plain
## dictionaries: who may launch, how each player's pick becomes one squad, and how
## the mission's one report becomes one report per player. No scene, no autoload,
## no network — CoopLobby and Campaign call these; tools/test_coop_campaign.gd
## drives them directly.
##
## A MEMBER (CoopLobby's table, one per player key):
##   {name, ready: bool, pick: {records, grenades, attachments, ammo} (or {}),
##    roster: [record dicts], vote: int}
## `order` is the lobby's member keys, host first — the spawn and ownership order.


## Why the host cannot launch yet, or "". The host's own Ready is implied by the
## Launch press; everybody else must have readied up with a valid pick.
static func launch_blocker(order: Array, members: Dictionary, offer_index: int, board_size: int) -> String:
	if offer_index < 0 or offer_index >= board_size:
		return "Choose a contract"
	var total := 0
	for i in order.size():
		var key := String(order[i])
		var m: Dictionary = members.get(key, {})
		var pick_recs: Array = (m.get("pick", {}) as Dictionary).get("records", [])
		var n := pick_recs.size()
		var who := String(m.get("name", "A player"))
		if n < CampaignEconomy.COOP_MIN_PER_PLAYER or n > CampaignEconomy.COOP_MAX_PER_PLAYER:
			return "%s must pick %d–%d soldiers" % [
				"You" if i == 0 else who, CampaignEconomy.COOP_MIN_PER_PLAYER, CampaignEconomy.COOP_MAX_PER_PLAYER]
		if i > 0 and not bool(m.get("ready", false)):
			return "Waiting for %s to ready up" % who
		total += n
	if total < CampaignEconomy.MIN_SQUAD:
		return "The squad needs at least %d soldiers" % CampaignEconomy.MIN_SQUAD
	if total > CampaignEconomy.COOP_MAX_SQUAD:
		return "The squad is at most %d soldiers" % CampaignEconomy.COOP_MAX_SQUAD
	return ""


## One deployment out of every player's pick, in lobby order (host first). Shaped
## like a solo `CampaignState.make_deployment` — main.gd builds the mission from it
## the same way — plus:
##   records[i].owner  the player key whose save that soldier is from
##   owners            key -> {name, attachments, ammo}: each player's own stash,
##                     which their loadout screen fits their own soldiers from
##   scale             CampaignEconomy.squad_scale of the squad (enemies, payout)
##   coop              {mission_id, host_key, host_name, players: [keys], names}
## Top-level `attachments`/`ammo` are the host's, for anything that reads a solo
## deployment.
static func merge_deployment(order: Array, members: Dictionary, offer: Dictionary,
		spawn_seed: int, mission_id: String) -> Dictionary:
	var recs: Array = []
	var counts: Array = []
	var owners := {}
	var names := {}
	for key_v in order:
		var key := String(key_v)
		var m: Dictionary = members.get(key, {})
		var pick: Dictionary = m.get("pick", {})
		var pick_recs: Array = pick.get("records", [])
		var pick_counts: Array = pick.get("grenades", [])
		for i in pick_recs.size():
			var d: Dictionary = (pick_recs[i] as Dictionary).duplicate(true)
			d["owner"] = key
			recs.append(d)
			counts.append(int(pick_counts[i]) if i < pick_counts.size() else 0)
		owners[key] = {
			"name": String(m.get("name", "")),
			"attachments": (pick.get("attachments", {}) as Dictionary).duplicate(),
			"ammo": (pick.get("ammo", [AmmoPresets.AmmoId.STANDARD]) as Array).duplicate(),
		}
		names[key] = String(m.get("name", ""))
	var host_key := String(order[0]) if not order.is_empty() else ""
	var host_owner: Dictionary = owners.get(host_key, {})
	var o := ContractOffer.from_dict(offer) if not offer.is_empty() else null
	return {
		"records": recs,
		"grenades": counts,
		"offer": offer.duplicate(),
		"deck": o.deck() if o != null else {},
		"attachments": (host_owner.get("attachments", {}) as Dictionary).duplicate(),
		"ammo": (host_owner.get("ammo", [AmmoPresets.AmmoId.STANDARD]) as Array).duplicate(),
		"spawn_seed": spawn_seed,
		"owners": owners,
		"scale": CampaignEconomy.squad_scale(recs.size()),
		"coop": {
			"mission_id": mission_id, "host_key": host_key, "host_name": names.get(host_key, ""),
			"players": order.duplicate(), "names": names,
		},
	}


## Whether `deployment` is a per-player co-op one (has an owner table).
static func is_coop(deployment: Dictionary) -> bool:
	return deployment.has("coop") and not (deployment.get("coop", {}) as Dictionary).is_empty()


## The players a co-op deployment was launched with, host first.
static func players_of(deployment: Dictionary) -> Array:
	return ((deployment.get("coop", {}) as Dictionary).get("players", []) as Array).duplicate()


## Splits the mission's one report (Campaign.report_from_result, whose soldier and
## benched entries carry `owner`) into one per player in the deployment:
##   soldiers/benched   that player's own only
##   payout_divisor     every player in the deployment, wiped or dropped included
##                      (MULTIPLAYER_PLAN.md: split evenly among everyone launched)
##   party              the OTHER players' soldiers: {player, name, class, fate}
##   mission_id         which `away` entry / `in_mission` it settles
## Loot needs no rule of its own: it rides in each soldier's `items`, so it lands in
## the save of whoever's soldier carried it out.
static func split_report(report: Dictionary, deployment: Dictionary) -> Dictionary:
	var coop: Dictionary = deployment.get("coop", {})
	var players: Array = coop.get("players", [])
	var names: Dictionary = coop.get("names", {})
	var mission_id := String(coop.get("mission_id", ""))
	var lines: Array = []
	for s: Dictionary in report.get("soldiers", []):
		var owner := String(s.get("owner", ""))
		lines.append({
			"owner": owner, "player": String(names.get(owner, "?")),
			"name": String(s.get("name", "?")), "class": String(s.get("class", "")),
			"fate": String(s.get("fate", CampaignState.FATE_LOST)),
		})
	var out := {}
	for key_v in players:
		var key := String(key_v)
		var mine: Dictionary = report.duplicate(true)
		mine["soldiers"] = (report.get("soldiers", []) as Array).filter(
			func(s: Dictionary) -> bool: return String(s.get("owner", "")) == key).duplicate(true)
		mine["benched"] = (report.get("benched", []) as Array).filter(
			func(b: Dictionary) -> bool: return String(b.get("owner", "")) == key).duplicate(true)
		mine["payout_divisor"] = maxi(1, players.size())
		mine["party"] = lines.filter(func(l: Dictionary) -> bool: return String(l["owner"]) != key).duplicate(true)
		mine["mission_id"] = mission_id
		out[key] = mine
	return out


## A fresh id for one co-op mission: what an `away` entry, a pending report and a
## rejoin all match on. 64 random bits as hex — a string, so it survives JSON.
static func new_mission_id() -> String:
	return "%08x%08x" % [randi(), randi()]
