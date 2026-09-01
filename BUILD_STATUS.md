# BUILD STATUS

_Last updated: 2026-09-01_

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
