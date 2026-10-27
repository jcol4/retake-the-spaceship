class_name TerminalRules
extends RefCounted
## The Hold-a-terminal objective's clock (GDD §7.5, extraction plan Phase 6): "stay
## at a console for N rounds. Noisy." Engine-free — it knows nothing about tiles,
## units or the network, only whether the console was HELD when a round began — so
## the count is testable from a --script tool, and ObjectiveManager is left with
## the deck-facing half (who is standing next to it, the noise, the mirror).
##
## THE RULE (decisions log, "Phase 6 — Hold the terminal"):
##   - A soldier next to the console OPERATES it (PlayerUnit.try_operate_terminal,
##     flat AP). IDLE or PAUSED -> RUNNING.
##   - At every round start (`tick`, ObjectiveManager on `turn_started` — the
##     plan's "every countdown ticks on turn_started") a RUNNING console counts
##     one round if any contractor is standing next to it, and the console is
##     loud that round (NOISE_RADIUS).
##   - Nobody next to it at a round start INTERRUPTS it: RUNNING -> PAUSED. The
##     count is KEPT, not reset, and it does not resume on its own — somebody
##     has to operate it again, paying the AP again.
##   - HOLD_ROUNDS counted rounds -> COMPLETE, which latches (like a dead nest:
##     done whether or not anyone extracts; the payout still needs a departure).

## APPEND-ONLY: the state crosses the wire as an int (`snapshot`).
enum State { IDLE, RUNNING, PAUSED, COMPLETE }

## What one round-start tick did — ObjectiveManager logs it and makes the noise.
enum Tick {
	NONE,         ## not running: nothing happened
	COUNTED,      ## held, one more round on the clock
	COMPLETED,    ## held, and that round finished it
	INTERRUPTED,  ## running, nobody at it: paused with the count kept
}

## Rounds the console must be held. Four: with the 3-round arrival and the 5-round
## landed window (ExtractionRules) a full hold is about one ship cycle — long
## enough that the noise it makes every round (below) brings something down the
## corridor, short enough to fit a 20–40 minute mission (GDD §7.7) with the walk
## there and back. PLACEHOLDER, tune in play.
const HOLD_ROUNDS := 4
## The console's noise each round it runs (and the round it is started): the plan's
## `report_noise` at radius 8 — a gunshot is 5–8 (WeaponPresets noise), so a
## running console is as loud as a firefight every single round, which is what
## "Noisy" (GDD §7.5) has to mean for holding it to be a decision.
const NOISE_RADIUS := 8

var state: State = State.IDLE
## Rounds counted so far, 0..HOLD_ROUNDS. Kept through a pause.
var progress := 0
## Times it has been interrupted — for the HUD line and the log.
var interruptions := 0


## Why the console cannot be started (or restarted) now, or "".
func start_blocker() -> String:
	match state:
		State.RUNNING:
			return "already running"
		State.COMPLETE:
			return "already complete"
	return ""


## IDLE/PAUSED -> RUNNING. False (and nothing changes) if `start_blocker` objects.
func start() -> bool:
	if start_blocker() != "":
		return false
	state = State.RUNNING
	return true


## One round start. `held`: some contractor is standing next to the console now.
func tick(held: bool) -> Tick:
	if state != State.RUNNING:
		return Tick.NONE
	if not held:
		state = State.PAUSED
		interruptions += 1
		return Tick.INTERRUPTED
	progress = mini(progress + 1, HOLD_ROUNDS)
	if progress >= HOLD_ROUNDS:
		state = State.COMPLETE
		return Tick.COMPLETED
	return Tick.COUNTED


## Whether a tick result is a round the console ran (and so made its noise).
static func is_loud(t: Tick) -> bool:
	return t == Tick.COUNTED or t == Tick.COMPLETED


func is_complete() -> bool:
	return state == State.COMPLETE


func is_running() -> bool:
	return state == State.RUNNING


func rounds_left() -> int:
	return HOLD_ROUNDS - progress


## The HUD's half-line: "idle", "uploading 2/4", "PAUSED at 2/4", "complete".
func describe() -> String:
	match state:
		State.IDLE:
			return "not started — operate it, then hold it %d rounds" % HOLD_ROUNDS
		State.RUNNING:
			return "running %d/%d — stay next to it" % [progress, HOLD_ROUNDS]
		State.PAUSED:
			return "PAUSED at %d/%d — nobody held it; operate it again" % [progress, HOLD_ROUNDS]
		State.COMPLETE:
			return "complete — extract to get paid"
	return ""


## Wire form for ObjectiveManager's mirror: ints only.
func snapshot() -> Array:
	return [int(state), progress, interruptions]


func apply_snapshot(snap: Array) -> void:
	if snap.size() < 3:
		return
	state = int(snap[0]) as State
	progress = int(snap[1])
	interruptions = int(snap[2])
