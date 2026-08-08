#!/bin/bash
# Recompile streflop's libm/dbl-64 objects with homebrew gcc and swap them into
# the clang-built libstreflop.a.
#
# Why: Recoil's CMake passes -fsingle-precision-constant (gcc-only) on fleet
# builds, demoting every unsuffixed FP literal in dbl-64 (e.g. the correction
# gates `res == res + 1.025*cor` in e_asin) to float precision. Clang has no
# equivalent flag, so a pure-clang build diverges from the x86 fleet in
# double-precision libm results (observed: asin/acos, up to ~45 ulps).
# Compiling these objects with gcc reproduces the fleet's literal semantics
# bit-exactly; NEON vs SSE codegen parity is guaranteed by -ffp-contract=off
# (verified by scripts/double-fn probes).
#
# Usage: gcc-dbl64-swap.sh <build-dir> [gxx]
set -euo pipefail

BUILD=${1:?build dir}
GXX=${2:-/opt/homebrew/bin/g++-15}
# SOURCE TREE: derive from the BUILD DIR's own CMake cache, never from a fixed
# path. This used to be hardcoded to $BAR/engine, so whichever build dir was
# passed in, the objects swapped into it were compiled from THAT tree's streflop
# — silently mixing two different streflop versions once a second engine tree
# existed (caught 2026-08-07 on the 2026.07.04 lane: a patched submodule source
# had no effect because this script was reading the stale July worktree). Same
# class as build-engine.sh's source-tree guard; a build artifact must be
# traceable to the source it was actually built from.
SRC_ROOT=$(awk -F= '/^CMAKE_HOME_DIRECTORY:INTERNAL=/{print $2}' "$BUILD/CMakeCache.txt" 2>/dev/null)
if [ -z "$SRC_ROOT" ]; then
  echo "FATAL: cannot read CMAKE_HOME_DIRECTORY from $BUILD/CMakeCache.txt —"
  echo "  refusing to guess the streflop source tree (would risk swapping objects"
  echo "  compiled from a different engine version into this build)."
  exit 1
fi
STREF=$SRC_ROOT/rts/lib/streflop
echo "[gcc-dbl64-swap] source tree: $SRC_ROOT"
OBJDIR=$BUILD/rts/lib/streflop/CMakeFiles/streflop.dir/libm/dbl-64
ARCHIVE=$BUILD/rts/lib/streflop/libstreflop.a

[ -x "$GXX" ] || { echo "gcc not found: $GXX"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "archive missing (build streflop first): $ARCHIVE"; exit 1; }

FLAGS=(
  -DASIO_STANDALONE -DMACOSX_BUNDLE -DREPORT_LUANAN -DSPRING_DATADIR='""'
  -DSSE2NEON -DSSE2NEON_SUPPRESS_WARNINGS -DSTREFLOP_NEON -DSYNCCHECK
  -DSYNC_HISTORY -DTHREADPOOL -D_GLIBCXX_USE_NANOSLEEP -DNDEBUG
  -DLIBM_COMPILING_DBL64
  -I"$SRC_ROOT/rts" -I"$SRC_ROOT/rts/lib" -I"$STREF" -I"$STREF/libm/headers"
  -std=c++17 -O2 -fPIC -march=armv8-a
  -fsingle-precision-constant -frounding-math -ffp-contract=off
  -fno-strict-aliasing -fvisibility-inlines-hidden -pthread
  -fno-exceptions -fno-rtti
  -w -Wno-narrowing
)

n=0
for src in "$STREF"/libm/dbl-64/*.cpp; do
  obj=$OBJDIR/$(basename "$src").o
  [ -f "$obj" ] || continue  # only swap objects that are part of the build
  "$GXX" "${FLAGS[@]}" -c "$src" -o "$obj"
  n=$((n+1))
done
# Assert the swap actually DID something. If $STREF/libm/dbl-64 is wrong or
# empty the glob stays literal, every [ -f "$obj" ] fails, n stays 0, and `ar r`
# happily succeeds on the pre-existing CLANG objects — leaving a library with no
# fleet-parity content while this script prints "swapped 0 dbl-64 objects" and
# exits 0. That is precisely the failure the source-tree fix above was written to
# prevent, guarded at the derivation but not at the outcome. The two trees really
# do differ here (29 vs 80 dbl-64 sources), so a wrong tree is not hypothetical.
if [ "$n" -eq 0 ]; then
  echo "FATAL: swapped 0 dbl-64 objects from $STREF/libm/dbl-64"
  echo "  The archive still holds clang-built objects, so fleet parity is NOT"
  echo "  established. Check that the source tree above is the one that was built."
  exit 1
fi

ar r "$ARCHIVE" "$OBJDIR"/*.cpp.o 2>/dev/null

# fastiroot shim (2026 submodule lane only). streflop's mpsqrt.cpp declares
# `Double fastiroot(Double)` at GLOBAL scope but defines it INSIDE
# namespace streflop_libm. Clang binds the call to the namespace member; GCC
# binds it to the global (which is standard-correct) and the global is never
# defined -> undefined symbol at link, but ONLY once these objects are built
# with GCC, i.e. exactly what this script does. Add a forwarding definition to
# the archive so every consumer links.
#
# Deliberately NOT fixed by patching the submodule: that edit would live in an
# untracked submodule working tree and vanish on a fresh clone. Keeping it here
# means the lane reproduces from a clean checkout with an untouched upstream
# streflop. (The proper home is a PR to RecoilEngine/streflop.)
# NB probe the OBJECT, not the archive: at this point `ar r` has run but
# `ranlib` has not, so the archive's symbol index is stale and nm can come back
# empty — which silently skipped this whole block on the first attempt.
if nm "$OBJDIR/mpsqrt.cpp.o" 2>/dev/null | grep -q "streflop_libm.*fastiroot"; then
  SHIM_SRC=$(cd "$(dirname "$0")" && pwd)/fastiroot_shim.cpp
  if [ -f "$SHIM_SRC" ]; then
    "$GXX" "${FLAGS[@]}" -c "$SHIM_SRC" -o "$OBJDIR/fastiroot_shim.cpp.o"
    ar r "$ARCHIVE" "$OBJDIR/fastiroot_shim.cpp.o"
    echo "added fastiroot shim (global -> streflop_libm::fastiroot)"
  else
    echo "WARNING: streflop exports streflop_libm::fastiroot but $SHIM_SRC is missing;"
    echo "  the link will fail with an undefined ::fastiroot(double)."
  fi
fi

ranlib "$ARCHIVE"
echo "swapped $n dbl-64 objects into $ARCHIVE with $GXX"
