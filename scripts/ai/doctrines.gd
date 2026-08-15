class_name Doctrines
extends RefCounted
## What separates three factions running one planner into three different fights.
## Design: docs/design/systems/coordinated-ai/ Sec 5.
##
## Each doctrine is exactly two things — the ACTION LIBRARY a unit may draw from
## and the ORDER it wants goals in — because that is the whole of the difference
## the design asks for. There is no third knob, and adding one would be the first
## step toward three planners again.
##
## The libraries are built fresh per unit rather than shared, since a
## `GoapBrain` prunes actions that turn out impossible during an activation
## (see `run`), and one squad's pruning must not silently disarm another's.

## Squad key -> blackboard. Squads are identified per faction: mercs by encounter
## (one squad for now), robots by security zone, aliens by nest cluster.
static var _boards: Dictionary = {}


static func blackboard_for(key: String) -> SquadBlackboard:
	if not _boards.has(key):
		_boards[key] = SquadBlackboard.new()
	return _boards[key]


## Cleared between missions — the boards are static, so without this a second
## mission would start holding the first one's claims on freed units.
static func reset() -> void:
	_boards.clear()


## Rival mercs: find the angle that defeats their cover (Sec 5.1).
##
## `Flank` is the headline goal and `Suppress` exists to enable it — pin the
## target's attention so a second unit can reposition safely. That relationship
## is not scripted anywhere: it falls out of the planner discovering that the
## flank goal's cheapest satisfying plan runs through Suppress first.
##
## `RepositionToCover` is REACTIVE here, sitting under the doctrine goal — a merc
## takes cover when it is losing, not as an opening move.
static func merc_brain(board: SquadBlackboard) -> GoapBrain:
	var library: Array = [
		GoapActions.Suppress.new(),
		GoapActions.Flank.new(),
		# Without this a merc beyond weapon range can plan NOTHING — every goal
		# needs `IN_RANGE`, and a flank tile has to be within range of the target
		# to count. It stood still until the player closed. See GoapActions.Advance.
		GoapActions.Advance.new(),
		GoapActions.Attack.new(),
		GoapActions.AttackFromCover.new(),
		GoapActions.RepositionToCover.new(),
		GoapActions.Reload.new(),
		GoapActions.MeleeStrike.new(),
		GoapActions.HoldOverwatch.new(),
	]
	var goals: Array = [
		# COVER IS A MEANS, NOT AN END (fix B). This replaced a standalone
		# "survive" goal of `{IN_COVER: true}`, which a merc could satisfy
		# completely by ducking — so a hurt one ducked, succeeded, and stopped.
		#
		# The goal now demands DAMAGE as well as cover, so every plan that routes
		# through a crate still ends in a shot. There is no state a unit can reach
		# where it has "won" by hiding. Cover became a step on the way to
		# fighting, which is roughly what F.E.A.R. did with AttackFromCover and
		# the reason its soldiers never looked passive.
		# THE DOCTRINE, and it is a SQUAD-level sequence rather than a chain one
		# unit walks: suppression ends the suppressor's activation outright, so
		# the merc that pins is never the merc that flanks.
		#
		# Which merc does which is now DECIDED FOR THE SQUAD by
		# `SquadCoordinator`, and both goals carry a `role` so an assignment can
		# reach them. It used to fall out of a `squad_needs_pin` world fact each
		# unit evaluated privately — which worked for two mercs and could not
		# scale: with three, every one of them independently concluded "somebody
		# should suppress" and all three did, because a fact cannot divide labour.
		{"name": &"pin_for_the_squad", "role": SquadBlackboard.Role.SUPPRESSOR,
			"when": GoapAction.SQUAD_NEEDS_PIN,
			"goal": {GoapAction.TARGET_SUPPRESSED: true}},
		{"name": &"flank", "role": SquadBlackboard.Role.FLANKER,
			"goal": {GoapAction.FLANKED: true}},
		# COVER IS A MEANS, NOT AN END (fix B), and no longer gated on being hurt.
		#
		# The gate was there to stop a merc ducking on turn one instead of
		# flanking, back when this goal asked for `{IN_COVER}` alone and a unit
		# could satisfy it completely by hiding. It now demands DAMAGE as well, so
		# satisfying it means shooting from behind something rather than declining
		# to shoot — and gating that on injury left a healthy merc with a clean
		# line no reason to move at all. It stood in the open trading shots, which
		# is what "they mainly just stay still" looked like.
		#
		# Ranked BELOW flanking, so an angle that defeats their cover still wins.
		# The relevance curve is what restores the original urgency: `HURT` is a
		# threshold that calls 8% health and 49% the same situation, where this
		# scales continuously and lifts the goal above flanking once a merc is
		# genuinely in trouble.
		{"name": &"fight_from_cover",
			"goal": {GoapAction.TARGET_DAMAGED: true, GoapAction.IN_COVER: true},
			#
			# 24.0, up from 20.0, and the reason is the shortened HP scale rather
			# than a change of doctrine. This curve has to be able to outweigh
			# GoapBrain's commitment thumb when a merc is nearly dead, and at 20.0
			# it only just could — it needed `missing` to reach ~0.98, i.e. 1 HP out
			# of the ~57 a merc used to have. A merc has ~16 HP now, so 1 HP left is
			# `missing` 0.94 and the old weight fell about a fifth of a point short:
			# a dying merc would keep running its committed plan. The curve's SHAPE
			# is unchanged and a healthy unit still scores 0 from it, so flanking
			# still outranks cover for anyone not actually in trouble.
			"relevance": func(unit: Unit, _s: Dictionary) -> float:
				var missing := 1.0 - float(unit.current_hp) / float(maxi(unit.stats.max_hp(), 1))
				return missing * 24.0},
		{"name": &"engage", "goal": {GoapAction.TARGET_DAMAGED: true}},
	]
	return GoapBrain.new(library, goals, board)


## Cerberus: forward pressure, and NO FLANKING EVER (Sec 5.2, locked).
##
## `Flank` is absent from this library rather than deprioritised, and that is the
## point: a robot squad must never read as "mercs with worse aim". It reads as a
## different kind of threat — you cannot out-position it, you have to out-damage
## it or get past it before your cover is gone.
##
## `RepositionToCover` is absent too, for the same reason. A machine grinding
## forward does not duck.
static func cerberus_brain(board: SquadBlackboard) -> GoapBrain:
	var library: Array = [
		GoapActions.DestroyCover.new(),
		GoapActions.Suppress.new(),
		GoapActions.Advance.new(),
		GoapActions.Attack.new(),
		GoapActions.Reload.new(),
		GoapActions.MeleeStrike.new(),
		GoapActions.HoldOverwatch.new(),
	]
	var goals: Array = [
		# Take the cover away first. This is what forces the player to move
		# without the squad ever manoeuvring — the doctrine in one line.
		{"name": &"break_their_cover", "goal": {GoapAction.COVER_BROKEN: true}},
		{"name": &"pin_and_close", "goal": {
			GoapAction.TARGET_SUPPRESSED: true, GoapAction.IN_RANGE: true}},
		{"name": &"engage", "goal": {GoapAction.TARGET_DAMAGED: true}},
	]
	return GoapBrain.new(library, goals, board)


## Agile Hunter: opportunistic flank/rush, standing tactic rather than gated to
## an ambush (Sec 5.3).
##
## No `Suppress` and no `DestroyCover` — it carries no gun. What it has is speed
## and an angle, and the `ally_is_engaging_target` fact that Fodder writes simply
## by doing what Fodder always does. Fodder itself never plans (Sec 8).
static func hunter_brain(board: SquadBlackboard) -> GoapBrain:
	var library: Array = [
		GoapActions.Flank.new(),
		GoapActions.Rush.new(),
		GoapActions.MeleeStrike.new(),
	]
	var goals: Array = [
		{"name": &"flank_and_strike", "goal": {
			GoapAction.FLANKED: true, GoapAction.TARGET_DAMAGED: true}},
		{"name": &"strike", "goal": {GoapAction.TARGET_DAMAGED: true}},
		{"name": &"close", "goal": {GoapAction.IN_RANGE: true}},
	]
	return GoapBrain.new(library, goals, board)
