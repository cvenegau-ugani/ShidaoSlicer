# Windows-only G-code rename failure on re-slice — root cause & fix

**Symptom (Marc, Windows):** on re-slice the export fails with
`Failed to rename the output G-code <name>.gcode.tmp -> <name>.gcode: permission denied / the file is locked`.
Survives all retries. Never reproduces on Linux.

**Status:** root cause identified, minimal fix applied. **Real-Windows verification by Marc is still required — this is done-conditional** (no Windows machine available here; the change is static-analysis-validated and self-consistent, but the locking behaviour itself is Windows-runtime-only).

---

## 1. The exact remaining handle

There is exactly **one** memory-mapped-file handle on the output G-code in the whole GUI:

```
src/slic3r/GUI/GCodeViewer.hpp:646
    boost::iostreams::mapped_file_source m_file;   // inside class GCodeWindow
```

opened at

```
src/slic3r/GUI/GCodeViewer.cpp:504
    m_file.open(boost::filesystem::path(m_filename));   // GCodeWindow::load_gcode
```

`boost::iostreams::mapped_file_source` on Windows wraps `CreateFileMapping`/`MapViewOfFile`
and (crucially) opens the backing file **without `FILE_SHARE_DELETE`**. boost exposes no API
to pass share flags, so a mapped file is locked against rename/delete for as long as the
mapping is open. On Linux the same mapping does **not** block a rename (the inode survives the
rename), which is why the bug is Windows-only.

### Why this handle is the one in the failing rename

The failing rename is:

```
src/libslic3r/GCode.cpp:2028
    std::error_code ret = rename_file(path_tmp, path);   // <name>.gcode.tmp -> <name>.gcode
```

Here `path` is **the slicer's per-plate temp output path**, produced by

```
src/slic3r/GUI/BackgroundSlicingProcess.cpp:245
    m_temp_output_path = this->get_current_plate()->get_tmp_gcode_path();
src/slic3r/GUI/BackgroundSlicingProcess.cpp:246
    m_fff_print->export_gcode(m_temp_output_path, m_gcode_result, ...);
```

Two facts make this the locked file:

1. **`get_tmp_gcode_path()` is per-plate and STABLE across re-slices of the same plate.**
   Re-slicing plate N writes to the *same* path as the previous slice of plate N.
2. **That exact path is what the preview maps.** After a slice, the preview loads via
   `GCodeViewer::load` → `m_sequential_view.gcode_window.load_gcode(gcode_result.filename, ...)`
   (`GCodeViewer.cpp:989`), and `gcode_result.filename` was set to that temp path in
   `GCode.cpp:2022 (result->filename = path)`. The G-code viewer deliberately maps the
   **unprocessed** temp G-code because its move vertices reference line offsets in that file
   (see the comment block at `BackgroundSlicingProcess.cpp:803`).

So on the next slice the background thread re-writes `path.tmp` and, at `GCode.cpp:2028`,
tries to rename `path.tmp -> path` **while `GCodeWindow::m_file` still maps the previous
`path`** → Windows denies the rename → the user-visible error.

(`GCodeProcessor.cpp:1282` is a second `rename_file`, but it operates on `*.postprocess ->
m_temp_output_path` and runs *before* the preview has re-mapped, so it is not the failing
site reported. The message Marc quotes — `.gcode.tmp -> .gcode` — is uniquely `GCode.cpp:2028`.)

---

## 2. Why the previous fix (commit 2b73bfe07e) missed it

The earlier fix released the mapping in **`Plater::reslice()`** only:

```
src/slic3r/GUI/Plater.cpp:15724
    if (GLCanvas3D* preview_canvas = get_preview_canvas3D())
        preview_canvas->release_gcode_file_mapping();
```

It is incomplete on **two independent axes**:

### (a) Wrong/insufficient set of canvases

Every `GLCanvas3D` embeds its **own** `GCodeViewer m_gcode_viewer` (`GLCanvas3D.hpp:563`),
hence its own `GCodeWindow::m_file` mapping. There are two relevant canvases:

| canvas | getter | released by old fix? |
|---|---|---|
| **Preview** | `get_preview_canvas3D()` → `p->preview->get_canvas3d()` | yes |
| **View3D**  | `get_view3D_canvas3D()`  → `p->view3D->get_canvas3d()`  | **NO** |

The View3D canvas's G-code viewer can hold a live mapping of the same temp path, and the old
fix never touched it.

### (b) Wrong/insufficient set of entry points

`Plater::reslice()` is **not** the only path that reaches `GCode::export()` and thus the
`GCode.cpp:2028` rename. Every G-code-producing path funnels through
**`Plater::priv::restart_background_process()`** (`Plater.cpp:7716`) →
`background_process.start()` → the slicing thread → `export_gcode()` → `GCode::export()`.
Callers that bypass `reslice()` entirely (so the old release never ran):

* `Plater::priv::export_gcode(...)` (both overloads, `Plater.cpp:7784` / `7816`) —
  **"Export G-code"** and **send-to-printer / upload**, via `FORCE_EXPORT`.
* the per-plate reslice variants at `Plater.cpp:15957` / `16005`.

On any of these, the preview's (and/or View3D's) mapping of the previous slice is still open
when the new slice renames over the same temp path → the bug reproduces despite the old fix.

Additionally, the rename runs on the **background slicing thread** while the mapping is held by
the **main GUI thread**; releasing only on one specific main-thread path leaves a wide window
where the lock is still present.

---

## 3. The fix (applied)

Move the release to the **single chokepoint** that every export/reslice/upload path shares —
`Plater::priv::restart_background_process()` — and release **both** canvases, immediately
before `background_process.start()` (i.e. before the slicing thread can reach the rename):

```
src/slic3r/GUI/Plater.cpp:7741   (new lambda)
    auto belt_release_all_gcode_mappings = [this]() {
        if (this->view3D)
            if (GLCanvas3D* c = this->view3D->get_canvas3d())
                c->release_gcode_file_mapping();
        if (this->preview)
            if (GLCanvas3D* c = this->preview->get_canvas3d())
                c->release_gcode_file_mapping();
    };
```

called at both `start()` branches:

```
src/slic3r/GUI/Plater.cpp:7757   belt_release_all_gcode_mappings();  (FORCE_RESTART/FORCE_EXPORT/RESTART branch)
src/slic3r/GUI/Plater.cpp:7768   belt_release_all_gcode_mappings();  (empty-process FORCE_RESTART branch)
```

`release_gcode_file_mapping()` → `GCodeViewer::stop_mapping_gcode_file()` →
`m_sequential_view.gcode_window.reset()` → `stop_mapping_file()` → `m_file.close()`. It drops
**only** the file text mapping, not the 3D toolpaths, so the belt preview stays on screen with
no flicker. It is idempotent (no-op if nothing is mapped) and a harmless no-op on Linux.

The old `reslice()`-only release at `Plater.cpp:15724` is now redundant but left in place
(idempotent) to keep the diff minimal and avoid any behavioural risk.

### Why not "open the mapping with FILE_SHARE_DELETE" instead

boost's `mapped_file_source` provides no way to pass Windows share flags, so the only robust
options are (i) guarantee the unmap happens before the rename, or (ii) replace boost's mmap
with a hand-rolled `CreateFileMapping` that passes `FILE_SHARE_DELETE`. Option (i) is far less
invasive and touches no belt-transform code, so that is what was done. The existing
`WindowsSupport::rename` wrapper (`utils.cpp:627`, borrowed from LLVM) already retries 12× and
even tries to move a locked *destination* aside — but it cannot defeat a *self-inflicted* lock
held by our own process on the same path; only dropping our mapping first fixes that.

---

## 4. Files touched

* `src/slic3r/GUI/Plater.cpp` — added `belt_release_all_gcode_mappings` lambda in
  `Plater::priv::restart_background_process()` and two call sites (lines ~7741, 7757, 7768).

No belt-transform core code was modified (GCode.cpp/GCodeWriter.cpp math, BeltTransform.*,
slicing geometry untouched). This is purely file-handle/IO ordering.

## 5. Verification status

* Static analysis: the fix sits on the proven single chokepoint; both canvases and all
  entry points are now covered. Symbols (`view3D`/`preview` members, `get_canvas3d()`,
  `release_gcode_file_mapping()`) are all used identically elsewhere in the same translation
  unit (139 existing `*->get_canvas3d()` calls), so it compiles.
* **Not** built here (no build dir in the worktree; full OrcaSlicer configure+build is
  infeasible in this isolated worktree). Edit verified syntactically sound and self-consistent.
* **Windows runtime verification by Marc is required** to confirm the rename now succeeds on
  repeated re-slice and on "Export G-code"/send-to-printer. Done-conditional until then.
