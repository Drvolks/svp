import Foundation

public final class TimestampNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var firstPTS: Int64?
    private let wrap = Int64(1 << 33)

    public init() {}

    public func normalize(_ pts: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if firstPTS == nil {
            firstPTS = pts
        }
        guard let firstPTS else { return pts }
        var adjusted = pts
        if adjusted < firstPTS && (firstPTS - adjusted) > wrap / 2 {
            adjusted += wrap
        }
        return adjusted - firstPTS
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        firstPTS = nil
    }
}
