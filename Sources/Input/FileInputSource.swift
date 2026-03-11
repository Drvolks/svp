import Foundation
import PlayerCore

public actor FileInputSource: InputSource {
    public let descriptor: MediaSourceDescriptor
    private let url: URL
    private var handle: FileHandle?

    public init(url: URL) {
        self.url = url
        self.descriptor = MediaSourceDescriptor(
            kind: .file(url),
            isLive: false,
            streams: [],
            preferredClock: .audio
        )
    }

    public func open() async throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    public func read(maxLength: Int) async throws -> Data? {
        try handle?.read(upToCount: maxLength)
    }

    public func close() async {
        try? handle?.close()
        handle = nil
    }
}
