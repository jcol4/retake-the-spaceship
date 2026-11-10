extends SceneTree

var failures := 0
var assemblies := 0
func _initialize() -> void:
	var parcels := PlotAssembler.resources("res://maps/parcels")
	var plots := PlotAssembler.resources("res://maps/plots")
	_check(not parcels.is_empty() and not plots.is_empty(), "Authored resources exist")
	for parcel: ParcelData in parcels:
		_report(parcel.resource_path, DeckValidator.parcel(parcel, plots))
	for plot: PlotData in plots:
		_report(plot.resource_path, DeckValidator.plot(plot, parcels))
		for condition in [-1, 0, 1, 2, 3]:
			for seed_value in 50:
				var rng := RandomNumberGenerator.new()
				rng.seed = seed_value
				var assembler := PlotAssembler.new()
				var data := assembler.assemble(plot, rng, parcels, condition)
				_check(assembler.errors.is_empty(), "%s seed %d condition %d: %s" % [plot.display_name, seed_value, condition, assembler.errors])
				_check(assembler.assignments.size() == plot.slots.size() and not assembler.assignments.has(null), "All slots assigned")
				_report("seed %d condition %d" % [seed_value, condition], DeckValidator.assembled(data))
				assemblies += 1
	print("Parcels: %d parcels, %d plots, %d assemblies, %d failures" % [parcels.size(), plots.size(), assemblies, failures])
	quit(1 if failures else 0)

func _report(context: String, issues: Array) -> void:
	for issue: Dictionary in issues:
		if issue.hard: _check(false, "%s: %s at %s" % [context, issue.message, issue.cell])
		elif not context.begins_with("seed"): print("NOTE %s: %s" % [context, issue.message])

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
