# BUILD STATUS

_Last updated: 2026-08-27_

## Environment note

This codebase was authored in a Linux cloud environment (Swift 6.2.1
toolchain). **`Packages/FieldPlanCore` compiles and its 100-test suite
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
  package, test foundation (100 passing tests).
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
