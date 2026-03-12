import Foundation
import PlayerCore

public actor LiveTSInputSource: InputSource {
    public let descriptor: MediaSourceDescriptor
    private let streamURL: URL
    private let session: URLSession
    private var byteIterator: URLSession.AsyncBytes.Iterator?
    private var opened = false

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

    public func open() async throws {
        var request = URLRequest(url: streamURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        byteIterator = bytes.makeAsyncIterator()
        opened = true
    }

    public func read(maxLength: Int) async throws -> Data? {
        guard opened, var iterator = byteIterator else {
            return nil
        }
        guard maxLength > 0 else { return nil }

        var data = Data()
        data.reserveCapacity(maxLength)

        while data.count < maxLength {
            guard let byte = try await iterator.next() else {
                byteIterator = iterator
                return data.isEmpty ? nil : data
            }
            data.append(byte)

            if data.count >= 188, data.count % 188 == 0 {
                break
            }
        }

        byteIterator = iterator
        return data.isEmpty ? nil : data
    }

    public func close() async {
        opened = false
        byteIterator = nil
    }
}
