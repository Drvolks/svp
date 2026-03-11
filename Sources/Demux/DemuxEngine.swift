import CoreMedia
import Foundation
import Input
import PlayerCore

public enum BasicDemuxError: Error, Sendable {
    case sourceOpenFailed(underlying: String)
    case sourceReadFailed(underlying: String)
    case sourceCloseFailed(underlying: String)
}

extension BasicDemuxError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        switch self {
        case .sourceOpenFailed:
            return .sourceOpen
        case .sourceReadFailed, .sourceCloseFailed:
            return .demux
        }
    }
}

public actor BasicDemuxEngine: PlayerCore.DemuxEngine {
    private let source: any InputSource
    private let delegatedDemux: FFmpegDemuxAdapter?

    public init(source: any InputSource) {
        self.source = source
        self.delegatedDemux = Self.makeDelegatedDemux(from: source.descriptor)
    }

    public func makePacketStream() -> AsyncThrowingStream<DemuxedPacket, Error> {
        if let delegatedDemux {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let stream = await delegatedDemux.makePacketStream()
                        for try await packet in stream {
                            continuation.yield(packet)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await source.open()
                    } catch {
                        throw BasicDemuxError.sourceOpenFailed(underlying: String(describing: error))
                    }
                    let tsParser = TSTransportParser()
                    var transportMode: Bool?
                    var pts: Int64 = 0
                    while !Task.isCancelled {
                        let chunk: Data?
                        do {
                            chunk = try await source.read(maxLength: 188 * 7)
                        } catch {
                            throw BasicDemuxError.sourceReadFailed(underlying: String(describing: error))
                        }
                        guard let chunk else { break }
                        if chunk.isEmpty { break }
                        if transportMode == nil {
                            transportMode = Self.looksLikeTransportStream(chunk)
                        }

                        if transportMode == true {
                            for packet in tsParser.consume(chunk) {
                                continuation.yield(packet)
                            }
                            continue
                        }

                        let packet = DemuxedPacket(
                            streamID: StreamID(0),
                            pts: pts,
                            dts: pts,
                            duration: 3000,
                            data: chunk,
                            isKeyframe: false,
                            formatHint: .unknown
                        )
                        continuation.yield(packet)
                        pts += 3000
                    }

                    if transportMode == true {
                        for packet in tsParser.finalize() {
                            continuation.yield(packet)
                        }
                    }

                    await source.close()
                    continuation.finish()
                } catch {
                    await source.close()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func seek(to: CMTime) async throws {
        if let delegatedDemux {
            try await delegatedDemux.seek(to: to)
            return
        }
        _ = to
        await source.close()
        do {
            try await source.open()
        } catch {
            throw BasicDemuxError.sourceOpenFailed(underlying: String(describing: error))
        }
    }

    public func duration() async -> CMTime? {
        if let delegatedDemux {
            return await delegatedDemux.duration()
        }
        return nil
    }

    private static func looksLikeTransportStream(_ data: Data) -> Bool {
        guard data.count >= 188 else { return false }
        if data[0] != 0x47 { return false }
        if data.count >= 376 {
            return data[188] == 0x47
        }
        return true
    }

    private static func makeDelegatedDemux(from descriptor: MediaSourceDescriptor) -> FFmpegDemuxAdapter? {
        switch descriptor.kind {
        case .file(let url):
            return isTransportStreamURL(url) ? nil : FFmpegDemuxAdapter(url: url)
        case .network(let url):
            return isTransportStreamURL(url) ? nil : FFmpegDemuxAdapter(url: url)
        case .liveTS, .segmented:
            return nil
        }
    }

    private static func isTransportStreamURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ts" || ext == "m2ts"
    }
}
