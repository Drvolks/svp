#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

echo "==> Validating FFmpeg vendor artifact"
Scripts/validate_ffmpeg_vendor.sh

echo "==> Building SVP package"
swift build

echo "==> Smoke checks complete"
echo "Recommended next manual checks:"
echo "  1) 1h playback stability (MP4 + TS live)"
echo "  2) Aggressive seek loop (100 seeks)"
echo "  3) PiP start/stop/re-entry stress"
echo "  4) Network drop/recovery scenarios"
