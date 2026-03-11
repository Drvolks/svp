import Foundation

public actor PacketQueue {
    private let capacity: Int
    private var queue: [DemuxedPacket] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { queue.count }

    public func clear() {
        queue.removeAll(keepingCapacity: true)
    }

    public func push(_ packet: DemuxedPacket) -> Bool {
        guard queue.count < capacity else { return false }
        queue.append(packet)
        return true
    }

    public func pop() -> DemuxedPacket? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}
