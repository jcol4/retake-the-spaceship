class_name BrawlerUnit
extends SwarmUnit
## The heavy of the melee tier: the Fodder loop (Sec 11.3/11.4) run by something
## worth being afraid of one at a time.
##
## Behaviourally IDENTICAL to the swarm, and that is why it extends it rather
## than copying it — crawl toward the quarry, claw it once adjacent, no ranged
## attack at any point. Everything that separates the two is a NUMBER, and the
## numbers live where numbers live: the stat block in `main.gd._brawler_stats`
## (roughly double the swarm's HP and nearly double its damage) and the scene's
## `move_speed`.
##
## What that buys is a different answer to the same question. A swarm asks
## whether you can afford the ammunition; a brawler asks whether you can afford
## the two turns it takes to put one down while the rest of the deck closes.
## Ignoring one is not attrition — it is a soldier.
##
## The shamble is the compensation, and it is authored rather than balanced:
## `walks_only` on the scene means this thing has one gait and it is the walk,
## at 0.9 m/s against the soldier's 4.5. It is outrunnable by a wide margin, in
## the open. The map is what takes that away.
