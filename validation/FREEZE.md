# Freezing `support_preprocess.py` (belt-z96)

Distributed builds (AppImage / Windows / macOS) bundle a **frozen** standalone
executable of `support_preprocess.py` so belt supports work on end-user machines
that have no Python / numpy / scipy / trimesh installed.

The freeze is produced in CI (`.github/workflows/build_orca.yml`, "Freeze
support_preprocess" steps) and dropped into `resources/validation/` before the
slicer build, so the resources-copy/packaging step ships it inside the app
payload. At runtime `Plater.cpp::belt_supports_find_runner()` prefers
`resources/validation/support_preprocess[.exe]` and runs it directly (no
`python3` prefix), falling back to the `.py` script only in source/dev trees.

## Validated command (PyInstaller 6.20.0, Python 3.11)

```sh
python -m pip install \
  "pyinstaller==6.20.0" "numpy==2.4.6" "scipy==1.17.1" \
  "trimesh==4.12.2" "manifold3d==3.5.0" "networkx==3.6.1" "shapely==2.1.2"

pyinstaller --onefile --name support_preprocess \
  --collect-all scipy --collect-all trimesh \
  --collect-all manifold3d --collect-all networkx \
  --hidden-import scipy.sparse.csgraph --hidden-import shapely \
  validation/support_preprocess.py
# → dist/support_preprocess  (or dist/support_preprocess.exe on Windows)
```

### Why each dependency / flag

- `numpy`, `scipy.sparse.csgraph` — overhang connected-component detection.
- `trimesh` + `manifold3d` — mesh boolean ops use `engine="manifold"`.
- `networkx` — trimesh `mesh.split()` / face-adjacency graphs (otherwise
  `ModuleNotFoundError: No module named 'networkx'` at the first boolean/split).
- `shapely` — pulled in by some trimesh paths; collected defensively.
- `--collect-all` is required for scipy/trimesh/manifold3d/networkx: their data
  files and dynamically-imported submodules are not picked up automatically.

### Smoke test

```sh
dist/support_preprocess --help
dist/support_preprocess model.stl --compound -o /tmp/out.stl   # exercises scipy + manifold + networkx + export
```

> macOS note: the GitHub runner is arm64, so the frozen helper is arm64-only
> even though the `.app` is universal. Apple Silicon (the majority) gets the
> bundled binary; Intel Macs fall back to the `python3 <script>` path.
