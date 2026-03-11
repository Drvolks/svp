#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCFRAMEWORK_PATH="${ROOT_DIR}/Vendor/FFmpeg/FFmpeg.xcframework"

if [[ ! -d "${XCFRAMEWORK_PATH}" ]]; then
  echo "Missing FFmpeg.xcframework at ${XCFRAMEWORK_PATH}"
  exit 1
fi

if [[ ! -f "${XCFRAMEWORK_PATH}/Info.plist" ]]; then
  echo "Invalid XCFramework: missing Info.plist"
  exit 1
fi

echo "FFmpeg vendor artifact found:"
echo "  ${XCFRAMEWORK_PATH}"
echo "Validation OK."
