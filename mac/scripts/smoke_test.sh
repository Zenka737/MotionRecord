#!/bin/zsh
# Smoke test: export a recording folder with its project.json through the real renderer, then print frame timing
# stats and extract PNG frames you can look at.
#   scripts/smoke_test.sh <recording-folder> [out-dir] [seconds...]
# Example: scripts/smoke_test.sh ~/Movies/MotionRecord/2026-10-13_20-26-34 /tmp/smoke 0.2 1 6
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REC="${1:?recording folder}"; OUT="${2:-${TMPDIR:-/tmp}/motionrecord-smoke}"; shift 2 2>/dev/null || true
TIMES=("$@"); [[ ${#TIMES[@]} -eq 0 ]] && TIMES=(0.5 2 5)
M="$ROOT/Sources/MotionRecord"
mkdir -p "$OUT"
echo "==> compiling export harness (real Render/ + Models sources)"
# top-level code is only allowed in a file named main.swift
for n in export frames pts; do mkdir -p "$OUT/src_$n"; cp "$ROOT/scripts/smoke/${n}_main.swift" "$OUT/src_$n/main.swift"; done
swiftc -O -swift-version 5 -o "$OUT/exp" "$OUT/src_export/main.swift" "$M/Models.swift" "$M/Models/EditProject.swift" "$M"/Render/*.swift "$M/App/ModelsCompat.swift" 2>&1 | grep -E "error:" || true
swiftc -O -swift-version 5 -o "$OUT/frames" "$OUT/src_frames/main.swift" 2>&1 | grep -E "error:" || true
swiftc -O -swift-version 5 -o "$OUT/pts" "$OUT/src_pts/main.swift" 2>&1 | grep -E "error:" || true
echo "==> exporting"
"$OUT/exp" "$REC" "$OUT/smoke.mp4" | tail -3
echo "==> timing / bitrate (expect ~60 fps, no gaps)"
"$OUT/pts" "$OUT/smoke.mp4" | head -4
echo "==> frames"
"$OUT/frames" "$OUT/smoke.mp4" "$OUT/f" "${TIMES[@]}"; ls "$OUT"/f_*.png
