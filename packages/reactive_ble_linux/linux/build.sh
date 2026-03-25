#!/usr/bin/env bash
# build.sh — One-shot build script for dart_bluez_ble.
# Mirrors the pattern from jwinarske/native_comms/build.sh.
#
# Usage:
#   ./build.sh                    # CMake build (preferred)
#   ./build.sh --make             # Makefile fallback
#   ./build.sh --test             # build + run Dart tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

USE_MAKE=0
RUN_TESTS=0

for arg in "$@"; do
  case "$arg" in
    --make)  USE_MAKE=1 ;;
    --test)  RUN_TESTS=1 ;;
    *)       echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ── Dependency check ─────────────────────────────────────────────────────
echo "=== Checking dependencies ==="

if ! command -v pkg-config &>/dev/null; then
  echo "ERROR: pkg-config not found."
  echo "       Ubuntu/Debian: sudo apt install pkg-config"
  exit 1
fi

if ! pkg-config --exists sdbus-c++; then
  echo "ERROR: sdbus-c++ not found via pkg-config."
  echo "       Ubuntu/Debian: sudo apt install libsdbus-c++-dev"
  echo "       Or build from source: https://github.com/Kistler-Group/sdbus-cpp"
  exit 1
fi

SDBUS_VERSION="$(pkg-config --modversion sdbus-c++)"
echo "  sdbus-c++ $SDBUS_VERSION  ✓"

if ! command -v dart &>/dev/null; then
  echo "ERROR: dart SDK not found on PATH."
  echo "       Ubuntu/Debian: sudo apt install dart"
  echo "       Or: https://dart.dev/get-dart"
  exit 1
fi

DART_VERSION="$(dart --version 2>&1 | head -1)"
echo "  $DART_VERSION  ✓"

CXX_VERSION="$(g++ --version | head -1)"
echo "  $CXX_VERSION"

GCC_MAJOR="$(g++ -dumpversion | cut -d. -f1)"
if [ "$GCC_MAJOR" -lt 13 ]; then
  echo "WARNING: GCC 13+ recommended for full C++23 support (found GCC $GCC_MAJOR)."
  echo "         Ubuntu 24.04 ships GCC 13 by default."
fi

echo ""

# ── Build native .so ─────────────────────────────────────────────────────
if [ "$USE_MAKE" -eq 1 ]; then
  echo "=== Building with Makefile ==="
  make -j"$(nproc)" verify
else
  echo "=== Building with CMake ==="
  cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -G Ninja 2>/dev/null || cmake -B build -DCMAKE_BUILD_TYPE=Release
  cmake --build build --parallel "$(nproc)"
  echo ""
  echo "=== Exported symbols ==="
  nm -D --defined-only build/libdart_bluez_ble.so \
      | grep " T " | sort | awk '{print "  " $3}'
  echo ""
  echo "=== Section sizes ==="
  size build/libdart_bluez_ble.so
fi

echo ""

# ── Dart dependencies ─────────────────────────────────────────────────────
echo "=== dart pub get ==="
dart pub get

echo ""

# ── Run Dart decoder tests (no .so required) ──────────────────────────────
if [ "$RUN_TESTS" -eq 1 ]; then
  echo "=== Running Dart event-decoder tests ==="
  dart test test/ble_events_test.dart --reporter expanded
  echo ""
fi

echo "=== Build complete ==="
echo ""
echo "Run examples:"
echo "  dart run bin/ble_scan.dart 10"
echo "  dart run bin/ble_gatt.dart AA:BB:CC:DD:EE:FF"
echo ""
echo "Run tests:"
echo "  dart test test/ble_events_test.dart"
