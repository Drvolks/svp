import Foundation
import PlayerCore

public protocol SplitInputSource: InputSource {
    var videoSource: any InputSource { get }
    var audioSource: any InputSource { get }
}

public struct SplitAVInputSource: SplitInputSource {
    public let descriptor: MediaSourceDescriptor
    public let videoSource: any InputSource
    public let audioSource: any InputSource

    public init(videoSource: any InputSource, audioSource: any InputSource) {
        self.videoSource = videoSource
        self.audioSource = audioSource
        self.descriptor = MediaSourceDescriptor(
            kind: .split(video: videoSource.descriptor.kind, audio: audioSource.descriptor.kind),
            isLive: videoSource.descriptor.isLive || audioSource.descriptor.isLive,
            streams: Self.mergeStreams(video: videoSource.descriptor.streams, audio: audioSource.descriptor.streams),
            preferredClock: .audio
        )
    }

    public func open() async throws {
        try await videoSource.open()
        do {
            try await audioSource.open()
        } catch {
            await videoSource.close()
            throw error
        }
    }

    public func read(maxLength: Int) async throws -> Data? {
        _ = maxLength
        return nil
    }

    public func close() async {
        await videoSource.close()
        await audioSource.close()
    }

    private static func mergeStreams(video: [StreamDescriptor], audio: [StreamDescriptor]) -> [StreamDescriptor] {
        if !video.isEmpty || !audio.isEmpty {
            return video + audio
        }

        return [
            StreamDescriptor(id: StreamID(0), kind: .video, codec: .unknown),
            StreamDescriptor(id: StreamID(1), kind: .audio, codec: .unknown),
        ]
    }
}
