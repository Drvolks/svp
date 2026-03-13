#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.vendor-build/ffmpeg-lgpl"
SRC_PARENT="${ROOT_DIR}/.vendor-src"
SRC_DIR="${SRC_PARENT}/ffmpeg"
DAV1D_SRC_DIR="${SRC_PARENT}/dav1d"
PREFIX_DIR="${WORK_DIR}/prefix"
DAV1D_PREFIX_DIR="${WORK_DIR}/dav1d-prefix"
ARTIFACT_DIR="${ROOT_DIR}/Vendor/FFmpeg"
XCFRAMEWORK_PATH="${ARTIFACT_DIR}/FFmpeg.xcframework"

FFMPEG_GIT_URL="${FFMPEG_GIT_URL:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_GIT_REF="${FFMPEG_GIT_REF:-n8.0.1}"
DAV1D_GIT_URL="${DAV1D_GIT_URL:-https://github.com/videolan/dav1d.git}"
DAV1D_GIT_REF="${DAV1D_GIT_REF:-1.1.0}"
IOS_MIN="${IOS_MIN:-15.0}"
TVOS_MIN="${TVOS_MIN:-15.0}"
MACOS_MIN="${MACOS_MIN:-13.0}"
SKIP_FETCH="${SKIP_FETCH:-0}"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

MESON_BIN="${MESON_BIN:-$(command -v meson || true)}"
PKG_CONFIG_BIN="${PKG_CONFIG_BIN:-$(command -v pkg-config || true)}"
NINJA_BIN="${NINJA_BIN:-$(command -v ninja || true)}"
DAV1D_ENABLE_ASM="${DAV1D_ENABLE_ASM:-1}"

if [[ -z "${MESON_BIN}" || -z "${PKG_CONFIG_BIN}" || -z "${NINJA_BIN}" ]]; then
  echo "Missing required build tools. Need meson, ninja and pkg-config in PATH." >&2
  exit 1
fi

if [[ "${DAV1D_ENABLE_ASM}" == "1" ]]; then
  DAV1D_ENABLE_ASM="true"
elif [[ "${DAV1D_ENABLE_ASM}" == "0" ]]; then
  DAV1D_ENABLE_ASM="false"
fi

echo "==> Preparing folders"
mkdir -p "${WORK_DIR}" "${SRC_PARENT}" "${ARTIFACT_DIR}"
rm -rf "${PREFIX_DIR}" "${DAV1D_PREFIX_DIR}" "${XCFRAMEWORK_PATH}"
mkdir -p "${PREFIX_DIR}" "${DAV1D_PREFIX_DIR}"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "==> Cloning FFmpeg (${FFMPEG_GIT_REF})"
  git clone --depth 1 --branch "${FFMPEG_GIT_REF}" "${FFMPEG_GIT_URL}" "${SRC_DIR}"
else
  echo "==> Reusing existing FFmpeg source at ${SRC_DIR}"
  pushd "${SRC_DIR}" >/dev/null
  if [[ "${SKIP_FETCH}" != "1" ]]; then
    git fetch --tags --force origin
  else
    echo "==> SKIP_FETCH=1, skipping git fetch"
  fi
  git checkout --force "${FFMPEG_GIT_REF}"
  popd >/dev/null
fi

if [[ ! -d "${DAV1D_SRC_DIR}/.git" ]]; then
  echo "==> Cloning dav1d (${DAV1D_GIT_REF})"
  git clone --depth 1 --branch "${DAV1D_GIT_REF}" "${DAV1D_GIT_URL}" "${DAV1D_SRC_DIR}"
else
  echo "==> Reusing existing dav1d source at ${DAV1D_SRC_DIR}"
  pushd "${DAV1D_SRC_DIR}" >/dev/null
  if [[ "${SKIP_FETCH}" != "1" ]]; then
    git fetch --tags --force origin
  else
    echo "==> SKIP_FETCH=1, skipping git fetch for dav1d"
  fi
  git checkout --force "${DAV1D_GIT_REF}"
  popd >/dev/null
fi

FF_CONFIG_COMMON=(
  --disable-programs
  --disable-doc
  --disable-debug
  --enable-pic
  --pkg-config="${PKG_CONFIG_BIN}"
  --pkg-config-flags=--static
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
  --enable-libdav1d
  # Keep AV1 path explicit/deterministic for SVP split A/V validation.
  --enable-bsf=av1_frame_merge
  --enable-bsf=av1_frame_split
  --enable-bsf=h264_mp4toannexb
  --enable-bsf=hevc_mp4toannexb
  --enable-parser=av1
  --enable-parser=h264
  --enable-parser=hevc
  --enable-parser=aac
  --enable-parser=opus
  --enable-demuxer=mov
  --enable-demuxer=matroska
  --enable-demuxer=mpegts
  --enable-protocol=file
  --enable-protocol=http
  --enable-protocol=https
  --enable-protocol=tcp
  --enable-protocol=tls
  --enable-decoder=av1
  --enable-decoder=libdav1d
  --enable-decoder=h264
  --enable-decoder=hevc
  --enable-decoder=vp9
  --enable-decoder=aac
  --enable-decoder=opus
  --enable-decoder=ac3
  --enable-decoder=eac3
)

meson_subsystem() {
  local sdk="$1"
  case "${sdk}" in
    iphoneos) echo "ios" ;;
    iphonesimulator) echo "ios-simulator" ;;
    appletvos) echo "tvos" ;;
    appletvsimulator) echo "tvos-simulator" ;;
    macosx) echo "macos" ;;
    *)
      echo "Unsupported SDK for meson subsystem: ${sdk}" >&2
      exit 1
      ;;
  esac
}

target_cpu() {
  local arch="$1"
  case "${arch}" in
    arm64) echo "aarch64" ;;
    x86_64) echo "x86_64" ;;
    *)
      echo "Unsupported arch: ${arch}" >&2
      exit 1
      ;;
  esac
}

create_dav1d_cross_file() {
  local sdk="$1"
  local arch="$2"
  local cflags="$3"
  local ldflags="$4"
  local install_dir="$5"
  local cross_file="$6"
  local subsystem
  local cpu
  local cflags_joined
  local ldflags_joined

  subsystem="$(meson_subsystem "${sdk}")"
  cpu="$(target_cpu "${arch}")"
  cflags_joined="$(printf "'%s', " ${cflags})"
  cflags_joined="${cflags_joined%, }"
  ldflags_joined="$(printf "'%s', " ${ldflags})"
  ldflags_joined="${ldflags_joined%, }"

  cat > "${cross_file}" <<EOF
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
objcpp = '/usr/bin/clang++'
ar = '$(xcrun --sdk "${sdk}" -f ar)'
strip = '$(xcrun --sdk "${sdk}" -f strip)'
pkgconfig = '${PKG_CONFIG_BIN}'

[host_machine]
system = 'darwin'
subsystem = '${subsystem}'
kernel = 'xnu'
cpu_family = '${cpu}'
cpu = '${cpu}'
endian = 'little'

[built-in options]
default_library = 'static'
buildtype = 'release'
prefix = '${install_dir}'
c_args = [${cflags_joined}]
cpp_args = [${cflags_joined}]
objc_args = [${cflags_joined}]
objcpp_args = [${cflags_joined}]
c_link_args = [${ldflags_joined}]
cpp_link_args = [${ldflags_joined}]
objc_link_args = [${ldflags_joined}]
objcpp_link_args = [${ldflags_joined}]
EOF
}

build_dav1d_one() {
  local sdk="$1"
  local arch="$2"
  local min_flag="$3"
  local min_version="$4"

  local build_dir="${WORK_DIR}/dav1d-build-${sdk}-${arch}"
  local install_dir="${DAV1D_PREFIX_DIR}/${sdk}-${arch}"
  local sdkroot
  local cflags=()
  local ldflags=()
  local cross_file
  local meson_args=()

  sdkroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cflags=(-arch "${arch}" -isysroot "${sdkroot}" "${min_flag}=${min_version}" -O2)
  ldflags=(-arch "${arch}" -isysroot "${sdkroot}" "${min_flag}=${min_version}")
  cross_file="${build_dir}/cross-file.meson"

  echo "==> Building dav1d for ${sdk} ${arch}"
  rm -rf "${build_dir}" "${install_dir}"
  mkdir -p "${build_dir}" "${install_dir}"
  create_dav1d_cross_file "${sdk}" "${arch}" "${cflags[*]}" "${ldflags[*]}" "${install_dir}" "${cross_file}"

  if [[ "${arch}" == "x86_64" && -z "$(command -v nasm || true)" ]]; then
    echo "==> nasm not found, install it with brew"
    exit 1
  else
    meson_args+=("-Denable_asm=${DAV1D_ENABLE_ASM}")
  fi

  meson_args+=(
    "-Denable_tools=false"
    "-Denable_tests=false"
    "-Denable_examples=false"
  )

  "${MESON_BIN}" setup "${build_dir}" --cross-file="${cross_file}" "${meson_args[@]}" "${DAV1D_SRC_DIR}"
  "${MESON_BIN}" compile -C "${build_dir}" --clean
  "${MESON_BIN}" compile -C "${build_dir}" --verbose
  "${MESON_BIN}" install -C "${build_dir}"
}

build_one() {
  local sdk="$1"
  local arch="$2"
  local min_flag="$3"
  local min_version="$4"

  local build_dir="${WORK_DIR}/build-${sdk}-${arch}"
  local install_dir="${PREFIX_DIR}/${sdk}-${arch}"
  local dav1d_install_dir="${DAV1D_PREFIX_DIR}/${sdk}-${arch}"
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
  PKG_CONFIG_PATH="${dav1d_install_dir}/lib/pkgconfig" \
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
build_dav1d_one "iphoneos" "arm64" "-miphoneos-version-min" "${IOS_MIN}"
build_dav1d_one "iphonesimulator" "arm64" "-mios-simulator-version-min" "${IOS_MIN}"
build_dav1d_one "iphonesimulator" "x86_64" "-mios-simulator-version-min" "${IOS_MIN}"
build_dav1d_one "appletvos" "arm64" "-mtvos-version-min" "${TVOS_MIN}"
build_dav1d_one "appletvsimulator" "arm64" "-mtvos-simulator-version-min" "${TVOS_MIN}"
build_dav1d_one "appletvsimulator" "x86_64" "-mtvos-simulator-version-min" "${TVOS_MIN}"
build_dav1d_one "macosx" "arm64" "-mmacosx-version-min" "${MACOS_MIN}"
build_dav1d_one "macosx" "x86_64" "-mmacosx-version-min" "${MACOS_MIN}"

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

lipo -create \
  "${DAV1D_PREFIX_DIR}/iphonesimulator-arm64/lib/libdav1d.a" \
  "${DAV1D_PREFIX_DIR}/iphonesimulator-x86_64/lib/libdav1d.a" \
  -output "${WORK_DIR}/universal/ios-sim/libdav1d.a"

lipo -create \
  "${DAV1D_PREFIX_DIR}/macosx-arm64/lib/libdav1d.a" \
  "${DAV1D_PREFIX_DIR}/macosx-x86_64/lib/libdav1d.a" \
  -output "${WORK_DIR}/universal/macos/libdav1d.a"

lipo -create \
  "${DAV1D_PREFIX_DIR}/appletvsimulator-arm64/lib/libdav1d.a" \
  "${DAV1D_PREFIX_DIR}/appletvsimulator-x86_64/lib/libdav1d.a" \
  -output "${WORK_DIR}/universal/tvos-sim/libdav1d.a"

echo "==> Creating merged FFmpeg static archives"
create_platform_archive "${WORK_DIR}/libs/libffmpeg-ios.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libavcodec.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libavformat.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libavutil.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libswresample.a" \
  "${PREFIX_DIR}/iphoneos-arm64/lib/libswscale.a" \
  "${DAV1D_PREFIX_DIR}/iphoneos-arm64/lib/libdav1d.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-ios-sim.a" \
  "${WORK_DIR}/universal/ios-sim/libavcodec.a" \
  "${WORK_DIR}/universal/ios-sim/libavformat.a" \
  "${WORK_DIR}/universal/ios-sim/libavutil.a" \
  "${WORK_DIR}/universal/ios-sim/libswresample.a" \
  "${WORK_DIR}/universal/ios-sim/libswscale.a" \
  "${WORK_DIR}/universal/ios-sim/libdav1d.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-tvos.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libavcodec.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libavformat.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libavutil.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libswresample.a" \
  "${PREFIX_DIR}/appletvos-arm64/lib/libswscale.a" \
  "${DAV1D_PREFIX_DIR}/appletvos-arm64/lib/libdav1d.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-tvos-sim.a" \
  "${WORK_DIR}/universal/tvos-sim/libavcodec.a" \
  "${WORK_DIR}/universal/tvos-sim/libavformat.a" \
  "${WORK_DIR}/universal/tvos-sim/libavutil.a" \
  "${WORK_DIR}/universal/tvos-sim/libswresample.a" \
  "${WORK_DIR}/universal/tvos-sim/libswscale.a" \
  "${WORK_DIR}/universal/tvos-sim/libdav1d.a"

create_platform_archive "${WORK_DIR}/libs/libffmpeg-macos.a" \
  "${WORK_DIR}/universal/macos/libavcodec.a" \
  "${WORK_DIR}/universal/macos/libavformat.a" \
  "${WORK_DIR}/universal/macos/libavutil.a" \
  "${WORK_DIR}/universal/macos/libswresample.a" \
  "${WORK_DIR}/universal/macos/libswscale.a" \
  "${WORK_DIR}/universal/macos/libdav1d.a"

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
profile_flags=av1-explicit
dav1d_ref=${DAV1D_GIT_REF}
ios_min=${IOS_MIN}
tvos_min=${TVOS_MIN}
macos_min=${MACOS_MIN}
EOF

echo "==> Done"
echo "Artifact: ${XCFRAMEWORK_PATH}"
echo "Metadata: ${ARTIFACT_DIR}/ffmpeg-version.txt"
