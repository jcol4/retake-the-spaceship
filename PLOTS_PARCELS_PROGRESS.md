# Plots and parcels implementation

Current status: **experimental opt-in**. The original plot-default decision was
superseded at the user's request after it left unsupported deck sizes empty.
Procedural generation is restored as the default. Contracts now have a **Map gen**
checkbox: checked uses procedural maps, unchecked uses available authored plots.
The source is saved in each offer/deployment and shared with co-op clients.
Earlier empty contract boards are repaired on load. Launch validates the map
before booking the mission, and the local HUD debug setting no longer overrides it.

Implemented the data model, shared eight-way transforms, seeded constraint
assembler, optional plot generator path, exact catalog rendering, authored lights,
wall pieces, dressing/stacking, validator, main-screen editor and starter content
from `PLOTS_PARCELS_PLAN.md`.

Authoring instructions and commands: [`addons/deck_editor/README.md`](addons/deck_editor/README.md).

Implementation decisions:

- The starter hangar is 18 × 14. Existing bays have a 210–280 tile area guideline;
  the plan's rough 14 × 12 estimate would be smaller than that.
- The starter plot has an explicit `test_only` required-type exemption: the two
  requested parcel types cannot satisfy Habitation's bathroom/mess/galley rules.
  Production plots enforce those rules and all plots enforce room caps.
- Wider accepted sockets can contain smaller plot openings, with the same side.
- Optional entries have a Weight export for weighted pick-one groups. Groups span
  all entry kinds within one parcel (or the plot's own corridor content).
- Door sockets create corridor regions and room links, keeping gameplay room
  adjacency consistent with navigation. Authored room identities survive building.
- Runtime preview uses a separate game process and captures its SubViewport, so
  the same MapBuilder can run with its runtime autoloads. The editor displays the
  resulting image; it does not run those singleton systems inside the editor.
- Heatmap is the same radial falloff/power multiplier, without physics occlusion;
  the runtime preview shows actual lighting.
- Stack parents are piece-list indices, as specified. Editor duplicate/delete
  remap references; validation catches invalid references/cycles. Direct manual
  reordering of the array requires reviewing parent indices.
- Existing procedural regression tools now explicitly request GENERATED.

Verification completed:

- All eight transforms: 872 geometry, socket, side and wall-flush checks.
- All starter resources: 250 assemblies (50 seeds × four conditions plus mixed),
  all slots filled, connected floor, valid pads, no obstacle spawns.
- Runtime integration: 20 generator seeds, deterministic content/loot/spawns,
  player insertion, room graph connectivity, repeated MapBuilder model selection;
  negative socket/type/required-room/marker checks and optional-group checks.
- Editor: movement, duplicate, delete, grouping, undo/redo, advisory validation,
  save of invalid resources; actual GPU-rendered palette and runtime preview.
- Legacy map round-trip, objectives, room visibility, 300-seed hangar generation,
  51 fully dressed procedural theme cases (3 seeds across 17 size/profile cases),
  and campaign checks including 32 saved offers regenerated from descriptors.
- Real bunk-room runtime render reviewed. Test output and captures are in ignored
  `out/`; temporary editor preview/thumbnail resources are in `.godot/`.

The sandbox prevents writing Godot's ordinary editor settings and thumbnail cache
under AppData. The campaign save test passed with normal user-data access; the
ordinary sandbox run failed its temporary-save writes. Editor screenshot runs
also log AppData cache denials and the engine's associated progress-dialog errors.
These are separate from script/assembly failures.
The headless SceneTree editor-test harness also reports RID/ObjectDB allocations
at shutdown; its edit/undo assertions pass. Normal editor imports and runtime
assembly tests do not report those shutdown leaks.

Content still intentionally consists only of the two parcels and Small test plot.
Other sizes/zones need authoring and report gaps. Shipping content, raised platforms,
stairs, save version migration and co-op content-version negotiation remain outside
this plan's requested starter scope.

Map-source follow-up verification: contract checkbox toggling, both actual map
builders and launch paths, save/JSON and co-op deployment source preservation,
repair of earlier empty boards, and main.tscn's loadout Deploy flow. A GPU capture
of the main scene after Deploy confirms visible map geometry and squad members.
