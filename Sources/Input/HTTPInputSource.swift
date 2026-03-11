import Foundation
import PlayerCore

public enum HTTPInputSourceError: Error, Sendable {
    case openFailed(statusCode: Int)
    case sourceNotOpen
    case readFailed(statusCode: Int)
}

extension HTTPInputSourceError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        .sourceOpen
    }
}

public actor HTTPInputSource: InputSource {
    public let descriptor: MediaSourceDescriptor
    private let url: URL
    private let session: URLSession
    private var opened = false
    private var bufferedData = Data()
    private var offset = 0

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
        self.descriptor = MediaSourceDescriptor(
            kind: .network(url),
            isLive: false,
            streams: [],
            preferredClock: .audio
        )
    }

    public func open() async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPInputSourceError.openFailed(statusCode: -1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPInputSourceError.openFailed(statusCode: http.statusCode)
        }
        bufferedData = data
        offset = 0
        opened = true
    }

    public func read(maxLength: Int) async throws -> Data? {
        guard opened else {
            throw HTTPInputSourceError.sourceNotOpen
        }
        guard maxLength > 0 else { return nil }
        guard offset < bufferedData.count else { return nil }

        let end = min(bufferedData.count, offset + maxLength)
        let chunk = bufferedData.subdata(in: offset..<end)
        offset = end
        return chunk.isEmpty ? nil : chunk
    }

    public func close() async {
        opened = false
        offset = 0
        bufferedData.removeAll(keepingCapacity: false)
    }
}
