import Foundation

public actor FrameQueue {
    private let capacity: Int
    private var queue: [DecodedVideoFrame] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { queue.count }

    public func clear() {
        queue.removeAll(keepingCapacity: true)
    }

    public func push(_ frame: DecodedVideoFrame) -> Bool {
        guard queue.count < capacity else { return false }
        queue.append(frame)
        return true
    }

    public func pop() -> DecodedVideoFrame? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}
