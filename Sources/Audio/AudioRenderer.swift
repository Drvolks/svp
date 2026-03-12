import Foundation
import PlayerCore

#if canImport(AVFoundation)
import AVFoundation
#endif

public final class AudioRenderer: @unchecked Sendable, AudioOutput, AudioOutputLifecycle {
    private let lock = NSLock()
    private var renderedFrames = 0
    private var wantsPlayback = false
    private var droppedFrames = 0
    private var loggedFirstRender = false
    private var scheduledFrames = 0
    private var underrunCount = 0
    private var lowWaterHitCount = 0
    private var queuedBufferSeconds: Double = 0
    private let baseStartBufferSeconds: Double = 0.650
    private let maxStartBufferSeconds: Double = 1.200
    private let startBufferStepOnUnderrun: Double = 0.120
    private var minStartBufferSeconds: Double = 0.650
    private let rebufferLowWaterSeconds: Double = 0.080
    private let lowWaterHitsBeforeRebuffer: Int = 4
    private let enableActiveRebuffer: Bool = false
    private var isRebuffering = true

    #if canImport(AVFoundation)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var configuredFormat: AVAudioFormat?
    private var notificationTokens: [NSObjectProtocol] = []
    #endif

    public init() {
        #if canImport(AVFoundation)
        engine.attach(playerNode)
        setupAudioSessionIfAvailable()
        registerNotifications()
        #endif
    }

    deinit {
        #if canImport(AVFoundation)
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        #endif
    }

    public func render(frame: DecodedAudioFrame) {
        let shouldPlay = lock.withLock {
            renderedFrames += 1
            if !loggedFirstRender {
                loggedFirstRender = true
                #if DEBUG
                print("[SVP][Audio] first_render pts=\(frame.pts.seconds) sampleRate=\(frame.sampleRate) channels=\(frame.channels) bytes=\(frame.data.count)")
                print("[SVP][Audio] jitter_buffer start=\(minStartBufferSeconds)s base=\(baseStartBufferSeconds)s max=\(maxStartBufferSeconds)s lowWater=\(rebufferLowWaterSeconds)s lowHits=\(lowWaterHitsBeforeRebuffer)s callback=dataPlayedBack")
                #endif
            }
            return wantsPlayback
        }

        #if canImport(AVFoundation)
        guard shouldPlay else { return }
        do {
            try configureIfNeeded(for: frame)
            guard let format = configuredFormat else { return }
            guard let pcmBuffer = makePCMBuffer(frame: frame, format: format) else {
                lock.withLock { droppedFrames += 1 }
                #if DEBUG
                print("[SVP][Audio] drop_frame reason=pcm_buffer")
                #endif
                return
            }

            if !engine.isRunning {
                try engine.start()
                #if DEBUG
                print("[SVP][Audio] engine_started_in_render")
                #endif
            }
            let bufferSeconds = Double(pcmBuffer.frameLength) / format.sampleRate
            lock.withLock {
                queuedBufferSeconds += bufferSeconds
            }
            playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.queuedBufferSeconds = max(0, self.queuedBufferSeconds - bufferSeconds)
                }
            }
            maybeEnterRebufferIfUnderrun()
            maybeStartPlaybackIfReady(logContext: "render")
            lock.withLock {
                scheduledFrames += 1
                if scheduledFrames == 1 {
                    #if DEBUG
                    print("[SVP][Audio] first_schedule frameLength=\(pcmBuffer.frameLength)")
                    #endif
                }
            }
        } catch {
            lock.withLock { droppedFrames += 1 }
            #if DEBUG
            print("[SVP][Audio] render_error \(error.localizedDescription)")
            #endif
            return
        }
        #endif
    }

    public func stats() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return renderedFrames
    }

    public func handlePlay() {
        lock.withLock {
            wantsPlayback = true
            isRebuffering = true
        }
        #if DEBUG
        print("[SVP][Audio] handlePlay")
        #endif
        #if canImport(AVFoundation)
        do {
            // Engine must have a valid connected format before starting.
            guard configuredFormat != nil else { return }
            if !engine.isRunning {
                try engine.start()
                #if DEBUG
                print("[SVP][Audio] engine_started_in_handlePlay")
                #endif
            }
            maybeStartPlaybackIfReady(logContext: "handlePlay")
        } catch {
            #if DEBUG
            print("[SVP][Audio] handlePlay_error \(error.localizedDescription)")
            #endif
            return
        }
        #endif
    }

    public func handlePause() {
        lock.withLock {
            wantsPlayback = false
            isRebuffering = true
        }
        #if DEBUG
        print("[SVP][Audio] handlePause")
        #endif
        #if canImport(AVFoundation)
        playerNode.pause()
        #endif
    }

    public func handleDiscontinuity() {
        lock.withLock {
            wantsPlayback = false
            queuedBufferSeconds = 0
            isRebuffering = true
            minStartBufferSeconds = baseStartBufferSeconds
            lowWaterHitCount = 0
        }
        #if canImport(AVFoundation)
        playerNode.stop()
        if engine.isRunning {
            engine.pause()
        }
        #endif
    }

    #if canImport(AVFoundation)
    private func configureIfNeeded(for frame: DecodedAudioFrame) throws {
        let channelCount = AVAudioChannelCount(frame.channels)
        guard channelCount > 0 else { return }
        let sampleRate = frame.sampleRate > 0 ? frame.sampleRate : 48_000

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channelCount, interleaved: true) else {
            return
        }

        if let configuredFormat,
           configuredFormat.sampleRate == format.sampleRate,
           configuredFormat.channelCount == format.channelCount,
           configuredFormat.commonFormat == format.commonFormat,
           configuredFormat.isInterleaved == format.isInterleaved {
            return
        }

        if engine.isRunning {
            playerNode.stop()
            engine.stop()
        }
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        configuredFormat = format
        try engine.start()
    }

    private func makePCMBuffer(frame: DecodedAudioFrame, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameLength = frame.data.count / bytesPerFrame
        guard frameLength > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameLength)

        guard let target = buffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        frame.data.copyBytes(to: target.assumingMemoryBound(to: UInt8.self), count: frame.data.count)
        let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        if !audioBufferList.isEmpty {
            audioBufferList[0].mDataByteSize = UInt32(frame.data.count)
        }
        return buffer
    }

    private func registerNotifications() {
        let center = NotificationCenter.default

        let engineToken = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
        notificationTokens.append(engineToken)

        #if canImport(UIKit)
        let interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
        notificationTokens.append(interruptionToken)

        let routeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
        notificationTokens.append(routeToken)
        #endif
    }

    private func handleEngineConfigurationChange() {
        let shouldPlay = lock.withLock { wantsPlayback }
        guard shouldPlay else { return }
        guard configuredFormat != nil else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            maybeStartPlaybackIfReady(logContext: "engineConfigChange")
        } catch {
            return
        }
    }

    private func maybeStartPlaybackIfReady(logContext: String) {
        let state = lock.withLock { (wantsPlayback, queuedBufferSeconds, isRebuffering, minStartBufferSeconds) }
        let shouldPlay = state.0
        guard shouldPlay else { return }
        let queuedSeconds = state.1
        let rebuffering = state.2
        let requiredBufferSeconds = state.3
        guard queuedSeconds >= requiredBufferSeconds else { return }
        if !playerNode.isPlaying {
            playerNode.play()
            lock.withLock {
                isRebuffering = false
            }
            #if DEBUG
            let reason = rebuffering ? "rebuffer" : "start"
            print("[SVP][Audio] playerNode_play_in_\(logContext) queued=\(queuedSeconds) target=\(requiredBufferSeconds) reason=\(reason)")
            #endif
        }
    }

    private func maybeEnterRebufferIfUnderrun() {
        guard enableActiveRebuffer else { return }
        guard playerNode.isPlaying else { return }
        let queuedSeconds = lock.withLock { queuedBufferSeconds }
        let lowWaterState = lock.withLock { () -> (Int, Bool) in
            if queuedSeconds < rebufferLowWaterSeconds {
                lowWaterHitCount += 1
            } else {
                lowWaterHitCount = 0
            }
            return (lowWaterHitCount, lowWaterHitCount >= lowWaterHitsBeforeRebuffer)
        }
        guard lowWaterState.1 else { return }
        playerNode.pause()
        let state = lock.withLock { () -> (Int, Double) in
            isRebuffering = true
            underrunCount += 1
            minStartBufferSeconds = min(maxStartBufferSeconds, minStartBufferSeconds + startBufferStepOnUnderrun)
            lowWaterHitCount = 0
            return (underrunCount, minStartBufferSeconds)
        }
        #if DEBUG
        print("[SVP][Audio] underrun_enter count=\(state.0) queued=\(queuedSeconds) lowHits=\(lowWaterState.0) nextTarget=\(state.1)")
        #endif
    }

    #if canImport(UIKit)
    private func setupAudioSessionIfAvailable() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.023)
            try session.setActive(true)
            #if DEBUG
            print("[SVP][Audio] session_config sampleRate=\(session.sampleRate) ioBuffer=\(session.ioBufferDuration)")
            #endif
        } catch {
            #if DEBUG
            print("[SVP][Audio] session_config_failed \(error.localizedDescription)")
            #endif
            return
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            playerNode.pause()
        case .ended:
            let shouldPlay = lock.withLock { wantsPlayback }
            guard shouldPlay else { return }
            guard configuredFormat != nil else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                if !engine.isRunning {
                    try engine.start()
                }
                maybeStartPlaybackIfReady(logContext: "interruptionEnd")
            } catch {
                return
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange() {
        let shouldPlay = lock.withLock { wantsPlayback }
        guard shouldPlay else { return }
        guard configuredFormat != nil else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            maybeStartPlaybackIfReady(logContext: "routeChange")
        } catch {
            return
        }
    }
    #else
    private func setupAudioSessionIfAvailable() {}
    #endif
    #endif
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
