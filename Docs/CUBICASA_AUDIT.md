# CubiCasa benchmark and FieldPlan technical audit

_Audit date: 2026-09-01. Target device: iPhone 16 Pro Max (LiDAR), iOS 17+._

This document does three things:

1. Records what CubiCasa's current product actually does, from its own
   knowledge base and public material (not from memory), so the comparison is
   evidence-based.
2. Audits every part of the FieldPlan repository that touches scanning,
   reconstruction, the canonical model, 2D/3D generation, editing, export and
   persistence — with concrete defects and file references.
3. Produces the comparison matrix and the prioritised plan that the
   implementation stages in `Docs/SCAN_PIPELINE.md` follow.

The standard applied throughout is the owner's: _walk in with the phone, scan
once, leave knowing everything was captured, and use the numbers, the 2D plan
and the 3D model in a construction proposal._

---

## Part 1 — What CubiCasa does today

### 1.1 Product shape

CubiCasa is a **capture app plus a cloud service with human QA**, not an
on-device reconstruction engine. Its own description of processing is:
_"Our state-of-the-art machine vision and artificial intelligence algorithms
create a point cloud from the data"_, a 2D plan is rendered from it, and then
_"we have a QA engineer check it for accuracy"_ before delivery. Room labels are
_"detected automatically from the scan using state-of-the-art machine vision
algorithms"_ and verified by the human QA team. Nothing is available on the
device after a scan: _"No immediate sketch available post-scan."_

Consequences that matter for this project:

- Every architectural decision (wall lines, thickness, door type, room type,
  missed windows) is made off-device, with a person in the loop.
- The app's job is to produce a **good video + tracking stream**. All of its
  scanning rules exist to make that stream reconstructable later.
- There is **no in-app coverage feedback**: _"Currently, we don't provide
  feedback on what you've already scanned."_ Users are told to plan a route
  and _"review the video recording before submitting"_.

### 1.2 Scanning methodology (the rules and why they exist)

From the quick guide, best practices and "where to start" articles:

| Rule | Stated form | Why it works (reconstruction reason) |
|---|---|---|
| One continuous scan | "scan the whole property in one continuous scan (including all floors and any detached garage/porch)"; multiple scans "will be processed/charged separately" and "we are unable to combine or merge orders" | One tracking session = one coordinate frame. Their pipeline has no cross-session registration. |
| Lowest floor first, finish each floor | "Start scanning on the lowest floor and work your way upwards… do not go back and forth between floors" | Monotonic elevation lets floors be segmented by height; revisiting floors creates ambiguous vertical assignment. |
| Chest height, both hands, portrait | "Hold the device with both hands at chest height"; "Snapshots have to be taken in portrait otherwise it will affect the scan" | Constant camera height = stable floor-plane estimate; portrait keeps floor/wall junction and ceiling context in the vertical FOV. |
| Camera straight ahead in walking direction, slightly down | "Point the camera straight ahead toward the walking direction. Don't walk sideways"; "Angle your phone slightly down… focus on the floors" | Visual-inertial tracking is most stable with forward motion parallax; the wall/floor line is the primary feature their 2D pipeline extracts. |
| 5–11 ft (1.5–3 m) from walls and furniture | "no closer than 5 feet… and no farther away than 11 feet" | Too close: textureless walls, tracking loss, depth saturation. Too far: line extraction precision falls off with distance. |
| Keep baseboards/floor in frame; walk along walls | "Walk along the walls as much as possible, ensuring baseboards and floor are in the frame" | The floor–wall intersection is the measured quantity; wall height is not. |
| Never pan from the room centre | "Don't stand in the middle of the rooms to pan" | Pure rotation gives no parallax → scale drift and depth ambiguity for monocular tracking. |
| Back out of small rooms, turn slowly | "Turn slowly and back out of narrow spaces rather than turning around" | Fast rotation blurs features and breaks tracking; small spaces have too little parallax to re-localise. |
| Stop and pan only for fixed furniture and windows | "For installed furniture or windows, stop completely, pan upward… then pan downward while remaining stationary" | Fixtures and windows are above the floor line and need explicit coverage. |
| Kitchens: pause and pan to cover wall cabinets | "Pause and pan to cover all furnitures and especially wall cabinet" | Uppers are otherwise never in the frame at chest height, slightly down. |
| Closets from the doorway | "Scan smaller spaces through the door opening without entering"; "just stand at the doorway and pan to both sides"; walk in only if the walk-in is large | Entering tiny spaces kills tracking; closet depth behind a door is inferred ("automatically detect closet doors and infer enclosed storage behind them"). |
| Ceilings: only under 7 ft, < 5 s, slight upward angle | "only scan ceilings that are less than 7 feet"; "Do not scan ceilings for over 5 seconds" | Ceilings are featureless; sustained ceiling views lose tracking. Height is not a deliverable. |
| Doors open before scanning; don't operate doors on camera | "Open doors before scanning. If you can't don't open/close them in front of the camera" | Moving planes corrupt tracking and confuse the door/opening classifier. |
| Lighting: all lights on, curtains open; flashlight in dark spaces; skip very dark spaces | "Turn on all lights, open shutters and curtains"; "if it's dark… use lights" | Feature tracking is camera-based even on LiDAR devices. |
| Stairs: point up the stairs and walk at normal pace | "When you get to the bottom of the stairs, point the device up the stairs and walk up them" | Keeps tracking through the floor transition; the staircase is the vertical alignment anchor between floors. |
| Detached structures ≤ 300 ft walk outdoors, daylight | "Up to 300 feet between structures while maintaining continuous scanning" | Same continuous-frame requirement; outdoors relies on visual features. |
| Property size | "up to 10,000 sq ft / 900 m²" recommended; up to 50,000 sq ft processed; disable "Show Mesh" on LiDAR devices to save memory; "scan and save in parts" (iOS) | Memory of the recorded stream on device. |
| Review before upload | "always review your scan before you leave the property" (video review only) | No coverage model exists; the user is the coverage model. |

### 1.3 Device handling and LiDAR

- Supported: iPhone XR+ (iOS 18+ for the current app); LiDAR on Pro models
  gives _"better accuracy overall"_ and _"better position tracking, which
  improves scan stability."_ The App Store notes read _"Mesh is back for iOS 26
  users with LiDAR"_, i.e. a live mesh overlay is a display feature.
- Public material never describes storing depth maps, meshes or IMU logs; the
  product language is "video"; LiDAR is used for tracking stability and
  accuracy of the same pipeline. There is a documented warning _"No Depth Data
  Warning on iPhone Pro Scans"_, so depth is consumed on LiDAR devices.
- Tracking loss handling: _"Tracking lost due to mishandling the device. Keep
  the device in scanning position at all times"_ → **Relocate** → "Go back and
  rescan the previous space" → yellow "Relocating…" → green "We have
  relocated!". iOS only. Causes listed: featureless surfaces, excessive
  motion/sharp turns, sudden lighting change, dark spaces. _"Scans cannot be
  resumed or merged once the app crashes."_
- Resume scan (iOS only, before upload): return to _"the exact spot where
  scanning stopped"_, relocalise on previously scanned features, continue.

### 1.4 Accuracy claims and measurement conventions

- _"average accuracy of 95% to 97%"_; LiDAR devices _"within 3%"_; the FAQ
  states _"error margin is around 3%-5%"_ overall.
- Accuracy is expressed only as a percentage; they explicitly _"cannot provide
  absolute offset values (e.g. ±3 inches)"_. All measurements are _"rounded to
  the closest inch"_.
- Factors: scanning technique, lighting, obstructions of the floor/wall line,
  hardware.
- Wall thickness is **assumed**, not measured: _"6" for exterior walls and 4"
  for interior walls"_ by default; custom thickness by request, only before
  processing.
- Room dimensions on the plan are **maximum width × length** ("may include
  alcoves"); room **area** is the shoelace polygon area, and they warn that
  W×L overstates irregular rooms (their example: 19'10" × 14'10" → 294 vs 227
  sq ft actual).
- Total drawn area = all spaces + all walls (internal and external); GLA
  follows ANSI Z765 (7 ft ceilings, stairs counted on the floor they descend
  from, area under stairs on the landing floor, openings to below excluded,
  sloped ceilings counted down to 5 ft, bay windows only if floor-to-ceiling;
  exterior walls included for single units, half of shared walls for
  townhouses, excluded for apartments).
- Variance framing: even two appraisers differ by _"an average 4%"_.

### 1.5 What is drawn, and what can be edited

- 2D plan: walls, door openings with swings, windows, stairs, room labels,
  room dimensions (toggle), areas (option), compass (option), total area
  breakdown (GIA / GLA options), disclaimer; **fixed furniture only with
  PLUS** (kitchen cabinets and appliances, plumbing fixtures, built-ins);
  patios/balconies/decks appear if scanned. Themes/styles change colours,
  fonts, wall fill; plans are highly customisable and _"don't follow a
  specific standard"_ except GLA plans.
- GLA legend: green living, red non-living with an exclusion reason printed,
  yellow below-grade living, purple ADU; Fannie Mae UAD 3.6 patterns.
- 3D plan (PLUS 3D): walls, doors, windows, floors, _"wall colors, wallpaper"_,
  materials matched approximately, furniture matched at _"approximately 80%"_
  or virtual staging for vacant homes; **no dimensions, no area labels, no
  compass** in the 3D; decorative accessories and renovations-in-progress
  excluded; 3D video renders and CAD (.dwg, .dae, .obj, .fbx) as add-ons.
- QuickEdit (web, Chrome only): rename rooms / change space type, move/rotate
  labels, label size, show/hide dimensions, draw lines and custom
  measurements, add free text, rename floors, set above/below grade, compass
  orientation, and (PLUS) move/resize/rotate/add/remove fixed furniture.
  **Walls, doors and windows are not user-editable** — those go through a
  change request to production staff (typical: "if a door or window has been
  missed (it can happen for high windows), CubiCasa will correct and add it").
- Missing rooms: one forgotten room → fix request with a sketch and
  dimensions; more than one → _"redo the entire scan"_.
- Snapshots: photos taken with an in-scan button; position on the plan is
  captured at shutter time; delivered as a PDF report with markers; external
  photos cannot be positioned afterwards.
- Home Report: per-room dimensions and counts for MLS entry.

### 1.6 Things CubiCasa does that the brief did not list

- **Property type drives area rules** (single unit / townhouse / apartment).
- **Speech recognition** for room labels while scanning (2.0 release notes).
- **Per-scan comments** (custom wall thickness, notes to production).
- **Hosted floor plan / tour** links and MLS integrations (irrelevant here).
- **Storage warnings** with remaining scan minutes.

---

## Part 2 — FieldPlan repository audit

### 2.1 Component map

| Concern | Files | Notes |
|---|---|---|
| RoomPlan capture | `FieldPlan/Scanning/ScanFlowView.swift` (`ScanCoordinator`, `ScanFlowView`, `RoomNameSheet`) | `RoomCaptureView` + `RoomCaptureSession`, continuous AR session across rooms (`stop(pauseARSession: false)`), `StructureBuilder` merge used only for a combined USDZ. |
| RoomPlan → DTO bridge | `FieldPlan/Scanning/ScanSupport.swift` (`CapturedRoomBridge`, `ScanCapability`) | The only file that reads RoomPlan geometry types. |
| ARKit | `ScanSupport.swift` (`ARWorldTrackingConfiguration.supportsSceneReconstruction` capability check only) | **No ARSession delegate, no ARFrame, no mesh anchors, no depth, no camera intrinsics, no tracking state are read anywhere.** |
| CoreMotion / compass | none | Not used. `LocationAddressService.swift` uses CoreLocation for reverse geocoding only. |
| Camera | `FieldPlan/Photos/PhotosScreen.swift` (`UIImagePickerController`) | Jobsite photos, no pose. |
| Mesh / point cloud | none | RoomPlan's mesh is never observed; only the processed `CapturedRoom` is kept. |
| Canonical model | `Packages/FieldPlanCore/.../Model/CanonicalModel.swift` | `Wall`, `WallOpening`, `RoomShape`, `FixtureItem`, `PlanAnnotation`, `LevelGeometry`, `PlanSnapshot`, provenance enums. |
| Scan conversion | `.../Scan/ScanConversion.swift` | DTOs, `convert`, `merge`, `splitIntoRooms`, `dedupeSharedWalls`, room typing. |
| Geometry | `.../Geometry/Vector2.swift`, `GeometryOps.swift`, `WallGraph.swift`, `DoorSwingInference.swift` | Half-edge face walk, junction splitting, polygon ops, swing inference. |
| Room detection | `ScanConversion.splitIntoRooms` + `WallGraph.interiorFaces` | Faces of the planar wall graph, typed from contained fixtures. |
| Measurement | `.../Measurement/Units.swift`, `FieldMeasurement.swift`; `FieldPlan/Measurements/MeasurementsScreen.swift` | Formatter/parser, manual measurements with provenance. |
| 2D plan | `.../Plan/PlanScene.swift`, `PlanGenerator.swift`, `PlanTextMetrics.swift`; `FieldPlan/Plan/PlanRendering.swift`, `PlanCanvasView.swift`, `FloorPlanScreen.swift` | Vector primitives → Canvas / CGContext / SVG / DXF. |
| 3D | `FieldPlan/ThreeD/ThreeDViewerScreen.swift` (`ThreeDSceneBuilder`), `SceneStyling.swift`, `FurnitureLibrary.swift`, `FurnitureModels.swift`, `ThreeDSnapshot.swift` | SceneKit, built from `LevelGeometry` (same source as 2D). |
| Editing | `.../Editing/EditorEngine.swift`; `FieldPlan/Plan/PlanEditorScreen.swift` | Pure functions over `LevelGeometry`, undo stack of whole levels. |
| QA | `.../Analysis/QAEngine.swift` | Reports, never mutates. |
| Quantities | `.../Analysis/RoomCalculations.swift`, `.../Takeoff/Takeoff.swift` | Per-room and project rollups, takeoff with explicit waste. |
| Export | `.../Export/SVGExporter.swift`, `DXFExporter.swift`, `CSVExporter.swift`, `ProjectArchive.swift`, `ZipArchive.swift`; `FieldPlan/Export/ExportScreen.swift`; `FieldPlan/Reports/ReportBuilder.swift` | PDF, PNG, SVG, DXF R12, CSV, JSON, USDZ (raw RoomPlan), `.fieldplan`. |
| Persistence | `FieldPlan/Models/Records.swift`, `ProjectStore.swift` | SwiftData metadata + per-project JSON snapshots; raw `CapturedRoom` JSON + USDZ per scan. |
| Accuracy | `FieldPlan/Accuracy/AccuracyScreen.swift`, `AccuracyTestRecord` | Manual known-vs-app pairs, per-test delta only. |

### 2.2 What raw information is captured today

Per accepted room: the processed `CapturedRoom` encoded to JSON
(`CapturedRoomBridge.rawJSON`) and a parametric USDZ. That is RoomPlan's
**interpretation**, not the observations. Discarded: every ARFrame, camera
pose track, intrinsics, `sceneDepth` and its confidence map, every
`ARMeshAnchor` (vertices, faces, per-face classification), tracking state
history, light estimates, IMU, heading, timestamps.

The architecture note claims _"the original scan is never lost"_. That is true
of RoomPlan's output and false of the sensor data. A future reconstruction
algorithm cannot be applied to old scans; nothing but RoomPlan's own walls can
ever be re-derived. **This is the single largest structural gap against the
brief (§4, §21).**

### 2.3 Reconstruction path and its systematic issues

`CapturedRoom` → `ScannedRoomDTO` → `ScanConversion.convert` → `merge` →
`splitIntoRooms` → `LevelGeometry`.

Defects and limitations found, with locations:

1. **Door open/closed state is dropped.** `ScannedSurfaceDTO.isDoorOpen`
   exists but `CapturedRoomBridge.surfaceDTO` never sets it
   (`ScanSupport.swift:55-68`). RoomPlan reports it in
   `CapturedRoom.Surface.Category.door(isOpen:)`.
2. **Every wall is 4½" thick.** `thickness: nil` in the bridge → default
   `0.1143` in `ScanConversion.swift:314`. RoomPlan reports wall *surfaces*;
   when a partition is captured from both sides the two surfaces are 4–8"
   apart and `dedupeSharedWalls` (`ScanConversion.swift:492-542`) collapses
   them into one line at the higher-confidence face **and discards the
   measured gap** — the one wall thickness the scan actually measured.
   CubiCasa assumes 4"/6"; the app assumes 4½" for everything including
   exterior walls.
3. **Walls sit on the interior surface line but are drawn as centerlines.**
   `emitWall` (`PlanGenerator.swift:325-413`) and `wallNodes`
   (`ThreeDViewerScreen.swift:378-427`) put half the thickness on each side of
   the measured surface, so the poché intrudes 2¼" into every room in 2D and
   the 3D wall box straddles the real face. 2D and 3D agree with each other
   and both disagree with the floor polygon by half a wall.
4. **Curved walls are flattened to one chord.** `Surface.curve` is never
   bridged; `Docs/DEVICE_TESTING.md` lists it as a known limitation.
5. **Floor elevation is ignored.** `merge` (`ScanConversion.swift:453`) drops
   everything into the user-picked level regardless of the captured floor's
   world Y; `LevelGeometry` has no elevation and no transform; the 3D viewer
   stacks stories at a fixed 3.4 m (`ThreeDViewerScreen.swift:304`). Separate
   scan sessions are not registered to each other at all
   (`Docs/DEVICE_TESTING.md`, "Known limitations").
6. **RoomPlan's per-section room labels are wasted.** Only
   `room.sections.first` is bridged (`ScanSupport.swift:103`) and applied to
   the whole capture; sections carry a centre point each and would type the
   individual faces `splitIntoRooms` recovers.
7. **No tracking-state awareness.** Only `RoomCaptureSession.Instruction`
   (`moveCloseToWall`, `slowDown`, `turnOnLight`, `lowTexture`) is surfaced
   (`ScanFlowView.swift:158-172`); `ARCamera.TrackingState`, relocalisation,
   and interruption recovery are absent — an interruption is a hard failure
   for the room in progress (`handleInterruption`).
8. **Confidence is three buckets and never reaches the plan.**
   `CaptureConfidence.low/medium/high` is copied from RoomPlan and shown
   nowhere on the drawing or in the room schedule; nothing distinguishes a
   wall seen for 30 s from three angles from one glimpsed once.
9. **No coverage model, no missing-space detection.** QA
   (`QAEngine.swift`) checks topology of what exists (gaps, overlaps,
   impossible openings). Nothing reasons about what is *absent*: a doorway
   with no room behind it, a void inside the footprint, an open polygon edge.
10. **Dimensioning is wall-based and collision-blind.**
    `dimensionPrimitives` (`PlanGenerator.swift:551-604`) dimensions each
    wall segment individually with no exterior overall chain and no text
    overlap resolution; small interior partitions are simply skipped.
11. **Wall quantities mix bases.** `RoomCalculations.grossWallArea` sums
    bounding-wall lengths × heights while `baseMoldingLength` and
    `crownMoldingLength` use the polygon perimeter
    (`RoomCalculations.swift:81-122`). With surface-line walls these agree;
    once walls become centerlines they diverge by a wall thickness per corner.
12. **Accuracy testing is manual and stat-free.** Both the known and the app
    value are typed by hand (`AccuracyScreen.swift:136-174`); no link to the
    element measured, no MAE/median/p95, no repeat-scan variance, no
    calibration against a predicted confidence.
13. **Photos are not positioned.** `PhotoRecord` has room/wall links but no
    plan position or heading; no in-scan snapshot button.
14. **Stairs are a box.** Tread lines only (`emitFixture`, `.stairs`); no
    up/down direction, no floor opening, no automatic level transition.
15. **No sliding / pocket / bi-fold doors.** `OpeningKind` is door / window /
    opening; a door's `swing` is the only style data.
16. **`StructureBuilder` result is unused for geometry** — it is exported to
    USDZ (`ScanFlowView.swift:493-502`) but conversion runs on the
    individually captured rooms, so its cross-room de-duplication and object
    beautification never reach the plan.
17. **Persistence writes the whole snapshot per edit** (`ProjectStore.
    saveSnapshot`) — fine at plan scale, but raw sensor logs must not go
    through the same JSON path.

What is sound and should be preserved:

- One canonical `LevelGeometry` feeds 2D, 3D, quantities, exports and the
  editor (brief §13 already satisfied structurally).
- Provenance enums (`MeasurementSource`, `VerificationStatus`,
  `ChangeStatus`) and `originalLength` preservation on edits.
- Wall graph with junction splitting and half-edge faces; room typing from
  fixtures; door swing inference with hand override.
- Pure `EditorEngine` with angle-preserving propagation and four exact-length
  strategies; QA as a reporter.
- Vector plan pipeline with one primitive set for every medium; DXF R12 with
  layers; `.fieldplan` package; atomic writes; Linux-tested core (123 tests).
- Presentation work already matched to the owner's CubiCasa reference sheet
  (room tints, swing-only doors, centered title block, fixture symbols,
  lit 3D with real furniture models).

### 2.4 Performance and offline posture

- Everything runs on device; no network except geocoding on request. Matches
  brief §23 already.
- Memory: RoomPlan owns the mesh; the app holds only `CapturedRoom`s. Adding
  raw capture must be throttled (poses at ~4 Hz, keyframes by distance, mesh
  anchors as latest-version binary chunks) and written to disk during the
  scan, not held in RAM.
- Thermal: RoomPlan + SceneKit overlay already push the SoC; the recorder
  must do no per-frame image encoding on the main thread.

---

## Part 3 — Comparison matrix

Priority: **P0** accuracy/reliability foundations, **P1** reconstruction and
QC, **P2** presentation and workflow. Difficulty: L / M / H.

| Category | FieldPlan today | CubiCasa | FieldPlan weakness | Recommended improvement | Pri | Diff |
|---|---|---|---|---|---|---|
| Scanning workflow | Room-by-room: name → scan → review → accept; level picked manually; continuous AR session | One continuous property walk, lowest floor first, review video, upload | Per-room stop/accept is slower than a walk-through and fragments coverage; no route guidance | Keep room segmentation (it gives per-room review) but add whole-floor "walk-through" mode with automatic room splitting (already exists in `splitIntoRooms`), lowest-floor-first prompting, elevation-based level assignment | P1 | M |
| LiDAR utilisation | RoomPlan only; mesh/depth never observed | Tracking + accuracy; live mesh display; depth warning | Nothing derived from the sensor beyond RoomPlan's boxes; no evidence retained | `ScanRecorder` on the shared `ARSession`: mesh anchors (classified), pose track, intrinsics, depth availability/confidence stats, light estimate, tracking state; persisted per session | P0 | M |
| Tracking | RoomPlan instructions only; interruption = failure | Tracking-lost → Relocate flow; resume scan by returning to the stop point | No tracking-state feedback; no relocalisation UX | Observe `ARCamera.TrackingState`; show reason-specific advice; on interruption keep the session and offer "return to where you were and hold steady" instead of failing the room | P0 | M |
| Coverage detection | None | None ("we don't provide feedback on what you've already scanned") | Parity with CubiCasa, but the brief requires better | `CoverageGrid` from classified mesh faces + camera path: per-wall, per-floor, per-corner, per-opening evidence; live minimap; per-element coverage stored with the geometry | P0 | M |
| Measurement accuracy | RoomPlan's (~1–2" observed by owner); no way to prove | "within 3%" on LiDAR, ±1" rounding; no absolute claim | No validation framework, no repeat statistics, thickness assumed everywhere | Accuracy framework with element-linked tests, MAE/median/p95/max, repeat SD, bias, calibration; measured partition thickness from both faces; mesh-fit wall evidence recorded alongside RoomPlan values so the two can be compared before either is trusted | P0 | M |
| Room detection | Wall-graph faces typed from fixtures; RoomPlan first-section label for the whole capture | ML + human QA | Per-section labels unused; closet/hall heuristics thin | Bridge all sections with centres; combine with fixture inference; area/aspect heuristics for hallway/closet; user override remains | P1 | L |
| Wall reconstruction | RoomPlan surfaces at the interior face, 4½" everywhere, both-side captures collapsed | Assumed 4"/6"; drawn as centerlines with poché | Thickness never measured; drawing offset by half a wall; curved walls flattened | Centerline walls with `thicknessSource` (measured/assumed/edited); measure partitions from facing surfaces; offset single-face walls outward; curved walls as arc-sampled segments with the radius retained; polygon inset so room areas stay interior | P0 | H |
| Door detection | RoomPlan doors; swing inferred; open state dropped | Doors with swings; type fixed by QA | No sliding/pocket/bifold; open state lost | Bridge `door(isOpen:)`; add `DoorStyle`; symbols for sliding/pocket/bifold/double; evidence-based confidence | P1 | L |
| Window detection | RoomPlan windows with sill from surface height | Windows, "high windows can be missed" | No confidence or coverage per window | Per-opening evidence (mesh coverage around the opening, confidence bucket, tracking during observation); "Window not fully captured" advice when RoomPlan reports low confidence | P1 | M |
| Fixed fixture detection | 18 RoomPlan categories → fixtures; counters/cabinets only as boxes | Fixed furniture drawn by QA (PLUS) | No island/counter recognition; cabinet runs not merged | Merge adjacent cabinet boxes into runs; island = cabinet not against a wall; counter line derived from base cabinets; manual add stays | P2 | M |
| Multi-floor | Manual level pick; fixed 3.4 m stacking; sessions unregistered | Lowest-floor-first, stairs as anchor, floors under 10 ft may merge | No elevation model; no alignment | `LevelGeometry.elevation` + `transform`; automatic level assignment from captured floor Y; shared-frame alignment when the AR session is continuous; footprint/stair registration for separate sessions with manual nudge | P1 | H |
| Stairs | Box with tread lines | Drawn with direction; ANSI area rules | No direction, no opening, no transition | Stair symbol with UP arrow and break line; opening-to-below on the upper level; stair fixture on both levels linked; QA if stairs lead to an unscanned level | P2 | M |
| 2D floor plans | Vector plan matched to owner's reference: tints, swings, labels W×D, title block | Themed plans, dimensions toggle, areas, compass | Dimension chains wall-based and collision-blind; no exterior overall dims; no findings/photo layers | Polygon-edge interior dims + exterior overall chain with lane packing; confidence shading option; photo markers; missing-space hatch | P2 | M |
| 3D floor plans | SceneKit dollhouse from the same geometry; lit; real furniture models | Rendered 3D with materials, furniture ~80% matched | Window elevations correct; wall boxes offset (see walls); stairs/openings crude | Follows from centerline walls; add stair mass and floor openings; OBJ export | P2 | M |
| Editing | Parametric editor: walls, corners, openings, fixtures, rooms, notes, dims, statuses, undo | Labels, dims, furniture, floor names, compass; walls/doors/windows not editable | Missing: door type, wall thickness source, rotate plan, set north, rename level in editor | Add those controls; everything already parametric | P2 | L |
| Measurements | Manual measurements with provenance; 3D two-point measure | Room dimensions, custom measurement lines | No confidence on geometry-derived values | Confidence on walls/openings/rooms; shown as "Confidence 92%" with the basis, and calibrated by the accuracy framework | P0 | M |
| Exports | PDF, PNG, SVG, DXF R12, CSV, JSON, USDZ (raw), `.fieldplan` | JPG/PNG/PDF/SVG; CAD dwg/dae/obj/fbx (add-on) | No JPG, no OBJ/DAE of the canonical model, no door/window schedules | JPG; OBJ (+MTL) from canonical geometry; door and window schedule CSV + report tables; DXF stays | P2 | L |
| Scan recovery | Rescan the room; separate sessions unregistered | Relocate; resume before upload; fix request after | No add-a-room-later that aligns; no local rescan replacing one wall | Session continuation (keep AR session alive while app is foregrounded), relocalisation prompt, room re-scan replaces by ID (exists), separate-session registration | P1 | H |
| Quality control | QA engine on topology after the fact | Human QA in the cloud | No live QC; no evidence | Live `ScanQualityEngine` (tracking, speed, rotation, depth confidence, light), coverage, post-scan missing-space findings, per-element confidence | P0 | M |
| Contractor functionality | Wall/ceiling/floor areas, perimeters, baseboard/crown, counts, takeoff with waste | MLS-oriented Home Report | Tile-wall sqft, paintable area, volumes, fixture counts, door/window sizes not rolled up | Extend `RoomCalculations`/schedules; keep geometry untouched | P2 | L |
| Performance | Fine for plan-scale JSON | Memory warnings, mesh display toggle | Raw capture must not blow memory | Throttled recorder, streamed binary mesh chunks, keyframes by travel, background encoding | P0 | M |
| User experience | Big controls, jobsite mode, auto labels, build stamp | Simple record button, coaching | Scan screen shows only RoomPlan's chip | Advice with priority + hysteresis, status strip, coverage minimap, post-room findings, snapshot button | P1 | M |

Judgement, not assumption: CubiCasa is ahead on **workflow simplicity, tracking
recovery, and the polish that a human QA pass buys**. FieldPlan is already
ahead on **on-device immediacy, parametric editing of walls/doors/windows,
contractor quantities, exports and offline posture**, and is structurally
positioned (one canonical model, Linux-tested core) to overtake on **evidence,
coverage, confidence and validation** — none of which CubiCasa exposes.

---

## Part 4 — Prioritised plan (mapped to the brief)

Stage 1 — evidence, live quality, coverage, validation (brief §4–§9, §17, §21, §22)
— **done, build 12.**

- Raw capture on the shared `ARSession` (poses, intrinsics, tracking state,
  depth stats, light, mesh anchors with classification, IMU, heading,
  keyframes) written per session; the interpreted geometry links back to the
  session and, per element, to the evidence that supports it.
- `ScanQualityEngine` (pure, tested): tracking, speed, rotation, depth
  confidence, lighting, distance; prioritised, hysteretic advice.
- `CoverageGrid` (pure, tested): floor/wall/corner/opening evidence from
  classified mesh faces and the camera path; per-element coverage scores.
- Confidence on walls, openings, rooms, fixtures with an explicit basis.
- `MissingSpaceDetector` (pure, tested): doorway to nowhere, footprint voids,
  open polygon edges, stairs to an unscanned level.
- Accuracy framework (pure, tested): element-linked samples, MAE / median /
  p95 / max / bias / repeat SD / calibration; the screen fills the app value
  from the element tapped on the plan.
- Positioned snapshots during the scan, drawn as markers on the plan.

Stage 2 — reconstruction (brief §7, §10–§14, §16) — **done, build 13**
(`Docs/SCAN_PIPELINE.md`, "Reconstruction").

- Centerline walls with measured/assumed thickness; partitions measured from
  facing surfaces (or from the neighbouring room's floor edge when only one
  face was walked); lone faces offset outward; corners closed after the
  offset; polygon inset so areas remain interior; migration of existing
  snapshots on load and import, written back once.
- Curved walls as arc-sampled segments with the radius retained (stage 1).
- All RoomPlan sections bridged; per-face typing (stage 1).
- Mesh-fit wall evidence (robust line fit, residual, inliers) recorded next
  to RoomPlan's line for comparison by the accuracy framework — **not**
  substituted until validated.
- Level elevation; rooms grouped by floor height and assigned to levels in
  one walk; per-story coverage map; 3D stacked at measured heights; Align
  Below (stairs, then footprint) in the Levels manager.
- Dimensions moved here because they depend on the centerline model: face
  to face inside jogged rooms, outside-face chains where a side jogs, overall
  extents outside; quantities along the painted faces.
- Door open state (stage 1). Door *style* rendering and its editor control
  remain in stage 3.

Stage 3 — presentation, editing, exports, contractor (brief §10, §11, §18–§20,
§24)

- Door styles drawn (sliding/pocket/bifold/double); stair symbol with
  direction; confidence shading; lane packing where dimensions collide.
- Editor: door style, wall thickness source, set north / rotate, rename level.
- Door and window schedules; JPG; OBJ export; contractor rollups (tile,
  paintable area, volume, fixture counts).
- Documentation, build stamp, device checklist for validating each stage.

Everything in stage 1 and 2 that can be expressed without Apple frameworks
lives in `FieldPlanCore` and is unit-tested on Linux; the app layer is kept to
mechanical bridging so it can be type-checked here against a shim and then
compiled on the owner's Mac.
