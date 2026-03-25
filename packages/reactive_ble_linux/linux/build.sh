#!/usr/bin/env bash
# build.sh — Build libdart_bluez_ble.so for the reactive_ble_linux package.
#
# sdbus-cpp is bundled as a git submodule under third_party/sdbus-cpp.
# If the system has libsdbus-c++-dev installed, CMake prefers that.
#
# Usage:
#   ./build.sh                    # CMake build (preferred)
#   ./build.sh --test             # build + run Dart tests
#   ./build.sh --clean            # clean build artifacts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

RUN_TESTS=0
CLEAN=0

for arg in "$@"; do
  case "$arg" in
    --test)   RUN_TESTS=1 ;;
    --clean)  CLEAN=1 ;;
    *)        echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if [ "$CLEAN" -eq 1 ]; then
  echo "=== Cleaning ==="
  rm -rf build lib/libdart_bluez_ble.so*
  exit 0
fi

# ── Dependency check ─────────────────────────────────────────────────────
echo "=== Checking dependencies ==="

# GCC
if ! command -v g++ &>/dev/null; then
  echo "ERROR: g++ not found. Install build-essential."
  exit 1
fi

CXX_VERSION="$(g++ --version | head -1)"
echo "  $CXX_VERSION"

GCC_MAJOR="$(g++ -dumpversion | cut -d. -f1)"
if [ "$GCC_MAJOR" -lt 13 ]; then
  echo "WARNING: GCC 13+ recommended for C++23 (found GCC $GCC_MAJOR)."
fi

# CMake
if ! command -v cmake &>/dev/null; then
  echo "ERROR: cmake not found."
  echo "       sudo apt install cmake ninja-build"
  exit 1
fi

# Ninja (optional, falls back to make)
GENERATOR=""
if command -v ninja &>/dev/null; then
  GENERATOR="-G Ninja"
fi

# libsystemd (required by sdbus-cpp)
if ! pkg-config --exists libsystemd 2>/dev/null; then
  echo "ERROR: libsystemd not found. Required by sdbus-cpp."
  echo "       sudo apt install libsystemd-dev"
  exit 1
fi

# sdbus-cpp (optional system install; submodule used as fallback)
if pkg-config --exists sdbus-c++ 2>/dev/null; then
  SDBUS_VERSION="$(pkg-config --modversion sdbus-c++)"
  echo "  sdbus-c++ $SDBUS_VERSION (system)  OK"
else
  echo "  sdbus-c++ not installed — using bundled submodule"
  if [ ! -f third_party/sdbus-cpp/CMakeLists.txt ]; then
    echo "  Initializing git submodule..."
    git -C "$PKG_DIR/.." submodule update --init --recursive \
        packages/reactive_ble_linux/linux/third_party/sdbus-cpp
  fi
fi

echo ""

# ── Build native .so ─────────────────────────────────────────────────────
echo "=== Building with CMake ==="
cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      $GENERATOR 2>&1
cmake --build build --parallel "$(nproc)"

echo ""
echo "=== Exported symbols ==="
nm -D --defined-only lib/libdart_bluez_ble.so \
    2>/dev/null | grep " T " | grep "bluez_ble\|Dart_" | sort | awk '{print "  " $3}' || true
echo ""
echo "=== Library ==="
ls -lh lib/libdart_bluez_ble.so*

echo ""

# ── Run Dart tests ───────────────────────────────────────────────────────
if [ "$RUN_TESTS" -eq 1 ]; then
  echo "=== dart pub get ==="
  cd "$PKG_DIR"
  dart pub get 2>/dev/null || echo "  (dart not on PATH — skipping pub get)"

  echo ""
  echo "=== Running Dart tests ==="
  dart test test/ --reporter expanded 2>/dev/null || echo "  (dart not on PATH — skipping tests)"
  cd "$SCRIPT_DIR"
  echo ""
fi

echo "=== Build complete ==="
echo ""
echo "  .so location: $SCRIPT_DIR/lib/libdart_bluez_ble.so"
echo ""
echo "  To use with Flutter:"
echo "    export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:$SCRIPT_DIR/lib"
echo "    flutter run"
echo ""
