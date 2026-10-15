#!/bin/bash
# Regenerates tests/MotionRecord.Core.Tests/golden.json from the ORIGINAL macOS Swift logic.
set -e
S="${MOTIONRECORD_MAC_SRC:-$HOME/Desktop/vse/MotionRecord/Sources/MotionRecord}"
D="$(cd "$(dirname "$0")/.." && pwd)"
swiftc -o /tmp/mr_golden "$D/tools/golden_gen/main.swift" "$S/Models.swift" "$S/Models/EditProject.swift" \
  "$S/Render/Easing.swift" "$S/Render/CursorSmoother.swift" "$S/Render/CameraPlanner.swift"
/tmp/mr_golden > "$D/tests/MotionRecord.Core.Tests/golden.json"
