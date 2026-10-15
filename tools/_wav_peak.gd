extends SceneTree

func _init() -> void:
	# Parse the RIFF file on disk, NOT the imported resource -- the import is
	# QOA-compressed (format=3) and has no raw PCM to measure.
	var f := FileAccess.open("res://assets/audio/sfx/weapons/rifle_fire_01.wav", FileAccess.READ)
	if f == null:
		print("open failed")
		quit(); return
	var raw: PackedByteArray = f.get_buffer(f.get_length())
	print("file bytes=", raw.size())
	# Walk chunks to find 'data' and 'fmt '
	var pos := 12
	var bits := 16
	var data_at := -1
	var data_len := 0
	while pos + 8 <= raw.size():
		var cid := raw.slice(pos, pos + 4).get_string_from_ascii()
		var clen := raw.decode_u32(pos + 4)
		if cid == "fmt ":
			bits = raw.decode_u16(pos + 8 + 14)
			print("fmt: channels=%d rate=%d bits=%d" % [
				raw.decode_u16(pos + 8 + 2), raw.decode_u32(pos + 8 + 4), bits])
		elif cid == "data":
			data_at = pos + 8
			data_len = clen
			break
		pos += 8 + clen + (clen & 1)
	print("data chunk at=%d len=%d bits=%d" % [data_at, data_len, bits])
	if data_at < 0 or bits != 16:
		print("unsupported layout")
		quit(); return
	var peak := 0
	var sum := 0.0
	var n := 0
	var i := data_at
	var end := mini(data_at + data_len, raw.size() - 1)
	while i + 1 < end:
		var s := raw.decode_s16(i)
		peak = maxi(peak, absi(s))
		sum += float(s) * float(s)
		n += 1
		i += 2
	var pk := float(peak) / 32768.0
	var rms := sqrt(sum / n) / 32768.0
	print("samples=%d" % n)
	print("PEAK linear=%.4f  dBFS=%.2f" % [pk, linear_to_db(pk)])
	print("RMS  linear=%.4f  dBFS=%.2f" % [rms, linear_to_db(rms)])
	quit()
