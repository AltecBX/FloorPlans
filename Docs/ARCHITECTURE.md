# FieldPlan Architecture

## Two layers, one boundary

```
┌────────────────────────────────────────────────────────────┐
│  FieldPlan (iOS app — SwiftUI, SwiftData, RoomPlan, UIKit) │
│                                                            │
│  Projects · Scanning · Plan viewer/editor · 3D · Photos    │
│  Notes · Measurements UI · Takeoff UI · Reports · Exports  │
│  Settings · Jobsite mode · Accuracy                        │
│                                                            │
│  Persistence: SwiftData records (metadata, queryable)      │
│               + per-project files (geometry JSON, scans,   │
│                 photos, exports) via ProjectStore          │
└──────────────────────────┬─────────────────────────────────┘
                           │ imports (one direction only)
┌──────────────────────────▼─────────────────────────────────┐
│  FieldPlanCore (SwiftPM package — Foundation only)         │
│                                                            │
│  Geometry/    Vec2/Vec3, polygon ops, WallGraph            │
│  Model/       canonical entities (Wall, Opening, Room,     │
│               Fixture, Level, PlanSnapshot, provenance,    │
│               ElementEvidence + ConfidenceModel)           │
│  Measurement/ units, imperial parser/formatter,            │
│               field measurements, templates, providers     │
│  Scan/        ScannedRoomDTO → canonical conversion;       │
│               ScanSessionLog, MeshChunk codec,             │
│               ScanQualityEngine, CoverageGrid              │
│  Editing/     EditorEngine (constraint-propagating edits)  │
│  Analysis/    RoomCalculations, QAEngine, summary stats,   │
│               MissingSpaceDetector                         │
│  Accuracy/    AccuracySample + statistics + calibration    │
│  Takeoff/     categories, surface selections, calculator   │
│  Plan/        PlanScene primitives + PlanGenerator         │
│  Export/      SVG, DXF R12, CSV, ProjectArchive JSON, ZIP  │
│  Fixtures/    SAMPLE-labeled development geometry          │
└────────────────────────────────────────────────────────────┘
```

Everything below the line compiles and tests on Linux/macOS/iOS. That is a
deliberate spec priority (§63 measurement integrity first): the math that
puts numbers on a proposal is exercised by `swift test`, not by tapping
through screens.

## Data flow of a scan

1. `RoomCaptureView` runs; `stop(pauseARSession: false)` keeps one ARSession
   across rooms so a whole floor shares a coordinate space.
2. `ScanRecorder` joins that ARSession's delegate chain and writes the sensor
   stream to `sessions/<id>/` — poses, tracking, light, depth confidence,
   gyro, compass, keyframes, positioned photos and binary mesh chunks — while
   `ScanQualityEngine` and `CoverageGrid` (core) turn the same stream into
   live advice and a coverage minimap. See `Docs/SCAN_PIPELINE.md`.
3. Accepted `CapturedRoom`s are serialized (raw JSON + USDZ) into
   `scans/` — RoomPlan's interpretation is kept next to the observations it
   came from (§10, §22).
4. `CapturedRoomBridge` mechanically maps RoomPlan types to `ScannedRoomDTO`
   (the only file that reads RoomPlan geometry types), including door open
   state, curved-wall arcs, stories and every section label.
5. `LevelAssignment` groups the captured rooms by floor height; the group
   holding the first room goes to the selected level, any other to a level a
   story up or down (created if needed), with the owner told once.
6. `ScanConversion.convert` (core, tested) builds each group's wall faces
   with openings, room polygons (floor `polygonCorners` first, wall loop
   fallback) and fixtures, then `WallAssembly` turns faces into walls:
   facing pairs become one centerline with a measured thickness, lone faces
   are offset outward with an assumed one, corners are closed. `merge`
   replaces re-scanned rooms in the level and splits a continuous capture
   into its rooms, each inset by half its walls' thickness.
7. `EvidenceAttachment` scores every scanned element from the coverage grid,
   a mesh line fit (`WallFitter`, kept as the alternate measurement) and the
   session's tracking record; `NorthEstimator` places north from the
   compass; `MissingSpaceDetector` reports what looks unscanned.
8. The level is saved into the active `PlanSnapshot` (a JSON file), QA runs,
   and every downstream feature (plan, 3D, takeoff, report, export, accuracy
   tests) reads that same canonical geometry: wall centerlines for drawing
   and 3D, room polygons (the painted faces) for dimensions and quantities.

## Plan versions

- One `PlanSnapshot` per version; `Existing Conditions` is created
  automatically and lockable; proposed plans are whole-geometry duplicates
  (element IDs preserved so change tracking references the same walls).
- Renovation markup is per-element `ChangeStatus` (existing/demolish/new);
  the demolition plan is a *render mode* of a snapshot, not a third copy.

## Editing model

`EditorEngine` functions are pure `LevelGeometry -> LevelGeometry`. The
editor keeps an undo stack of whole levels (cheap value types) and persists
after every commit — aggressive autosave (§4). Exact length edits decompose
the corner delta against each attached wall: the along-axis component
stretches, the perpendicular component translates rigidly and propagates, so
a 10×10 room set to 12' becomes a clean 12×10 rectangle and legitimate
angled walls are never distorted (§17).

## Rendering

`PlanGenerator` emits semantic vector primitives (`PlanPrimitive` with
`PlanPen`s). Renderers map pens per medium: SwiftUI `Canvas` (interactive,
dark-mode aware), `CGContext` (PDF/PNG/JPG, print style), SVG (classes/colors),
DXF (layers). One geometry source; identical output everywhere. The 3D
viewer, the 3D snapshot and `OBJExporter` build from the same walls, rooms
and fixtures, and `OpeningSchedule` / `ContractorQuantities` read them for
the schedules and the numbers a bid is written from.

## Persistence & migration

- SwiftData models are registered under `FieldPlanSchemaV1`
  (`VersionedSchema`); future schema changes add a `SchemaMigrationPlan`.
- Geometry snapshots and the `.fieldplan` package embed
  `ProjectArchive.schemaVersion`; the decoder refuses newer versions and has
  a migration hook for older ones (§52).
- Geometry semantics are versioned separately per snapshot
  (`PlanSnapshot.schemaVersion`, current 2 = scanned walls are centerlines).
  `GeometryMigration` brings older snapshots forward on load and on import,
  and the store writes the result back so it runs once. See
  `Docs/SCAN_PIPELINE.md`.
- Files are written atomically; blobs (photos, scans, USDZ) are referenced
  by name, never embedded in JSON (§39).

## Future-ready seams (§61)

- `MeasurementProvider` protocol → Bluetooth laser meters.
- `ProjectStore` file layout + `.fieldplan` → iCloud/Drive sync.
- Core package compiles for macOS → Mac plan editor.
- `PlanScene` → additional CAD exports.
