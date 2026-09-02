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

## Scan engine (build 12) — verify on the property

9. **Recorder attached**: within a few seconds of starting a room the status
   strip shows speed/tracking/light and the mesh count climbs; the minimap
   fills with green floor cells behind you. If the strip never appears, the
   recorder did not receive frames — check the log for "re-attached".
10. **Advice**: jog for two seconds → "Slow down"; spin → "Turn slowly"; cover
    the camera → tracking advice in red. Chips must not flicker.
11. **Coverage**: walk one wall of a room and not the opposite one; after
    ~20 s the minimap shows the walked wall green and the far wall orange/red
    and "Wall not fully captured" appears.
12. **Photo**: tap the camera button twice; after Finish & Save the plan shows
    markers 1 and 2 where you stood, facing the way you looked; tapping opens
    the photo; the report's plan page carries the same markers.
13. **Findings**: scan two rooms but skip the one between them; the review
    sheet after saving should hatch the skipped space and name the doorway
    that leads into it. "Scan More" keeps the AR frame; "Use As Is" opens
    the plan with the Unscanned Space layer on.
14. **Evidence**: tap a wall on the plan — "Confidence NN%"; Room Detail shows
    a band per wall. Accuracy → Wall Evidence counts add up to the scanned
    walls.
15. **Accuracy tests**: Accuracy → Test From Plan → tap a wall → enter the
    tape length. Repeat on 6–10 walls, doors and windows; the statistics
    section fills in. Scan the same room twice with the same test names and
    Repeated Scans shows the spread.
16. **Curved wall**: scan a room with a curved wall; the plan should follow
    the curve and bulge the correct way. If it bulges outward when the wall
    bulges in, report it — the arc convention is then mirrored in
    `ScanConversion.curvedWallSegments`.
17. **Storage**: Settings shows the sensor-data toggle; a 5-minute scan should
    add roughly 20–60 MB under the project's `sessions/` folder.

## Reconstruction (build 13) — verify on the property

18. **Partition thickness**: scan two adjoining rooms in one session, walking
    both sides of the wall between them. Tap that wall on the plan: it
    should say the thickness is *measured* and the value should be within
    ½" of a tape across the door jamb. An exterior wall says *assumed*.
19. **Room size unchanged**: the W × D under each room name must match the
    tape face to face — the walls moved to their centerlines, the rooms did
    not grow. The overall dimensions outside the plan are outside face to
    outside face (room + one wall each side).
20. **Corners closed**: no gaps or overshoots where walls meet in the plan or
    in 3D; a partition runs into the exterior wall, not short of it.
21. **Old projects**: open a project scanned with build 12 or earlier. Its
    walls are moved outward by half a wall once (the log says "Migrated
    snapshot … v2"), room sizes stay the same, and the Existing Conditions
    plan still matches the tape. Report any wall left floating.
22. **Two stories in one walk**: start on the ground floor, climb the stairs
    and scan one room above without stopping. After Finish & Save an alert
    should say the upper room went to "Second Floor" (created if needed);
    Levels shows its floor height above the lowest; the 3D viewer stacks the
    two at that height.
23. **Align Below**: with two levels scanned in separate sessions, swipe the
    upper level right in Levels → Align Below. With a staircase on both it
    lands over the stair; otherwise the footprints are centred.
24. **Manual room**: draw a room by dimensions; its label reads the typed
    clear size and the walls sit outside it.

## Presentation and exports (build 14) — verify on the property

25. **Door styles**: in the editor tap a door → the style button (says
    "Hinged") → Sliding. The plan shows two panels; the schedule says
    "sliding" with no hand. Pocket and bi-fold likewise; the hinge/swing
    flips still move the pocket side and the fold side.
26. **Stairs**: scan a room with a staircase. The plan shows treads with an
    arrow and "UP"; if the arrow points at the bottom step, tap the stairs →
    "Up Direction". The 3D view's steps rise the same way.
27. **Cabinets**: scan a kitchen. Base cabinets arrive as runs (one outline
    per run, not one box per cabinet); uppers are drawn as upper cabinets;
    an island reads as an island in 3D and in Room Detail's fixture list.
    Report any run that joined across a gap or a corner.
28. **Schedule**: Export → Door & Window Schedule CSV. Marks count D1…, W1…;
    each door names the room it swings into and its hand — check three doors
    against the house from the push side (hinges on your left = LH).
29. **Quantities**: Room Detail shows Paintable Walls, Wall Tile to 7',
    Wainscot to 4', Volume and Fixtures; Takeoff → Job Quantities totals
    them. For one bathroom check paintable walls against tape: perimeter ×
    height minus the door and window.
30. **OBJ**: Export → 3D Model OBJ + MTL, AirDrop the zip to a Mac and open
    the .obj in Preview or Blender: walls with door and window holes, floors,
    fixtures, stairs as steps, both levels stacked if two were scanned.
31. **Level menu**: editor options → Level → Rotate 90°; everything turns
    together and the north arrow follows. Rename Level shows the new name on
    the plan, the schedules and the report.

## Known limitations to verify/accept

- Rooms scanned in *separate* sessions do not share a coordinate space; they
  are placed as captured. Use Align Below, or move them in the editor.
- A partition seen from one side only, inside a single floor polygon that
  spans both rooms, is left on the captured face (thickness unknown) and the
  room behind it reads one wall too wide. Walk both sides of every partition.
- Very cluttered/mirrored rooms reduce capture confidence — check the QA
  screen after each floor.
