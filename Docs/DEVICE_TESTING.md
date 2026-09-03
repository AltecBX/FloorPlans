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

## Build 15 — field validation and recovery

These are the ones that matter before collecting real data. Items 32–36 are
destructive on purpose: the point is to prove a scan cannot be lost.

32. **Interruption**: start a scan, accept two rooms, then call the phone
    from another phone and answer. Come back to FieldPlan. You should get
    *Scan Interrupted* naming both accepted rooms, with **Continue This
    Scan** and **Finish With Saved Rooms**. Continue should relocalize (walk
    back to a scanned room and point at it) and then let you scan on. Report
    it if Continue succeeds but the next room lands in the wrong place — that
    is the case the origin-anchor check is meant to catch.
33. **Termination**: accept three rooms, then force-quit FieldPlan from the
    app switcher without finishing the level. Reopen the project and tap
    Scan Property. You should get *Unfinished Scan — 3 rooms saved* with the
    last room's name and time, and three choices. Choose **Finish With Saved
    Rooms**: all three rooms must appear on the plan. Nothing should be lost,
    and nothing should be imported twice.
34. **Re-open after finishing**: reopen the same project and tap Scan
    Property again. There must be **no** recovery prompt — the rooms were
    imported, so there is nothing unfinished.
35. **Discard**: repeat item 33, but choose **Discard Unfinished Session**
    and confirm. The rooms go; the prompt does not come back. This is the
    only path that throws a scan away, and it takes two taps to reach.
36. **Checkpoint failure**: fill the phone almost full (a large video file
    works), then scan and accept a room. If the write fails you must get
    *Room Not Saved* naming the room. Silence here is a bug.
37. **Preflight**: Project → Validation → Run Preflight Test. With Airplane
    Mode on and Location off you should get warnings on compass heading but
    **Ready to scan**; with sensor recording off (only possible with
    validation mode off) the recorder check must *block*.
38. **Validation mode banner**: turn Field Validation Mode on. The screen
    must state the app version and build, the device identifier
    (iPhone17,x), the iOS version, LiDAR present, recording on, and the
    session ID. Check the build number matches the one you installed —
    that is how a mismatched install is caught.
39. **Live diagnostics**: scan with validation mode on. The diagnostics panel
    must show tracking, world map state, depth confidence, mesh anchor count,
    "rooms saved to disk N of N" and recording time left. If rooms saved is
    ever behind rooms accepted, stop and report it.
40. **Storage warning**: scan until under about 15 minutes of space remains.
    The warning should appear once, in minutes, not gigabytes; at critical it
    turns red. Everything already scanned must still be recoverable.
41. **Ground truth**: Validation → Measure Elements. Tap a wall: everything
    is filled in and the keyboard is already up on the laser field. Type what
    the laser says, tap **Save & Next Element**, and you are straight back on
    the plan with a tick on that wall. Do twenty in a row and time it — this
    is the workflow that has to survive hundreds of measurements.
42. **Every method side by side**: after a dozen samples, tap **Compare
    Methods**. FieldPlan's value, the mesh fit and the original scan should
    each have their own mean error and their own "no answer" count. If any
    two are identical for every sample, the mesh alternate is not being
    recorded — report it.
43. **Repeatability**: scan the same property a second time on the same day.
    When measuring, use the *same* "same physical element" name for the same
    real wall (pick it from the list). The Repeatability section should then
    show a spread across two scans for that wall.
44. **Problem flags**: tap the flag button, then tap something wrong on the
    plan and pick a kind. It must appear as a marker on the plan and in the
    list — and the plan itself must be unchanged.
45. **Checklist and bundle**: before leaving, Validation → Field Visit
    Checklist. Work every open item. Then **Export Validation Bundle** and
    AirDrop the zip to a Mac. It should contain the manifest, the samples
    CSV, the analysis, the markers, the scan events and the plan. Open the
    CSV: each row must carry the laser value and every method's answer in
    its own column.

## Build 16 — how the plan reads

46. **Room labels**: open a scanned plan. Each room shows its name as you
    typed it (not SHOUTED) with its size under it as `13'0" x 12'0"`. Check
    one room against the tape — the label rounds to the whole inch on
    purpose; the exact measurement is still in Measure and in the CSVs.
47. **Colours**: bedrooms should be warm peach, bathrooms and laundry cool
    aqua, and the living room, kitchen, dining and hall all the same cream.
    If the kitchen is a different colour from the dining room beside it,
    the listing palette is not being used — tell me.
48. **Labels and fixtures**: scan a bathroom with a tub, toilet and vanity.
    The label must sit on clear floor, not across the tub, and a small
    bathroom should print just its name and size rather than three lines.
49. **Sideways labels**: scan a galley bath or a walk-in closet — something
    much deeper than it is wide. Its label should turn to read bottom-to-top.
    Every normally-shaped room must stay horizontal. Report any room that
    turned when it did not need to.
50. **Area under the sheet**: Export → Floor Plan PNG with the title block
    on. It should read "Measured Floor Area: 560 sq ft" — a whole number,
    no decimal — with each floor listed under it when you scanned more
    than one.

## Known limitations to verify/accept

- Rooms scanned in *separate* sessions do not share a coordinate space; they
  are placed as captured. Use Align Below, or move them in the editor.
- A partition seen from one side only, inside a single floor polygon that
  spans both rooms, is left on the captured face (thickness unknown) and the
  room behind it reads one wall too wide. Walk both sides of every partition.
- Very cluttered/mirrored rooms reduce capture confidence — check the QA
  screen after each floor.
- **Resuming across a coordinate space is unproven on device.** Apple does
  not document whether an `ARWorldMap` survives RoomPlan re-running the
  session with its own configuration. FieldPlan attempts the restore and
  then verifies it against an origin anchor; if the check fails it refuses to
  merge and says so. Item 32 is what tells us which way it actually goes.
- FieldPlan does not yet choose between measurement methods. It records what
  each one said and how far each was from the laser. Deciding which is better
  needs many properties, not one.
