# Scan pipeline architecture

_Companion to `CUBICASA_AUDIT.md`. This is the design the implementation
stages follow; `ARCHITECTURE.md` describes the app as a whole._

## Principles

1. **Observations are kept; interpretations are derived.** Every scan
   session writes the sensor stream it was reconstructed from. RoomPlan's
   `CapturedRoom` is one interpretation of that stream; FieldPlan's own
   reconstruction is another; both link back to the session.
2. **Measured, assumed, edited and validated values are distinguishable.**
   `MeasurementSource`, `ThicknessSource`, `ElementEvidence` and
   `AccuracySample` never mix. A default is labelled a default.
3. **Nothing is snapped for looks.** Geometry changes only when a measurement
   or an explicit edit says so. Confidence is reported, never used to "clean".
4. **One canonical model.** `LevelGeometry` feeds the 2D generator, the 3D
   builder, quantities, exports and the editor. Evidence hangs off the same
   elements.
5. **Core first.** Anything expressible without Apple frameworks lives in
   `FieldPlanCore` and is tested on Linux; the app layer bridges mechanically.

## Data flow

```
ARSession (shared with RoomCaptureSession)
   │  frames, tracking state, light, depth stats, mesh anchors
   ▼
ScanRecorder (app)  ──►  sessions/<sessionID>/session.json      ScanSessionLog
                    ──►  sessions/<sessionID>/meshes/*.fpmesh   MeshChunk (binary)
                    ──►  sessions/<sessionID>/keyframes/*.jpg   pose-tagged keyframes
                    ──►  sessions/<sessionID>/photos/*.jpg      positioned snapshots
   │
   ├─ live ──► ScanQualityEngine (core) ──► advice + status strip
   └─ live ──► CoverageGrid (core)      ──► minimap, per-wall coverage advice

RoomCaptureSession ──► CapturedRoom ──► CapturedRoomBridge ──► ScannedRoomDTO
                                                                      │
                                    ScanConversion.convert / merge ◄──┘
                                              │
                          EvidenceAttachment (core): coverage + tracking + scanner
                          confidence → ElementEvidence on walls/openings/rooms/fixtures
                                              │
                                        LevelGeometry (canonical)
                                              │
              ┌───────────────┬───────────────┼───────────────┬──────────────┐
         PlanGenerator   ThreeDSceneBuilder  RoomCalculations  QAEngine   MissingSpaceDetector
```

## Session log (`ScanSessionLog`)

| Stream | Rate | Fields |
|---|---|---|
| `poses` | ≤ 10 Hz | time, 4×4 camera transform, tracking quality, depth availability, depth confidence fractions, ambient intensity / colour temperature, world-mapping status |
| `motion` | 20 Hz | gravity, rotation rate, user acceleration (CoreMotion) |
| `headings` | on change | magnetic/true heading, accuracy, camera plan heading at that instant |
| `keyframes` | every ≥ 0.8 m travelled or ≥ 25° turned | JPEG (≤ 1024 px long edge), transform, intrinsics, image size |
| `photos` | on demand | full-resolution JPEG, transform, plan position, plan heading, level/room |
| `meshes` | on anchor update, latest revision | binary `MeshChunk` per `ARMeshAnchor`: transform, vertices, faces, per-face classification when ARKit provides it |
| `events` | as they happen | room start/finish, interruption, relocalisation, RoomPlan instructions, tracking changes |
| `summary` | at end | duration, distance walked, speed stats, tracking/depth fractions, mesh totals |

`MeshChunk` binary layout (little-endian): `"FPMSH001"`, anchor UUID (16),
vertexCount u32, faceCount u32, flags u8 (bit 0 = classification present),
pad ×3, transform 16×f32 (column-major), vertices 3×f32 each, faces 3×u32
each, classification u8 per face. Decoding is in core so a Mac tool or a
future reconstruction pass can read old sessions.

Budget for a 20-minute scan on iPhone 16 Pro Max: poses ≈ 3 MB JSON,
motion ≈ 4 MB, keyframes ≈ 150 × 120 KB ≈ 18 MB, meshes ≈ 5–30 MB. All are
written during the scan from a background queue; nothing is buffered in RAM
beyond the latest revision of each mesh anchor.

## Scan quality engine

Pure state machine (`ScanQualityEngine`) fed by `PoseSample`s and optional
`MotionSample`s, plus pass-through of RoomPlan's own instructions and
coverage advice. Each condition has an enter/exit threshold, a minimum
duration before it is shown and a minimum display time so chips do not
flicker. Output is a prioritised list; the UI shows the first.

| Condition | Enter | Exit | Source |
|---|---|---|---|
| Tracking not available / initializing / lost / relocalizing | state | state | `ARCamera.TrackingState` |
| Excessive motion / insufficient features | state (0.3 s) | state | `ARCamera.TrackingState.Reason` |
| Slow down | speed > 1.4 m/s | < 1.0 m/s | pose track |
| Turn slowly | > 110°/s | < 70°/s | pose track or gyro |
| Low light | ambient < 300 | > 450 | `ARLightEstimate.ambientIntensity` |
| Low LiDAR confidence | high-confidence share < 35 % | > 55 % | `ARDepthData.confidenceMap` (when available) |
| Move closer / move away / low texture | RoomPlan | RoomPlan | `RoomCaptureSession.Instruction` |
| Wall / corner / opening not covered | coverage | coverage | `CoverageGrid` |

Thresholds come from CubiCasa's published guidance (normal walking pace,
turn slowly, 5–11 ft from walls, lights on) and ARKit's documented tracking
reasons; they are constants in `ScanQualityThresholds` so field testing can
tune them.

## Coverage grid

A sparse 0.25 m plan grid. Each classified mesh face contributes to the cell
under its centroid (floor / wall / ceiling / opening / other), and each pose
adds a visit. Classification uses ARKit's per-face classification when the
session provides it and a geometric fallback (face normal + height above the
estimated floor) otherwise, so coverage works even when RoomPlan's own
configuration omits mesh classification.

Queries: floor coverage of a polygon, wall coverage along a segment (with
the uncovered ranges), corner coverage, opening coverage, unobserved cells
for the minimap. These feed live advice, the post-scan review and
`ElementEvidence.coverage`.

## Evidence and confidence

`ElementEvidence` (optional on `Wall`, `WallOpening`, `RoomShape`,
`FixtureItem`) records: scanner confidence bucket, coverage fraction,
observation count, tracking-normal share while observed, both-sides-seen,
session id, an optional alternate measurement (e.g. a mesh line fit with its
residual), and the factors that produced the combined `confidence` score.

The score is a documented heuristic — base by scanner bucket, scaled by
coverage, tracking and observation count, clamped to [0.05, 0.99] — and it is
**not an accuracy claim**. The accuracy framework calibrates it: samples
carry the predicted confidence of the element they measured, and the
statistics report observed error per confidence bin. Until calibration data
exists the UI labels the number "confidence (evidence-based)".

## Missing-space detection

`MissingSpaceDetector` rasterises the level (0.15 m cells): wall cells,
room cells, cells reachable from outside, and the remainder — enclosed
cells no room explains. It reports:

- **Doorway to unscanned space** — a door/opening whose far side lands in an
  enclosed unexplained cell (an exterior door lands in an outside cell).
- **Footprint void** — an enclosed unexplained cluster ≥ 1.2 m² and ≥ 0.6 m
  wide, with its extent and cells for hatching on the plan.
- **Open room edge** — a room polygon edge with no wall behind it whose far
  side is not another room (open-plan boundaries between two rooms are fine).
- **Stairs to an unscanned level** — a stair fixture with no adjacent story.

Findings render as a hatched region with a label and appear in the review
step after every room and in the QA list. They never change geometry.

## Accuracy framework

`AccuracySample` links a known (tape/laser) value to a measured value, the
element it came from, its predicted confidence, an optional alternate
measurement, and the session. `AccuracyStatistics` computes MAE, median,
p95, max, bias, RMS, percent-error statistics, share within ½", 1" and 3 %,
per-kind breakdowns, repeat-scan standard deviation by (kind, name), and a
calibration table by confidence bin. No accuracy percentage is displayed
anywhere that does not come from these samples.

## Reconstruction (stage 2)

RoomPlan reports wall *surfaces*: the face of a wall as seen from inside a
room, with no thickness. Stage 2 turns faces into walls.

**Wall assembly** (`WallAssembly.assemble`, after `ScanConversion.convert`
has built every room's faces):

1. *Facing pairs.* Two parallel faces 4–45 cm apart that overlap along
   their length are the two sides of one wall. They become one centerline
   midway between them, spanning both, with `thickness` = the gap and
   `thicknessSource = .measured`. The higher-confidence face keeps its id;
   openings from both faces are re-placed by world position.
2. *Same-side duplicates* (a face captured twice, < 4 cm apart) fold into
   the better one.
3. *Lone faces* are offset half a wall away from the room they bound. Which
   side that is comes from the room polygons (a close probe first, since the
   face sits on its room's floor edge; a 30 cm probe when the floor stops
   short). What lies behind decides the thickness: a neighbouring room's
   floor edge within pairing range is the far face (measured); a neighbour
   further back, up to 75 cm, makes it a partition (4½" assumed); nothing
   makes it exterior (6" assumed). A face whose side cannot be told (one
   floor polygon spanning both rooms) stays where it was with
   `thicknessSource = nil`, which every consumer reads as "this line is the
   room boundary, not a centerline".
4. *Corners.* Offsetting pulls neighbours apart by a few inches.
   `closeCorners` extends walls meeting at an angle to their intersection,
   joins collinear neighbours end to end, and runs loose ends on to the
   centerline they stop against (a partition on an exterior wall). Ends
   more than 30 cm apart — a doorway between two wall segments — are left.

**Room polygons** stay interior. A room from a floor surface keeps RoomPlan's
floor corners; a room recovered from the wall graph (`splitIntoRooms`) is
the graph face inset by half the thickness of each wall that carries a
`thicknessSource` (`GeometryCleaner.interiorPolygon`). The editor rebuilds
rooms the same way, and manual rooms are entered as clear dimensions with
their centerlines placed half a wall outside.

**Quantities** (`RoomCalculations`) run along the polygon edges — the
painted faces — so gross wall area no longer grows when a centerline moves
outward. **Dimensions** read the way a drafter reads them: each jogged room
face to face inside, the footprint's outside faces where a side jogs, and
the overall width and depth in an outer lane; a rectangle reads from its
W × D label (`PlanGenerator.Options.interiorDimensions`). Nothing is
measured along a centerline.

**Mesh line fits** (`WallFitter`): a deterministic RANSAC line through the
wall-classified mesh faces beside each scanned wall, at 15 cm–2.2 m above
the floor, with residual and inlier count. It is stored as the wall's
`AlternateMeasurement` for the accuracy framework to judge and never
replaces RoomPlan's value.

**Stories** (`LevelAssignment`): captured rooms group by floor height (1.2 m
tolerance, one flow's frame). The group holding the first room scanned is
the level the owner selected; other groups go to a level within 1.2 m or a
new one a story up or down, named by story index, with the owner told once.
Heights are stored relative to the selected level because every scan starts
its own AR frame. The coverage map for another story is rebuilt from the
session's mesh at that floor height, with the ceiling estimate capped to the
story's band. The 3D viewer stacks levels at measured heights when every
level has one.

**Registration** (`LevelRegistration`): translate/rotate a whole level
(north turns with it); "Align Below" in the Levels manager puts a level's
staircase over the one below, or its footprint centre when there is no
stair.

## Presentation, quantities and exports (stage 3)

Everything below reads the canonical model; nothing re-measures.

- **Door styles** (`WallOpening.style`, `resolvedStyle`): hinged is the
  default because a scan sees a hole, never a leaf. The plan draws each
  style its own way (leaf and arc; two leaves; two slab panels on their
  tracks; a panel with its hidden pocket; folding pairs; an overhead panel
  with its raised position hidden). The swing record still decides hinge
  side and direction, and for a pocket door which jamb it slides into.
- **Stairs**: the fixture's local +y is the upper end. The plan draws
  treads, the walk line, an arrowhead at the top and "UP" at the foot; the
  3D primitive and the OBJ steps rise the same way; the editor flips it.
- **Cabinets** (`FixtureCleanup`): a scanned "storage" box with its bottom
  ≥ 0.9 m up and ≤ 1.3 m tall is an upper cabinet; one on the floor,
  0.75–1.05 m tall and 0.40–0.80 m deep, at least 0.45 m long, is a base
  cabinet. Base cabinets that continue each other (same axis within 6°,
  within 12 cm laterally and 12 cm end to end, depths within 15 cm) become
  one run; a run more than half its depth plus 25 cm from every wall is an
  island. Hand-placed fixtures are never touched.
- **Schedules** (`OpeningSchedule`): doors, then windows, then cased
  openings, numbered per kind across the levels in story order; rooms
  either side from a probe 30 cm past each face; for swinging doors the
  served room and the hand, read from the push side (the side the leaf
  swings away from): hinges on the viewer's left is LH.
- **Contractor quantities** (`ContractorQuantities`, `ContractorSummary`):
  paintable wall area = the room's net wall area along its polygon edges;
  tile and wainscot areas take each face's length × min(limit, wall height)
  less the part of every opening below the limit; volume = floor area ×
  ceiling height; fixture counts by category, with demolished ones apart;
  wet rooms are bathrooms, powder rooms, kitchens and laundries. The takeoff
  uses the same net area when every wall of a room is selected.
- **OBJ** (`OBJExporter`): metres, Y up, plan +y → −z. Walls are boxes
  between openings with headers and sills, exactly as the 3D viewer builds
  them; floors are slabs whose top and bottom are ear-clipped
  (`GeometryOps.triangulate`); fixtures are boxes at typical heights and
  offsets (uppers, hoods and mirrors hang); stairs are steps. Levels stack at
  their scanned heights when every level has one, else by story. Mode
  filtering is the plan's (`PlanGenerator.includeElement`). The MTL carries
  flat colours; both files ship zipped.

## Session ownership and recovery (build 15)

FieldPlan creates the `ARSession` and hands it to RoomPlan through
`RoomCaptureView(frame:arSession:)`. Everything — mesh anchors, camera
poses and intrinsics, keyframes, depth, light estimates, tracking and world
mapping state — arrives on one session the app controls. `SpatialSession`
owns it; `ScanRecorder` is its delegate and feeds tracking and mapping state
back. RoomPlan may still install its own delegate when it configures the
session, so the recorder re-attaches behind it after three seconds if no
frame has arrived, and records a `delegateReattached` event when it does.

**A room is safe the moment it is accepted.** Accept writes the raw
`CapturedRoom` JSON, the USDZ and a `RoomCheckpoint` before anything else.
Everything is keyed by `CapturedRoom.identifier`:

- `CheckpointStore.merge` folds a re-accepted or reprocessed room onto its
  existing record instead of adding a second one, and never loses a merge
  stamp to an older replay.
- `CheckpointStore.outstanding` is what Finish Level imports — read back
  from disk, not from memory, so a walk interrupted an hour ago is folded in
  and a room already merged is skipped.
- A checkpoint whose raw file will not decode is *reported*, never skipped
  silently. A room that cannot be recovered is something to know about while
  still at the property.

**World maps.** A map is checkpointed after each accepted room and on
interruption, but only from `mapped` or `extending` state, and never over a
better one (`WorldMapPolicy`). An origin `ARAnchor` is planted before saving.

**Resuming.** `initialWorldMap` is set and relocalization is awaited. Apple
does not document whether that map survives RoomPlan re-running the session
with its own configuration, so the app does not assume: it compares the
origin anchor's translation after the restore against the one saved, and
treats more than 10 cm of movement as a different coordinate space. A failed
verification never merges — it offers a separate session to be registered
later. `Docs/DEVICE_TESTING.md` item 32 is what settles the device behaviour.

**Storage.** The recorder measures its own session directory at each
30-second checkpoint and converts free space into minutes of recording left
at the observed rate, holding back a 500 MB reserve. Below 15 minutes it
warns, below 4 it is critical; with no rate yet it claims nothing.

## Validation dataset (build 15)

Ground truth is evidence recorded beside the plan, never an edit to it. One
`ValidationSample` holds every method's answer for one element —
`canonical`, `roomPlan`, `meshFit` (with its residual and inlier count),
`originalScanned`, `userEdited` — beside the laser or tape value. A method
with no answer is absent, not zero, and nothing is averaged or arbitrated.
`ValidationAnalysis` reports mean absolute error per method, head-to-head
counts over elements both methods measured, repeatability across rescans
linked by an explicit physical-element name (not by IDs, which change), and
confidence calibration. `FieldValidationBundle` exports the lot with the
heavy binaries referenced by path rather than copied.

## Snapshot files and migration

- `PlanSnapshot.schemaVersion` (nil = 1, current = 2). Version 2 means
  scanned walls are centerlines. `GeometryMigration` brings a version-1
  snapshot forward once, on load and on `.fieldplan` import: each
  `lidarScanned` wall with no `thicknessSource` is placed from the rooms
  beside it — a room on one side pushes it half a wall outward (assumed); a
  room on each side puts it midway between the two floor edges with the
  total as measured thickness when that is ≤ 45 cm; a wall the rooms cannot
  place is left exactly where it was — then the moved walls' corners are
  closed. Sample and manual walls are untouched. Migration is idempotent and
  the file is written back so it never runs twice.
- New model fields are optional so version-1 files decode unchanged.
- `ScanRecord.sessionID` links a RoomPlan capture to its sensor session;
  `.fieldplan` packages include `sessions/`.
