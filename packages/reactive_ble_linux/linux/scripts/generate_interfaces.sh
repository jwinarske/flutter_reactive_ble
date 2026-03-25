#!/usr/bin/env bash
# scripts/generate_interfaces.sh
# Regenerate C++ proxy headers from the BlueZ XML interface files.
# Pattern from jwinarske/sdbus-cpp-examples/generate.sh.
#
# Prerequisites:
#   Build this project once first so sdbus-c++-xml2cpp is available:
#     cmake -B build && cmake --build build
#
# Usage:
#   ./scripts/generate_interfaces.sh [path-to-xml2cpp]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

XML2CPP="${1:-$(which sdbus-c++-xml2cpp 2>/dev/null || true)}"

if [ -z "$XML2CPP" ] || [ ! -x "$XML2CPP" ]; then
  # Try the build directory
  if [ -x "build/sdbus-c++-xml2cpp" ]; then
    XML2CPP="build/sdbus-c++-xml2cpp"
  else
    echo "ERROR: sdbus-c++-xml2cpp not found."
    echo "       Build sdbus-cpp first, or install libsdbus-c++-bin."
    exit 1
  fi
fi

echo "Using: $XML2CPP"
OUT="include/generated"
mkdir -p "$OUT"

generate() {
  local xml="$1"
  local base; base="$(basename "${xml%.xml}")"
  local proxy="$OUT/${base}-proxy.h"
  echo "  $xml → $proxy"
  "$XML2CPP" "$xml" --proxy="$proxy"
}

for xml in interfaces/bluez/*.xml; do
  generate "$xml"
done

echo ""
echo "Generated headers in $OUT/"
echo "Include them in bluez_ble.cpp if you switch to type-safe proxies:"
echo "  #include \"../include/generated/org.bluez.Adapter1-proxy.h\""
