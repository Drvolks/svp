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
    private let discontinuityGapSeconds: Double
    private let discontinuityRecoveryHoldSeconds: Double
    private var recoveryAnchorPTS: Double?

    private static let log = Logger(subsystem: "com.drvolks.svp", category: "Reorder")

    init(
        maxSize: Int = 8,
        discontinuityGapSeconds: Double = 0.5,
        discontinuityRecoveryHoldSeconds: Double = 1.25
    ) {
        self.maxSize = maxSize
        self.discontinuityGapSeconds = discontinuityGapSeconds
        self.discontinuityRecoveryHoldSeconds = discontinuityRecoveryHoldSeconds
    }

    mutating func add(_ frame: DecodedVideoFrame) -> DecodedVideoFrame? {
        let beforeCount = frames.count
        frames.append(frame)
        frames.sort { $0.pts.seconds < $1.pts.seconds }
        trimDiscontinuityPrefixIfNeeded()

        var releasedFrame: DecodedVideoFrame? = nil

        // Release frames that are ready (not too far from the earliest pending)
        if shouldReleaseNextFrame() {
            releasedFrame = frames.removeFirst()
            if let recoveryAnchorPTS,
               releasedFrame?.pts.seconds ?? -.infinity >= recoveryAnchorPTS {
                self.recoveryAnchorPTS = nil
            }
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

    private mutating func trimDiscontinuityPrefixIfNeeded() {
        guard frames.count >= 2 else { return }

        for index in 1..<frames.count {
            let previousPTS = frames[index - 1].pts.seconds
            let currentPTS = frames[index].pts.seconds
            let gap = currentPTS - previousPTS
            if gap > discontinuityGapSeconds {
                let dropped = frames[..<index]
                let droppedCount = dropped.count
                let droppedUntilPTS = frames[index - 1].pts.seconds
                frames.removeFirst(droppedCount)
                recoveryAnchorPTS = currentPTS
                let msg =
                    "[SVP][Reorder] trim_discontinuity dropped=\(droppedCount) " +
                    "gap=\(String(format: "%.3f", gap)) " +
                    "keptFrom=\(String(format: "%.3f", currentPTS)) " +
                    "droppedUntil=\(String(format: "%.3f", droppedUntilPTS))"
                Self.log.debug("\(msg)")
                return
            }
        }
    }

    private func shouldReleaseNextFrame() -> Bool {
        guard !frames.isEmpty else { return false }

        if let recoveryAnchorPTS {
            let recoveredSpanSeconds = frames.last!.pts.seconds - recoveryAnchorPTS
            if recoveredSpanSeconds < discontinuityRecoveryHoldSeconds,
               frames.count < maxSize {
                return false
            }
        }

        return frames.count >= maxSize || isNextFrameReady()
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
        guard fallback != nil else {
            return try await primary.decode(packet)
        }

        let codec = packet.formatHint
        if shouldUseSoftwareDecoder(for: codec) {
            return try await decodeWithFallback(packet)
        }

        do {
            let decoded = try await primary.decode(packet)
            if decoded != nil {
                consecutiveSkippedFrameCount[codec] = 0
            }
            return decoded
        } catch {
            guard shouldForceSoftwareFallback(for: error) else {
                throw error
            }
            softwareForcedCodecs.insert(codec)
            consecutiveSkippedFrameCount[codec] = 0
            log.debug("[SVP][VideoPipeline] force_software codec=\(String(describing: codec)) reason=\(String(describing: error))")
            return try await decodeWithFallback(packet)
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

    private func shouldForceSoftwareFallback(for error: Error) -> Bool {
        guard let decodeError = error as? VideoDecodeError else { return true }
        switch decodeError {
        case .unsupportedCodec, .backendUnavailable, .sessionCreationFailed:
            return true
        case .needMoreData, .sampleBufferCreationFailed, .decodeFailed, .outputUnavailable, .needsKeyframe:
            return false
        }
    }

    private func shouldUseSoftwareDecoder(for codec: CodecID) -> Bool {
        softwareForcedCodecs.contains(codec)
    }

    private func decodeWithFallback(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        guard let fallback else { return nil }
        if let decoded = try await fallback.decode(packet) {
            if reorderBuffer[packet.formatHint] == nil {
                reorderBuffer[packet.formatHint] = FrameReorderBuffer()
            }
            return reorderBuffer[packet.formatHint]!.add(decoded)
        }
        return nil
    }
}
