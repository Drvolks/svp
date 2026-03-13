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
}

extension VideoDecodeError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        .decode
    }
}

public actor DefaultVideoPipeline: PlayerCore.VideoPipeline {
    private let primary: any VideoDecoder
    private let fallback: (any VideoDecoder)?
    private let preferHardware: Bool
    private var softwareForcedCodecs: Set<CodecID> = []

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
            return try await fallback.decode(packet)
        }
        if shouldBypassPrimary(for: packet.formatHint), let fallback {
            softwareForcedCodecs.insert(packet.formatHint)
            return try await fallback.decode(packet)
        }
        do {
            if let frame = try await primary.decode(packet) {
                return frame
            }
            return nil
        } catch {
            if let decodeError = error as? VideoDecodeError {
                if case .needMoreData = decodeError {
                    // Primary decoder may need SPS/PPS/VPS before it can output frames.
                    // This is not a hard failure and should not force fallback.
                    return nil
                }
                if case .decodeFailed = decodeError {
                    // Transient decode failures (e.g. missing/invalid units) should be
                    // handled by packet/keyframe resync in the session, not by forcing
                    // a permanent software fallback for the rest of playback.
                    throw error
                }
                if case .outputUnavailable = decodeError {
                    throw error
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
        case .needMoreData, .sampleBufferCreationFailed, .decodeFailed, .outputUnavailable:
            return false
        }
    }
}
