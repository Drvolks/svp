import CoreMedia
import Foundation
import OSLog
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

    private static let log = Logger(subsystem: "com.drvolks.svp", category: "Reorder")

    init(maxSize: Int = 8) {
        self.maxSize = maxSize
    }

    mutating func add(_ frame: DecodedVideoFrame) -> DecodedVideoFrame? {
        let beforeCount = frames.count
        frames.append(frame)
        frames.sort { $0.pts.seconds < $1.pts.seconds }

        var releasedFrame: DecodedVideoFrame? = nil

        // Release frames that are ready (not too far from the earliest pending)
        if frames.count >= maxSize || isNextFrameReady() {
            releasedFrame = frames.removeFirst()
        }

        let releasedPTS: String
        if let rf = releasedFrame {
            releasedPTS = String(format: "%.3f", rf.pts.seconds)
        } else {
            releasedPTS = "nil"
        }
        let afterCount = frames.count
        let msg = "[SVP][Reorder] add pts=\(String(format: "%.3f", frame.pts.seconds)) before=\(beforeCount) after=\(afterCount) released=\(releasedPTS)"
        Self.log.debug("\(msg)")

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

    private let log = Logger(subsystem: "com.drvolks.svp", category: "VideoPipeline")

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
        // Use only FFmpeg for all codecs to avoid VideoToolbox pixel format issues
        guard let fallback else {
            return try await primary.decode(packet)
        }
        if let decoded = try await fallback.decode(packet) {
            if reorderBuffer[packet.formatHint] == nil {
                reorderBuffer[packet.formatHint] = FrameReorderBuffer()
            }
            return reorderBuffer[packet.formatHint]!.add(decoded)
        }
        return nil
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

