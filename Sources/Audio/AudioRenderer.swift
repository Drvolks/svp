import Foundation
import OSLog
import PlayerCore

#if canImport(AVFoundation)
import AVFoundation
#endif

public final class AudioRenderer: @unchecked Sendable, AudioOutput, AudioOutputLifecycle, AudioPlaybackClockProviding, AudioRenderBufferProviding, AudioOutputSourceConfigurable {
    private struct PlaybackProfile: Sendable {
        let mode: String
        let baseStartBufferSeconds: Double
        let maxStartBufferSeconds: Double
        let startBufferStepOnUnderrun: Double
        let rebufferLowWaterSeconds: Double
        let lowWaterHitsBeforeRebuffer: Int
        let maxBufferedAudioSeconds: Double

        static let vod = PlaybackProfile(
            mode: "vod",
            baseStartBufferSeconds: 0.150,
            maxStartBufferSeconds: 0.600,
            startBufferStepOnUnderrun: 0.080,
            rebufferLowWaterSeconds: 0.080,
            lowWaterHitsBeforeRebuffer: 4,
            maxBufferedAudioSeconds: 0.80
        )

        static let live = PlaybackProfile(
            mode: "live",
            baseStartBufferSeconds: 0.300,
            maxStartBufferSeconds: 0.750,
            startBufferStepOnUnderrun: 0.080,
            rebufferLowWaterSeconds: 0.050,
            lowWaterHitsBeforeRebuffer: 3,
            maxBufferedAudioSeconds: 0.55
        )
    }

    private let lock = NSLock()
    private var renderedFrames = 0
    private var wantsPlayback = false
    private var droppedFrames = 0
    private var loggedFirstRender = false
    private var scheduledFrames = 0
    private var underrunCount = 0
    private var lowWaterHitCount = 0
    private var queuedBufferSeconds: Double = 0
    private var hasStartedPlayerNode = false
    private var profile = PlaybackProfile.vod
    private var minStartBufferSeconds: Double = 0.180
    private let enableActiveRebuffer: Bool = false
    private var isRebuffering = true
    private var playbackAnchorPTS: CMTime?
    private var playbackAnchorSampleRate: Double?
    private var playbackAnchorSampleTime: AVAudioFramePosition?
    private var audioClockQueryCount = 0
    private var lastDerivedPlaybackPTS: CMTime?

    #if canImport(AVFoundation)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var configuredFormat: AVAudioFormat?
    private var notificationTokens: [NSObjectProtocol] = []
    #endif

    private let log = Logger(subsystem: "com.drvolks.svp", category: "Audio")

    public init() {
        minStartBufferSeconds = profile.baseStartBufferSeconds
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
        let ptsSeconds = frame.pts.seconds
        let sampleRate = frame.sampleRate
        let channels = frame.channels
        let byteCount = frame.data.count

        let shouldLogFirstRender = lock.withLock {
            renderedFrames += 1
            if !loggedFirstRender {
                loggedFirstRender = true
                return true
            }
            return false
        }
        
        #if canImport(AVFoundation)
        do {
            try configureIfNeeded(for: frame)
            guard let format = configuredFormat else { return }
            guard let pcmBuffer = makePCMBuffer(frame: frame, format: format) else {
                lock.withLock { droppedFrames += 1 }
                log.debug("[SVP][Audio] drop_frame reason=pcm_buffer")
                return
            }

            if !engine.isRunning {
                try engine.start()
                log.debug("[SVP][Audio] engine_started_in_render")
            }
            let bufferSeconds = Double(pcmBuffer.frameLength) / format.sampleRate
            let queuedAfterAppend = lock.withLock { () -> Double in
                queuedBufferSeconds += bufferSeconds
                if playbackAnchorPTS == nil || playbackAnchorSampleRate == nil {
                    playbackAnchorPTS = frame.pts
                    playbackAnchorSampleRate = format.sampleRate
                    playbackAnchorSampleTime = nil
                    log.debug("[SVP][Audio] audioClockAnchor pts=\(frame.pts.seconds) sampleRate=\(format.sampleRate)")
                }
                return queuedBufferSeconds
            }
            let shouldForceStart = lock.withLock { () -> Bool in
                !hasStartedPlayerNode && queuedBufferSeconds >= minStartBufferSeconds
            }
            if shouldForceStart && !playerNode.isPlaying {
                playerNode.play()
                lock.withLock {
                    hasStartedPlayerNode = true
                    isRebuffering = false
                }
                let state = lock.withLock { (wantsPlayback, queuedBufferSeconds, minStartBufferSeconds) }
                log.debug("[SVP][Audio] playerNode_start_now wants=\(state.0) queued=\(String(format: "%.3f", state.1)) target=\(String(format: "%.3f", state.2))")
            }
            if queuedAfterAppend > profile.maxBufferedAudioSeconds {
                lock.withLock { [self] in
                    queuedBufferSeconds = max(0, queuedBufferSeconds - bufferSeconds)
                    droppedFrames += 1
                }
                log.debug("[SVP][Audio] drop_frame reason=queue_overflow queued=\(queuedAfterAppend) max=\(self.profile.maxBufferedAudioSeconds)")
                return
            }
            playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    guard self.hasStartedPlayerNode else { return }
                    self.queuedBufferSeconds = max(0, self.queuedBufferSeconds - bufferSeconds)
                }
            }
            maybeEnterRebufferIfUnderrun()
            maybeStartPlaybackIfReady(logContext: "render")
            lock.withLock {
                scheduledFrames += 1
                if scheduledFrames == 1 {
                    log.debug("[SVP][Audio] first_schedule frameLength=\(pcmBuffer.frameLength)")
                }
            }
        } catch {
            lock.withLock { droppedFrames += 1 }
            log.debug("[SVP][Audio] render_error \(error.localizedDescription)")
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
        log.debug("[SVP][Audio] handlePlay")
        #if canImport(AVFoundation)
        do {
            // Engine must have a valid connected format before starting.
            guard configuredFormat != nil else { return }
            if !engine.isRunning {
                try engine.start()
                log.debug("[SVP][Audio] engine_started_in_handlePlay")
            }
            maybeStartPlaybackIfReady(logContext: "handlePlay")
        } catch {
            log.debug("[SVP][Audio] handlePlay_error \(error.localizedDescription)")
            return
        }
        #endif
    }

    public func handlePause() {
        lock.withLock {
            wantsPlayback = false
            isRebuffering = true
            hasStartedPlayerNode = false
            queuedBufferSeconds = 0
        }
        log.debug("[SVP][Audio] handlePause")
        #if canImport(AVFoundation)
        playerNode.pause()
        #endif
    }

    public func handleDiscontinuity() {
        lock.withLock {
            wantsPlayback = false
            queuedBufferSeconds = 0
            hasStartedPlayerNode = false
            isRebuffering = true
            minStartBufferSeconds = profile.baseStartBufferSeconds
            lowWaterHitCount = 0
            playbackAnchorPTS = nil
            playbackAnchorSampleRate = nil
            playbackAnchorSampleTime = nil
            lastDerivedPlaybackPTS = nil
            audioClockQueryCount = 0
        }
        #if canImport(AVFoundation)
        playerNode.stop()
        if engine.isRunning {
            engine.pause()
        }
        #endif
    }

    public func currentPlaybackTime() -> CMTime? {
        #if canImport(AVFoundation)
        let state = lock.withLock { () -> (CMTime?, Double?, Double, Int) in
            audioClockQueryCount += 1
            return (playbackAnchorPTS, playbackAnchorSampleRate, queuedBufferSeconds, audioClockQueryCount)
        }
        guard let anchorPTS = state.0, let sampleRate = state.1, sampleRate > 0 else { return nil }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return lock.withLock { lastDerivedPlaybackPTS }
        }
        let sampleTime = playerTime.sampleTime
        if sampleTime < 0 {
            return lock.withLock { lastDerivedPlaybackPTS ?? anchorPTS }
        }
        let elapsedSamples = lock.withLock { () -> AVAudioFramePosition in
            if playbackAnchorSampleTime == nil {
                playbackAnchorSampleTime = sampleTime
            }
            let anchorSampleTime = playbackAnchorSampleTime ?? sampleTime
            if sampleTime < anchorSampleTime {
                playbackAnchorSampleTime = sampleTime
                return 0
            }
            return sampleTime - anchorSampleTime
        }
        let elapsedSeconds = Double(elapsedSamples) / sampleRate
        let playedTime = anchorPTS + CMTime(seconds: elapsedSeconds, preferredTimescale: 90_000)
        let playbackTime = lock.withLock { () -> CMTime in
            if playedTime.isValid {
                if let lastDerivedPlaybackPTS, playedTime < lastDerivedPlaybackPTS {
                    return lastDerivedPlaybackPTS
                }
                lastDerivedPlaybackPTS = playedTime
                return playedTime
            }
            return lastDerivedPlaybackPTS ?? playedTime
        }
        let queryCount = state.3
        if queryCount == 1 || queryCount % 60 == 0 {
            let anchorText = String(format: "%.3f", anchorPTS.seconds)
            let sampleRateText = String(format: "%.1f", playerTime.sampleRate)
            let derivedText = String(format: "%.3f", playbackTime.seconds)
            let queuedText = String(format: "%.3f", state.2)
            let anchorSampleText = String(lock.withLock { playbackAnchorSampleTime ?? 0 })
            let msg = "[SVP][AudioClock] query=\(queryCount) anchorPTS=\(anchorText) sampleTime=\(playerTime.sampleTime) anchorSampleTime=\(anchorSampleText) sampleRate=\(sampleRateText) derivedPTS=\(derivedText) queued=\(queuedText)"
            log.debug("\(msg)")
        }
        return playbackTime.isValid ? playbackTime : nil
        #else
        return nil
        #endif
    }

    public func bufferedAudioSeconds() -> Double {
        lock.withLock { queuedBufferSeconds }
    }

    public func configure(for descriptor: MediaSourceDescriptor) {
        let nextProfile: PlaybackProfile = descriptor.isLive ? .live : .vod
        let changed = lock.withLock { () -> Bool in
            let changed = profile.mode != nextProfile.mode
            profile = nextProfile
            minStartBufferSeconds = nextProfile.baseStartBufferSeconds
            return changed
        }
        if changed {
            let msg = "[SVP][Audio] profile mode=\(nextProfile.mode) base=\(nextProfile.baseStartBufferSeconds) max=\(nextProfile.maxStartBufferSeconds) lowWater=\(nextProfile.rebufferLowWaterSeconds) maxBuffered=\(nextProfile.maxBufferedAudioSeconds)"
            log.debug("\(msg)")
        }
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
        lock.withLock {
            playbackAnchorPTS = nil
            playbackAnchorSampleRate = nil
            playbackAnchorSampleTime = nil
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
        let state = lock.withLock { (wantsPlayback, queuedBufferSeconds, isRebuffering, minStartBufferSeconds, hasStartedPlayerNode) }
        let shouldPlay = state.0
        guard shouldPlay else { return }
        if playerNode.isPlaying {
            lock.withLock {
                hasStartedPlayerNode = true
                isRebuffering = false
            }
            return
        }
        let queuedSeconds = state.1
        let rebuffering = state.2
        let requiredBufferSeconds = state.3
        let startedBefore = state.4

        // If playback was already started once, resume immediately when any
        // audio is queued instead of waiting for the full startup threshold.
        if startedBefore && queuedSeconds > 0 {
            playerNode.play()
            lock.withLock {
                hasStartedPlayerNode = true
                isRebuffering = false
            }
            log.debug("[SVP][Audio] playerNode_resume_in_\(logContext) queued=\(queuedSeconds)")
            return
        }

        guard queuedSeconds >= requiredBufferSeconds else {
            if queuedSeconds > 0 {
                log.debug("[SVP][Audio] start_wait_in_\(logContext) queued=\(queuedSeconds) target=\(requiredBufferSeconds)")
            }
            return
        }
        if !playerNode.isPlaying {
            playerNode.play()
            lock.withLock {
                hasStartedPlayerNode = true
                isRebuffering = false
            }
            let reason = rebuffering ? "rebuffer" : "start"
            log.debug("[SVP][Audio] playerNode_play_in_\(logContext) queued=\(queuedSeconds) target=\(requiredBufferSeconds) reason=\(reason)")
        }
    }

    private func maybeEnterRebufferIfUnderrun() {
        guard enableActiveRebuffer else { return }
        guard playerNode.isPlaying else { return }
        let queuedSeconds = lock.withLock { queuedBufferSeconds }
        let lowWaterState = lock.withLock { () -> (Int, Bool) in
            if queuedSeconds < profile.rebufferLowWaterSeconds {
                lowWaterHitCount += 1
            } else {
                lowWaterHitCount = 0
            }
            return (lowWaterHitCount, lowWaterHitCount >= profile.lowWaterHitsBeforeRebuffer)
        }
        guard lowWaterState.1 else { return }
        playerNode.pause()
        let state = lock.withLock { () -> (Int, Double) in
            isRebuffering = true
            underrunCount += 1
            minStartBufferSeconds = min(profile.maxStartBufferSeconds, minStartBufferSeconds + profile.startBufferStepOnUnderrun)
            lowWaterHitCount = 0
            return (underrunCount, minStartBufferSeconds)
        }
        log.debug("[SVP][Audio] underrun_enter count=\(state.0) queued=\(queuedSeconds) lowHits=\(lowWaterState.0) nextTarget=\(state.1)")
    }

    #if canImport(UIKit)
    private func setupAudioSessionIfAvailable() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            // Use larger buffer duration (46ms) to prevent HAL overload
            // This reduces callback frequency and prevents the "skipping cycle due to overload" errors
            try session.setPreferredIOBufferDuration(0.046)
            // Don't set preferred sample rate - let the stream determine it (44.1kHz or 48kHz)
            // Setting a mismatched sample rate causes clock drift
            try session.setActive(true)
            log.debug("[SVP][Audio] session_config sampleRate=\(session.sampleRate) ioBuffer=\(session.ioBufferDuration)")
        } catch {
            log.debug("[SVP][Audio] session_config_failed \(error.localizedDescription)")
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
