import CoreMedia
import Foundation

public enum FrameQueueOverflowPolicy: Sendable {
    case blockProducer
    case dropOldest
}

public struct FrameQueueSnapshot: Sendable {
    public let count: Int
    public let capacity: Int
    public let firstPTSSeconds: Double?
    public let lastPTSSeconds: Double?
    public let mediaSpanSeconds: Double?

    public init(count: Int, capacity: Int, firstPTSSeconds: Double?, lastPTSSeconds: Double?, mediaSpanSeconds: Double?) {
        self.count = count
        self.capacity = capacity
        self.firstPTSSeconds = firstPTSSeconds
        self.lastPTSSeconds = lastPTSSeconds
        self.mediaSpanSeconds = mediaSpanSeconds
    }
}

public struct FrameQueuePopResult: Sendable {
    public let frame: DecodedVideoFrame?
    public let droppedCount: Int

    public init(frame: DecodedVideoFrame?, droppedCount: Int) {
        self.frame = frame
        self.droppedCount = droppedCount
    }
}

public actor FrameQueue {
    private var capacity: Int
    private var overflowPolicy: FrameQueueOverflowPolicy
    private var queue: [DecodedVideoFrame] = []
    private var closed = false
    private var dequeueWaiters: [CheckedContinuation<DecodedVideoFrame?, Never>] = []
    private var enqueueWaiters: [CheckedContinuation<Bool, Never>] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.overflowPolicy = .blockProducer
    }

    public var count: Int { queue.count }

    public func snapshot() -> FrameQueueSnapshot {
        let firstPTS = queue.first?.pts.seconds
        let lastPTS = queue.last?.pts.seconds
        let mediaSpanSeconds: Double?
        if let firstPTS, let lastPTS, lastPTS >= firstPTS {
            mediaSpanSeconds = lastPTS - firstPTS
        } else {
            mediaSpanSeconds = nil
        }
        return FrameQueueSnapshot(
            count: queue.count,
            capacity: capacity,
            firstPTSSeconds: firstPTS,
            lastPTSSeconds: lastPTS,
            mediaSpanSeconds: mediaSpanSeconds
        )
    }

    public func reset() {
        queue.removeAll(keepingCapacity: true)
        closed = false
        resumeEnqueueWaiters()
    }

    public func configure(capacity: Int, overflowPolicy: FrameQueueOverflowPolicy = .blockProducer) {
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

    public func enqueue(_ frame: DecodedVideoFrame) async -> Bool {
        if closed {
            return false
        }

        if let waiter = dequeueWaiters.first {
            dequeueWaiters.removeFirst()
            waiter.resume(returning: frame)
            return true
        }

        if queue.count < capacity {
            insertSorted(frame)
            return true
        }

        switch overflowPolicy {
        case .dropOldest:
            if !queue.isEmpty {
                queue.removeFirst()
            }
            insertSorted(frame)
            resumeEnqueueWaiters()
            return true
        case .blockProducer:
            let shouldRetry = await withCheckedContinuation { continuation in
                enqueueWaiters.append(continuation)
            }
            guard shouldRetry else { return false }
            return await enqueue(frame)
        }
    }

    public func dequeue() async -> DecodedVideoFrame? {
        if !queue.isEmpty {
            let frame = queue.removeFirst()
            resumeSingleEnqueueWaiter()
            return frame
        }
        if closed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            dequeueWaiters.append(continuation)
        }
    }

    public func popLatestEligible(upTo maxPTS: CMTime) -> FrameQueuePopResult {
        guard !queue.isEmpty else {
            return FrameQueuePopResult(frame: nil, droppedCount: 0)
        }

        var latestEligibleIndex: Int?
        for (index, frame) in queue.enumerated() {
            guard frame.pts.isValid else {
                latestEligibleIndex = index
                continue
            }
            if CMTimeCompare(frame.pts, maxPTS) <= 0 {
                latestEligibleIndex = index
            } else {
                break
            }
        }

        guard let latestEligibleIndex else {
            return FrameQueuePopResult(frame: nil, droppedCount: 0)
        }

        let removed = Array(queue[0...latestEligibleIndex])
        queue.removeFirst(latestEligibleIndex + 1)
        resumeEnqueueWaiters()
        return FrameQueuePopResult(
            frame: removed.last,
            droppedCount: max(0, removed.count - 1)
        )
    }

    private func resumeSingleEnqueueWaiter() {
        guard queue.count < capacity, !enqueueWaiters.isEmpty else { return }
        enqueueWaiters.removeFirst().resume(returning: true)
    }

    private func insertSorted(_ frame: DecodedVideoFrame) {
        guard frame.pts.isValid else {
            queue.append(frame)
            return
        }
        guard !queue.isEmpty else {
            queue.append(frame)
            return
        }
        let index = queue.firstIndex(where: { existing in
            existing.pts.isValid && CMTimeCompare(frame.pts, existing.pts) < 0
        }) ?? queue.endIndex
        queue.insert(frame, at: index)
    }

    private func resumeEnqueueWaiters() {
        while queue.count < capacity, !enqueueWaiters.isEmpty {
            enqueueWaiters.removeFirst().resume(returning: true)
        }
    }
}
