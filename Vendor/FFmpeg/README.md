# FFmpeg Vendor Slot

This folder is the integration slot for the prebuilt FFmpeg binary used by SVP.

Expected artifact path:
- `Vendor/FFmpeg/FFmpeg.xcframework`

Behavior in `Package.swift`:
- If `FFmpeg.xcframework` exists, `FFmpegBinary` is added as a binary target.
- If it does not exist, SVP builds with the local bridge fallback.

## Expected XCFramework Packaging

`FFmpeg.xcframework` should expose one framework module that links FFmpeg static libs.

Recommended naming:
- Framework module name: `FFmpegBinary`
- Include headers for `libavcodec`, `libavformat`, `libavutil`, `libswscale`, `libswresample`

If the module name differs, update `Package.swift` and bridge integration accordingly.

## Suggested CI Output

Your vendor pipeline should publish:
- `FFmpeg.xcframework`
- build metadata (`ffmpeg-version.txt`, configure flags, git commit)
- license bundle (`COPYING.LGPLv2.1`, notices)

Keep this folder under source control only for small metadata files; large binary artifacts are usually distributed via release assets or internal artifact storage.
