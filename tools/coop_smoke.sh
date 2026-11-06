#!/usr/bin/env bash
# Headless end-to-end co-op runs (MULTIPLAYER_PLAN.md §5): two or three instances
# of the game on this machine, over the ENet dev lobby, each driven by CoopBot
# (scripts/net/coop_bot.gd) and each on its own save slot.
#
#   GODOT=/path/to/godot_console tools/coop_smoke.sh [basic|three|rejoin|resume|all]
#
#   basic   host + guest: lobby, picks, Ready, launch, a few rounds, extract; both
#           debriefs booked into their own saves (the guest's valuable is theirs).
#   three   host + two guests (six soldiers: the 1.5x scaling).
#   rejoin  the guest leaves in round 2 and joins again; brought back in, and
#           still gets its report.
#   resume  the host saves and quits in round 2; relaunched, it resumes from the
#           checkpoint and the waiting guest is brought back in.
#
# Exit status 0 if every instance printed `COOPBOT RESULT ... OK`. Logs go to
# $LOGDIR (default: a temp dir), one per instance.
set -u
GODOT="${GODOT:-godot}"
LOGDIR="${LOGDIR:-$(mktemp -d)}"
PORT="${PORT:-24699}"
cd "$(dirname "$0")/.." || exit 2

bot() {  # bot <role> <slot> <log> [extra args...]
	local role="$1" slot="$2" log="$3"
	shift 3
	"$GODOT" --headless --path . -- --coop-bot="$role" --save-slot="coopsmoke_$slot" \
		--player-key="smoke-$slot" --player-name="$slot" "$@" > "$LOGDIR/$log.log" 2>&1
}

verdict() {  # verdict <log>...
	local ok=0
	for log in "$@"; do
		local line
		line=$(grep -a "COOPBOT RESULT" "$LOGDIR/$log.log" | tail -1)
		echo "  $log: ${line:-no result (see $LOGDIR/$log.log)}"
		[[ "$line" == *" OK "* ]] || ok=1
		grep -a "SCRIPT ERROR" "$LOGDIR/$log.log" | sort | uniq -c | head -5 | sed 's/^/      /'
	done
	return $ok
}

run_basic() {
	echo "basic:"
	bot host Ann basic_host --enet-host="$PORT" --coop-bot-fresh --coop-bot-players=2 &
	sleep 4
	bot guest Bea basic_guest --enet-join="127.0.0.1:$PORT" --coop-bot-fresh &
	wait
	verdict basic_host basic_guest
}

run_three() {
	echo "three:"
	bot host Ann three_host --enet-host="$PORT" --coop-bot-fresh --coop-bot-players=3 &
	sleep 4
	bot guest Bea three_guest1 --enet-join="127.0.0.1:$PORT" --coop-bot-fresh &
	bot guest Cal three_guest2 --enet-join="127.0.0.1:$PORT" --coop-bot-fresh &
	wait
	verdict three_host three_guest1 three_guest2
}

run_rejoin() {
	echo "rejoin:"
	bot host Ann rejoin_host --enet-host="$PORT" --coop-bot-fresh --coop-bot-players=2 --coop-bot-end=9 &
	sleep 4
	bot guest-drop Bea rejoin_guest --enet-join="127.0.0.1:$PORT" --coop-bot-fresh &
	wait
	verdict rejoin_host rejoin_guest
}

run_resume() {
	echo "resume:"
	bot host-quit Ann resume_host1 --enet-host="$PORT" --coop-bot-fresh --coop-bot-players=2 &
	sleep 4
	bot guest-wait Bea resume_guest --enet-join="127.0.0.1:$PORT" --coop-bot-fresh &
	local guest=$!
	wait %1
	sleep 2
	bot host-resume Ann resume_host2 --enet-host="$PORT" --coop-bot-players=2 --coop-bot-end=6
	wait "$guest"
	verdict resume_host1 resume_host2 resume_guest
}

status=0
case "${1:-basic}" in
	basic) run_basic || status=1 ;;
	three) run_three || status=1 ;;
	rejoin) run_rejoin || status=1 ;;
	resume) run_resume || status=1 ;;
	all) run_basic || status=1; run_three || status=1; run_rejoin || status=1; run_resume || status=1 ;;
	*) echo "unknown scenario $1"; exit 2 ;;
esac
echo "logs: $LOGDIR"
exit $status
