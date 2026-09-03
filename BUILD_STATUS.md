# BUILD STATUS

_Last updated: 2026-09-03_

## 2026-09-03 — Build 16 (version 1.6): the plan reads like a floor plan

Styling pass against five reference sheets the owner supplied. The geometry
is untouched — this is entirely how the same measurements are presented.

- **Room names as written** (`RoomNameStyle`), not forced to uppercase.
  "Primary Bedroom", the way a listing sheet sets it. `.uppercase` remains
  for a drawing issued to a trade.
- **The size line in the tight form** (`UnitFormatter.roomDimensions`):
  `14'0" x 12'5"`, whole inches, a lowercase x, no space inside the feet —
  and `4.28 m x 3.79 m` in metric. An eighth of an inch is noise on a room
  label; the room's real measurement stays in the model.
- **Listing palette** (`RoomPalette.staging`, now the default): bedrooms
  warm, bath and laundry cool, outdoor green, garage and utility grey, and
  everything a person lives in — living, dining, kitchen, hall — one quiet
  cream. Colouring a kitchen differently from the dining room beside it
  makes an open plan look partitioned. `.byCategory` keeps the old
  per-type colouring for working on the plan.
- **The generator resolves the colour** (`PlanFill.roomTint(PlanColor)`
  instead of `.roomTint(RoomType)`), so a room can never be tinted one way
  on screen and another in the exported sheet.
- **Labels sit on clear floor** (`PlanGenerator.labelAnchor`). A room's
  label used to be drawn over its own bathtub and vanity. It now starts at
  the interior label point and, when fixtures cover it, searches the room
  on a fixed grid for the clearest spot near the middle. Only things
  actually drawn move a label — an undrawn bed used to shove the bedroom's
  name into a wall.
- **A crowded room drops lines rather than stacking over fixtures**: the
  line budget is limited by the clear floor around the anchor, not just by
  the room's size, so a small bathroom prints its name and its size and
  stops.
- **Sideways only as a last resort** (`shouldTurnLabel`). A room clearly
  taller than wide, whose block cannot be read across it at a useful size,
  turns to read bottom-to-top — judged on the widest line (usually the size,
  not the name), and only when turning buys a materially bigger label. Every
  room in the sample apartment stays horizontal.
- **Whole square feet under the drawing** (`UnitFormatter.sheetArea`,
  `PlanAreaSummary`): "Measured Floor Area: 1,455 sq ft" with each floor
  listed under it, lowest first. The takeoff keeps its tenth of a foot;
  only the sheet rounds. There is deliberately no "excluded areas" line —
  deciding what counts is what ANSI Z765 is for, and FieldPlan implements
  none of it, so printing an exclusion it did not compute would be the same
  unfounded claim as calling the figure GLA.
- Core suite: **306 tests**, all passing on Linux (`PlanStyleTests`,
  `PlanAreaSummaryTests` added). Every app file parses. Rendered and
  inspected against the reference sheets before and after.
- **Not verified here:** as ever, the iOS target cannot be compiled in this
  environment. The Xcode build must be confirmed on the owner's Mac.

## 2026-09-03 — Build 15 (version 1.5): field validation and recovery

Not an accuracy build. This one makes a property visit hard to lose and
turns it into evidence that can decide, later and with numbers, which
measurement method is actually better.

**The audit finding that started it.** `ScanFlowView` carried a comment
saying accepted rooms were already safe and only the in-progress room could
be lost. That was false: accepted rooms lived in an array in
`ScanCoordinator` until Finish Level ran, so an iOS memory kill after five
rooms lost all five. The comment is true now.

- **FieldPlan owns the ARSession** (`SpatialSession`). The app creates the
  session and hands it to RoomPlan through
  `RoomCaptureView(frame:arSession:)`, the supported existing-session
  initializer. The mesh, poses, keyframes, depth, light estimates, tracking
  and mapping state all stay on one session, so the recorder no longer rides
  a session it does not control. The 3-second delegate re-attach is kept as
  instrumented defence and now writes a `delegateReattached` session event,
  so a field visit shows whether RoomPlan actually takes the delegate.
- **World map checkpointing** (`WorldMapPolicy`, core, tested). Maps are
  saved only from `mapped` or `extending` state, and a good map is never
  overwritten by a worse one. Before saving, an origin anchor is planted;
  after a restore, the same anchor coming back within 10 cm is what proves
  the coordinate system survived. **Apple does not document whether
  `initialWorldMap` survives RoomPlan re-running the session with its own
  configuration** — so the app attempts the restore, verifies it, and on
  failure offers a separate session that has to be registered later rather
  than silently merging two coordinate spaces.
- **Every accepted room is written to disk immediately**
  (`ScanCheckpointStore`, `CheckpointStore` in core, tested). Accept writes
  the raw `CapturedRoom` JSON, the USDZ and a checkpoint record before
  anything else happens. Everything is keyed by RoomPlan's own
  `CapturedRoom.identifier`, so replaying a checkpoint cannot import the same
  room twice, and a merge stamp is never lost to a stale replay. Finish Level
  now folds in what is *on disk*, not what happens to be in memory. A
  checkpoint write that fails is the one failure that surfaces to the owner.
- **Unfinished scan recovery** (`UnfinishedScanSheet`). Reopening a project
  with unimported rooms offers *Continue Property Scan* / *Finish With Saved
  Rooms* / *Discard Unfinished Session*. Nothing is discarded without an
  explicit choice, and Continue restores the world map first.
- **Field Validation Mode** (`ValidationScreen`): forces sensor recording on
  and states the app version and build, device identifier, iOS version, LiDAR
  presence, recorder state and validation session ID, so every number
  collected is attributable to the build that produced it.
- **Preflight test** (`Preflight`, `PreflightReport` in core, tested):
  RoomPlan, LiDAR, camera permission, motion, heading, recorder, storage,
  battery, thermal state and the session folder. Only genuinely disabling
  problems block; a missing compass warns.
- **Live field diagnostics** (`FieldDiagnosticsPanel`): tracking, world
  mapping, depth confidence, mesh anchors, keyframes, rooms actually written
  to disk, whether a map is saved, and recording time left — on screen
  during the walk instead of in a log afterwards.
- **Storage protection** (`StorageEstimate`, core, tested): measured from
  the session's own data rate and reported as minutes of recording left,
  with a 500 MB reserve so the phone never reaches zero. It claims no time
  remaining until it has a rate to base one on.
- **Ground truth in one tap and one number** (`ValidationPrefill`, core,
  tested). Tapping an element on the plan fills in the project, session,
  level, room, element, type and label, every method's answer, the mesh
  residual and inlier count, and the evidence and tracking scores. One large
  field takes the laser or tape value; Save & Next returns to the plan.
  Recording ground truth never edits geometry.
- **Competing measurements are never merged** (`CompetingMeasurements`).
  RoomPlan's value, the mesh fit, the canonical value, the original scanned
  value and any user edit are each stored separately and each scored against
  the same laser value. A method with no answer for an element is absent,
  not zero.
- **Repeatability** links rescans by an explicit "same physical element"
  name, never by element IDs — a rescan produces new IDs for the same wall.
- **Problem markers** (`ProblemMarker`): one tap flags fifteen kinds of
  wrongness with its place on the plan. Flagging never edits the plan; the
  wrong geometry stays as scanned so it can be studied.
- **Validation bundle** (`FieldValidationBundle`, core, tested): manifest,
  samples as JSON and a 31-column CSV, the analysis, problem markers, the
  scan event log, the canonical snapshot and the room schedule — with the
  raw captures, world maps and sensor sessions referenced by path and byte
  count rather than copied in twice.
- **Field visit checklist** (`FieldVisitChecklist`, core, tested): ten items
  built from the app's actual state, not a static list, so a walk is not left
  with rooms unimported or a session unfinalized.
- **No measurement arbitration.** Nothing here averages, weights or picks a
  winner between methods. The comparison screen reports; the decision needs
  far more properties than one.
- **The GLA label is gone** where it implied an ANSI Z765 engine that does
  not exist; the figure is called Measured Floor Area.
- Core suite: **287 tests**, all passing on Linux — including 16
  crash-test scenarios (`FieldRecoveryScenarioTests`) covering termination
  after three rooms, resume-and-finish, rescan, stale replay, drifted
  relocalization, a full disk and an unreadable raw file. Every app file
  parses. `AppBoundaryTests` gained two new fences for the build-15 calls,
  and caught two real signature mistakes before they could reach the Mac.
- **Not verified here:** the iOS target cannot be compiled in this
  environment (no Xcode, no macOS, no iOS SDK). Only the Linux core tests and
  `swiftc -parse` on every app file were run. The Xcode build must be
  confirmed on the owner's Mac.

## 2026-09-02 — Build 14 (version 1.4): presentation, quantities, exports (stage 3)

Stage 3 of the CubiCasa benchmark audit: what leaves the phone.

- **Door styles drawn** (`PlanGenerator`): hinged (leaf + arc), double
  (two leaves meeting), sliding (two slab panels on their tracks), pocket
  (panel plus the hidden pocket in the wall), bi-fold (two folding pairs)
  and garage (panel plus the raised position, hidden). Set per door in the
  editor's opening inspector (a scan sees a hole, never the leaf); the
  hinge/swing flips still apply. Rendered and inspected.
- **Stairs with direction**: treads, walk line, arrowhead at the top and
  "UP" at the foot; "Up Direction" in the fixture inspector flips which end
  rises. The 3D primitive steps and the OBJ steps rise the same way.
- **Cabinet runs** (`FixtureCleanup`, core, tested): RoomPlan "storage" is
  read from its measured box — wall-hung is an upper cabinet, counter-height
  and counter-deep is a base cabinet — base cabinets that continue each
  other become one run, and a run with no wall behind it is an island.
- **Door & window schedule** (`OpeningSchedule`, core, tested): D1/W1/O1
  marks per kind, size, sill, rooms either side (served room first), hand
  (LH/RH from the push side) and swing room for hinged doors, style, status,
  evidence, "open at scan". CSV export and a report page.
- **Contractor quantities** (`ContractorQuantities`, `ContractorSummary`,
  core, tested): per room and for the job — floor, ceiling, paintable wall
  area (net), wall tile to 7' and wainscot to 4' (openings below the height
  removed), volume, trim, door/window counts, fixture counts by category,
  fixtures marked for removal, wet-room flag. Room Detail rows, a Job
  Quantities section on the Takeoff screen, CSV export, a report page. The
  takeoff's "all walls" selection now uses the same painted-face area.
- **Exports**: floor plan and 3D dollhouse as **JPG**; **OBJ + MTL** (zipped)
  from the canonical geometry — walls with their openings as headers and
  sills, floor slabs (ear-clipped, so L-shapes are fine), fixtures as boxes
  and stairs as steps, every level stacked at its scanned height, mode
  filtering as on the plan (`OBJExporter`, core, tested with index and
  height checks); door/window and quantities CSVs.
- **Editor**: door style menu; wall thickness shows *measured / assumed /
  edited* (typing one marks it edited and rebuilds the rooms either side —
  `EditorEngine.setWallThickness`); "on scanned face" flags a wall never
  placed as a centerline; Level menu — rotate the plan 90° either way, turn
  it so north is up, set north = up as drawn, rename the level.
- **Report**: Door & Window Schedule and Contractor Quantities pages with
  their toggles.
- Core suite: 219 tests, all passing on Linux. Every app file parses.
  Device checklist items 25–31 in `Docs/DEVICE_TESTING.md`.
- **Xcode build fixes** (from the owner's build 14 run): the migration log
  line interpolated an optional `Int` into `os.Logger`, which has no such
  overload and reported it as an `NSObject?` conversion — the version is
  unwrapped first now. `SettingsScreen` read the main-actor `companyLogo`
  from inside the photo picker's label closure; the logo is read once into
  a local and the closure sees only a `Bool`, which also stops the property
  re-reading the file from disk three times per redraw.
- **`AppBoundaryTests`** is a new compile fence: the iOS layer cannot be
  compiled here, so it mirrors every call `FieldPlan/` makes into
  `FieldPlanCore` with the same labels and bound types. A wrong label or
  type at that boundary now fails on Linux instead of on the owner's Mac.
  Add to it whenever the app starts calling something new.

## 2026-09-02 — Build 13 (version 1.3): reconstruction (scan engine stage 2)

Stage 2 of the CubiCasa benchmark audit: the wall model. Design and rules
in `Docs/SCAN_PIPELINE.md`, "Reconstruction (stage 2)".

- **Faces become walls** (`WallAssembly`, core, tested). RoomPlan reports
  wall surfaces; a partition walked from both sides arrives twice, a few
  inches apart. Facing pairs now become one centerline midway between them
  with the gap as a *measured* thickness (the old converter threw that gap
  away and drew every wall at 4½"). A face seen from one side is offset half
  a wall away from its room with an *assumed* thickness — the neighbouring
  room's floor edge when it is within pairing range, 4½" for a partition,
  6" for an exterior wall — and a face whose side cannot be told stays put,
  marked `thicknessSource = nil`, which every consumer reads as "line = room
  boundary". Corners are closed after the offset (intersection, end-to-end
  join, or run on to the wall a partition stops against); door gaps are left.
- **Rooms keep their face-to-face size.** Floor polygons are what RoomPlan
  measured; rooms recovered from the wall graph are inset by half of each
  placed wall (`GeometryOps.insetPolygon`, `GeometryCleaner.interiorPolygon`,
  tested for L-shapes and collapse). Manual rooms are typed as clear
  dimensions with the walls placed outside them. The editor rebuilds rooms
  the same way.
- **Quantities and dimensions read the painted faces.** `RoomCalculations`
  runs along the polygon edges (gross wall area no longer grows when a
  centerline moves). `PlanGenerator` dimensions the way a drafter reads a
  sheet: jogged rooms face to face inside, outside-face chains only where a
  side jogs, overall width and depth outside; a rectangle reads from its
  W × D label (`Options.interiorDimensions`, default `.jogsOnly`). Rendered
  and inspected: two scanned rooms with a measured partition, an L-shaped
  footprint with a partition and a door, the sample apartment.
- **Mesh line fits** (`WallFitter`, core, tested): deterministic RANSAC over
  the wall-classified mesh beside each scanned wall, stored as the wall's
  alternate measurement with residual and inlier count for the accuracy
  framework to judge. Never substituted.
- **Stories** (`LevelAssignment`, core, tested): captured rooms group by
  floor height; the group holding the first room stays on the selected
  level, the rest go to a level within 1.2 m or a new one a story up or
  down, and the owner is told once. Elevations are relative to the selected
  level (every scan starts its own AR frame). Other stories get their own
  coverage map from the session mesh (ceiling estimate capped to the story
  band). The 3D viewer stacks levels at measured heights when all have one.
- **Registration** (`LevelRegistration`, core, tested): translate/rotate a
  level with north following; **Align Below** in the Levels manager (swipe
  or long-press) puts a level's staircase over the one below, or centres the
  footprints, and says how far it moved. Levels list their floor height
  above the lowest scanned floor.
- **Migration** (`GeometryMigration`, core, tested): `PlanSnapshot.
  schemaVersion` 2. Version-1 snapshots are placed from the rooms beside
  each scanned wall on load and on `.fieldplan` import, corners closed,
  written back once; sample and manual walls untouched; idempotent.
- `MeshFaceClassifier.estimateCeilingElevation` now ignores faces more than
  4.5 m above the floor so an upper story does not pass for a ceiling.
- Core suite: 207 tests, all passing on Linux. Every app file parses; the
  Xcode build must be done on the owner's Mac. Device checklist items 18–24
  in `Docs/DEVICE_TESTING.md` verify partition thickness, room size, corner
  closure, migration of an old project, two stories in one walk, Align Below
  and manual rooms.

## 2026-09-01 — Build 12 (version 1.2): scan engine stage 1

Driven by the CubiCasa benchmark audit (`Docs/CUBICASA_AUDIT.md`) and the
pipeline design (`Docs/SCAN_PIPELINE.md`). Accuracy and reliability first.

- **Sensor sessions are recorded** (`ScanRecorder`): the recorder joins the
  RoomPlan `ARSession`'s delegate chain (forwarding to whatever was there) and
  writes `sessions/<id>/` — `session.json` with 10 Hz camera poses (tracking
  state, depth availability and confidence shares, light estimate, mapping
  status), 20 Hz gyro/gravity, compass headings paired with the camera's
  heading, pose-tagged keyframes every 0.8 m / 25°, positioned photos, and one
  binary `MeshChunk` per LiDAR mesh anchor (latest revision, with ARKit's
  per-face classification when present). Checkpointed every 30 s. RoomPlan's
  configuration is never touched.
- **Live scan quality** (`ScanQualityEngine`, core, tested): tracking state,
  speed, rotation, light and LiDAR confidence with enter/exit hysteresis and
  minimum display times; RoomPlan's own coaching folds into the same
  prioritised list. The scan screen shows one chip, a status strip and the
  elapsed/observed-floor counters.
- **Coverage map** (`CoverageGrid`, core, tested): floor/wall/opening mesh
  evidence per 0.25 m cell, per-wall coverage with the uncovered ranges,
  corner and opening coverage. Classification uses ARKit's labels when the
  session provides them and a normal-plus-height fallback otherwise. Wall
  coverage only counts faces that run along the wall, so a corner does not
  credit both walls. The minimap draws it live with the walk and the walls
  RoomPlan has found so far, coloured by coverage.
- **Evidence on every scanned element** (`ElementEvidence`, `ConfidenceModel`,
  `EvidenceAttachment`): scanner bucket × coverage × tracking × observations,
  clamped to 5–99 %, with the factors recorded. Shown on tap in the plan, in
  Room Detail and on the Accuracy screen; the report states the band counts.
  Documented as an evidence score, not an accuracy claim.
- **Missing-space detection** (`MissingSpaceDetector`, core, tested): a
  footprint raster finds enclosed cells no room explains, doorways whose far
  side is unscanned, room edges with no wall behind them, and stairs with no
  adjacent level. After every save a review sheet hatches them on the plan and
  offers "Scan More" / "Use As Is"; the plan viewer keeps an Unscanned Space
  layer and the Accuracy screen lists them.
- **Accuracy framework** (`AccuracySample`, `AccuracyStatistics`,
  `AccuracyAnalysis`, core, tested): MAE / median / p95 / max / bias / RMS,
  percent errors, share within ½", 1" and 3 %, per-kind breakdown,
  repeat-scan standard deviation by name, confidence-bin calibration and
  primary-versus-alternate comparison. **Test From Plan** picks a wall, door,
  window or room and records its app value, element id and evidence score
  with the tape value. The report prints these statistics and nothing else as
  accuracy.
- **Positioned photos** (`PositionedPhotoRecord` → `PhotoRecord.planX/Y/
  heading`): the camera button on the scan screen stores a full-resolution
  JPEG with the pose; photos become numbered markers with a view wedge on the
  plan and in the report, and tapping a marker opens the photo.
- **Bridge fills in what RoomPlan already reports**: `door(isOpen:)`,
  `Surface.curve` (curved walls traced into arc segments with a chord and
  floor-outline sanity check), `story`, every `Section` with its centre
  (`splitIntoRooms` now types faces from sections and fixtures together), and
  object attributes/parents.
- **North** from the compass (`NorthEstimator`) when the level has none;
  `LevelGeometry.elevation` from the mesh floor.
- Model additions are all optional (`thicknessSource`, `evidence`, door
  `style`, `isOpenAtCapture`, `elevation`, `scanSessionIDs`,
  `schemaVersion`), so existing project files decode unchanged (tested).
- `.fieldplan` packages now carry `sessions/` and accuracy samples.
- Core suite: 174 tests, all passing on Linux. The iOS layer was
  syntax-checked here; `ScanRecorder.swift` is new and ARKit-heavy and must be
  compiled on the owner's Mac. Known one-liners if the SDK disagrees:
  `CapturedRoom.Object.story` / `.parentIdentifier` in `ScanSupport.swift`.

## Output validation (done in CI environment)

- `swift run GenerateSamplePlan <dir>` (SwiftPM snippet in the core package)
  emits the sample apartment's SVG/DXF/CSV/JSON/.fieldplan artifacts.
- The generated SVG plans (existing + demolition modes) were rendered in
  headless Chromium and visually inspected: poché walls with corner closure,
  window/door/opening symbols with swings, exterior dimension chains with
  extension lines and ticks, fitted room labels with areas, red-dashed
  demolition styling, scale bar and north arrow.
- The generated DXF was parsed with **ezdxf**: AC1009 recognized, all
  FieldPlan layers present (WALLS/DOORS/WINDOWS/DIMENSIONS/TEXT/FIXTURES/
  DEMOLITION/NEW_CONSTRUCTION/SYMBOLS), 273 entities on correct layers,
  inch-scaled extents and dimension texts verified.

## Environment note

This codebase was authored in a Linux cloud environment (Swift 6.2.1
toolchain). **`Packages/FieldPlanCore` compiles and its 113-test suite
passes there** — that package contains all measurement-critical logic.
The iOS app target requires Xcode on macOS; it has been kept to
conservative iOS 17 APIs and every app source file is machine-checked for
syntax, but the first `xcodebuild` must happen on a Mac. Expect the usual
first-open housekeeping (signing team selection); if any API drifted from
the installed SDK, fixes should be one-liners at clearly-marked call sites
(`Scanning/ScanSupport.swift`, `Scanning/ScanFlowView.swift` are the only
files touching RoomPlan).

## Completed

- **Phase 1 — Foundation**: project scaffold, SwiftData models with
  versioned schema, file store with atomic writes, settings (units,
  precision, branding), imperial parser/formatter, Linux-testable core
  package, test foundation.
- **Phase 2 — Scanning**: RoomPlan capture flow (level select → name room →
  scan → review → accept/rescan → next room), continuous ARSession for
  multi-room coordinate continuity, StructureBuilder merge, raw
  CapturedRoom JSON + USDZ persisted per scan, interruption handling,
  unsupported-device path with full manual room entry (rect + L-shape).
- **Phase 3 — Geometry engine**: canonical model, scan conversion with
  shared-wall dedupe, wall graph (snap, faces/room loops, collinear merge,
  overlap/dangling detection), room calculations, QA engine.
- **Phase 4 — 2D plan**: vector plan generator (walls with poché + openings,
  door swings, window glazing, fixtures, dimensions with extension lines and
  ticks, room + area labels, scale bar, north arrow), one renderer feeding
  screen, PDF, PNG, SVG, DXF.
- **Phase 5 — Plan editor**: select/drag corners/walls/fixtures with
  angle-preserving constraint propagation, exact length editing (4
  strategies, original value preserved), add wall/door/window/opening/
  fixture/note/dimension, split wall, merge/split rooms, ceiling heights,
  undo/redo (100 steps), snap + ortho + grid, per-element demolish/new
  markup, QA sheet.
- **Phase 6 — 3D**: SceneKit dollhouse from canonical geometry (openings cut
  as real holes with headers/sills), orbit/pan/zoom, existing vs proposed,
  furniture toggle, cutaway slider, element selection, two-point measuring,
  QuickLook for raw scan USDZ.
- **Phase 7 — Field documentation**: measurements with categories/kinds/
  provenance/verification/critical flags and edit-preserves-original,
  bathroom/kitchen/flooring/painting templates, photos (camera + import,
  thumbnails, captions, room attachment, arrow/circle/box/freehand/text
  annotation, cover photo), quick notes with phrase chips.
- **Phase 8 — Renovation tools**: Existing Conditions baseline with lock,
  proposed duplicates, existing/proposed/demolition/overlay render modes,
  side-by-side compare.
- **Phase 9 — Takeoff**: 20 categories, per-room surface selection (floor/
  ceiling/all-or-individual walls), explicit waste factors incl. custom,
  manual overrides that preserve computed values, live totals, CSV.
- **Phase 10 — Reporting**: configurable PDF (cover with logo/branding,
  project info, property summary, plans per level per mode, room schedule,
  measurement schedule, takeoff, photo pages with flattened annotations,
  notes, verification summary, disclaimer), QuickLook preview, share.
- **Phase 11 — Exports**: PNG, vector SVG, DXF R12 with layers, room/
  measurement/takeoff CSVs, versioned project JSON, USDZ, portable
  `.fieldplan` ZIP package with import.
- **Phase 12 — Production polish (first pass)**: jobsite mode, accuracy &
  verification screen with known-dimension tests, error surfacing
  throughout, accessibility labels on icon controls, dark mode via semantic
  colors, structured logging.

## In progress / next

- First build + run on macOS/Xcode with a real device (see
  `Docs/DEVICE_TESTING.md` for the on-site checklist).
- iCloud sync, Bluetooth laser meters, AR point-to-point measuring:
  deliberately deferred (§61); `MeasurementProvider` protocol and
  file-based storage are in place for them.

## Blocked

- Nothing blocked in code. Real-device RoomPlan validation requires the
  owner's LiDAR iPhone (cannot be simulated).

## 2026-08-30 — Jerry FieldPlans update

- Renamed user-facing app to **Jerry FieldPlans** (`JerryFieldPlans.xcodeproj`,
  target/product `JerryFieldPlans`, bundle id `com.jerry.fieldplans`, display
  name) so it can't collide with the owner's other FieldPlan project.
  Internal source folder and package names unchanged.
- Automatic room labeling: RoomPlan section labels bridged through, plus
  fixture-based inference in the core (tub→Bathroom, bed→Bedroom, stove→
  Kitchen, tiny toilet-only room→Powder Room, tiny empty room→Closet) with
  per-level numbered auto-names; scan flow naming is now optional.
- CubiCasa-style room labels on the plan: name / `W × D` (oriented bounding
  box aligned to the longest wall) / area, with fit-based line dropping.
- Use Current Address on the project form (CoreLocation + reverse geocoding,
  explicit user action only; location usage key added).
- Client PDF now pairs each level's 2D plan with a 3D dollhouse render on the
  same page (offscreen SCNRenderer) plus a per-level "Total: X sq ft" line;
  standalone 3D PNG export added; dollhouse materials restyled (wood floors,
  tile in wet rooms, white built-ins, warm furniture).
- Core suite now 105 tests, all passing on Linux; plan output re-rendered and
  visually reviewed with the new labels.

## 2026-08-30 — Sheet quality pass (from rendered-output review)

Findings came from rendering the generated SVG in a browser and reading the
generated DXF back with ezdxf, then fixing what the drawings actually showed:

- **`W × D` is now qualified for irregular rooms.** `GeometryOps.orientedExtents`
  reports how much of its bounding box a room fills; a room that does not fill
  it (L-shape, cut corner) is labelled `… overall` so the extents can never be
  multiplied into an area the room does not have.
- **Text fitting uses real font metrics.** `PlanTextMetrics` carries Helvetica
  advance widths (verified against browser measurements in a unit test): a
  single average was wrong by 2× between `BEDROOM` and `5' 0" × 6' 0"`, which
  both dropped labels that fit and kept labels that ran over a wall. Labels are
  now sized to the room, and a line that still does not fit is dropped.
- **Interior dimensions no longer land on top of small rooms' labels** — a wall
  is dimensioned inside a room only when that room is at least 2 m in its
  smaller direction; those walls are already on the exterior chains.
- **Sheet title block** (`PlanTitleBlock`, opt-in): property, address, plan
  title, total area, date, company and contact under the plan, wired into the
  PNG/SVG/DXF exports. The report keeps its own header and does not use it.
- **DXF text is now plain ASCII.** R12 declares no encoding, so the `×` in
  every room label reached CAD as `Ã—`; text is folded (×→x, dashes, curly
  quotes, accents) and text anchors are honoured, so title-block lines stay
  left-justified in AutoCAD.
- Core suite now 113 tests, all passing on Linux.

## 2026-08-30 — Client-sheet pass (matched to the owner's CubiCasa reference)

Driven by a marked-up reference plan from the owner, verified by rendering:

- **Door swings are derived, not defaulted.** `ScanConversion` and the sample
  fixtures were hard-setting `DoorSwing()`, so every door on every plan hinged
  the same way regardless of the rooms around it. Both now leave `swing` nil and
  `DoorSwingInference` reads it from the geometry: exterior doors swing in,
  closet doors swing out, doors off circulation swing into the room they serve,
  and between two rooms the leaf goes into the smaller one; the hinge lands on
  the jamb that parks the leaf against a wall. A hand-set swing always wins, and
  the editor's flip buttons now start from the swing actually drawn.
- **Room colour coding** by room type (`RoomType.planTint`, new `.roomFills`
  layer under everything). Muted register: warm for sleeping, cool for wet
  rooms. Skipped in DXF, where a fill would double every room outline.
- **Client-sheet defaults**: dimension chains, per-room areas, scale bar and
  north arrow are all off by default — the room label carries `W × D` and the
  totals live in the title block. The plan editor turns dimensions back on.
- **Centered title block** (`PlanTitleBlock.Style.centered`): company, area
  totals, address, centered under the plan with no border. The bordered
  two-column sheet block is still available as `.sheet`.
- **Plan symbols redrawn** to read at a glance: tub with rolled rim and tap,
  toilet as tank plus bowl, basin inset in its counter, range with burners and
  control strip, bed with pillows, sofa with back and arms.
- **3D furniture is modelled, not boxed** (`FurnitureModels`): each scanned
  bounding box is filled with primitives — bed with mattress and pillows, sofa
  with back and arms, toilet with tank and bowl, tub with a recessed basin,
  cabinets with door fronts, appliances with handles and burners, stairs with
  real treads. Proportions stay exactly as scanned.
- Core suite now 117 tests, all passing on Linux.

## 2026-08-30 — First real scan (living room / hallway / bathroom / kitchen)

The owner scanned four connected spaces on a LiDAR iPhone. Findings:

- **The whole capture came back as one room called "Living Room."** RoomPlan
  merges a continuous walk into a single `CapturedRoom`, and the converter made
  one `RoomShape` per captured room, typed from every object at once. The rooms
  were in the geometry all along: `ScanConversion.splitIntoRooms` now recovers
  them from the wall graph's interior faces and types each from the fixtures
  standing inside it, so a toilet makes a bathroom and a range makes a kitchen.
- **Face detection needed planar walls first.** A partition ends against the
  middle of an exterior wall, not at a corner, so the graph pruned it as a
  dead-end stub and returned a single face for the whole floor.
  `GeometryCleaner.splitAtJunctions` cuts walls where another wall's endpoint
  lands mid-span (tolerating a partition that stops at the wall face rather
  than its centreline). Four spaces → one face before, four faces after.
- Room colour coding was never broken — with every room typed `livingRoom`
  they were all correctly painted the same colour. It follows the fix above.
- **3D fixtures**: the toilet and basin were cylinders, which read as white
  blobs from above. Both are now oval in plan (a scaled cylinder section), the
  toilet gaining a cistern, pedestal and seat, the basin a recess and a spout.
- **Accuracy**: the scan path was audited for systematic error and adds none —
  no endpoint snapping is applied, and the room outline comes straight from
  RoomPlan's floor mesh (`GeometryOps.simplified` runs at a 1e-6 tolerance).
  A 1–2 inch disagreement with a tape measure is RoomPlan's own accuracy. The
  answer is correction, not smoothing: exact dimension editing preserves
  `originalLength` and marks the wall `.edited`.
- Core suite now 122 tests, all passing on Linux.

## 2026-08-30 — Build 8 (version 1.1), from bedroom/bathroom scan feedback

- **The app now says which build it is.** Settings → About shows version and
  build number, the release date and a one-line summary of what changed.
  `MARKETING_VERSION` 1.1 / `CURRENT_PROJECT_VERSION` 8, both bumped every
  push. Without this a pull that silently failed looked identical to one that
  worked, and "the version still says 1.0" was the only signal available.
- **Door hinge side now follows the corner, not the room.** The old rule chose
  the jamb whose open leaf sat closest to the room boundary, which put a
  bathroom door on the wrong jamb. A drafter hinges on the jamb nearer the
  wall's end so the leaf lies back along the adjacent wall; that is now the
  primary rule, with leaf clearance only breaking ties for genuinely centred
  openings. Note RoomPlan reports the opening identically whether the door was
  open or shut during the scan — hinge side is never in the capture data.
- **Ceiling heights on the plan**: `PlanGenerator.Options.showCeilingHeights`
  adds "CEILING 8' 0\"" under the room label, with a Ceiling Heights toggle in
  the plan's layer menu.
- **Mirror is a fixture category now** (`FixtureCategory.mirror`) with a plan
  symbol and a 3D model. RoomPlan does not detect mirrors, so this exists to be
  placed by hand in the editor.
- **Small storage renders as a nightstand/dresser** — drawer fronts and pulls
  below 0.85 m rather than shelves. RoomPlan reports nightstands as plain
  "storage".
- Core suite now 123 tests, all passing on Linux.

## 2026-08-30 — Build 9: the dollhouse was lit wrong, not shaped wrong

The owner compared the 3D view against a CubiCasa render and called it lame.
Fair: the geometry was never the main problem.

- The scene rendered with `autoenablesDefaultLighting` — a single flat
  headlight, no shadows, no ambient occlusion — over untextured solid colours.
  Under that setup any model reads as moulded plastic however well it is shaped.
- `SceneStyling` replaces it: warm key light casting soft deferred shadows,
  cool fill, ambient, and a gradient lighting environment so the
  physically-based materials have something to reflect. The camera gains
  screen-space ambient occlusion (which seats furniture on the floor), HDR and
  a little bloom. Both the interactive view and the offscreen PDF snapshot use
  it, and both now switch the headlight off.
- Floors are textured per room type, drawn procedurally in Core Graphics:
  staggered oak planks with grain for living space, grouted tile for wet rooms,
  flat-weave carpet for bedrooms. Nothing to license or download, and it scales
  to any room size.
- Remaining honest gap: furniture is still assembled from primitives. Matching
  a CubiCasa render exactly needs a library of authored meshes per object
  category — an asset/licensing decision, not a code one.

## 2026-08-30 — Build 10: furniture model library (drop-in)

The owner chose to replace primitive furniture with real models, starting from
free CC0 assets.

- `FurnitureLibrary` loads a model per fixture category from
  `FieldPlan/Furniture/`, accepting `.usdz/.scn/.usdc/.dae/.obj` — SceneKit
  reads OBJ and DAE through ModelIO, so downloaded models need no conversion.
- The scanned bounding box stays the measurement; the model is fitted to it.
  Loading normalises whatever it is given: flatten, centre the footprint, stand
  it on the floor, then scale to the scanned size. Anisotropy is clamped to
  1.6× so a bad detection cannot produce a grotesque model, and categories with
  a standardised shape (toilet, basin, vanity, mirror, TV) are fitted uniformly
  instead of stretched.
- Templates are cached and cloned per instance — a scan can hold a dozen
  chairs.
- **Every category without a model falls back to the primitive build**, so the
  library fills in one piece at a time and the app never regresses.
- `FurnitureLibrary.adjustments` carries a per-category yaw, so a model that
  faces the wrong way is a one-number fix rather than a re-export.
- Settings → 3D Model Library lists which categories are live.
- `Docs/FURNITURE_MODELS.md` documents the naming and orientation contract and
  names CC0 sources (Poly Haven, Kenney, Sketchfab CC0 filter). No models are
  committed: acquiring them is the owner's call, and binaries that cannot be
  inspected here should not be added blind.

## 2026-08-30 — Build 11: real furniture models installed

- **Kenney Furniture Kit (CC0) ships with the app** — 18 models: sofa, bed,
  chair, table, toilet, sink, vanity, bathtub, shower, mirror, television,
  refrigerator, stove, washer, storage, base/upper cabinets, stairs. Under
  600 KB total, no textures (colours come from the .mtl files), attribution in
  `FieldPlan/Furniture/CREDITS.txt` though CC0 does not require it.
- Verified before shipping rather than downloaded blind: the kit's own preview
  renders were assembled into a contact sheet and inspected, and each model's
  geometry was analysed for units and facing. Tall mass (toilet cistern, sofa
  back, headboard, shower wall) sits consistently at +Z, so the front is −Z,
  matching the loader's contract — no yaw corrections were needed.
- **Furniture is turned to face the room.** RoomPlan's oriented bounding box
  has no notion of a front, so the scanned rotation is only correct to a half
  turn. With primitives that barely showed; a real sofa backwards into the room
  is obvious. `wallFacingYaw` turns anything that belongs against a wall away
  from the nearest one, and leaves free-standing pieces as scanned. The yaw
  formula was checked against all four wall directions.
- Models are scaled to the scanned box, so the kit being at roughly half real
  scale does not matter.
