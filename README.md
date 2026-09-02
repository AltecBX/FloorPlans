# Jerry FieldPlans

A private, offline-first iPhone app for renovation contractors: walk a
property, scan rooms with LiDAR, get an auto-labeled plan with room
dimensions, correct anything, photograph and measure everything, mark up the
proposed renovation, and leave with a client-ready PDF (2D plan + 3D
dollhouse on the same page), quantity takeoff and CAD-compatible exports.

Built with Swift, SwiftUI, RoomPlan, ARKit, SceneKit, SwiftData, PDFKit and
QuickLook. No accounts, no cloud, no analytics — everything stays on the
device (see [Privacy](#privacy)).

Highlights inspired by professional scanning workflows:

- **Automatic room labels** — scanned rooms name themselves (RoomPlan's room
  detection plus fixture inference: a tub means Bathroom, a bed means
  Bedroom), with numbering for duplicates. Type a name only when you want to.
- **Room dimensions on the plan** — every room shows `11' 5" × 12' 0"` and
  its area under the name, CubiCasa-style.
- **Use Current Address** — one tap on the project form fills the property
  address from where you're standing; you add the apartment number.
- **2D + 3D together** — the client PDF pairs each level's 2D plan with a
  3D dollhouse render on the same page, plus a standalone 3D PNG export.
- **Title block on shared plans** — PNG/SVG/DXF exports carry a sheet block
  with the property, total area, date and your company details, so a plan
  that leaves the phone identifies itself.
- **Scan engine** — live advice (tracking, speed, light, LiDAR confidence),
  a coverage minimap built from the LiDAR mesh, the sensor stream kept per
  session so scans can be re-processed later, an evidence score on every
  wall, positioned photos, unscanned-space detection before you leave, and
  an accuracy framework that only reports what a tape test showed. See
  `Docs/CUBICASA_AUDIT.md` and `Docs/SCAN_PIPELINE.md`.

> Internal names: the source folder is `FieldPlan/` and the engine package is
> `FieldPlanCore` — deliberately unchanged so code history stays clean. The
> app's product, bundle id (`com.jerry.fieldplans`) and every user-visible
> surface say **Jerry FieldPlans**, so it won't collide with any other
> FieldPlan project in Xcode.

## Opening the project

1. Open `JerryFieldPlans.xcodeproj` in **Xcode 15.4 or newer** (Xcode 16+/26
   recommended) on macOS.
2. Select the FieldPlan target → Signing & Capabilities → choose your
   personal team (automatic signing).
3. Build & run on your **LiDAR iPhone** (iPhone 12 Pro or newer Pro/Pro Max,
   or any iPhone with LiDAR). Deployment target is iOS 17.0.

The simulator runs everything except live scanning (RoomPlan requires real
LiDAR hardware); use **Settings → Load SAMPLE Project** to exercise plans,
editing, takeoff, reports and exports without a device or a property.

## Repository layout

| Path | What it is |
|---|---|
| `FieldPlan/` | The iOS app (SwiftUI, SwiftData, RoomPlan adapter, editors, 3D, reports) |
| `JerryFieldPlans.xcodeproj` | Xcode project (synchronized folders — files added to `FieldPlan/` are picked up automatically) |
| `Packages/FieldPlanCore/` | Platform-independent engine: geometry, wall graph, units, editing, QA, takeoff, plan generation, exports |
| `Docs/` | Architecture and device-testing notes |
| `BUILD_STATUS.md` | Current implementation status per phase |

## The core package

Every measurement-critical calculation lives in `FieldPlanCore`, which has
**zero UIKit/SwiftUI/RoomPlan dependencies** and runs on any Swift platform:

```sh
cd Packages/FieldPlanCore
swift test        # 219 unit tests: parser, geometry, wall graph, QA, takeoff, exports,
                  # scan quality, coverage, evidence, missing-space detection, accuracy stats
```

The test suite covers the spec's known shapes (10×10, 12×15, L-shape, angled
walls, connected rooms), imperial parsing (`12' 6 1/2"`, `84"`, `12 6`, …),
display-only rounding, exact dimension editing with angle preservation, DXF
and SVG output, JSON schema round-trips and the `.fieldplan` ZIP package.

## Key design decisions

- **Meters internally, always.** Feet-and-inches (default, 1/8″ precision)
  are display-only formatting; geometry is never rounded.
- **RoomPlan is an input, not the architecture.** Scans are converted into
  FieldPlan's own canonical model (walls, openings, rooms, fixtures) with
  per-element provenance; raw `CapturedRoom` JSON and USDZ are preserved per
  scan so processing can improve later without revisiting a property.
- **Plans are vectors.** The 2D plan is generated as structured primitives
  and rendered identically to screen, PDF, PNG, SVG and DXF (R12, layered
  WALLS/DOORS/WINDOWS/DIMENSIONS/TEXT/FIXTURES/DEMOLITION/NEW_CONSTRUCTION).
- **Existing Conditions is the locked baseline**; proposed renovations are
  duplicates carrying per-element Existing/Demolish/New status, from which
  the demolition and proposed plans render.
- **QA reports, never mutates.** Unclosed rooms, gaps, overlaps, impossible
  openings and suspicious dimensions are flagged for you to fix in the
  editor — the app never silently "fixes" a measurement.

## Privacy

All projects, scans, photos and measurements are stored locally
(SwiftData + Application Support files). There are no analytics or
advertising SDKs and no telemetry. The only network use is Apple's
geocoding service, and only at the moment you tap **Use Current Address**.
Data leaves the device only when you explicitly share an export.

## License / use

Private tool for the repository owner's contracting work. Not affiliated
with, and contains no code or assets from, any commercial scanning product.
