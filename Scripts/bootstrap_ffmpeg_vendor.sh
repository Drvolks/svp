#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/FFmpeg"
XCFRAMEWORK_PATH="${VENDOR_DIR}/FFmpeg.xcframework"

mkdir -p "${VENDOR_DIR}"

if [[ -d "${XCFRAMEWORK_PATH}" ]]; then
  echo "FFmpeg vendor slot already populated at ${XCFRAMEWORK_PATH}"
  exit 0
fi

cat <<'EOF'
FFmpeg vendor slot created.

Next step:
1. Build or download FFmpeg.xcframework
2. Place it at Vendor/FFmpeg/FFmpeg.xcframework
3. Run: Scripts/validate_ffmpeg_vendor.sh

Package.swift auto-detects this artifact and enables the FFmpegBinary target.
EOF
