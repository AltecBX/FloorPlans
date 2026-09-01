# BUILD STATUS

_Last updated: 2026-08-30_

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
