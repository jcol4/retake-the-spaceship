class_name Barks
extends RefCounted
## What a unit says when it takes a squad role.
## Design: docs/design/systems/coordinated-ai/
##
## Orkin's own account of F.E.A.R. is that a large part of what read as
## coordination was the AI ANNOUNCING what it was about to do. Two soldiers
## running independent plans sound like a team the moment one of them calls
## "Covering!" and the other answers. The planning underneath barely changed.
##
## So these are not flavour text. The rule that makes them work is that a bark is
## PREDICTIVE — it names the role and therefore what happens next — rather than
## descriptive. "Merc_1 fired" tells the player something they already watched.
## "Suppressing, move up" tells them where the second merc is about to go, one
## activation before it goes there, which is the whole effect.
##
## VOICE IS PER FACTION, and that is a design constraint rather than decoration.
## A hivemind announcing "Flanking!" in English would undo the aliens entirely,
## so their announcement is a SENSORY cue in the narrator's voice — the player
## gets the same predictive information through a channel that fits the fiction.
## The security robots talk, but as network traffic rather than as people.

## Keyed by SquadBlackboard.Role. Spelled as plain ints so this file does not
## depend on SquadBlackboard, which reaches TurnManager — see the load() note in
## the headless test tools.
const ROLE_SUPPRESSOR := 0
const ROLE_FLANKER := 1
const ROLE_COVER_BREAKER := 2
const ROLE_ADVANCER := 3


## The line `speaker` says on claiming `role`, or "" for a role that faction does
## not announce.
##
## `responding` is the call-and-response half, and it is the part that actually
## sells the illusion: the blackboard can see that somebody is ALREADY holding
## the suppressor role when a second unit claims flanker, so the flanker answers
## the covering fire instead of narrating itself. Two units that never
## communicated now sound like they did, for the price of one boolean.
static func line(faction: Faction.Id, role: int, speaker: String, target: String,
		responding: bool) -> String:
	match faction:
		# The player's own squad. Never heard in normal play — a human is the
		# planner, and nothing claims roles on their behalf — but the headless
		# harness drives soldiers with the merc doctrine, and a faction that can
		# hold a role and cannot speak is a hole in the model rather than a
		# deliberate silence. Also the obvious home for a future squad-order UI.
		Faction.Id.CONTRACTORS:
			return _contractor(role, speaker, target, responding)
		Faction.Id.RIVAL_MERCS:
			return _merc(role, speaker, target, responding)
		Faction.Id.SECURITY:
			return _cerberus(role, speaker, target)
		Faction.Id.ALIENS:
			return _alien(role, speaker, responding)
	return ""


## Drilled where the rival crew are casual — the two factions carry the same kit
## and the same doctrine, so the only thing separating them on the audio channel
## is that one of them still keeps radio discipline.
static func _contractor(role: int, speaker: String, target: String, responding: bool) -> String:
	match role:
		ROLE_SUPPRESSOR:
			return "%s: \"On %s. Suppressing — go.\"" % [speaker, target]
		ROLE_FLANKER:
			if responding:
				return "%s: \"Moving on your fire.\"" % speaker
			return "%s: \"Taking the angle on %s.\"" % [speaker, target]
		ROLE_ADVANCER:
			return "%s: \"Advancing.\"" % speaker
	return ""


static func _merc(role: int, speaker: String, target: String, responding: bool) -> String:
	match role:
		ROLE_SUPPRESSOR:
			return "%s: \"Suppressing %s — move up!\"" % [speaker, target]
		ROLE_FLANKER:
			# The response variant. Same action, different sentence, and the
			# difference is entirely whether an ally is currently laying down fire.
			if responding:
				return "%s: \"Copy — going wide on your fire.\"" % speaker
			return "%s: \"Moving up on %s.\"" % [speaker, target]
		ROLE_ADVANCER:
			return "%s: \"Pushing.\"" % speaker
	return ""


## Clipped, impersonal, and addressed to the network rather than to a comrade —
## the same distinction the faction's alert broadcasts already make. A machine
## does not encourage anybody.
static func _cerberus(role: int, speaker: String, target: String) -> String:
	match role:
		ROLE_SUPPRESSOR:
			return "%s: SUPPRESSING FIRE ON %s. HOLD POSITION." % [speaker, target.to_upper()]
		ROLE_COVER_BREAKER:
			return "%s: OBSTRUCTION FLAGGED. COMMENCING DEMOLITION." % speaker
		ROLE_ADVANCER:
			return "%s: ADVANCING. MAINTAIN SUPPRESSION." % speaker
	return ""


## NOT SPEECH. The aliens announce by being heard and half-seen, so the player
## reads the same intent off the environment. Deliberately in the narrator's
## voice with no name attached where possible — a swarm is a noise, not a person.
##
## Suppression is absent because no alien carries a gun; the roles they can hold
## are the ones the melee tier actually uses.
static func _alien(role: int, speaker: String, responding: bool) -> String:
	match role:
		ROLE_FLANKER:
			if responding:
				return "Something moves fast along the bulkhead, away from the shrieking"
			return "Something breaks from the pack and circles wide"
		ROLE_ADVANCER:
			return "The shrieking around %s rises" % speaker
	return ""
