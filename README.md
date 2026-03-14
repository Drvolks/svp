# SVP (Swift Video Player)

SVP is a source-centric Swift player architecture designed to replace MPV-based playback stacks in Apple apps.

Current repository status:
- Swift Package with modular targets (`PlayerCore`, `Input`, `Demux`, `Decode`, `Render`, `Audio`, `PiP`)
- A working `PlaybackSession` core and `Player` facade
- Build passes with `swift build`
- Several components are scaffolds and must be completed for production use (real FFmpeg/TS decode paths)

## Requirements

- Xcode 16+ (Swift 6 toolchain)
- iOS 17+ / macOS 14+

## Add SVP to Your App

In Xcode:
1. Open your app project (`Tube`, `NexusPVR`, or another app).
2. Add a local Swift Package dependency pointing to this repository path.
3. Link the `SVP` product.

Or in `Package.swift`:

```swift
dependencies: [
    .package(path: "../svp")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SVP", package: "svp")
        ]
    )
]
```

## Minimal Integration

```swift
import SVP
import Input
import PlayerCore
import Render
import Foundation

let url = URL(fileURLWithPath: "/path/to/video.mp4")
let input = FileInputSource(url: url)
let player = Player(source: input, preferHardwareDecode: true)

let videoRenderer = MetalRenderer()
await player.attachVideoOutput(videoRenderer)

let source = PlayableSource(
    descriptor: MediaSourceDescriptor(
        kind: .file(url),
        isLive: false,
        streams: [],
        preferredClock: .audio
    )
)

try await player.load(source)
await player.play()
```

### YouTube-Style Dual Stream Integration

For YouTube or similar streams with separate video/audio URLs:

```swift
import SVP
import Input
import PlayerCore
import Render
import Demux
import Foundation

let videoURL = URL(string: "https://.../video.mp4")!
let audioURL = URL(string: "https://.../audio.m4a")!

let videoInput = HTTPInputSource(url: videoURL)
let audioInput = HTTPInputSource(url: audioURL)

let player = Player(
    videoSource: videoInput,
    audioSource: audioInput,
    preferHardwareDecode: true
)

let videoRenderer = MetalRenderer()
await player.attachVideoOutput(videoRenderer)

let source = PlayableSource(
    descriptor: MediaSourceDescriptor(
        kind: .split(video: .network(videoURL), audio: .network(audioURL)),
        isLive: false,
        streams: [],
        preferredClock: .audio
    )
)

try await player.load(source)
await player.play()
```

## PiP Integration (Sample Buffer Path)

`PiPBridge` is available as a `VideoOutput`:

```swift
import PiP

let pipBridge = PiPBridge()
await player.attachVideoOutput(pipBridge)
let layer = pipBridge.outputLayer() // AVSampleBufferDisplayLayer
```

Use `layer` with your `AVPictureInPictureController` setup in app code.

## Suggested App Wiring

For each app (`Tube` / `NexusPVR`):
1. Add an app-level `PlayerViewModel` that owns one `Player`.
2. Keep one `PlaybackSession` path for fullscreen and PiP outputs.
3. Attach/detach outputs (`MetalRenderer`, `PiPBridge`) instead of creating multiple players.
4. Keep extractor/manifest logic outside SVP and pass resolved media URLs into SVP inputs.

## Source Types Available

- `FileInputSource` - Local file playback
- `HTTPInputSource` - Network stream playback
- `LiveTSInputSource` - Live transport stream (single URL)
- `SegmentedInputSource` - HLS/DASH segmented streams
- `FFmpegDemuxAdapter` - FFmpeg-based demuxer with support for:
  - Single URL (local file, network stream, HLS)
  - **Dual URL** (YouTube-style separate video/audio streams)

## Unified FFmpeg Input Source

SVP includes a unified FFmpeg demuxer that handles both single and dual-input streams:

### Single URL Mode
For local files, network streams, or HLS:
```swift
let demux = FFmpegDemuxAdapter(url: videoURL)
```

### Dual URL Mode (YouTube)
For streams with separate video/audio URLs (like YouTube):
```swift
let demux = FFmpegDemuxAdapter(videoURL: videoURL, audioURL: audioURL)
```

### Architecture Benefits

1. **PTS/DTS Preservation**: Opens both video and audio URLs in a single FFmpeg context, preserving the timing relationships needed for proper video decode
2. **Hardware Decode Support**: With correct PTS/DTS, VideoToolbox hardware decoder works properly (no more -8969 reference frame errors)
3. **Automatic HLS Detection**: Automatically detects m3u8/HLS streams and uses the appropriate demuxer

### How It Works

```
YouTube URLs (separate video + audio)
           │
           ▼
┌──────────────────────────────┐
│ FFmpegDemuxAdapter           │
│ - Opens video URL            │
│ - Opens audio URL            │
│ - Creates unified TS context │
│ - Preserves PTS/DTS         │
└──────────────────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ Single packet stream         │
│ with correct timing         │
└──────────────────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ VideoToolbox (hardware)      │
│ - Reference frames intact   │
│ - Decode works!             │
└──────────────────────────────┘
```

## What Is Production-Ready vs Scaffold

Implemented:
- Modular architecture and public API shape
- Core playback orchestration (`PlaybackSession`)
- Async actor-safe boundaries (Swift 6)
- PiP output bridge primitives (`DecodedVideoFrame -> CMSampleBuffer`)

Scaffold / to complete:
- Full TS demux logic (PAT/PMT/PCR/PES/discontinuities)
- Hardware decode fallback strategy with real pixel buffers
- A/V sync tuning for unstable live streams
- Error recovery and telemetry

Note: The FFmpeg demux/decode integration is now implemented via the unified FFmpeg input source, supporting both single and dual URL modes for YouTube-style streams.

## Build

```bash
swift build
```

## FFmpeg Vendor Integration (Recommended)

SVP now auto-detects a prebuilt FFmpeg artifact at:
- `Vendor/FFmpeg/FFmpeg.xcframework`

When present, `Package.swift` enables a binary target named `FFmpegBinary`.

Bootstrap and validation:

```bash
Scripts/bootstrap_ffmpeg_vendor.sh
Scripts/build_ffmpeg_vendor_lgpl.sh
Scripts/validate_ffmpeg_vendor.sh
```

Recommended workflow:
1. Bootstrap vendor slot: `Scripts/bootstrap_ffmpeg_vendor.sh`
2. Build LGPL artifact: `Scripts/build_ffmpeg_vendor_lgpl.sh`
3. Validate artifact: `Scripts/validate_ffmpeg_vendor.sh`
4. Run `swift build` in SVP.

Useful env overrides:
- `FFMPEG_GIT_REF=n8.0.1`
- `IOS_MIN=15.0`
- `TVOS_MIN=15.0`
- `MACOS_MIN=13.0`
- `JOBS=8`

## Next Steps for MPV Replacement

If your goal is to retire MPV in `Tube` and `NexusPVR`, do this in order:
1. Integrate SVP for local MP4 playback first.
2. Replace one MPV playback entrypoint with SVP behind a feature flag.
3. Validate TS live behavior early (clock drift, rebuffer, discontinuities).
4. Roll out PiP on top of the same session (no second player instance).

Because yes, two independent players for fullscreen + PiP is how chaos enters production.
