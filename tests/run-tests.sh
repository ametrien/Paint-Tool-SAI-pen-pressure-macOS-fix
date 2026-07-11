#!/bin/bash
# Build + run all unit tests (native, no tablet/Wine/mingw needed).
# Usage: bash tests/run-tests.sh
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== C core (wintab_core.h) =="
cc -Wall -Wextra -Werror -o "$WORK/test_wintab_core" "$REPO/tests/test_wintab_core.c"
"$WORK/test_wintab_core"

echo ""
echo "== Swift core (PressureCore.swift) =="
swiftc -o "$WORK/core-tests" "$REPO/wacom-helper/PressureCore.swift" "$REPO/tests/CoreTests.swift"
"$WORK/core-tests"

echo ""
echo "All test suites passed."
