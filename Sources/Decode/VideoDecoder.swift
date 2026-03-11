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
    private var fallbackLocked = false

    public init(preferHardware: Bool = true) {
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
    }

    public func decode(packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        if fallbackLocked, let fallback {
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
            }
            guard let fallback else { throw error }
            fallbackLocked = true
            return try await fallback.decode(packet)
        }
    }

    public func flush() async {
        await primary.flush()
        await fallback?.flush()
    }
}
