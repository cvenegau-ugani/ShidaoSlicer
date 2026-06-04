# Linux 24.04 — Setup Wizard freezes / blank / "loading"

**Status:** root cause identified, low-risk fix applied in worktree. **DONE-CONDITIONAL:**
real Ubuntu-24.04-desktop verification by Marc still required (see "Verification" below).

> **LAYER 1 (blank render)** — fixed by `WEBKIT_DISABLE_DMABUF_RENDERER=1`, commit
> `8b41a68108`, CONFIRMED on a real VM by Marc (wizard now PAINTS).
> **LAYER 2 (hangs on "Loading.....")** — NEW downstream problem; see the
> "Layer 2" section at the bottom of this file. `belt-a00` stays OPEN until the
> wizard is interactive end-to-end.

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

---

## Layer 2 — wizard PAINTS but hangs forever on "Loading....."

After Layer 1's `WEBKIT_DISABLE_DMABUF_RENDERER=1` (CONFIRMED on a real VM by Marc),
the wizard window now renders, but sits on **"Loading....."** and never becomes
interactive. The GPU/render half is solved; this is the **C++↔JS handshake never
completing**.

### The handshake (exact sequence, file:line)

The wizard's first page is the **passive loader** `resources/web/guide/0/index.html`
(`<div id="LoadTip">Loading……</div>`) with `resources/web/guide/0/load.js`:

```js
// load.js — the page does NOT request anything; it WAITS to be pushed to.
function HandleStudio(pVal) {
    if (pVal['command'] == 'userguide_profile_load_finish') JumpToTarget();  // -> real wizard page
}
function JumpToTarget(){ window.open('../'+TargetPage+'/index.html','_self'); }
```

C++ side (`src/slic3r/GUI/WebGuideDialog.cpp`):

1. `m_browser = WebView::CreateWebView(this, TargetUrl)` — `:128`. URL is
   `file://…/resources/web/guide/0/index.html?target=N` (`:217`).
2. `Bind(wxEVT_WEBVIEW_NAVIGATED, &GuideFrame::OnNavigationComplete, …)` — `:169`.
3. `OnNavigationComplete` (`:301`) — on first completion spawns worker thread
   `LoadProfileData` (`:305`).
4. `LoadProfileData` (`:1002`) scans local vendor JSON, builds
   `{command:"userguide_profile_load_finish"}`, then **injects it into the page**:
   `wxGetApp().CallAfter([…]{ RunScript("HandleStudio({…})"); })` — `:1081`.
5. `GuideFrame::RunScript` (`:523`) → `WebView::RunScript` →
   **`webkit_web_view_run_javascript(...)`** — `src/slic3r/GUI/Widgets/WebView.cpp:378`.

So the load is **C++ pushes, page jumps**. The page never makes a request, so this is
NOT a JS→C++ bridge dependency for the first load (hypothesis 1 is ruled out for the
initial hang — the `request_userguide_profile` JS→C++ path at `WebGuideDialog.cpp:401`
is used by *later* pages, not the loader). No external/CDN/font fetch exists in the
guide web assets (only a base64-inlined woff in `swiper-bundle.css`), so hypothesis 2
is ruled out. `resources_dir()` resolves the page correctly (the page paints), so
hypothesis 4 is ruled out for the stall.

### The stalling point — hypothesis 3 (webkit2gtk bubblewrap sandbox)

**Stall:** the injection in step 4/5 (`WebGuideDialog.cpp:1081` →
`WebView.cpp:378`) never lands in the WebProcess, so `HandleStudio()` /
`JumpToTarget()` never fire and the loader stays on "Loading.....".

**Evidence — the codebase already knows this and applies the fix to its OTHER two
webviews, but never to the wizard:**

| Webview site | DMA-BUF off | **Sandbox off** | Source |
|---|---|---|---|
| Fluidd (`orcabelt_fluidd_host`, subprocess) | ✅ | ✅ | `main.cpp` env list (DMABUF + `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS`) |
| `PrinterWebView` (in-process fallback) | ✅ | ✅ | `PrinterWebView.cpp:350` |
| **Setup Wizard (`GuideFrame`)** | ✅ (Layer 1) | ❌ **never** | — |

`PrinterWebView.cpp:349` comments it verbatim: *"Disable WebKit sandbox in child
(bwrap fails silently in nested forks)"*. Inside webkit2gtk's bwrap sandbox on a clean
24.04 / AppImage mount, the confined WebProcess can stall on `file://` local-resource
access and on the JSC bridge that `webkit_web_view_run_javascript` drives — the page
paints (DMA-BUF fixed in Layer 1) but the injection never completes. This is the single
most likely cause and it is corroborated by the project's own established pattern.

(Secondary note, not the primary cause: the wizard still runs JSC with JIT enabled,
whereas the Fluidd subprocess disables all JIT tiers to dodge the deterministic
`libjavascriptcoregtk +0x191f9fc` SIGSEGV ~2 s after load. The wizard report is a HANG,
not a crash, so the sandbox — not JSC-JIT — is the primary lever. If the sandbox flag
alone does not fully fix it, adding `JSC_useJIT=false` etc. is the proven next step.)

### Fix applied (worktree only — not committed)

`src/OrcaSlicer.cpp`, immediately after the existing
`setenv("WEBKIT_DISABLE_DMABUF_RENDERER","1",0)`:

```cpp
::setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", /* replace */ 0);
```

- `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` is the canonical disable variable for
  webkit2gtk-4.x (since 2.26); **NOT** `WEBKIT_FORCE_SANDBOX`, which does the opposite.
- Mode `0`: respect an explicit user/launcher override.
- Linux-only (`__WXGTK__`), once at process start before any webview is created —
  same site and pattern as the Layer 1 flag.
- Low blast radius: it only relaxes the WebKit WebProcess sandbox (the project already
  does this for its other two webviews); does **not** touch the belt transform core or
  support generation.

### FREE pre-check for Marc (NO rebuild)

Relaunch the **current** AppImage with both flags forced — if the wizard becomes
interactive (jumps past "Loading....."), Layer 2 is proven and the in-process setenv
is exactly that, made permanent:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
  ./ShidaoSlicer_nightly_x86_64.AppImage
```

If it STILL hangs on "Loading.....", add the JSC-JIT-off levers (the same set the
Fluidd subprocess uses) to isolate the JSC-crash family from the sandbox:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
JSC_useJIT=false JSC_useDFGJIT=false JSC_useFTLJIT=false JSC_useBaselineJIT=false \
  ./ShidaoSlicer_nightly_x86_64.AppImage
```

### Still DONE-CONDITIONAL

Real Ubuntu-24.04-VM verification by Marc is required. `belt-a00` stays **OPEN** until
the wizard is interactive end-to-end — "not blank" (Layer 1) is only partial progress.
