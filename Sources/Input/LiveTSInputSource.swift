import Foundation
import PlayerCore

public actor LiveTSInputSource: InputSource {
    public let descriptor: MediaSourceDescriptor
    private let streamURL: URL
    private let session: URLSession

    public init(streamURL: URL, session: URLSession = .shared) {
        self.streamURL = streamURL
        self.session = session
        self.descriptor = MediaSourceDescriptor(
            kind: .liveTS(streamURL),
            isLive: true,
            streams: [],
            preferredClock: .external
        )
    }

    public func open() async throws {}

    public func read(maxLength: Int) async throws -> Data? {
        _ = maxLength
        let (data, response) = try await session.data(from: streamURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data.isEmpty ? nil : data
    }

    public func close() async {}
}
