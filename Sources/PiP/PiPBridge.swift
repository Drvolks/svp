import AVFoundation
import CoreMedia
import Foundation
import PlayerCore

public final class PiPBridge: NSObject, @unchecked Sendable, VideoOutput, VideoOutputLifecycle {
    private let sampleBufferFactory = SampleBufferFactory()
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()
    private var lastPTS: CMTime?
    private var lastFrame: DecodedVideoFrame?
    private var enqueuedFrameCount = 0
    private let minimumStep = CMTime(value: 1_500, timescale: 90_000) // ~16.6ms

    public override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    public func render(frame: DecodedVideoFrame) {
        lock.withLock {
            lastFrame = frame
        }
        let pts = makeMonotonicRealtimePTS()
        guard let sampleBuffer = sampleBufferFactory.makeSampleBuffer(
            from: frame,
            presentationTimeStamp: pts,
            displayImmediately: true
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.displayLayer.status == .failed {
                self.displayLayer.flushAndRemoveImage()
            }
            self.displayLayer.enqueue(sampleBuffer)
            self.lock.withLock {
                self.enqueuedFrameCount += 1
            }
        }
    }

    public func outputLayer() -> AVSampleBufferDisplayLayer {
        displayLayer
    }

    public func hasEnqueuedFrames() -> Bool {
        lock.withLock { enqueuedFrameCount > 0 }
    }

    public func enqueuedFramesCount() -> Int {
        lock.withLock { enqueuedFrameCount }
    }

    @MainActor
    public func primeFromLatestFrame() {
        let frame = lock.withLock { lastFrame }
        guard let frame else { return }
        let pts = makeMonotonicRealtimePTS()
        guard let sampleBuffer = sampleBufferFactory.makeSampleBuffer(
            from: frame,
            presentationTimeStamp: pts,
            displayImmediately: true
        ) else { return }
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }
        displayLayer.enqueue(sampleBuffer)
        lock.withLock {
            enqueuedFrameCount += 1
        }
    }

    public func handleDiscontinuity() {
        lock.lock()
        lastPTS = nil
        lastFrame = nil
        enqueuedFrameCount = 0
        lock.unlock()
        displayLayer.flushAndRemoveImage()
    }

    private func makeMonotonicRealtimePTS() -> CMTime {
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        defer { lock.unlock() }
        guard let lastPTS else {
            self.lastPTS = pts
            return pts
        }
        if pts > lastPTS {
            self.lastPTS = pts
            return pts
        }
        let adjusted = lastPTS + minimumStep
        self.lastPTS = adjusted
        return adjusted
    }
}
