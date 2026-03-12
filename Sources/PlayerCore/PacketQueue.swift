import Foundation

public enum PacketQueueOverflowPolicy: Sendable {
    case blockProducer
    case dropNewest
    case preferKeyframes
}

public struct PacketQueueSnapshot: Sendable {
    public let count: Int
    public let capacity: Int
    public let firstPTS: Int64?
    public let lastPTS: Int64?
    public let mediaSpanSeconds: Double?

    public init(count: Int, capacity: Int, firstPTS: Int64?, lastPTS: Int64?, mediaSpanSeconds: Double?) {
        self.count = count
        self.capacity = capacity
        self.firstPTS = firstPTS
        self.lastPTS = lastPTS
        self.mediaSpanSeconds = mediaSpanSeconds
    }
}

public actor PacketQueue {
    private var capacity: Int
    private var overflowPolicy: PacketQueueOverflowPolicy
    private var queue: [DemuxedPacket] = []
    private var closed = false
    private var dequeueWaiters: [CheckedContinuation<DemuxedPacket?, Never>] = []
    private var enqueueWaiters: [CheckedContinuation<Bool, Never>] = []

    public init(capacity: Int, overflowPolicy: PacketQueueOverflowPolicy) {
        self.capacity = max(1, capacity)
        self.overflowPolicy = overflowPolicy
    }

    public var count: Int { queue.count }

    public func snapshot() -> PacketQueueSnapshot {
        let firstPTS = queue.first?.pts
        let lastPTS = queue.last?.pts
        let mediaSpanSeconds: Double?
        if let firstPTS, let lastPTS, lastPTS >= firstPTS {
            mediaSpanSeconds = Double(lastPTS - firstPTS) / 90_000.0
        } else {
            mediaSpanSeconds = nil
        }
        return PacketQueueSnapshot(
            count: queue.count,
            capacity: capacity,
            firstPTS: firstPTS,
            lastPTS: lastPTS,
            mediaSpanSeconds: mediaSpanSeconds
        )
    }

    public func reset() {
        queue.removeAll(keepingCapacity: true)
        closed = false
        resumeEnqueueWaiters()
    }

    public func configure(capacity: Int, overflowPolicy: PacketQueueOverflowPolicy) {
        self.capacity = max(1, capacity)
        self.overflowPolicy = overflowPolicy
        queue.removeAll(keepingCapacity: true)
        closed = false
        while !dequeueWaiters.isEmpty {
            dequeueWaiters.removeFirst().resume(returning: nil)
        }
        while !enqueueWaiters.isEmpty {
            enqueueWaiters.removeFirst().resume(returning: false)
        }
    }

    public func close() {
        closed = true
        while !dequeueWaiters.isEmpty {
            dequeueWaiters.removeFirst().resume(returning: nil)
        }
        while !enqueueWaiters.isEmpty {
            enqueueWaiters.removeFirst().resume(returning: false)
        }
    }

    public func enqueue(_ packet: DemuxedPacket) async -> Bool {
        if closed {
            return false
        }

        if let waiter = dequeueWaiters.first {
            dequeueWaiters.removeFirst()
            waiter.resume(returning: packet)
            return true
        }

        if queue.count < capacity {
            queue.append(packet)
            return true
        }

        switch overflowPolicy {
        case .dropNewest:
            return false
        case .preferKeyframes:
            guard packet.isKeyframe else { return false }
            queue.removeAll(keepingCapacity: true)
            queue.append(packet)
            resumeEnqueueWaiters()
            return true
        case .blockProducer:
            let shouldRetry = await withCheckedContinuation { continuation in
                enqueueWaiters.append(continuation)
            }
            guard shouldRetry else { return false }
            return await enqueue(packet)
        }
    }

    public func dequeue() async -> DemuxedPacket? {
        if !queue.isEmpty {
            let packet = queue.removeFirst()
            resumeSingleEnqueueWaiter()
            return packet
        }
        if closed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            dequeueWaiters.append(continuation)
        }
    }

    private func resumeSingleEnqueueWaiter() {
        guard queue.count < capacity, !enqueueWaiters.isEmpty else { return }
        enqueueWaiters.removeFirst().resume(returning: true)
    }

    private func resumeEnqueueWaiters() {
        while queue.count < capacity, !enqueueWaiters.isEmpty {
            enqueueWaiters.removeFirst().resume(returning: true)
        }
    }
}
