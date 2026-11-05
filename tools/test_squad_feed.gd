extends SceneTree
## The squad feed's vitals: the ECG's condition bands and the trace itself.
##   godot --headless --path . --script res://tools/test_squad_feed.gd
##
## Headless has no renderer, so the face cameras are not built here (the HUD
## skips them too); this pins the numbers they sit beside.
##
## Covers:
##   - HP bands: FINE above 2/3, CAUTION above 1/3, DANGER below;
##   - the heart speeds up as condition worsens;
##   - downed reads CRITICAL, weaker and faster as the bar drains;
##   - dead is a flatline;
##   - the PQRST beat peaks at the R wave and is flat between beats;
##   - the monitor writes trace and a shock forces a beat.

var _failures := 0


func _initialize() -> void:
	var ecg_script: GDScript = load("res://scripts/ecg_monitor.gd")
	var ACTIVE := 0
	var DOWNED := 1
	var DEAD := 2
	var fine: Dictionary = ecg_script.vitals(ACTIVE, 1.0, 0.0)
	var caution: Dictionary = ecg_script.vitals(ACTIVE, 0.5, 0.0)
	var danger: Dictionary = ecg_script.vitals(ACTIVE, 0.2, 0.0)
	_check(fine.condition == 0, "full HP is FINE")
	_check(ecg_script.vitals(ACTIVE, 0.67, 0.0).condition == 0, "just over 2/3 is FINE")
	_check(caution.condition == 1, "half HP is CAUTION")
	_check(danger.condition == 2, "a fifth of HP is DANGER")
	_check(fine.bpm < caution.bpm and caution.bpm < danger.bpm, "heart rate climbs with damage")
	_check(danger.irregularity > fine.irregularity, "danger is ragged")
	var down_full: Dictionary = ecg_script.vitals(DOWNED, 0.0, 1.0)
	var down_low: Dictionary = ecg_script.vitals(DOWNED, 0.0, 0.1)
	_check(down_full.condition == 3, "downed is CRITICAL")
	_check(down_low.amplitude < down_full.amplitude, "a draining bar weakens the beat")
	_check(down_low.bpm > down_full.bpm, "a draining bar speeds the beat")
	var dead: Dictionary = ecg_script.vitals(DEAD, 0.0, 0.0)
	_check(dead.condition == 4 and dead.bpm == 0.0 and dead.amplitude == 0.0, "dead flatlines")

	_check(absf(ecg_script.pqrst(0.23) - 1.0) < 0.05, "R wave peaks near 1")
	_check(absf(ecg_script.pqrst(0.8)) < 0.01, "flat between beats")
	_check(ecg_script.pqrst(0.26) < 0.0, "S wave dips")

	var monitor: Control = ecg_script.new()
	monitor.size = Vector2(150, 40)
	root.add_child(monitor)
	monitor.apply(fine)
	for i in 120:
		await process_frame
	var peak := 0.0
	for s in monitor._samples:
		peak = maxf(peak, s)
	_check(peak > 0.5, "the monitor draws beats (peak %.2f)" % peak)
	monitor.shock()
	_check(monitor._shock > 0.0, "a shock starts an arrhythmia burst")
	monitor._shock = 0.0
	monitor.apply(dead)
	monitor.shock()
	_check(monitor._shock == 0.0, "a corpse does not jolt")

	if _failures == 0:
		print("test_squad_feed: ALL PASSED")
	else:
		print("test_squad_feed: %d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		_failures += 1
