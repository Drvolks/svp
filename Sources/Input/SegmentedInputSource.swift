import Foundation
import PlayerCore

public actor SegmentedInputSource: InputSource {
    public let descriptor: MediaSourceDescriptor
    private let segmentURLs: [URL]
    private let session: URLSession
    private var index = 0

    public init(segmentURLs: [URL], session: URLSession = .shared) {
        self.segmentURLs = segmentURLs
        self.session = session
        self.descriptor = MediaSourceDescriptor(
            kind: .segmented(segmentURLs),
            isLive: false,
            streams: [],
            preferredClock: .audio
        )
    }

    public func open() async throws {
        index = 0
    }

    public func read(maxLength: Int) async throws -> Data? {
        _ = maxLength
        guard index < segmentURLs.count else { return nil }
        defer { index += 1 }
        let (data, response) = try await session.data(from: segmentURLs[index])
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func close() async {
        index = 0
    }
}
