# 3D furniture models

The 3D view draws every scanned object twice over: RoomPlan reports a labelled
**bounding box**, and the app draws *something* inside that box. By default it
builds a shape from primitives — recognisable, but obviously not a real sofa.

Drop a real model into `FieldPlan/Furniture/` and it is used instead. The box
is still the measurement; the model is only how that measurement is drawn, so
a plan never becomes less accurate by looking better.

## Naming

One file per category, named exactly as below, in `FieldPlan/Furniture/`:

| File | What it is | File | What it is |
|---|---|---|---|
| `sofa` | Sofa / couch | `toilet` | Toilet |
| `bed` | Bed | `sink` | Wash basin |
| `chair` | Chair | `vanity` | Vanity unit |
| `table` | Table | `bathtub` | Bathtub |
| `storage` | Dresser, nightstand, shelving | `shower` | Shower |
| `television` | TV | `mirror` | Mirror |
| `refrigerator` | Fridge | `dishwasher` | Dishwasher |
| `stove` | Range / cooktop | `washerDryer` | Washer / dryer |
| `oven` | Wall oven | `fireplace` | Fireplace |
| `cabinetBase` | Base cabinet run | `stairs` | Stairs |

Accepted extensions, tried in this order:

    .usdz  .scn  .usdc  .dae  .obj

**You do not have to convert to USDZ.** SceneKit reads OBJ and DAE directly,
so a downloaded `sofa.obj` (with its `.mtl` beside it) works as-is. If you do
want USDZ, Apple's free **Reality Converter** does it by drag and drop.

Only add what you have — every category without a file keeps its built-in
shape. **Settings → 3D Model Library** lists which ones are live.

## Orientation and scale

The loader normalises whatever you give it: it centres the footprint, stands
the model on the floor, and scales it to the scanned object's real dimensions.
You do not need to size models correctly. Two things it cannot guess:

- **Which way the model faces.** The convention is *front toward −Z*. If a
  piece comes out facing the wrong way, don't re-export it — set a yaw in
  `FurnitureLibrary.adjustments`, e.g. `.sofa: Adjustment(yaw: 90)`.
- **Whether stretching is acceptable.** Most furniture is stretched to fill the
  measured box (a 7-foot scanned sofa should draw 7 feet long). Fixtures with a
  standardised shape look wrong stretched, so toilets, basins, vanities,
  mirrors and TVs are fitted uniformly instead. Change that per category with
  `Adjustment(uniform: true/false)`.

Keep models reasonably light — a few thousand triangles each is plenty for a
dollhouse view, and a scan can contain a dozen chairs.

## What is already installed

The **Kenney Furniture Kit (CC0)** ships with the app — 18 models covering
sofa, bed, chair, table, toilet, sink, vanity, bathtub, shower, mirror,
television, refrigerator, stove, washer/dryer, storage, base and upper
cabinets, and stairs. They are low-poly and stylised, which suits a dollhouse
render and keeps the whole set under 600 KB. See `FieldPlan/Furniture/
CREDITS.txt`.

To replace any of them with something you prefer, just overwrite the file —
the name is all that matters.

## Where to get more free models

All of these are **CC0** (public domain, no attribution required, safe to ship
in a commercial app). Always confirm the licence on the individual model — a
site can host mixed licences.

- **Poly Haven** — polyhaven.com/models — CC0, high quality, small catalogue.
- **Kenney** — kenney.nl — CC0 furniture kits, low-poly and stylised, which
  suits a dollhouse render and keeps files tiny.
- **Sketchfab** — sketchfab.com, filter Downloadable + CC0. The largest
  selection; quality varies, so check the triangle count before downloading.

Avoid Apple's AR Quick Look gallery models: they are samples licensed for
evaluation, not for shipping inside an app.

## Adding one

1. Download the model and rename it to the category, e.g. `sofa.usdz`.
2. Put it in `FieldPlan/Furniture/`.
3. Build. The Xcode project uses a synchronized folder, so the file is picked
   up with no project changes.
4. Open **Settings → 3D Model Library** to confirm it registered, then look at
   the 3D view.

If it registers but does not appear, check Build Phases → Copy Bundle
Resources includes it. If it appears facing the wrong way, add a yaw as above.
