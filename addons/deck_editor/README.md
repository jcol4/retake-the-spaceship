# Deck Editor

Open the project in Godot 4.7.2 and select **Deck Editor** beside the 2D/3D/Script
tabs. The plugin is enabled in `project.godot`. Open a `.tres` from `maps/plots/`
or `maps/parcels/`, or choose New. For new parcels, select the zone and room type
in the main toolbar first, then enter the name, width and depth in New. New plots
use the Small/Medium/Large dimensions. Room size suggestions are advisory.

The starter resources are:

- `maps/parcels/hangar/hangar_standard.tres`: 18 × 14 hangar, pad, wrecks, crates and lights.
- `maps/parcels/habitation/bunk_room_a.tres`: 8 × 10 bunks, lockers, terminal, lights and markers.
- `maps/plots/test_small.tres`: two hangars, four bunk slots, two spines and cross passages.

The test plot intentionally has `test_only = true`. It still enforces caps,
socket compatibility and connectivity, but is exempt from the full Habitation
required-room set (bathroom, mess, galley). Leave `test_only` off for production
plots. No Medium/Large plots or other-zone parcels are supplied by this starter set.

## Authoring

Use the mouse wheel to zoom and middle drag to pan. Select a tool in the toolbar
or press its letter while the canvas has focus:

| Key | Tool |
| --- | --- |
| S | Select; Shift adds, drag empty space for box selection, drag selection to move |
| T | Paint a tile or rectangular stroke using Floor/Wall/Door/Hull |
| P | Place the selected catalog piece at its tile footprint |
| R | Rotate the placement cursor and selected pieces by 90° |
| L | Place a light using the named preset dropdown |
| M | Place an enemy/patrol/nest/loot/player/pad marker |
| C | Cycle a tile edge through none/light/heavy cover |
| D | Toggle a two-tile door socket at the nearest parcel/slot edge |
| K | Draw a plot corridor or spine rectangle, painting its floor |
| Q | Draw a plot slot using the selected zone and optional required type |

Right click selects entries under the cursor. Arrow keys move the selection;
Delete removes it and Ctrl+D duplicates it. Ctrl+S saves. Editor undo/redo works
for terrain, placement, sockets, rectangles, moving, rotating, grouping, deletion
and duplication. Inspect a slot to change its dimensions or socket widths.

The palette filters by catalog socket. Thumbnail rendering is cached under
`.godot/deck_editor_thumbs/`. Catalog IDs are exact, so adding another model to a
socket does not silently change authored furniture.

Select an entry to edit its sub-resource in Godot's inspector. Chance has four
labelled sliders. Entries sharing a nonempty Group across pieces/lights/markers
choose one member by Weight, then apply that member's condition chance. Use the
group field and button to apply a group to the current selection.

Gameplay furniture snaps to tiles and quarter turns. Hold Alt when placing
non-gameplay dressing for fractional offsets and automatic stacking on a piece.
Edit Offset, Yaw Deg and Stack On in the inspector for finer adjustments. Stack
On indexes the document's Pieces list; editor duplicate/delete remap those indices.
Review references after manually reordering the array in the inspector. Missing
optional parents suppress their stacked dressing.
Wall pieces and wall lights snap to a neighbouring wall; wall-normal offsets are
discarded and their catalog front always faces into the room after transforms.

Parcel terrain describes only the interior. Plot slots exclude their surrounding
wall; the plot supplies that wall and owns actual door sockets. Parcel sockets
declare where openings are acceptable. A wider accepted socket can contain a
narrower actual opening. Mirroring flips local X before clockwise rotation.

## Preview and validation

Preview uses the selected seed and condition. Reroll increments the seed. Plot
previews label each slot with its parcel; incompatible slots are red. Save also
refreshes the preview. Warnings select/focus their tile when clicked. Saving is
always permitted, including content with hard errors.

The runtime preview runs `PlotAssembler` and the actual `MapBuilder` in a separate
Godot game process, captures its 1200 × 900 SubViewport and displays the image on
the right. This isolates runtime autoloads, physics, power and lighting from the
editor. The child process exits after rendering; preview errors are recorded in
`.godot/deck_editor_preview/preview.log`. Preview is a fixed camera capture;
pan/zoom controls apply to the authoring canvas. Thumbnails use an editor-local
SubViewport.

Light heatmap uses the game's Chebyshev linear falloff and the powered/emergency
intensity multiplier. It is an authoring estimate without physics occlusion or
ambient light. The runtime preview provides the actual rendered lighting.

Run from the project root (substitute your Godot executable):

```sh
godot --headless --path . --editor --import --quit
godot --headless --path . --script res://tools/test_parcel_transform.gd
godot --headless --path . --script res://tools/test_parcels.gd
godot --headless --path . --script res://tools/test_plot_assembly.gd
godot --headless --path . --editor --script res://tools/test_deck_editor.gd
```

The content test validates every resource and assembles each plot with 50 seeds
for each of four forced conditions plus a seeded mix. Hard errors fail the test.
The editor test verifies selection edits and actual EditorUndoRedoManager history.
Set `DECK_EDITOR_SCREENSHOT` to an output PNG path and run the editor test without
`--headless` to capture the screen and exercise the runtime preview.

`tools/create_starter_parcels.gd` rebuilds the examples; it overwrites those three
resources, so do not run it over teammates' authored edits.

Plots are the default in `MapGenerator.Config`. Missing size/zone content produces
`MapData.layout_errors` and an error; it never falls back to procedural geometry.
For procedural development use `-- --deck-source=generated` or the HUD settings
checkbox **Dev: procedural decks (next mission)**. `--deck-source=plot` overrides
the stored debug setting. The Small starter can be played with a deployment deck
size of Small; the default `--seed` path requests Medium, which needs authored content.
