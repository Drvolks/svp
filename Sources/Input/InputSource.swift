import Foundation
import PlayerCore

public protocol InputSource: Sendable {
    var descriptor: MediaSourceDescriptor { get }
    func open() async throws
    func read(maxLength: Int) async throws -> Data?
    func close() async
}
