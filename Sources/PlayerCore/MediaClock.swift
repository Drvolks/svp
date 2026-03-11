import CoreMedia
import Foundation

public final class MediaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAtUptime: TimeInterval?
    private var positionWhenStopped = CMTime.zero
    private var rate: Double = 1.0

    public init() {}

    public func setRate(_ newRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        rate = newRate
    }

    public func play() {
        lock.lock()
        defer { lock.unlock() }
        guard startedAtUptime == nil else { return }
        startedAtUptime = ProcessInfo.processInfo.systemUptime
    }

    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt = startedAtUptime else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        positionWhenStopped = positionWhenStopped + CMTime(seconds: elapsed * rate, preferredTimescale: 600)
        startedAtUptime = nil
    }

    public func seek(to time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        positionWhenStopped = time
        if startedAtUptime != nil {
            startedAtUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    public func currentTime() -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt = startedAtUptime else { return positionWhenStopped }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        return positionWhenStopped + CMTime(seconds: elapsed * rate, preferredTimescale: 600)
    }

    public func sync(to time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        positionWhenStopped = time
        if startedAtUptime != nil {
            startedAtUptime = ProcessInfo.processInfo.systemUptime
        }
    }
}
