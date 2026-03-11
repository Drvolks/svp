#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.vendor-build/ffmpeg-lgpl"
SRC_PARENT="${ROOT_DIR}/.vendor-src"
SRC_DIR="${SRC_PARENT}/ffmpeg"
PREFIX_DIR="${WORK_DIR}/prefix"
ARTIFACT_DIR="${ROOT_DIR}/Vendor/FFmpeg"
XCFRAMEWORK_PATH="${ARTIFACT_DIR}/FFmpeg.xcframework"

FFMPEG_GIT_URL="${FFMPEG_GIT_URL:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_GIT_REF="${FFMPEG_GIT_REF:-n8.0.1}"
IOS_MIN="${IOS_MIN:-15.0}"
TVOS_MIN="${TVOS_MIN:-15.0}"
MACOS_MIN="${MACOS_MIN:-13.0}"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

echo "==> Preparing folders"
mkdir -p "${WORK_DIR}" "${SRC_PARENT}" "${ARTIFACT_DIR}"
rm -rf "${PREFIX_DIR}" "${XCFRAMEWORK_PATH}"
mkdir -p "${PREFIX_DIR}"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "==> Cloning FFmpeg (${FFMPEG_GIT_REF})"
  git clone --depth 1 --branch "${FFMPEG_GIT_REF}" "${FFMPEG_GIT_URL}" "${SRC_DIR}"
else
  echo "==> Reusing existing FFmpeg source at ${SRC_DIR}"
  pushd "${SRC_DIR}" >/dev/null
  git fetch --tags --force origin
  git checkout --force "${FFMPEG_GIT_REF}"
  popd >/dev/null
fi

FF_CONFIG_COMMON=(
  --disable-programs
  --disable-doc
  --disable-debug
  --enable-pic
  --disable-gpl
  --disable-nonfree
  --disable-avdevice
  --disable-indevs
  --disable-outdevs
  --disable-avfilter
  --enable-avcodec
  --enable-avformat
  --enable-avutil
  --enable-swresample
  --enable-swscale
  --enable-network
)

build_one() {
  local sdk="$1"
  local arch="$2"
  local min_flag="$3"
  local min_version="$4"

  local build_dir="${WORK_DIR}/build-${sdk}-${arch}"
  local install_dir="${PREFIX_DIR}/${sdk}-${arch}"
  local cc
  local sdkroot
  local cflags
  local ldflags

  cc="$(xcrun --sdk "${sdk}" -f clang)"
  sdkroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cflags="-arch ${arch} -isysroot ${sdkroot} ${min_flag}=${min_version} -O2"
  ldflags="-arch ${arch} -isysroot ${sdkroot} ${min_flag}=${min_version}"

  echo "==> Building FFmpeg for ${sdk} ${arch}"
  rm -rf "${build_dir}" "${install_dir}"
  mkdir -p "${build_dir}" "${install_dir}"

  pushd "${build_dir}" >/dev/null
  "${SRC_DIR}/configure" \
    --prefix="${install_dir}" \
    --cc="${cc}" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="${arch}" \
    --host-cc=clang \
    --extra-cflags="${cflags}" \
    --extra-ldflags="${ldflags}" \
    "${FF_CONFIG_COMMON[@]}"

  make -j"${JOBS}"
  make install
  popd >/dev/null
}

create_platform_archive() {
  local output="$1"
  shift
  local libs=("$@")
  libtool -static -o "${output}" "${libs[@]}"
}

echo "==> Building Apple slices (LGPL-only)"
build_one "iphoneos" "arm64" "-miphoneos-version-min" "${IOS_MIN}"
build_one "iphonesimulator" "arm64" "-mios-simulator-version-min" "${IOS_MIN}"
build_one "iphonesimulator" "x86_64" "-mios-simulator-version-min" "${IOS_MIN}"
build_one "appletvos" "arm64" "-mtvos-version-min" "${TVOS_MIN}"
build_one "appletvsimulator" "arm64" "-mtvos-simulator-version-min" "${TVOS_MIN}"
build_one "appletvsimulator" "x86_64" "-mtvos-simulator-version-min" "${TVOS_MIN}"
build_one "macosx" "arm64" "-mmacosx-version-min" "${MACOS_MIN}"
build_one "macosx" "x86_64" "-mmacosx-version-min" "${MACOS_MIN}"

echo "==> Creating universal static libraries"
mkdir -p "${WORK_DIR}/universal/ios-sim" "${WORK_DIR}/universal/tvos-sim" "${WORK_DIR}/universal/macos" "${WORK_DIR}/libs"

for lib in avcodec avformat avutil swresample swscale; do
  lipo -create \
    "${PREFIX_DIR}/iphonesimulator-arm64/lib/lib${lib}.a" \
    "${PREFIX_DIR}/iphonesimulator-x86_64/lib/lib${lib}.a" \
    -output "${WORK_DIR}/universal/ios-sim/lib${lib}.a"

  lipo -create \
    "${PREFIX_DIR}/macosx-arm64/lib/lib${lib}.a" \
    "${PREFIX_DIR}/macosx-x86_64/lib/lib${lib}.a" \
    -output "${WORK_DIR}/universal/macos/lib${lib}.a"

  lipo -create \
    "${PREFIX_DIR}/appletvsimulator-arm64/lib/lib${lib}.a" \
    "${PREFIX_DIR}/appletvsimulator-x86_64/lib/lib${lib}.a" \
    -output "${WORK_DIR}/universal/tvos-sim/lib${lib}.a"
done

echo "==> Creating merged FFmpeg static archives"
create_platform_archive "${WORK_DIR}/libs/libffmpeg-ios.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libavcodec.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libavformat.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libavutil.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libswresample.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libswscale.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-ios-sim.a" \
  "${WORK_DIR}/universal/ios-sim/libavcodec.a" \
  "${WORK_DIR}/universal/ios-sim/libavformat.a" \
  "${WORK_DIR}/universal/ios-sim/libavutil.a" \
  "${WORK_DIR}/universal/ios-sim/libswresample.a" \
  "${WORK_DIR}/universal/ios-sim/libswscale.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-tvos.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libavcodec.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libavformat.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libavutil.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libswresample.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libswscale.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-tvos-sim.a" \
  "${WORK_DIR}/universal/tvos-sim/libavcodec.a" \
  "${WORK_DIR}/universal/tvos-sim/libavformat.a" \
  "${WORK_DIR}/universal/tvos-sim/libavutil.a" \
  "${WORK_DIR}/universal/tvos-sim/libswresample.a" \
  "${WORK_DIR}/universal/tvos-sim/libswscale.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-macos.a" \
  "${WORK_DIR}/universal/macos/libavcodec.a" \
  "${WORK_DIR}/universal/macos/libavformat.a" \
  "${WORK_DIR}/universal/macos/libavutil.a" \
  "${WORK_DIR}/universal/macos/libswresample.a" \
  "${WORK_DIR}/universal/macos/libswscale.a"

echo "==> Creating FFmpeg.xcframework"
xcodebuild -create-xcframework \
  -library "${WORK_DIR}/libs/libffmpeg-ios.a" -headers "${PREFIX_DIR}/iphoneos-arm64/include" \
  -library "${WORK_DIR}/libs/libffmpeg-ios-sim.a" -headers "${PREFIX_DIR}/iphonesimulator-arm64/include" \
  -library "${WORK_DIR}/libs/libffmpeg-tvos.a" -headers "${PREFIX_DIR}/appletvos-arm64/include" \
  -library "${WORK_DIR}/libs/libffmpeg-tvos-sim.a" -headers "${PREFIX_DIR}/appletvsimulator-arm64/include" \
  -library "${WORK_DIR}/libs/libffmpeg-macos.a" -headers "${PREFIX_DIR}/macosx-arm64/include" \
  -output "${XCFRAMEWORK_PATH}"

cat > "${ARTIFACT_DIR}/ffmpeg-version.txt" <<EOF
source=${FFMPEG_GIT_URL}
ref=${FFMPEG_GIT_REF}
profile=lgpl
ios_min=${IOS_MIN}
tvos_min=${TVOS_MIN}
macos_min=${MACOS_MIN}
EOF

echo "==> Done"
echo "Artifact: ${XCFRAMEWORK_PATH}"
echo "Metadata: ${ARTIFACT_DIR}/ffmpeg-version.txt"
