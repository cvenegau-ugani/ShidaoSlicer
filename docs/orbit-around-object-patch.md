# ShidaoSlicer — Orbit camera around the selected object

Goal: left-drag should orbit the view around the **selected object's center**, not the middle
of the print bed. Fall back to bed-center behavior when nothing is selected.

## Why this is a small change

OrcaSlicer's `Camera` class already has a target-aware version of the exact rotation
function used by the main editor view:

- Currently the editor orbits with `Camera::rotate_on_sphere(azimut, zenit, apply_limits)`,
  which always pivots on `m_target` (the bed center).
- There is already `Camera::rotate_on_sphere_with_target(azimut, zenit, apply_limits, target)`
  that pivots on any point you pass in. (The Assembly view already uses the `_with_target`
  variants.)

So we just feed it the selection's bounding-box center.

Files involved:
- `src/slic3r/GUI/Camera.hpp` / `Camera.cpp` — no changes needed (function already exists).
- `src/slic3r/GUI/GLCanvas3D.cpp` — one edit in the mouse-drag rotation branch.

## Step 1 — find the call site

In `src/slic3r/GUI/GLCanvas3D.cpp`, search for:

```
rotate_on_sphere(
```

You're looking for the call inside `GLCanvas3D::on_mouse(...)`, in the branch that handles
**left-button dragging over empty space** (the orbit). It looks roughly like:

```cpp
const Vec3d rot = (Vec3d(pos.x(), pos.y(), 0.0) - m_mouse.drag.start_position_3D) * (PI * TRACKBALLSIZE / 300.0);
...
camera.rotate_on_sphere(rot.x(), rot.y(), current_printer_technology() != ptSLA);
```

Notes:
- Ignore any `rotate_local_with_target` / `rotate_local_around_target` calls guarded by
  `CanvasAssembleView` or `use_free_camera` — leave those alone.
- The 3rd argument (`current_printer_technology() != ptSLA` above) may read differently in
  your 2.4-dev source. **Keep whatever it currently is** — just copy it into the new call.

## Step 2 — make the edit

Replace the single `rotate_on_sphere(...)` call with a selection-aware version:

```cpp
// Orca: orbit around the selected object's center instead of the bed center
if (!m_selection.is_empty()) {
    const Vec3d rotate_target = m_selection.get_bounding_box().center();
    camera.rotate_on_sphere_with_target(rot.x(), rot.y(),
                                        current_printer_technology() != ptSLA,
                                        rotate_target);
} else {
    camera.rotate_on_sphere(rot.x(), rot.y(),
                            current_printer_technology() != ptSLA);
}
```

Details that make this compile cleanly:
- `m_selection` is the `Selection` member of `GLCanvas3D` (use `get_selection()` if `m_selection`
  isn't directly accessible in your version).
- `Selection::is_empty()` and `Selection::get_bounding_box()` both exist;
  `BoundingBoxf3::center()` gives the pivot point.
- Preserve the exact 3rd argument from the original call.

That's the whole functional change.

## Step 3 — build (office machine, VS2026)

Use the same build flow that produced your 2.4-dev build. If the stock `vs2022` script trips on
the CMake generator (the thing commit 84d8e6d was fixing), apply that generator fix first, then:

```
build_release_vs2022.bat
```

You can also do an incremental rebuild from the existing `build/` folder since only one .cpp
changed — much faster than a clean build.

## Step 4 — test

1. Launch the app, load a model, and move it **off** the bed center.
2. Select it, then left-drag to orbit — the view should now pivot on the object.
3. Deselect (click empty space) and left-drag — should fall back to the old bed-center orbit.
4. Check the Assembly view still rotates normally (we didn't touch it).

## Optional polish (later)

- Make it a Preference toggle ("Rotate around selection") so you can switch behaviors.
- Use the center of *all* objects when multiple are selected (already handled —
  `get_bounding_box()` covers the whole selection).
- If you want rotate-around-cursor (Fusion-style) instead, that's a bigger change: you'd
  raycast under the mouse to get a 3D hit point and pass that as the target.

## Caveat

I confirmed the `Camera` API from the current OrcaSlicer source directly. I could not pull the
exact lines of `GLCanvas3D::on_mouse` (the file is too large to fetch whole), so line numbers
above are approximate — rely on searching for `rotate_on_sphere(`. Your 2.4-dev source may
differ slightly from upstream `main`, but the approach holds.
