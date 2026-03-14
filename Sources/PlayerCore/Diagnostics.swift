import Foundation

#if canImport(OSLog)
import OSLog
#endif

public struct PlaybackMetrics: Sendable {
    public var startupTimeMs: Double?
    public var rebufferCount: Int
    public var decodeFailureCount: Int

    public init(startupTimeMs: Double? = nil, rebufferCount: Int = 0, decodeFailureCount: Int = 0) {
        self.startupTimeMs = startupTimeMs
        self.rebufferCount = rebufferCount
        self.decodeFailureCount = decodeFailureCount
    }
}

public final class PlaybackDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = PlaybackMetrics()
    private var startupStartUptime: TimeInterval?
    private var startupCaptured = false

    #if canImport(OSLog)
    private let logger = Logger(subsystem: "SVP", category: "Playback")
    #endif

    public init() {}

    public func markPlaybackStarted() {
        lock.lock()
        startupStartUptime = ProcessInfo.processInfo.systemUptime
        startupCaptured = false
        lock.unlock()
        log("playback_started")
    }

    public func markFirstFrameRendered() {
        lock.lock()
        defer { lock.unlock() }
        guard !startupCaptured, let start = startupStartUptime else { return }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metrics.startupTimeMs = elapsedMs
        startupCaptured = true
        log("startup_time_ms=\(elapsedMs)")
    }

    public func incrementRebuffer() {
        lock.lock()
        metrics.rebufferCount += 1
        let value = metrics.rebufferCount
        lock.unlock()
        log("rebuffer_count=\(value)")
    }

    public func incrementDecodeFailure() {
        lock.lock()
        metrics.decodeFailureCount += 1
        let value = metrics.decodeFailureCount
        lock.unlock()
        log("decode_failure_count=\(value)")
    }

    public func snapshot() -> PlaybackMetrics {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    public func log(_ message: String) {
        #if canImport(OSLog)
        logger.debug("\(message, privacy: .public)")
        #else
        print("[SVP] \(message)")
        #endif
    }
}
