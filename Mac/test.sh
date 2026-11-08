#!/bin/bash
# Runs packet regression checks without Bluetooth hardware or cursor events.
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -o "$TEST_DIR/input-tests" \
  Tests/main.swift Sources/InputEvent.swift Sources/PointerEngine.swift ../Shared/Protocol.swift \
  -framework AppKit -framework CoreBluetooth
"$TEST_DIR/input-tests"
