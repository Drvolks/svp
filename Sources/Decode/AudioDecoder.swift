import CoreMedia
import Foundation
import PlayerCore

public protocol AudioDecoder: Sendable {
    func decode(_ packet: DemuxedPacket) async throws -> [DecodedAudioFrame]
    func flush() async
}

public enum AudioDecodeError: Error, Sendable {
    case unsupportedCodec(CodecID)
    case needMoreData
    case decodeFailed(OSStatus)
    case backendUnavailable
}

extension AudioDecodeError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        .audio
    }
}

public actor DefaultAudioPipeline: PlayerCore.AudioPipeline {
    private let decoder: any AudioDecoder

    public init(decoder: any AudioDecoder = FFmpegAudioDecoder()) {
        self.decoder = decoder
    }

    public func decode(packet: DemuxedPacket) async throws -> [DecodedAudioFrame] {
        try await decoder.decode(packet)
    }

    public func flush() async {
        await decoder.flush()
    }
}
