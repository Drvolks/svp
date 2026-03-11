# SVP Implementation TODO (MPV Replacement)

Goal: make `SVP` production-ready enough to replace MPV in Tube fullscreen playback + PiP.

## 1) Demux Real Packets
- [x] Replace synthetic packet generation in `svp/Sources/Demux/DemuxEngine.swift` (`BasicDemuxEngine`) with real demux output.
- [x] Parse TS packet header + adaptation field (including PCR extraction).
- [x] Parse PAT sections and track active program -> PMT PID mapping.
- [x] Parse PMT sections and discover elementary stream PIDs + stream types.
- [x] Assemble PES payload across TS packets (payload_unit_start aware).
- [x] Emit correct `formatHint` values (`h264`, `hevc`, `aac`, `opus`, etc.).
- [x] Emit stable `pts/dts/duration` from source timestamps.
- [x] Handle discontinuities and invalid timestamps (normalize/reset strategy).
- [x] Validate continuity counters per PID and recover from gaps.
- [x] Handle 33-bit wraparound for PTS/DTS and 42-bit PCR clock rollover.
- [x] Keep TS parser house path for TS/live-TS robustness.

## 2) Real Video Decode -> CVPixelBuffer
- [x] Implement real decode path in `svp/Sources/Decode/VideoToolboxDecoder.swift`.
- [x] Implement software fallback in `svp/Sources/Decode/FFmpegVideoDecoder.swift`.
- [x] Ensure `DecodedVideoFrame.pixelBuffer` is non-nil for decodable frames.
- [x] Define codec fallback policy (HW fail -> SW decode).
- [x] Build VT format descriptions from codec extradata (H.264 SPS/PPS, HEVC VPS/SPS/PPS).
- [x] Handle Annex-B vs AVCC/HVCC conversion before decode.
- [x] Normalize frame PTS to `CMTime` in a single timescale policy.
- [x] Support dynamic format changes (resolution/profile) without session leaks.

## 3) Real Metal Rendering
- [x] Implement frame rendering in `svp/Sources/Render/MetalRenderer.swift`.
- [x] Implement display host in `svp/Sources/Render/MetalVideoView.swift`.
- [x] Present decoded `CVPixelBuffer` with proper colorspace conversion.
- [~] Support resize/orientation and frame pacing.

## 4) Real Audio Output
- [~] Implement audio playback in `svp/Sources/Audio` (renderer + synchronizer).
- [~] Decode packets to PCM and feed output path with low-latency buffering.
- [~] Define master clock policy (audio clock preferred for VOD/live).
- [~] Handle pause/resume/flush during seek.
- [~] Prepare multichannel codec plumbing (AC-3/E-AC-3 mapping and channel intent).

## 5) FFmpeg Bridge Completion
- [x] Implement concrete FFmpeg bridge in `FFmpegBridge` target.
- [x] Expose demux and decode primitives needed by `Demux` + `Decode` modules.
- [~] Map FFmpeg stream/codec metadata to `PlayerCore` models.
- [ ] Add robust error mapping for diagnostics.
- [x] Add vendor artifact slot + package auto-detection (`Vendor/FFmpeg/FFmpeg.xcframework`).
- [x] Real FFmpeg demux adapter (`avformat`) for file/network sources.

## 6) YouTube-Compatible Input Source
- [ ] Add a YouTube-oriented HTTP input strategy (range requests, reconnect, retry backoff).
- [ ] Handle signed URL expiration and graceful recover/fail behavior.
- [ ] Add cancellation-safe read loop for fast player teardown.

## 7) Quality / Stream Switching
- [ ] Add API for switching streams while preserving playback position.
- [ ] Define switch semantics: immediate switch vs buffered switch.
- [ ] Ensure no deadlocks during rapid repeated quality changes.

## 8) Subtitles + Chapters
- [ ] Add subtitle pipeline hooks (external + embedded where possible).
- [ ] Add chapter model integration so host app can render chapter UI.
- [ ] Expose events/state needed by Tube UI.

## 9) PiP (Production Path)
- [x] Stabilize `svp/Sources/PiP/PiPBridge.swift` sample timing.
- [x] Ensure consistent frame cadence through `AVSampleBufferDisplayLayer`.
- [x] Define lifecycle API for start/stop/restore of PiP from host app.
- [ ] Validate re-entry from PiP to fullscreen with shared session.
- [x] Mark discontinuities and flush display layer correctly on seek/rebuffer.
- [x] Ensure monotonic PTS for sample buffers (drop/retime invalid frames).
- [x] Share decoded frames from the same playback session (no duplicate decode path by default).

## 10) Playback Controls / App API Parity
- [~] Ensure reliable `play/pause/seek/load/stop` behavior under stress.
- [x] Expose buffer state / stall / recover callbacks.
- [x] Expose current position, duration, and playback state transitions.
- [x] Add explicit end-of-playback and error events.

## 11) Diagnostics & Telemetry
- [~] Add structured logs for source open, demux, decode, render, audio, PiP.
- [x] Add key metrics: startup time, rebuffer count, decode failures.
- [ ] Add error domains/codes to support host-level UI handling.

## 12) Tube Integration Strategy (Feature Flag)
- [~] Integrate SVP in Tube behind a runtime flag: `MPV` / `SVP (Experimental)`.
- [ ] Keep MPV default until SVP reaches parity.
- [~] Add fast rollback path to MPV for release safety.

## 13) Platform Coverage
- [x] Decide tvOS strategy:
  - [x] Add tvOS support to `SVP`, or
  - [ ] Keep MPV on tvOS while SVP ships on iOS/macOS.
- [x] Ensure package platform constraints match Tube deployment targets.

## 14) Test Matrix Before MPV Retirement
- [ ] VOD playback: AVC/HEVC/VP9/AV1 where available.
- [ ] Long playback stability test (>= 1h).
- [ ] Aggressive seek test (rapid seek + pause/resume).
- [ ] Quality switching test across multiple renditions.
- [ ] PiP start/stop/restore stress test.
- [ ] Network instability test (loss, latency, reconnect).

## 14) Documentation
- [x] Update README

## Suggested Milestones
- Milestone A: Local MP4 playback with video+audio stable, no PiP.
- Milestone B: YouTube HTTP playback stable with seek and quality switch.
- Milestone C: PiP parity with fullscreen continuity.
- Milestone D: Tube feature flag rollout + production validation.
