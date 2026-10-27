class_name CampaignEconomy
extends RefCounted
## Every price in the campaign (GDD §7.5, extraction plan 4.2), in one table, and
## the starting state of a new campaign. PLACEHOLDER numbers, all of them — the
## reasoning is in the decisions log ("Phase 4 — economy"); tune here, nothing
## else hardcodes a price.
##
## THE SHAPE THEY ARE FITTED TO: a DECENT run — a Medium contract completed, four
## or five ordinary finds carried out, nobody lost — pays about 750 cr, which is
## one average recruit (400) plus an attachment or an ammo unlock plus restocking
## the grenades and medical it used. A great run (Large, rare finds) buys two of
## those; a bad one (objective failed, a soldier lost with their kit) costs about
## a recruit and the attachments they carried. Leaving early with a pocketful is
## legal and pays poorly (GDD §2 "push or pull out"): loot alone is ~250 cr.
##
## Engine-free: a --script test prices things without a scene.

# --- Squad -------------------------------------------------------------------------

## A squad is 2–4 soldiers (GDD §2 "small squad"; §7.1). MAX_SQUAD is also the
## generated decks' `player_spawn_count`, so a full squad always has a tile.
const MIN_SQUAD := 2
const MAX_SQUAD := 4
## The roster cap. Twice a full squad: enough to rest the injured and still field
## four, few enough that every name on it is someone the player knows.
const MAX_ROSTER := 8

# --- Starting state -----------------------------------------------------------------

## One soldier per class (GDD §4.5), so a new player meets the whole roster before
## having to choose between them.
const STARTING_CLASSES: Array[int] = [
	UnitStats.UnitClass.ASSAULT, UnitStats.UnitClass.SNIPER,
	UnitStats.UnitClass.SUPPORT, UnitStats.UnitClass.HEAVY,
]
## Enough for one recruit on day one (a bad first mission is survivable) but not
## for a recruit AND a shopping trip.
const STARTING_CREDITS := 500
## One each for a squad of four — the alpha's one-charge-per-soldier (GDD §4.2.2),
## now as stock that has to be replaced once thrown.
const STARTING_GRENADES := 4
## Two treatments: the first injury or two are free, the habit of buying more is
## learned before it matters.
const STARTING_MEDICAL := 2
## A few of the "weaker items are the easy finds" tier (attachments.md), one per
## slot family, so the loadout screen has choices on mission one without the shop
## being pointless. AttachmentPresets ids.
const STARTING_ATTACHMENTS := {
	AttachmentPresets.AttachmentId.VERTICAL_GRIP: 1,
	AttachmentPresets.AttachmentId.HOLO_SIGHT: 1,
	AttachmentPresets.AttachmentId.EXTENDED_MAG: 1,
	AttachmentPresets.AttachmentId.SUPPRESSOR: 1,
}
## Standard only: every special ammo type is an unlock to buy.
const STARTING_AMMO: Array[int] = [AmmoPresets.AmmoId.STANDARD]

# --- Recruits -----------------------------------------------------------------------

## A recruit costs the base plus up to QUALITY more for a roll at the top of every
## class range (SoldierRecord.quality): 300–500, about 400 for a typical roll.
## Paying for quality rather than a flat fee makes the recruit tab a choice
## between candidates rather than "hire whoever is cheapest".
const RECRUIT_BASE_PRICE := 300
const RECRUIT_QUALITY_PRICE := 200
## Candidates on offer per hub visit (re-rolled after each debrief, never on
## reload — CampaignState saves them).
const RECRUITS_MIN := 2
const RECRUITS_MAX := 4

# --- Shop ---------------------------------------------------------------------------

## Attachment copies, priced by tier — the same "strictly worse is the easy find"
## ladder as attachments.md: a flat +3/+5 or a magazine tweak is cheap, a sight or
## a suppressor that changes how a soldier plays is mid, and the three that buy
## an AP or an optic's darkness-ignoring are dear.
const ATTACHMENT_PRICE := {
	AttachmentPresets.AttachmentId.VERTICAL_GRIP: 90,
	AttachmentPresets.AttachmentId.MUZZLE_BRAKE: 90,
	AttachmentPresets.AttachmentId.HEAVY_STOCK: 90,
	AttachmentPresets.AttachmentId.EXTENDED_MAG: 90,
	AttachmentPresets.AttachmentId.LIGHT_MAG: 90,
	AttachmentPresets.AttachmentId.SAWED_OFF_STOCK: 90,
	AttachmentPresets.AttachmentId.ANGLED_GRIP: 140,
	AttachmentPresets.AttachmentId.LASER_SIGHT: 140,
	AttachmentPresets.AttachmentId.SUPPRESSOR: 140,
	AttachmentPresets.AttachmentId.HOLO_SIGHT: 140,
	AttachmentPresets.AttachmentId.DRUM_MAG: 140,
	AttachmentPresets.AttachmentId.ERGO_STOCK: 140,
	AttachmentPresets.AttachmentId.LONG_BARREL: 200,
	AttachmentPresets.AttachmentId.SCOPE: 200,
	AttachmentPresets.AttachmentId.THERMAL_SIGHT: 200,
}
## Ammo is unlocked per TYPE (AmmoPresets: any number of guns can load it once
## owned), so an unlock is priced like two or three attachments — it fits the
## whole squad forever. Penetrator dearest: it is the answer to armor, and armor
## is two of the three factions.
const AMMO_UNLOCK_PRICE := {
	AmmoPresets.AmmoId.PENETRATOR: 250,
	AmmoPresets.AmmoId.HOLLOW_POINT: 200,
	AmmoPresets.AmmoId.SUBSONIC: 150,
	AmmoPresets.AmmoId.FMJ: 150,
	AmmoPresets.AmmoId.SLUG: 200,
}
## Grenades are STOCKED gear (decisions log): bought one at a time into the stash,
## allotted to soldiers at deploy (up to GRENADES_PER_SOLDIER each), and whatever
## is not thrown comes home. Cheap enough to restock every mission, dear enough
## that four of them is a real line in the budget.
const GRENADE_PRICE := 40
## Per-soldier carry limit. Two, up from the alpha's fixed one: a stocked squad
## can bring a second, a poor one brings none, and nobody walks in with six.
const GRENADES_PER_SOLDIER := 2
## The medical resource (GDD §7.5, name TBD — "medkit" in the UI): one clears one
## injured body part between missions.
const MEDICAL_PRICE := 60
const MEDICAL_PER_INJURY := 1

# --- Contracts ----------------------------------------------------------------------

## Deck sizes a contract can name (GDD §7.7: deck size is the mission-length
## lever). APPEND-ONLY: saved as ints.
enum DeckSize { SMALL, MEDIUM, LARGE }
const DECK_SIZE_NAME := {DeckSize.SMALL: "Small", DeckSize.MEDIUM: "Medium", DeckSize.LARGE: "Large"}
## Width x depth handed to MapGenerator.Config. Medium IS the generator's default
## deck (72x48), so a `--seed=` dev run and a Medium contract are the same size.
## One step up from before across the board: a hangar bay is now 3–4x the ship's
## landing zone (GDD §7.2, 210–280 tiles), and three or four of those have to fit
## with rooms between them. Small: 3 hangars; Large: 4 nearly always.
const DECK_DIMENSIONS := {
	DeckSize.SMALL: Vector2i(60, 40),
	DeckSize.MEDIUM: Vector2i(72, 48),
	DeckSize.LARGE: Vector2i(84, 56),
}
## How often each size is offered (weights, Small -> Large).
const DECK_SIZE_WEIGHTS: Array[int] = [30, 45, 25]
## A Medium contract's payout per type — the Phase 3 placeholders, kept. Destroy
## pays more: the nest keeps spawning and killing it wakes the deck
## (AlienHivemind.report_nest_destroyed); Retrieve's cost is the walk and a slot.
## Hold (Phase 6) 550: four loud rounds at one console, nothing to carry home.
## Recover (Phase 6) 650: the walk back is pistol-only and the VIP can be killed
## in the carrier's arms (the 25% redirect). Same as Contract.PLACEHOLDER_PAYOUT.
const BASE_PAYOUT := {
	Contract.Type.RETRIEVE: 500, Contract.Type.DESTROY: 600,
	Contract.Type.HOLD: 550, Contract.Type.RECOVER: 650,
}
## Payout per deck size, as a multiple of BASE_PAYOUT: a bigger deck is a longer
## walk to the objective and more of everything between you and it.
const DECK_PAYOUT_MULT := {DeckSize.SMALL: 0.7, DeckSize.MEDIUM: 1.0, DeckSize.LARGE: 1.3}
## Payouts round to this, so the contract board reads as prices, not arithmetic.
const PAYOUT_ROUNDING := 10
## Contracts on the board per hub visit.
const CONTRACT_OFFERS := 3

# --- Debrief ------------------------------------------------------------------------

## A looted ammo item whose type is already unlocked is just resale: it sells for
## its item value (ItemPresets.AMMO_VALUE_BY_TIER, by tier since Phase 6 — a spare
## Penetrator crate is worth more than a spare FMJ one). See CampaignState._bank_items.
## What a looted WEAPON's body sells for. Primaries are not stash items (every
## soldier can draw any of the five, GDD §4.3), so a looted gun is worth its
## attachments — stripped into the stash — plus this for the metal.
const LOOTED_WEAPON_SALE := ItemPresets.WEAPON_BASE_VALUE


static func recruit_price(record: SoldierRecord) -> int:
	return RECRUIT_BASE_PRICE + roundi(RECRUIT_QUALITY_PRICE * record.quality() / PAYOUT_ROUNDING) * PAYOUT_ROUNDING


static func payout_for(type: int, size: int) -> int:
	var base: int = BASE_PAYOUT.get(type, BASE_PAYOUT[Contract.Type.RETRIEVE])
	var mult: float = DECK_PAYOUT_MULT.get(size, 1.0)
	return roundi(base * mult / PAYOUT_ROUNDING) * PAYOUT_ROUNDING


static func attachment_price(id: int) -> int:
	return ATTACHMENT_PRICE.get(id, 150)


static func ammo_price(id: int) -> int:
	return AMMO_UNLOCK_PRICE.get(id, 200)


## The cheapest recruit any roll could produce — a floor for display, not the
## game-over rule (that reads the candidates actually on offer; see
## CampaignState.can_field_squad).
static func cheapest_possible_recruit() -> int:
	return RECRUIT_BASE_PRICE
