# Device Testing Checklist

RoomPlan cannot be validated in the simulator. This checklist covers the
first real-device session and what to verify on an actual property walk.

## Requirements

- LiDAR iPhone (12 Pro or newer Pro/Pro Max, or any LiDAR model), iOS 17+.
- Xcode 15.4+ on macOS, personal team selected for automatic signing.

## Simulator-testable (no device needed)

Everything except live capture: load **Settings → Load SAMPLE Project**,
then exercise the floor plan viewer/editor, exact dimension edits, plan
versions + demolition/proposed modes, 3D dollhouse, measurements +
templates, photos (import path), notes, takeoff with surface selection,
PDF report, and every export (PNG/SVG/DXF/CSV/JSON/.fieldplan).

## First device session

1. **Capability gate**: on a non-LiDAR device the Scan screen must show the
   manual-entry path, never a broken scanner.
2. **Single room**: scan a bedroom; verify coaching chips appear, Finish →
   review stats → Accept; check the plan's wall lengths against a tape
   measure in 2–3 places; record results in Accuracy → Known-Dimension Test.
3. **Multi-room**: scan 2–3 connected rooms in one session (do not close the
   scanner between rooms); after Finish & Save verify rooms land aligned on
   one plan and the shared partition is a single wall.
4. **Openings**: confirm doors/windows appear on the correct walls with
   plausible widths; fix any misses in the editor (tap wall → add opening).
5. **Interruption**: take a phone call / background the app mid-scan;
   confirm the interruption message, that previously accepted rooms
   survived, and that rescanning the in-progress room works.
6. **Raw data**: Export screen should list per-room USDZ; QuickLook them
   from the 3D screen menu.
7. **Storage pressure**: with a nearly full device, confirm scan save
   failures surface as alerts rather than silent loss.
8. **Jobsite mode**: brightness up, gloves if you use them — buttons must
   remain hittable; screen must stay awake during an active scan.

## Known limitations to verify/accept

- Rooms scanned in *separate* sessions do not share a coordinate space; they
  are placed as captured and may need repositioning in the editor (scan
  connected areas in one session for best alignment).
- RoomPlan curved-wall output is flattened to straight segments between
  polygon corners.
- Very cluttered/mirrored rooms reduce capture confidence — check the QA
  screen after each floor.
