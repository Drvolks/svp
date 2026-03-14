import CoreMedia
import Foundation
import PlayerCore

public protocol VideoDecoder: Sendable {
    func decode(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame?
    func flush() async
}

public enum VideoDecodeError: Error, Sendable {
    case unsupportedCodec(CodecID)
    case needMoreData
    case sessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case backendUnavailable
    case outputUnavailable
    /// Signals that the decoder needs a keyframe to continue (used for software fallback resync)
    case needsKeyframe
}

extension VideoDecodeError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        .decode
    }
}

/// Reorder buffer to ensure frames are output in PTS order (needed for software decoders
/// like FFmpeg that may output frames out of presentation order due to B-frame decoding)
private struct FrameReorderBuffer {
    private var frames: [DecodedVideoFrame] = []
    private let maxSize: Int

    init(maxSize: Int = 8) {
        self.maxSize = maxSize
    }

    mutating func add(_ frame: DecodedVideoFrame) -> DecodedVideoFrame? {
        #if DEBUG
        let beforeCount = frames.count
        #endif
        frames.append(frame)
        frames.sort { $0.pts.seconds < $1.pts.seconds }

        var releasedFrame: DecodedVideoFrame? = nil

        // Release frames that are ready (not too far from the earliest pending)
        if frames.count >= maxSize || isNextFrameReady() {
            releasedFrame = frames.removeFirst()
        }

        #if DEBUG
        print("[SVP][Reorder] add pts=\(String(format: "%.3f", frame.pts.seconds)) before=\(beforeCount) after=\(frames.count) released=\(releasedFrame != nil ? String(format: "%.3f", releasedFrame!.pts.seconds) : "nil")")
        #endif

        return releasedFrame
    }

    private func isNextFrameReady() -> Bool {
        guard frames.count >= 2 else { return false }
        // If the next frame is close to the current frame, release it
        let gap = frames[1].pts.seconds - frames[0].pts.seconds
        return gap < 0.1 // Within 100ms
    }

    mutating func flush() -> DecodedVideoFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    mutating func drain() -> [DecodedVideoFrame] {
        let result = frames.sorted { $0.pts.seconds < $1.pts.seconds }
        frames.removeAll()
        return result
    }
}

public actor DefaultVideoPipeline: PlayerCore.VideoPipeline {
    private let primary: any VideoDecoder
    private let fallback: (any VideoDecoder)?
    private let preferHardware: Bool
    private var softwareForcedCodecs: Set<CodecID> = []
    private var consecutiveSkippedFrameCount: [CodecID: Int] = [:]
    private let maxConsecutiveSkippedFramesBeforeFallback = 5
    private var reorderBuffer: [CodecID: FrameReorderBuffer] = [:]

    public init(preferHardware: Bool = true) {
        self.preferHardware = preferHardware
        if preferHardware {
            self.primary = VideoToolboxDecoder()
            self.fallback = FFmpegVideoDecoder()
        } else {
            self.primary = FFmpegVideoDecoder()
            self.fallback = nil
        }
    }

    public init(decoder: any VideoDecoder) {
        self.primary = decoder
        self.fallback = nil
        self.preferHardware = false
    }

    public func decode(packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        if softwareForcedCodecs.contains(packet.formatHint), let fallback {
            // When using software fallback, route through reorder buffer to ensure
            // frames are output in PTS order (software decoders may output out of order)
            if let decoded = try await fallback.decode(packet) {
                // Add to reorder buffer - it will return frames in order
                if reorderBuffer[packet.formatHint] == nil {
                    reorderBuffer[packet.formatHint] = FrameReorderBuffer()
                }
                return reorderBuffer[packet.formatHint]!.add(decoded)
            }
            return nil
        }
        if shouldBypassPrimary(for: packet.formatHint), let fallback {
            softwareForcedCodecs.insert(packet.formatHint)
            // Force keyframe resync when initially falling back
            throw VideoDecodeError.needsKeyframe
        }
        do {
            if let frame = try await primary.decode(packet) {
                // Success - reset skipped frame count
                consecutiveSkippedFrameCount[packet.formatHint] = 0
                return frame
            }
            // Decoder returned nil (skipped frame) - track consecutive skips
            let skipCount = (consecutiveSkippedFrameCount[packet.formatHint] ?? 0) + 1
            consecutiveSkippedFrameCount[packet.formatHint] = skipCount

            if skipCount >= maxConsecutiveSkippedFramesBeforeFallback {
                #if DEBUG
                print("[SVP][VideoPipeline] forcing software fallback after \(skipCount) consecutive skipped frames")
                #endif
                softwareForcedCodecs.insert(packet.formatHint)
                // Force keyframe resync - can't decode from mid-GOP
                throw VideoDecodeError.needsKeyframe
            }
            return nil
        } catch {
            // Clear skip count on error
            consecutiveSkippedFrameCount[packet.formatHint] = 0

            if let decodeError = error as? VideoDecodeError {
                if case .needMoreData = decodeError {
                    // Primary decoder may need SPS/PPS/VPS before it can output frames.
                    // This is not a hard failure and should not force fallback.
                    return nil
                }
            }
            guard let fallback else { throw error }
            if shouldForceSoftwareFallback(for: error) {
                softwareForcedCodecs.insert(packet.formatHint)
            }
            return try await fallback.decode(packet)
        }
    }

    public func flush() async {
        // Reset skip counts on flush (e.g., after seek)
        consecutiveSkippedFrameCount.removeAll()
        // Clear reorder buffers
        reorderBuffer.removeAll()
        // NOTE: Do NOT clear softwareForcedCodecs here - we want to keep using
        // software decoder after keyframe resync. The session handles waiting
        // for keyframe separately.
        await primary.flush()
        await fallback?.flush()
    }

    private func shouldBypassPrimary(for codec: CodecID) -> Bool {
        guard preferHardware else { return false }
        switch codec {
        case .av1, .vp9:
            // Use software decode for these codecs (hardware may not support them on all devices)
            return true
        default:
            return false
        }
    }

    private func shouldForceSoftwareFallback(for error: Error) -> Bool {
        guard let decodeError = error as? VideoDecodeError else { return true }
        switch decodeError {
        case .unsupportedCodec, .backendUnavailable, .sessionCreationFailed:
            return true
        case .needMoreData, .sampleBufferCreationFailed, .decodeFailed, .outputUnavailable, .needsKeyframe:
            return false
        }
    }
}
