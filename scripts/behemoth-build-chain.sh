#!/bin/bash
# Run ON BEHEMOTH. Clone ShidaoSlicer, build deps + orca-slicer Release
# linked against behemoth's pango 1.57 / glycin / gtk 3.24.52 ABI.
# Resolves belt-rs1 (binary built on Ubuntu 24.04 nativedev unusable on
# Ubuntu 26.04 sid behemoth).
set -uo pipefail

LOG=/tmp/behemoth-build.log
exec >>"$LOG" 2>&1
echo "=== START $(date) on $(hostname) ==="

# CMake 4.2 dropped support for cmake_minimum_required(VERSION < 3.5). Many
# vendored deps (GLEW, OpenVDB, etc.) declare ancient minimums. Set the env
# variable so it propagates to ExternalProject_Add sub-cmake invocations.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# Always write the final status so the watchdog can reliably distinguish
# success from failure (any non-zero exit code = FAIL).
rm -f /tmp/behemoth-build.status
trap '[ $? -eq 0 ] || echo "FAIL exit=$?" > /tmp/behemoth-build.status' EXIT

TG=~/projects/claude_telegram/bin/claude-tg
[ ! -x "$TG" ] && TG=true  # graceful no-op if telegram CLI missing on behemoth

REPO=$HOME/projects/ORCA_BELT_src
mkdir -p $HOME/projects

# 1. Fresh clone (the existing ~/projects/ORCA_BELT is a partial non-git layout)
if [ ! -d "$REPO/.git" ]; then
  echo "Cloning ShidaoSlicer to $REPO …"
  rm -rf "$REPO"
  git clone --depth=1 https://github.com/tommasobbianchi/ShidaoSlicer.git "$REPO" || {
    $TG notify "Behemoth build FAIL at git clone — check $LOG" -l error -t "Clone Fail"; exit 1; }
fi
cd "$REPO"
echo "HEAD: $(git rev-parse --short HEAD)"

# 2. Deps build
mkdir -p deps/build && cd deps/build
echo "deps cmake at $(date)"
cmake .. -G Ninja -DDEP_WX_GTK3=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 || { $TG notify "deps cmake FAIL — $LOG" -l error -t "Deps cmake"; exit 2; }
echo "deps ninja at $(date)"
ninja -j14 || { $TG notify "deps ninja FAIL — see $LOG (tail with: ssh behemoth tail -30 $LOG)" -l error -t "Deps build"; exit 3; }
echo "deps done at $(date)"

# 3. orca build (Release for size+speed)
cd "$REPO"
mkdir -p build && cd build
echo "orca cmake at $(date)"
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$REPO/deps/build/OrcaSlicer_dep/usr/local" \
  -DSLIC3R_GTK=3 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 || { $TG notify "orca cmake FAIL — $LOG" -l error -t "Orca cmake"; exit 4; }
echo "orca ninja at $(date)"
ninja -j14 OrcaSlicer || { $TG notify "orca ninja FAIL — $LOG" -l error -t "Orca build"; exit 5; }

BIN=$REPO/build/src/orca-slicer
[ ! -s "$BIN" ] && { $TG notify "orca binary missing post-build at $BIN" -l error -t "Missing"; exit 6; }
SIZE=$(du -sh "$BIN" | cut -f1)
echo "Built: $BIN ($SIZE) at $(date)"

# 4. Deploy to ~/orca-belt-local layout
mkdir -p $HOME/orca-belt-local/bin
cp -f "$BIN" $HOME/orca-belt-local/bin/orca-slicer
# Resources need to be available adjacent — symlink to repo
rm -f $HOME/orca-belt-local/resources
ln -sf $REPO/resources $HOME/orca-belt-local/resources
MD5=$(md5sum $HOME/orca-belt-local/bin/orca-slicer | cut -d' ' -f1)
echo "Installed md5=$MD5"

# 5. Smoke: --help (no GUI, no display needed)
HELP=$(timeout 10 $HOME/orca-belt-local/bin/orca-slicer --help 2>&1 | head -1)
echo "help: $HELP"

$TG notify "BEHEMOTH BUILD DONE: orca-slicer Release rebuilt natively on Ubuntu 26.04 / pango 1.57 ($SIZE, md5 $MD5). Help test: $HELP. Path: ~/orca-belt-local/bin/orca-slicer. Pronto al lancio GUI." -l done -t "OrcaBelt Ready"
echo "OK" > /tmp/behemoth-build.status
echo "=== END $(date) ==="
