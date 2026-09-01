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

- Walls become **centerlines** with `thicknessSource`: partitions captured
  from both sides are measured (gap between facing surfaces), single-face
  walls are offset outward by an assumed thickness (marked assumed). Room
  polygons stay interior (RoomPlan floor corners, or wall-graph faces inset
  by half thickness). Quantities use interior faces; drawings and 3D use
  centerlines; the two now agree with each other and with the floor.
- Curved walls are arc-sampled into segments; the radius is kept as evidence.
- All RoomPlan sections (with centres and stories) bridge through and type the
  recovered faces.
- Mesh wall fits (robust 2D line fit on wall-classified faces near a wall)
  are recorded as the alternate measurement, never substituted until the
  accuracy framework shows they are better.
- `LevelGeometry.elevation` from the captured floor; automatic story
  assignment when the AR frame is continuous; registration for separate
  sessions.

## Snapshot files and migration

- `PlanSnapshot.schemaVersion` (nil = 1). Stage 2 introduces version 2
  (centerline walls) with a migration that offsets legacy surface-line walls
  outward by half their thickness using the rooms beside them.
- New model fields are optional so version-1 files decode unchanged.
- `ScanRecord.sessionID` links a RoomPlan capture to its sensor session;
  `.fieldplan` packages include `sessions/`.
