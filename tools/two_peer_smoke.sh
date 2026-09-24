#!/usr/bin/env bash
# Two-peer co-op smoke test: a headless host and a headless client on localhost
# ENet (no Steam), both on `--auto`, play one mission to its end. Passes when
# both exit cleanly and print identical end-of-mission digests (main.gd
# `_print_digest`) — every unit's HP, downed state, tile and ammo, plus a hash of
# every cover edge. A difference is state the host changed that the client never
# heard about.
#
# The host plays every merc (see main.gd `_auto_play`), so this covers the
# host -> client half of the protocol — layout/seed handoff, naming, the ready
# handshake, synchronizers, turn and visual RPCs — but not client commands.
#
# Usage: tools/two_peer_smoke.sh [extra user args, e.g. --map=coordination_deck]
#   GODOT=<path to console build> overrides the default below.
set -u
cd "$(dirname "$0")/.."

GODOT="${GODOT:-C:/Users/jpcol/Downloads/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64_console.exe}"
PORT="${PORT:-24565}"
OUT="${OUT:-$(mktemp -d)}"
TIMEOUT="${TIMEOUT:-600}"

"$GODOT" --headless --path . -- --auto --net=host --port="$PORT" "$@" > "$OUT/host.log" 2>&1 &
HOST=$!
# Give the host a moment to open its port; the client gives up after 10 s.
sleep 2
"$GODOT" --headless --path . -- --auto --net=join --port="$PORT" "$@" > "$OUT/client.log" 2>&1 &
CLIENT=$!

# Kill both if the mission hangs (a stalled turn loop never ends on its own).
( sleep "$TIMEOUT"; kill "$HOST" "$CLIENT" 2>/dev/null ) &
WATCHDOG=$!

wait "$HOST"; HOST_CODE=$?
wait "$CLIENT"; CLIENT_CODE=$?
kill "$WATCHDOG" 2>/dev/null

grep '^\[DIGEST\]' "$OUT/host.log" > "$OUT/host.digest"
grep '^\[DIGEST\]' "$OUT/client.log" > "$OUT/client.digest"

echo "logs: $OUT"
echo "host exit=$HOST_CODE client exit=$CLIENT_CODE"
FAIL=0
if [ "$HOST_CODE" -ne 0 ] || [ "$CLIENT_CODE" -ne 0 ]; then
	FAIL=1
fi
if [ ! -s "$OUT/host.digest" ]; then
	echo "FAIL: host printed no digest"
	FAIL=1
elif ! diff "$OUT/host.digest" "$OUT/client.digest"; then
	echo "FAIL: client's board differs from the host's (< host, > client)"
	FAIL=1
fi
for side in host client; do
	if grep -q "SCRIPT ERROR\|^ERROR" "$OUT/$side.log"; then
		echo "--- errors in $side.log:"
		grep -A2 "SCRIPT ERROR\|^ERROR" "$OUT/$side.log" | head -40
		FAIL=1
	fi
done
[ "$FAIL" -eq 0 ] && echo "PASS: $(wc -l < "$OUT/host.digest") digest lines match"
exit "$FAIL"
