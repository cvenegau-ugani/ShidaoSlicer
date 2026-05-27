#!/bin/bash
# rebuild-stale-dep.sh — surgically rebuild a single dep when its CMake config
# (e.g. deps/PNG/PNG.cmake) was changed but the cached binary in
# deps/build/OrcaSlicer_dep/usr/local/lib still reflects the old config.
#
# Symptom: orca-slicer final link fails with "DSO missing from command line"
# or "undefined reference" for a symbol that should be in a deps lib but isn't
# (or has the wrong prefix). Example: PNG_PREFIX=prusaslicer_ dropped in commit
# 737f1a267c (2026-05-16) but deps cache still has prefixed libpng.a symbols.
#
# Usage:  ./scripts/rebuild-stale-dep.sh PNG
#         ./scripts/rebuild-stale-dep.sh OpenCV
#         ./scripts/rebuild-stale-dep.sh wxWidgets

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <DepName>   (e.g. PNG, OpenCV, wxWidgets, TIFF, JPEG)"
  exit 1
fi

DEP="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_BUILD="$REPO_ROOT/deps/build"

if [ ! -d "$DEPS_BUILD" ]; then
  echo "ERROR: $DEPS_BUILD not found. Run the initial deps build first:"
  echo "  cd deps && mkdir build && cd build && cmake .. && ninja"
  exit 1
fi

cd "$DEPS_BUILD"

# 1. Regenerate build.ninja from current deps/*/*.cmake sources.
echo ">>> Re-running cmake on deps to pick up source changes"
cmake . > /dev/null

# 2. Nuke the cached install (libs, headers, cmake exports) for this dep.
#    Pattern matching the dep name is conservative; tune per-dep below.
echo ">>> Removing cached install artifacts for $DEP"
case "$DEP" in
  PNG)
    rm -rf "OrcaSlicer_dep/usr/local/lib/libpng"* \
           "OrcaSlicer_dep/usr/local/include/png"*.h \
           "OrcaSlicer_dep/usr/local/include/pnglibconf.h" \
           "OrcaSlicer_dep/usr/local/lib/pkgconfig/libpng"* \
           "OrcaSlicer_dep/usr/local/lib/libpng/" 2>/dev/null || true
    ;;
  OpenCV)
    # OpenCV produces both libopencv_world.a (monolithic, used by orca-slicer)
    # and per-module .a (used during its own build). Wipe both, plus headers
    # and cmake exports. Symptom forcing rebuild: stale libopencv_world.a
    # references TIFF symbols (TIFFWriteDirectory/...) after WITH_TIFF=OFF
    # was added — see commit a80a4d6033.
    rm -rf "OrcaSlicer_dep/usr/local/lib/libopencv_"* \
           "OrcaSlicer_dep/usr/local/include/opencv4" \
           "OrcaSlicer_dep/usr/local/lib/cmake/opencv4" \
           "OrcaSlicer_dep/usr/local/share/opencv4" 2>/dev/null || true
    ;;
  wxWidgets)
    # wxWidgets installs under usr/local/lib/wx/ (config) + libwx_*.a archives.
    # Symptom forcing rebuild: imagpng.cpp references prusaslicer_png_* symbols
    # after PNG_PREFIX was dropped from libpng.
    rm -rf "OrcaSlicer_dep/usr/local/lib/libwx_"* \
           "OrcaSlicer_dep/usr/local/lib/wx" \
           "OrcaSlicer_dep/usr/local/include/wx-3.1" \
           "OrcaSlicer_dep/usr/local/bin/wx-config" 2>/dev/null || true
    ;;
  TIFF)
    # System libtiff is preferred on Linux (WITH_TIFF=OFF disables internal).
    # If a custom TIFF dep is ever reintroduced, this pattern matches.
    rm -rf "OrcaSlicer_dep/usr/local/lib/libtiff"* \
           "OrcaSlicer_dep/usr/local/include/tiff"*.h \
           "OrcaSlicer_dep/usr/local/include/tiffio"*.h \
           "OrcaSlicer_dep/usr/local/lib/pkgconfig/libtiff"* 2>/dev/null || true
    ;;
  JPEG|FREETYPE|Boost|TBB|OpenEXR|OpenVDB|Eigen)
    echo "WARNING: surgical removal pattern not defined for $DEP."
    echo "         Manually wipe its files under OrcaSlicer_dep/usr/local/{lib,include}/."
    echo "         Falling back to stamp-only invalidation."
    ;;
  *)
    echo "WARNING: unknown dep '$DEP'. Falling back to stamp-only invalidation."
    ;;
esac

# 3. Wipe the dep's prefix dir + completion stamp so ninja rebuilds it.
#    cmake will regenerate src/ and tmp/ on the next ninja run.
echo ">>> Invalidating ninja stamps for dep_$DEP"
rm -rf "dep_${DEP}-prefix/src/dep_${DEP}-build" \
       "dep_${DEP}-prefix/src/dep_${DEP}-stamp" \
       "CMakeFiles/dep_${DEP}-complete" 2>/dev/null || true

# 4. Re-run cmake so stamp-info text files (patch-info.txt etc.) are regenerated.
cmake . > /dev/null

# 5. Rebuild the dep.
echo ">>> Building dep_$DEP"
ninja "dep_$DEP"

echo
echo ">>> dep_$DEP rebuilt. To pick up the new libs in orca-slicer:"
echo "    cd $REPO_ROOT/build && ninja -f build-Debug.ninja OrcaSlicer"
echo "    (or build-Release.ninja for Release)"
