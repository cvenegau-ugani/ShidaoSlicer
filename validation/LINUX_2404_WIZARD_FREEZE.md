# Linux 24.04 — Setup Wizard freezes / blank / "loading"

**Status:** root cause identified, low-risk fix applied in worktree. **DONE-CONDITIONAL:**
real Ubuntu-24.04-desktop verification by Marc still required (see "Verification" below).

**Reporter:** Marc — clean Ubuntu 24.04. App now launches (libpng `-Wl,--exclude-libs,ALL`
fix, commit `9dee1f965e`), but the first-run **Setup Wizard** window opens and stays
**frozen / blank / loading**, never becomes interactive.

**Symptom class:** MISRENDER (blank GTK/webkit content), not a hang in our own code and
not a SIGSEGV.

---

## 1. What the "Setup Wizard" actually is

It is **not** the classic PrusaSlicer/Orca `ConfigWizard` (that class still exists in
`ConfigWizard.cpp` but its `run_wizard()` path is commented out). On first run the flow is:

```
GUI_App::on_init_inner()
  -> config_wizard_startup()                 GUI_App.cpp:7128
       if (!m_app_conf_exists || only_default_printers())   // true on a clean machine
       -> run_wizard(RR_DATA_EMPTY)          GUI_App.cpp:6934
            -> GuideFrame wizard(...)        WebGuideDialog.cpp:108  (constructor)
            -> wizard.run()                  WebGuideDialog.cpp:855
                 -> ShowModal()              WebGuideDialog.cpp:877   (modal; blocks main loop)
```

`GuideFrame` (`WebGuideDialog.cpp` / `.hpp`) is a **wxWebView dialog**. Its entire UI is an
HTML page loaded from local resources:

- `WebGuideDialog.cpp:128` — `m_browser = WebView::CreateWebView(this, TargetUrl)`
- The page is `resources/web/guide/0/index.html?target=...` loaded via `file://`
  (`SetStartPage()`, `WebGuideDialog.cpp:~216-257`).
- On `OnNavigationComplete` it spawns a worker thread `LoadProfileData`
  (`WebGuideDialog.cpp:305`) which scans local vendor JSON and pushes it into the page via
  `RunScript("HandleStudio(...)")`.

So the wizard's window content **is** the webview. If webkit2gtk renders that page blank,
the user sees a blank/"loading" modal that never becomes usable — precisely the report.

There are **no blocking network calls** in this path (profile data is read from local
vendor JSON; `Http`/`boost::asio` is included but the first-run load is filesystem-only),
so the network-timeout hypothesis is ruled out. The blocking work that *does* happen on the
main thread is `ShowModal()` pumping a webview that never paints.

## 2. The blocking / failing point (file:line evidence)

The in-process webview is created here:

- `src/slic3r/GUI/Widgets/WebView.cpp:274` — `auto webView = wxWebView::New();` (Linux path),
  then `webView->Create(...)` at `:295`. This is webkit2gtk-4.1, **in the main process**.

On a clean Ubuntu 24.04 desktop, webkit2gtk-4.1's default **DMA-BUF renderer** frequently
fails to allocate a GBM/DMA-BUF surface — on llvmpipe/software GL, on many Intel/AMD/older-
NVIDIA driver combos, under X11 forwarding, and in VMs. When that allocation fails, the
WebKit *web process* produces **no painted output**: the page is blank, the dialog stays
open, nothing is interactive. This is the single most common "webkit2gtk shows blank
content" failure across the Linux ecosystem, and the canonical fix is the env var
`WEBKIT_DISABLE_DMABUF_RENDERER=1` (falls back to the shared-memory renderer).

### Why this project hits it on the wizard specifically

The codebase **already knows** about this exact flag and uses it everywhere a webview is
expected to work on 24.04 — but never in the path the wizard takes:

| Webview site | Gets `WEBKIT_DISABLE_DMABUF_RENDERER`? | How |
|---|---|---|
| Fluidd device tab | ✅ | child sets it — `src/orcabelt_fluidd_host/main.cpp` + `PrinterWebView.cpp:351` (`setenv(...,0)` in forked child) |
| `PrinterWebView` in-process fallback | ✅ | `PrinterWebView.cpp:351` |
| Launcher (NVIDIA+Wayland+driver>555 only) | ⚠️ narrow | `build_linux_image.sh.in:74` |
| **Setup Wizard (`GuideFrame`) in-process webview** | ❌ **NEVER** | — |

The launcher script (`src/dev-utils/platform/unix/build_linux_image.sh.in:60-78`) only
exports the flag inside a 5-deep conditional: Wayland session **and** `glxinfo` present
**and** NVIDIA renderer **and** `nvidia-smi` present **and** driver major > 555. Marc's
clean 24.04 (X11 and/or Intel/AMD GPU and/or no glxinfo and/or NVIDIA ≤555) matches none of
those, so the flag is never set, and the wizard webview uses the broken DMA-BUF path.

The prior webview work (`belt-jpa`, commit `859eee229d`) added
`ORCABELT_DISABLE_WEBVIEW` to *fully disable* in-process webviews — but that targets a
**SIGSEGV in JSC**, not a blank render, and disabling it entirely would leave the wizard
with no UI at all (the `GuideFrame` ctor early-returns on a null browser,
`WebGuideDialog.cpp:130`, producing an empty dialog). So that is not the right lever for a
render failure.

## 3. gdb backtrace

Not captured. Rationale: the symptom is a **render failure inside webkit2gtk's separate web
process**, not a hang or crash in our main thread. A `thread apply all bt` on the main
process would show the normal `ShowModal()` / GTK main-loop idle stack — it cannot reveal a
GBM allocation failure happening in the WebKit web process. Reproducing the blank render
also requires the *specific* GPU/driver environment that lacks the DMA-BUF fast path, which a
headless `Xvfb` container does not faithfully reproduce (and the failure is silent — no
fatal signal to catch). The evidence here is static + the project's own corroborating use of
the identical flag for the same webkit2gtk-4.1-on-24.04 stack. This is why verification is
explicitly handed back to Marc on real hardware.

## 4. Fix applied (worktree only — not committed)

`src/OrcaSlicer.cpp`, in `CLI::run()` inside the existing `#ifdef __WXGTK__` startup block,
immediately after the existing `setenv("GDK_BACKEND","x11",...)` workaround:

```cpp
::setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", /* replace */ 0);
```

- Runs **once at process start**, before any webview (wizard or otherwise) is created.
- Linux-only (`__WXGTK__`).
- Mode `0` = do **not** overwrite if the user/launcher already set it (so the existing
  NVIDIA-fast-path and any user override still win).
- Mirrors the project's own established pattern: the line right above it already forces
  `GDK_BACKEND=x11` in-process for the same class of GTK/webkit startup problems.
- Low blast radius: the shared-memory renderer is universally supported; the only effect is
  slightly less GPU-accelerated webview compositing, which is irrelevant for the wizard's
  static HTML page and the Fluidd dashboard. It does **not** touch the belt transform core.

This makes every in-process webview on Linux use the safe renderer by default, closing the
gap that the launcher's narrow NVIDIA-only condition left open.

### Diff summary
- `src/OrcaSlicer.cpp`: +12 lines (1 `setenv` + comment) in the `__WXGTK__` startup guard.
  No other files changed.

## 5. Verification (DONE-CONDITIONAL — required before shipping)

Static analysis + the project's own corroborating usage make this the unambiguous #1 cause,
but a render bug can only be *confirmed* on the real environment:

1. Marc, on his clean Ubuntu 24.04 desktop, runs a build/AppImage containing this change and
   confirms the Setup Wizard now paints and is interactive.
2. Quick pre-build sanity check that does **not** require a rebuild: have Marc launch the
   **current** failing AppImage with the flag forced —
   `WEBKIT_DISABLE_DMABUF_RENDERER=1 ./ShidaoSlicer_..._FIXED_belt-nds.AppImage`.
   If the wizard renders correctly with the env var set, the diagnosis is proven and the
   in-process `setenv` is exactly that, made permanent.

### Fallback if the env var alone does NOT fix it on Marc's machine
Then it is a deeper webkit2gtk-4.1-on-24.04 failure (same family as the JSC SIGSEGV the
`belt-jpa` work addressed). Ranked next steps:
1. Have Marc also try `WEBKIT_DISABLE_COMPOSITING_MODE=1` and `LIBGL_ALWAYS_SOFTWARE=1` to
   narrow GPU vs. webkit-core.
2. If still blank, route the wizard webview through the existing `orcabelt_fluidd_host`
   subprocess-isolation pattern (generalise it beyond Fluidd), or
3. Set `ORCABELT_DISABLE_WEBVIEW` for the wizard and give `GuideFrame` a real native
   fallback UI instead of the current empty-dialog early-return at `WebGuideDialog.cpp:130`.
