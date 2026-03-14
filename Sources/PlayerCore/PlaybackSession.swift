import CoreMedia
import Foundation

public protocol DemuxEngine: Actor {
    func makePacketStream() -> AsyncThrowingStream<DemuxedPacket, Error>
    func seek(to: CMTime) async throws
    func duration() async -> CMTime?
}

public protocol VideoPipeline: Actor {
    func decode(packet: DemuxedPacket) async throws -> DecodedVideoFrame?
    func flush() async
}

public protocol AudioPipeline: Actor {
    func decode(packet: DemuxedPacket) async throws -> [DecodedAudioFrame]
    func flush() async
}

public actor PlaybackSession: PlayerEngine {
    public let clock: MediaClock
    private let diagnostics = PlaybackDiagnostics()
    private let demuxer: any DemuxEngine
    private let videoPipeline: any VideoPipeline
    private let audioPipeline: any AudioPipeline
    private let videoPresenter: VideoPresenter
    private let audioPacketQueue = PacketQueue(capacity: 256, overflowPolicy: .blockProducer)
    private let videoPacketQueue = PacketQueue(capacity: 180, overflowPolicy: .preferKeyframes)
    private let videoFrameQueue = FrameQueue(capacity: 24)
    private var demuxTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var videoDecodeTask: Task<Void, Never>?
    private var videoPresentTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var state: PlaybackState = .idle
    private var videoOutputs: [ObjectIdentifier: any VideoOutput] = [:]
    private var audioOutputs: [ObjectIdentifier: any AudioOutput] = [:]
    private let audioSynchronizer = AudioSynchronizerAdapter()
    private var lastAudioPTS: CMTime?
    private var lastPacketUptime: TimeInterval = 0
    private let rebufferThreshold: TimeInterval = 0.8
    private let audioStallLowWaterSeconds: Double = 0.12
    private let videoFrameStallLowWaterSeconds: Double = 0.20
    private let videoPacketStallLowWaterSeconds: Double = 0.20
    private var eventContinuations: [UUID: AsyncStream<PlaybackEvent>.Continuation] = [:]
    private var taskGeneration: UInt64 = 0
    private var knownDuration: CMTime?
    private var sourceDescriptor: MediaSourceDescriptor?
    private var packetCount: Int = 0
    private var droppedVideoPackets = 0
    private var demuxCompleted = false
    private var audioWorkerFinished = false
    private var videoDecodeWorkerFinished = false
    private var videoPresentWorkerFinished = false
    private var consecutiveVideoDecodeFailures = 0
    private var waitingForVideoKeyframeResync = false
    private var loggedFirstVideoFrame = false
    private var loggedFirstAudioFrame = false
    private var lastRenderedAudioPTS: CMTime?
    private var lastRenderedAudioUptime: TimeInterval?
    private var audioTimelineAnchorPTS: CMTime?
    private var audioTimelineAnchorUptime: TimeInterval?
    private var lastRenderedVideoPTS: CMTime?
    private var lastRenderedVideoUptime: TimeInterval?
    private var videoTimelineAnchorPTS: CMTime?
    private var videoTimelineAnchorUptime: TimeInterval?
    private var videoRenderStartUptime: TimeInterval?
    private var videoRenderStartPTS: CMTime?
    private var lastQueueHealthLogUptime: TimeInterval = 0
    private var renderedVideoFrameCount: Int = 0
    private var lastDecodedVideoFramePTS: CMTime?
    private var lastDecodedVideoFrameUptime: TimeInterval?
    private var lastVideoDecodeElapsedMs: Double = 0
    private let liveAudioPacketBacklogSoftLimitSeconds: Double = 0.45
    private let liveVideoPacketBacklogSoftLimitSeconds: Double = 1.20
    private let liveFrameBacklogSoftLimitSeconds: Double = 0.35
    private let liveVideoDecodeLeadSoftLimitSeconds: Double = 0.18
    private let splitAudioPacketBacklogSoftLimitSeconds: Double = 0.35
    private let liveAudioDecodeLeadSoftLimitSeconds: Double = 0.20
    private let vodAudioDecodeLeadSoftLimitSeconds: Double = 0.65

    public init(
        clock: MediaClock = MediaClock(),
        demuxer: any DemuxEngine,
        videoPipeline: any VideoPipeline,
        audioPipeline: any AudioPipeline
    ) {
        self.clock = clock
        self.demuxer = demuxer
        self.videoPipeline = videoPipeline
        self.audioPipeline = audioPipeline
        self.videoPresenter = VideoPresenter(diagnostics: diagnostics)
    }

    public func load(_ source: PlayableSource) async throws {
        _ = source
        await stopPlaybackTasks()
        await resetRuntimeState()
        sourceDescriptor = source.descriptor
        await configureQueues(for: source.descriptor)
        for output in audioOutputs.values {
            (output as? any AudioOutputSourceConfigurable)?.configure(for: source.descriptor)
        }
        diagnostics.log("load_requested")
        setState(.loading)
        knownDuration = await demuxer.duration()
        if let knownDuration {
            diagnostics.log("duration_detected_seconds=\(knownDuration.seconds)")
        } else {
            diagnostics.log("duration_unknown")
        }
        setState(.ready)
    }

    public func play() async {
        guard demuxTask == nil else { return }
        if case .ended = state {
            diagnostics.log("play_requested_from_ended -> restart_from_zero")
            do {
                try await restartFromBeginningForReplay()
            } catch {
                let playerError = makePlayerError(from: error)
                let description = describe(playerError)
                diagnostics.log("replay_restart_failed: \(description)")
                setState(.failed(description))
                emitEvent(.error(description))
                return
            }
        }
        diagnostics.log("play_requested")
        setState(.playing)
        diagnostics.markPlaybackStarted()
        clock.play()
        lastPacketUptime = ProcessInfo.processInfo.systemUptime
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handlePlay()
        }
        taskGeneration &+= 1
        let generation = taskGeneration
        await startWorkerTasksIfNeeded(generation: generation)
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorForStalls(generation: generation)
        }
        demuxTask = Task { [weak self] in
            guard let self else { return }
            await self.runDemuxLoop(generation: generation)
        }
    }

    public func pause() async {
        diagnostics.log("pause_requested")
        await stopPlaybackTasks()
        clock.pause()
        setState(.paused)
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handlePause()
        }
    }

    public func seek(to time: CMTime) async throws {
        let resumeAfterSeek = demuxTask != nil
        diagnostics.log("seek_requested_seconds=\(time.seconds)")
        await stopPlaybackTasks()
        clock.seek(to: time)
        setState(resumeAfterSeek ? .buffering : .paused)
        try await demuxer.seek(to: time)
        await videoPipeline.flush()
        await audioPipeline.flush()
        lastAudioPTS = nil
        lastRenderedAudioPTS = nil
        lastRenderedAudioUptime = nil
        audioTimelineAnchorPTS = nil
        audioTimelineAnchorUptime = nil
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        waitingForVideoKeyframeResync = false
        lastPacketUptime = ProcessInfo.processInfo.systemUptime
        for output in videoOutputs.values {
            (output as? any VideoOutputLifecycle)?.handleDiscontinuity()
        }
        await videoPresenter.handleDiscontinuity()
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handleDiscontinuity()
        }
        if resumeAfterSeek {
            await play()
        }
    }

    public func attachVideoOutput(_ output: any VideoOutput) async {
        videoOutputs[ObjectIdentifier(output)] = output
        await videoPresenter.attachOutput(output)
    }

    public func detachVideoOutput(_ output: any VideoOutput) async {
        videoOutputs.removeValue(forKey: ObjectIdentifier(output))
        await videoPresenter.detachOutput(output)
    }

    public func attachAudioOutput(_ output: any AudioOutput) async {
        audioOutputs[ObjectIdentifier(output)] = output
        if case .playing = state {
            (output as? any AudioOutputLifecycle)?.handlePlay()
        } else if case .buffering = state {
            (output as? any AudioOutputLifecycle)?.handlePlay()
        } else if case .paused = state {
            (output as? any AudioOutputLifecycle)?.handlePause()
        }
    }

    public func detachAudioOutput(_ output: any AudioOutput) async {
        audioOutputs.removeValue(forKey: ObjectIdentifier(output))
    }

    public func playbackEvents() async -> AsyncStream<PlaybackEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(.stateChanged(state))
            continuation.yield(.progress(position: clock.currentTime(), duration: knownDuration))
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeEventContinuation(id: id) }
            }
        }
    }

    public func currentState() -> PlaybackState {
        state
    }

    public func currentPosition() async -> CMTime {
        clock.currentTime()
    }

    public func currentDuration() async -> CMTime? {
        knownDuration
    }

    public func playbackMetrics() async -> PlaybackMetrics {
        diagnostics.snapshot()
    }

    private func runDemuxLoop(generation: UInt64) async {
        guard isGenerationCurrent(generation) else { return }
        do {
            diagnostics.log("packet_consumer_started")
            let stream = await demuxer.makePacketStream()
            for try await packet in stream {
                if Task.isCancelled || !isGenerationCurrent(generation) { break }
                try? await throttleLiveIngestionIfNeeded()
                packetCount += 1
                if packetCount == 1 || packetCount % 100 == 0 {
                    //diagnostics.log("packet_received count=\(packetCount) codec=\(packet.formatHint) pts=\(String(describing: packet.pts)) size=\(packet.data.count)")
                }
                lastPacketUptime = ProcessInfo.processInfo.systemUptime
                emitEvent(.progress(position: clock.currentTime(), duration: knownDuration))
                if case .buffering = state {
                    setState(.playing)
                    await logQueueHealth(context: "playback_recovered")
                    diagnostics.log("playback_recovered")
                    emitEvent(.recovered)
                }
                switch packet.formatHint {
                case .h264, .hevc, .av1, .vp9:
                    #if DEBUG
                    print("[SVP] video_packet_enqueue pts=\(String(describing: packet.pts))")
                    #endif
                    if !(await videoPacketQueue.enqueue(packet)) {
                        droppedVideoPackets += 1
                        if droppedVideoPackets == 1 || droppedVideoPackets % 30 == 0 {
                            diagnostics.log("video_packet_drop_overflow count=\(droppedVideoPackets) keyframe=\(packet.isKeyframe)")
                        }
                    }
                case .aac, .ac3, .eac3, .opus:
                    try? await throttleSplitAudioIngestionIfNeeded()
                    _ = await audioPacketQueue.enqueue(packet)
                case .unknown:
                    continue
                }
            }
            if Task.isCancelled {
                return
            }
            guard isGenerationCurrent(generation) else { return }
            diagnostics.log("packet_stream_ended")
            demuxCompleted = true
            await logQueueHealth(context: "packet_stream_ended")
            await audioPacketQueue.close()
            await videoPacketQueue.close()
            await maybeFinishPlaybackAfterDrain()
        } catch {
            guard isGenerationCurrent(generation) else { return }
            let playerError = makePlayerError(from: error)
            let description = describe(playerError)
            diagnostics.incrementDecodeFailure()
            diagnostics.log("playback_error: \(description)")
            await audioPacketQueue.close()
            await videoPacketQueue.close()
            setState(.failed(description))
            emitEvent(.error(description))
        }
    }

    private func monitorForStalls(generation: UInt64) async {
        while !Task.isCancelled && isGenerationCurrent(generation) {
            let now = ProcessInfo.processInfo.systemUptime
            let sourceTimedOut = !demuxCompleted && (now - lastPacketUptime > rebufferThreshold)
            let buffersDrained = await arePlaybackBuffersDepletedForStall()
            let stalled = sourceTimedOut && buffersDrained
            if stalled, case .playing = state {
                await logQueueHealth(context: "playback_stalled")
                setState(.buffering)
                diagnostics.incrementRebuffer()
                diagnostics.log("playback_stalled")
                emitEvent(.stalled)
            }
            emitEvent(.progress(position: clock.currentTime(), duration: knownDuration))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func arePlaybackBuffersDepletedForStall() async -> Bool {
        let audio = await audioPacketQueue.snapshot()
        let video = await videoPacketQueue.snapshot()
        let videoFrames = await videoFrameQueue.snapshot()

        let audioBacklog = audio.mediaSpanSeconds ?? 0
        let videoPacketBacklog = video.mediaSpanSeconds ?? 0
        let videoFrameBacklog = videoFrames.mediaSpanSeconds ?? 0

        if audioBacklog > audioStallLowWaterSeconds {
            return false
        }
        if videoFrameBacklog > videoFrameStallLowWaterSeconds {
            return false
        }
        if videoPacketBacklog > videoPacketStallLowWaterSeconds {
            return false
        }
        return true
    }

    private func throttleLiveIngestionIfNeeded() async throws {
        guard let descriptor = sourceDescriptor else { return }
        let isLive = descriptor.isLive
        guard isLive else { return }

        while !Task.isCancelled {
            let audio = await audioPacketQueue.snapshot()
            let video = await videoPacketQueue.snapshot()
            let videoFrames = await videoFrameQueue.snapshot()

            let audioBacklog = audio.mediaSpanSeconds ?? 0
            let videoBacklog = video.mediaSpanSeconds ?? 0
            let frameBacklog = videoFrames.mediaSpanSeconds ?? 0

            let shouldThrottle =
                audioBacklog > liveAudioPacketBacklogSoftLimitSeconds ||
                videoBacklog > liveVideoPacketBacklogSoftLimitSeconds ||
                frameBacklog > liveFrameBacklogSoftLimitSeconds

            guard shouldThrottle else { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func throttleSplitAudioIngestionIfNeeded() async throws {
        guard isSplitSourceDescriptor(sourceDescriptor) else { return }

        while !Task.isCancelled {
            let audio = await audioPacketQueue.snapshot()
            let audioBacklog = audio.mediaSpanSeconds ?? 0
            guard audioBacklog > splitAudioPacketBacklogSoftLimitSeconds else { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func isSplitSourceDescriptor(_ descriptor: MediaSourceDescriptor?) -> Bool {
        guard let descriptor else { return false }
        if case .split = descriptor.kind {
            return true
        }
        return false
    }

    private func syncAudioMasterClock(with audioPTS: CMTime) {
        if lastAudioPTS == nil {
            lastAudioPTS = audioPTS
            clock.sync(to: audioPTS)
            return
        }
        let current = clock.currentTime()
        let corrected = audioSynchronizer.correctedVideoPTS(videoPTS: current, audioClock: audioPTS)
        if corrected != current {
            clock.sync(to: corrected)
        }
        lastAudioPTS = audioPTS
    }

    private func setState(_ newState: PlaybackState) {
        state = newState
        diagnostics.log("state=\(newState)")
        emitEvent(.stateChanged(newState))
    }

    private func restartFromBeginningForReplay() async throws {
        clock.seek(to: .zero)
        try await demuxer.seek(to: .zero)
        await videoPipeline.flush()
        await audioPipeline.flush()
        lastAudioPTS = nil
        lastRenderedAudioPTS = nil
        lastRenderedAudioUptime = nil
        audioTimelineAnchorPTS = nil
        audioTimelineAnchorUptime = nil
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        await resetRuntimeState()
        for output in videoOutputs.values {
            (output as? any VideoOutputLifecycle)?.handleDiscontinuity()
        }
        await videoPresenter.handleDiscontinuity()
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handleDiscontinuity()
        }
        setState(.ready)
    }

    private func paceVideoIfNeeded(framePTS: CMTime) async throws {
        guard framePTS.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if lastAudioPTS == nil {
            guard let anchorPTS = videoTimelineAnchorPTS, let anchorUptime = videoTimelineAnchorUptime else {
                videoTimelineAnchorPTS = framePTS
                videoTimelineAnchorUptime = now
                lastRenderedVideoPTS = framePTS
                lastRenderedVideoUptime = now
                return
            }

            let targetUptime = anchorUptime + max(0, framePTS.seconds - anchorPTS.seconds)
            let sleepSeconds = targetUptime - now
            if sleepSeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }

            lastRenderedVideoPTS = framePTS
            lastRenderedVideoUptime = ProcessInfo.processInfo.systemUptime
            return
        }

        guard let lastPTS = lastRenderedVideoPTS, let lastUptime = lastRenderedVideoUptime else {
            lastRenderedVideoPTS = framePTS
            lastRenderedVideoUptime = now
            return
        }

        let interval = framePTS.seconds - lastPTS.seconds
        if interval > 0.001, interval < 0.25 {
            let targetUptime = lastUptime + interval
            let sleepSeconds = targetUptime - now
            let nanos = sleepSeconds > 0 ? UInt64(sleepSeconds * 1_000_000_000) : 0
            if nanos > 0 {
                try await Task.sleep(nanoseconds: nanos)
            }
        }

        lastRenderedVideoPTS = framePTS
        lastRenderedVideoUptime = ProcessInfo.processInfo.systemUptime
    }

    private func paceAudioIfNeeded(framePTS: CMTime) async throws {
        guard framePTS.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime

        guard let anchorPTS = audioTimelineAnchorPTS, let anchorUptime = audioTimelineAnchorUptime else {
            audioTimelineAnchorPTS = framePTS
            audioTimelineAnchorUptime = now
            lastRenderedAudioPTS = framePTS
            lastRenderedAudioUptime = now
            return
        }

        let targetUptime = anchorUptime + max(0, framePTS.seconds - anchorPTS.seconds)
        let sleepSeconds = targetUptime - now
        if sleepSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }

        lastRenderedAudioPTS = framePTS
        lastRenderedAudioUptime = ProcessInfo.processInfo.systemUptime
    }

    private func stopPlaybackTasks() async {
        taskGeneration &+= 1
        demuxTask?.cancel()
        demuxTask = nil
        audioTask?.cancel()
        audioTask = nil
        videoDecodeTask?.cancel()
        videoDecodeTask = nil
        videoPresentTask?.cancel()
        videoPresentTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        await audioPacketQueue.close()
        await videoPacketQueue.close()
        await videoFrameQueue.close()
    }

    private func configureQueues(for descriptor: MediaSourceDescriptor) async {
        let hasAudio: Bool
        let hasVideo: Bool
        if descriptor.streams.isEmpty {
            switch descriptor.kind {
            case .liveTS:
                hasAudio = true
                hasVideo = true
            case .segmented:
                hasAudio = true
                hasVideo = true
            case .split:
                hasAudio = true
                hasVideo = true
            case .file, .network:
                hasAudio = descriptor.preferredClock == .audio
                hasVideo = true
            }
        } else {
            hasAudio = descriptor.streams.contains { $0.kind == .audio }
            hasVideo = descriptor.streams.contains { $0.kind == .video }
        }

        let isSplitSource = isSplitSourceDescriptor(descriptor)

        let audioCapacity: Int
        if descriptor.isLive {
            audioCapacity = 512
        } else if isSplitSource {
            audioCapacity = 96
        } else {
            audioCapacity = 256
        }

        let videoCapacity: Int
        let videoOverflowPolicy: PacketQueueOverflowPolicy
        let videoFrameCapacity: Int
        let videoFrameOverflowPolicy: FrameQueueOverflowPolicy
        if descriptor.isLive {
            // Increased for better buffering in live mode
            videoCapacity = hasAudio ? 240 : 360
            videoOverflowPolicy = .preferKeyframes
            videoFrameCapacity = hasAudio ? 24 : 30
            videoFrameOverflowPolicy = .blockProducer
        } else if isSplitSource && hasAudio {
            // Split VOD (separate video/audio URLs): keep packet ordering stable
            // while allowing late frame replacement at the presentation stage.
            videoCapacity = 180
            videoOverflowPolicy = .blockProducer
            videoFrameCapacity = 24
            videoFrameOverflowPolicy = .blockProducer
        } else {
            videoCapacity = hasAudio ? 240 : 600
            videoOverflowPolicy = .blockProducer
            videoFrameCapacity = hasAudio ? 24 : 30
            videoFrameOverflowPolicy = .blockProducer
        }

        await audioPacketQueue.configure(capacity: audioCapacity, overflowPolicy: .blockProducer)
        await videoPacketQueue.configure(capacity: videoCapacity, overflowPolicy: videoOverflowPolicy)
        await videoFrameQueue.configure(capacity: videoFrameCapacity, overflowPolicy: videoFrameOverflowPolicy)

        diagnostics.log(
            "queue_profile live=\(descriptor.isLive) hasAudio=\(hasAudio) hasVideo=\(hasVideo) " +
            "audioCapacity=\(audioCapacity) videoCapacity=\(videoCapacity) frameCapacity=\(videoFrameCapacity) " +
            "videoPolicy=\(String(describing: videoOverflowPolicy)) framePolicy=\(String(describing: videoFrameOverflowPolicy))"
        )
    }

    private func startWorkerTasksIfNeeded(generation: UInt64) async {
        guard audioTask == nil, videoDecodeTask == nil, videoPresentTask == nil else { return }
        demuxCompleted = false
        audioWorkerFinished = false
        videoDecodeWorkerFinished = false
        videoPresentWorkerFinished = false
        droppedVideoPackets = 0
        await audioPacketQueue.reset()
        await videoPacketQueue.reset()
        await videoFrameQueue.reset()
        audioTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeAudioPackets(generation: generation)
        }
        videoDecodeTask = Task { [weak self] in
            guard let self else { return }
            await self.decodeVideoPackets(generation: generation)
        }
        let preferredLeadSeconds: Double
        let useLivePresentation = sourceDescriptor?.isLive == true
        if sourceDescriptor?.isLive == true {
            preferredLeadSeconds = 0.08
        } else if isSplitSourceDescriptor(sourceDescriptor) {
            // Moderate lead for split AV - allows video to run slightly ahead of audio
            // for buffering headroom while keeping sync
            preferredLeadSeconds = 0.2
        } else {
            // For regular VOD, use a small lead to prevent video falling behind
            // The old 0.0 caused anchor-based pacing which can oscillate
            preferredLeadSeconds = 0.1
        }
        videoPresentTask = Task { [weak self] in
            guard let self else { return }
            await self.videoPresenter.presentFrames(
                from: self.videoFrameQueue,
                shouldDropLateFrame: { [weak self] pts in
                    guard let self else { return false }
                    return await self.shouldDropLateVideoFrameAsync(pts)
                },
                masterClockProvider: { [weak self] in
                    guard let self else { return nil }
                    return await self.currentAudioClockForPresentation()
                },
                preferredLeadSeconds: preferredLeadSeconds,
                useLivePresentation: useLivePresentation,
                renderHealthLogger: { [weak self] context, framePTS, decodeElapsedMs, renderElapsedMs, queueWaitMs, audioLeadMs in
                    guard let self else { return }
                    await self.logVideoRenderHealth(
                        context: context,
                        framePTS: framePTS,
                        decodeElapsedMs: decodeElapsedMs,
                        renderElapsedMs: renderElapsedMs,
                        queueWaitMs: queueWaitMs,
                        audioLeadMs: audioLeadMs
                    )
                }
            )
            guard await self.isGenerationCurrent(generation) else { return }
            await self.finishVideoPresentWorker()
        }
    }

    private func consumeAudioPackets(generation: UInt64) async {
        while let packet = await audioPacketQueue.dequeue() {
            if Task.isCancelled || !isGenerationCurrent(generation) { return }
            do {
                let frames = try await audioPipeline.decode(packet: packet)
                guard !frames.isEmpty else { continue }
                for frame in frames {
                    if Task.isCancelled || !isGenerationCurrent(generation) { return }
                    try? await throttleAudioDecodeIfNeeded(framePTS: frame.pts, generation: generation)
                    if Task.isCancelled || !isGenerationCurrent(generation) { return }
                    if !loggedFirstAudioFrame {
                        loggedFirstAudioFrame = true
                        diagnostics.log("first_audio_frame pts=\(frame.pts.seconds)")
                    }
                    for output in audioOutputs.values {
                        output.render(frame: frame)
                    }
                    syncAudioMasterClock(with: frame.pts)
                }
            } catch {
                if Task.isCancelled { return }
                diagnostics.incrementDecodeFailure()
                let description = describe(makePlayerError(from: error))
                diagnostics.log("audio_decode_drop error=\(description)")
            }
        }
        guard isGenerationCurrent(generation) else { return }
        audioWorkerFinished = true
        await maybeFinishPlaybackAfterDrain()
    }

    private func decodeVideoPackets(generation: UInt64) async {
        #if DEBUG
        print("[SVP] video_decode_loop starting")
        #endif
        while let packet = await videoPacketQueue.dequeue() {
            #if DEBUG
            print("[SVP] video_decode_loop dequeue pts=\(String(describing: packet.pts))")
            #endif
            if Task.isCancelled || !isGenerationCurrent(generation) { return }
            if waitingForVideoKeyframeResync {
                guard packet.isKeyframe else { continue }
                if let audioPTS = currentAudioClockForPresentation(allowDecodeFallback: false), let keyPTS = packet.pts {
                    let keyTime = CMTime(value: keyPTS, timescale: 90_000)
                    if (audioPTS - keyTime).seconds > 0.300 {
                        continue
                    }
                }
                waitingForVideoKeyframeResync = false
                lastRenderedVideoPTS = nil
                lastRenderedVideoUptime = nil
                await videoPipeline.flush()
                diagnostics.log("video_resync_keyframe pts=\(String(describing: packet.pts))")
            }
            do {
                let decodeStart = ProcessInfo.processInfo.systemUptime
                if let frame = try await videoPipeline.decode(packet: packet) {
                    #if DEBUG
                    print("[SVP] video_decode returned frame pts=\(String(describing: frame.pts))")
                    #endif
                    let decodeElapsedMs = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000
                    guard frame.pixelBuffer != nil else {
                        throw PlaybackSessionError.renderOutputMissing
                    }
                    try await throttleLiveDecodedVideoIfNeeded(framePTS: frame.pts)
                    let instrumentedFrame = DecodedVideoFrame(
                        pts: frame.pts,
                        pixelBuffer: frame.pixelBuffer,
                        opaqueDecoderPayload: frame.opaqueDecoderPayload,
                        colorInfo: frame.colorInfo,
                        decodeElapsedMs: decodeElapsedMs,
                        enqueuedUptime: ProcessInfo.processInfo.systemUptime
                    )
                    lastDecodedVideoFramePTS = frame.pts
                    lastDecodedVideoFrameUptime = ProcessInfo.processInfo.systemUptime
                    lastVideoDecodeElapsedMs = decodeElapsedMs
                    #if DEBUG
                    print("[SVP][VideoDecode] enqueue pts=\(String(format: "%.3f", frame.pts.seconds))")
                    #endif
                    if !(await videoFrameQueue.enqueue(instrumentedFrame)) {
                        return
                    }
                    consecutiveVideoDecodeFailures = 0
                }
            } catch {
                #if DEBUG
                print("[SVP] video_decode_error error=\(error)")
                #endif
                if Task.isCancelled { return }
                consecutiveVideoDecodeFailures += 1
                diagnostics.incrementDecodeFailure()
                let playerError = makePlayerError(from: error)
                let description = describe(playerError)
                if consecutiveVideoDecodeFailures == 1 || consecutiveVideoDecodeFailures % 10 == 0 {
                    await logQueueHealth(context: "video_decode_drop_\(consecutiveVideoDecodeFailures)")
                    diagnostics.log("video_decode_drop count=\(consecutiveVideoDecodeFailures) error=\(description)")
                }
                waitingForVideoKeyframeResync = true
                lastRenderedVideoPTS = nil
                lastRenderedVideoUptime = nil
            }
        }
        guard isGenerationCurrent(generation) else { return }
        videoDecodeWorkerFinished = true
        await videoFrameQueue.close()
        await maybeFinishPlaybackAfterDrain()
    }

    private func isGenerationCurrent(_ generation: UInt64) -> Bool {
        generation == taskGeneration
    }

    private func throttleAudioDecodeIfNeeded(framePTS: CMTime, generation: UInt64) async throws {
        guard framePTS.isValid else { return }
        let leadSoftLimit = sourceDescriptor?.isLive == true
            ? liveAudioDecodeLeadSoftLimitSeconds
            : vodAudioDecodeLeadSoftLimitSeconds

        while !Task.isCancelled && isGenerationCurrent(generation) {
            guard let playbackClock = currentAudioClockForPresentation(allowDecodeFallback: false),
                  playbackClock.isValid else {
                return
            }
            let leadSeconds = framePTS.seconds - playbackClock.seconds
            let sleepSeconds = leadSeconds - leadSoftLimit
            if sleepSeconds <= 0.01 {
                return
            }
            let boundedSleep = min(0.02, sleepSeconds)
            try await Task.sleep(nanoseconds: UInt64(boundedSleep * 1_000_000_000))
        }
    }

    private func throttleLiveDecodedVideoIfNeeded(framePTS: CMTime) async throws {
        guard sourceDescriptor?.isLive == true, framePTS.isValid else { return }

        while !Task.isCancelled {
            guard let audioClock = currentAudioClockForPresentation(),
                  audioClock.isValid,
                  audioClock.seconds > 1.0 else {
                return
            }

            let leadSeconds = framePTS.seconds - audioClock.seconds
            let sleepSeconds = leadSeconds - liveVideoDecodeLeadSoftLimitSeconds
            if sleepSeconds <= 0.01 {
                return
            }

            let boundedSleep = min(0.02, sleepSeconds)
            try await Task.sleep(nanoseconds: UInt64(boundedSleep * 1_000_000_000))
        }
    }

    private func finishVideoPresentWorker() async {
        videoPresentWorkerFinished = true
        await maybeFinishPlaybackAfterDrain()
    }

    private func shouldDropLateVideoFrameAsync(_ framePTS: CMTime) -> Bool {
        guard framePTS.isValid,
              let audioPTS = currentAudioClockForPresentation(),
              audioPTS.isValid else {
            return false
        }
        let lagSeconds = (audioPTS - framePTS).seconds
        if sourceDescriptor?.isLive == true {
            return lagSeconds > 0.200
        }
        // For VOD, allow some lag but don't let frame backlog grow indefinitely.
        return lagSeconds > 0.300
    }

    private func currentAudioClockForPresentation(allowDecodeFallback: Bool = true) -> CMTime? {
        var hasPlaybackClockProvider = false
        for output in audioOutputs.values {
            if let provider = output as? any AudioPlaybackClockProviding {
                hasPlaybackClockProvider = true
                if let playbackTime = provider.currentPlaybackTime(),
                   playbackTime.isValid {
                    return playbackTime
                }
            }
        }
        if hasPlaybackClockProvider {
            return nil
        }
        if allowDecodeFallback {
            return lastAudioPTS
        }
        return nil
    }

    private func maybeFinishPlaybackAfterDrain() async {
        guard demuxCompleted, audioWorkerFinished, videoDecodeWorkerFinished, videoPresentWorkerFinished else { return }
        setState(.ended)
        emitEvent(.ended)
    }

    private func resetRuntimeState() async {
        packetCount = 0
        droppedVideoPackets = 0
        demuxCompleted = false
        audioWorkerFinished = false
        videoDecodeWorkerFinished = false
        videoPresentWorkerFinished = false
        consecutiveVideoDecodeFailures = 0
        waitingForVideoKeyframeResync = false
        loggedFirstVideoFrame = false
        loggedFirstAudioFrame = false
        lastAudioPTS = nil
        lastRenderedAudioPTS = nil
        lastRenderedAudioUptime = nil
        audioTimelineAnchorPTS = nil
        audioTimelineAnchorUptime = nil
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        videoTimelineAnchorPTS = nil
        videoTimelineAnchorUptime = nil
        videoRenderStartUptime = nil
        videoRenderStartPTS = nil
        lastQueueHealthLogUptime = 0
        renderedVideoFrameCount = 0
        lastDecodedVideoFramePTS = nil
        lastDecodedVideoFrameUptime = nil
        lastVideoDecodeElapsedMs = 0
        await audioPacketQueue.reset()
        await videoPacketQueue.reset()
        await videoFrameQueue.reset()
        await videoPresenter.reset()
    }

    private func logQueueHealth(context: String, throttleSeconds: TimeInterval = 0) async {
        let now = ProcessInfo.processInfo.systemUptime
        if throttleSeconds > 0, now - lastQueueHealthLogUptime < throttleSeconds {
            return
        }
        lastQueueHealthLogUptime = now
        let audio = await audioPacketQueue.snapshot()
        let video = await videoPacketQueue.snapshot()
        let videoFrames = await videoFrameQueue.snapshot()
        let audioBacklog = audio.mediaSpanSeconds.map { String(format: "%.3f", $0) } ?? "nil"
        let videoBacklog = video.mediaSpanSeconds.map { String(format: "%.3f", $0) } ?? "nil"
        let videoFrameBacklog = videoFrames.mediaSpanSeconds.map { String(format: "%.3f", $0) } ?? "nil"
        let decodedAudioClock = lastAudioPTS.map { String(format: "%.3f", $0.seconds) } ?? "nil"
        let playbackAudioClock = currentAudioClockForPresentation(allowDecodeFallback: false).map { String(format: "%.3f", $0.seconds) } ?? "nil"
        diagnostics.log(
            "queue_health context=\(context) " +
            "audio=count:\(audio.count)/\(audio.capacity),backlog:\(audioBacklog),firstPTS:\(String(describing: audio.firstPTS)),lastPTS:\(String(describing: audio.lastPTS)) " +
            "video=count:\(video.count)/\(video.capacity),backlog:\(videoBacklog),firstPTS:\(String(describing: video.firstPTS)),lastPTS:\(String(describing: video.lastPTS)) " +
            "videoFrames=count:\(videoFrames.count)/\(videoFrames.capacity),backlog:\(videoFrameBacklog),firstPTS:\(String(describing: videoFrames.firstPTSSeconds)),lastPTS:\(String(describing: videoFrames.lastPTSSeconds)) " +
            "audioClockPlayback=\(playbackAudioClock) audioClockDecoded=\(decodedAudioClock) waitingKeyframe=\(waitingForVideoKeyframeResync)"
        )
    }

    private func logVideoRenderHealth(
        context: String,
        framePTS: CMTime,
        decodeElapsedMs: Double,
        renderElapsedMs: Double,
        queueWaitMs: Double,
        audioLeadMs: Double?
    ) async {
        await logQueueHealth(context: context)
        let wallElapsed: String
        if let start = videoRenderStartUptime {
            wallElapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start)
        } else {
            wallElapsed = "nil"
        }
        let mediaElapsed: String
        if let startPTS = videoRenderStartPTS {
            mediaElapsed = String(format: "%.3f", framePTS.seconds - startPTS.seconds)
        } else {
            mediaElapsed = "nil"
        }
        diagnostics.log(
            "video_timing context=\(context) framePTS=\(String(format: "%.3f", framePTS.seconds)) " +
            "decodeMs=\(String(format: "%.2f", decodeElapsedMs)) renderMs=\(String(format: "%.2f", renderElapsedMs)) " +
            "queueWaitMs=\(String(format: "%.2f", queueWaitMs)) audioLeadMs=\(audioLeadMs.map { String(format: "%.2f", $0) } ?? "nil") " +
            "wallElapsed=\(wallElapsed) mediaElapsed=\(mediaElapsed)"
        )
    }

    private func makePlayerError(from error: Error) -> PlayerError {
        if let playerError = error as? PlayerError {
            return playerError
        }
        if let categorized = error as? PlaybackCategorizedError {
            let message = String(describing: error)
            switch categorized.playbackErrorCategory {
            case .sourceOpen:
                return .sourceOpen(message)
            case .demux:
                return .demux(message)
            case .decode:
                return .decode(message)
            case .render:
                return .render(message)
            case .audio:
                return .audio(message)
            case .unknown:
                return .unknown(message)
            }
        }
        return .unknown(String(describing: error))
    }

    private func describe(_ error: PlayerError) -> String {
        switch error {
        case .sourceOpen(let message):
            return "sourceOpen: \(message)"
        case .demux(let message):
            return "demux: \(message)"
        case .decode(let message):
            return "decode: \(message)"
        case .render(let message):
            return "render: \(message)"
        case .audio(let message):
            return "audio: \(message)"
        case .unknown(let message):
            return "unknown: \(message)"
        }
    }

    private func emitEvent(_ event: PlaybackEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations[id]?.finish()
        eventContinuations.removeValue(forKey: id)
    }
}

private struct AudioSynchronizerAdapter: Sendable {
    func correctedVideoPTS(videoPTS: CMTime, audioClock: CMTime) -> CMTime {
        guard videoPTS.isValid, audioClock.isValid else { return audioClock }
        let drift = videoPTS - audioClock
        if abs(drift.seconds) >= 0.200 {
            return audioClock
        }
        if abs(drift.seconds) <= 0.020 {
            return videoPTS
        }
        let correction = CMTime(seconds: drift.seconds * 0.5, preferredTimescale: 90_000)
        return videoPTS - correction
    }
}

private actor VideoPresenter {
    private let diagnostics: PlaybackDiagnostics
    private var outputs: [ObjectIdentifier: any VideoOutput] = [:]
    private var loggedFirstVideoFrame = false
    private var lastRenderedVideoPTS: CMTime?
    private var lastRenderedVideoUptime: TimeInterval?
    private var videoTimelineAnchorPTS: CMTime?
    private var videoTimelineAnchorUptime: TimeInterval?
    private var videoRenderStartUptime: TimeInterval?
    private var videoRenderStartPTS: CMTime?
    private var renderedVideoFrameCount = 0
    private var droppedLiveFrames = 0

    init(diagnostics: PlaybackDiagnostics) {
        self.diagnostics = diagnostics
    }

    func attachOutput(_ output: any VideoOutput) {
        outputs[ObjectIdentifier(output)] = output
    }

    func detachOutput(_ output: any VideoOutput) {
        outputs.removeValue(forKey: ObjectIdentifier(output))
    }

    func reset() {
        loggedFirstVideoFrame = false
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        videoTimelineAnchorPTS = nil
        videoTimelineAnchorUptime = nil
        videoRenderStartUptime = nil
        videoRenderStartPTS = nil
        renderedVideoFrameCount = 0
        droppedLiveFrames = 0
    }

    func handleDiscontinuity() {
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        videoTimelineAnchorPTS = nil
        videoTimelineAnchorUptime = nil
        videoRenderStartUptime = nil
        videoRenderStartPTS = nil
        renderedVideoFrameCount = 0
        droppedLiveFrames = 0
    }

    func presentFrames(
        from frameQueue: FrameQueue,
        shouldDropLateFrame: @escaping @Sendable (CMTime) async -> Bool,
        masterClockProvider: @escaping @Sendable () async -> CMTime?,
        preferredLeadSeconds: Double,
        useLivePresentation: Bool,
        renderHealthLogger: @escaping @Sendable (String, CMTime, Double, Double, Double, Double?) async -> Void
    ) async {
        if useLivePresentation {
            await presentLiveFrames(
                from: frameQueue,
                shouldDropLateFrame: shouldDropLateFrame,
                masterClockProvider: masterClockProvider,
                preferredLeadSeconds: preferredLeadSeconds,
                renderHealthLogger: renderHealthLogger
            )
            return
        }

        while !Task.isCancelled {
            let frame: DecodedVideoFrame
            if let masterClock = await masterClockProvider(), masterClock.isValid {
                // Use simple FIFO dequeue for smooth playback instead of popLatestEligible
                // which can cause stuttering by aggressively skipping frames
                let snapshot = await frameQueue.snapshot()
                let lead = max(0.04, preferredLeadSeconds)
                let maxPTS = masterClock + CMTime(seconds: lead, preferredTimescale: 90_000)

                // If we have frames and the oldest is ready, dequeue it
                if let firstPTS = snapshot.firstPTSSeconds, firstPTS <= maxPTS.seconds {
                    guard let dequeued = await frameQueue.dequeue() else { break }
                    frame = dequeued
                } else if snapshot.count > 0 {
                    // Frame not yet ready, wait a bit
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    continue
                } else {
                    // Queue empty, wait for frame
                    guard let dequeued = await frameQueue.dequeue() else { break }
                    frame = dequeued
                }
            } else {
                guard let dequeued = await frameQueue.dequeue() else { break }
                frame = dequeued
            }
            if Task.isCancelled { return }
            do {
                #if DEBUG
                let audioClockNow = await masterClockProvider()
                let framePTS_sec = frame.pts.seconds
                let audioPTS_sec = audioClockNow?.seconds ?? -1
                let queueSnapshot = await frameQueue.snapshot()
                if renderedVideoFrameCount < 10 || renderedVideoFrameCount % 60 == 0 {
                    print("[SVP][VideoPresent] framePTS=\(String(format: "%.3f", framePTS_sec)) audioPTS=\(String(format: "%.3f", audioPTS_sec)) lead=\(String(format: "%.3f", framePTS_sec - audioPTS_sec)) queueCount=\(queueSnapshot.count)")
                }
                #endif
                if await shouldDropLateFrame(frame.pts) {
                    continue
                }
                try await pace(
                    framePTS: frame.pts,
                    masterClockProvider: masterClockProvider,
                    preferredLeadSeconds: preferredLeadSeconds
                )
                if !loggedFirstVideoFrame {
                    loggedFirstVideoFrame = true
                    diagnostics.log("first_video_frame pts=\(frame.pts.seconds)")
                }
                diagnostics.markFirstFrameRendered()
                if videoRenderStartUptime == nil {
                    videoRenderStartUptime = ProcessInfo.processInfo.systemUptime
                    videoRenderStartPTS = frame.pts
                }
                let renderStart = ProcessInfo.processInfo.systemUptime
                renderedVideoFrameCount += 1
                for output in outputs.values {
                    output.render(frame: frame)
                }
                let renderElapsedMs = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
                let queueWaitMs = frame.enqueuedUptime.map { (renderStart - $0) * 1000 } ?? 0
                let audioLeadMs: Double?
                if let masterClock = await masterClockProvider(), masterClock.isValid {
                    audioLeadMs = (frame.pts.seconds - masterClock.seconds) * 1000
                } else {
                    audioLeadMs = nil
                }
                if renderedVideoFrameCount == 1 || renderedVideoFrameCount % 60 == 0 {
                    await renderHealthLogger(
                        "video_render_\(renderedVideoFrameCount)",
                        frame.pts,
                        frame.decodeElapsedMs,
                        renderElapsedMs,
                        queueWaitMs,
                        audioLeadMs
                    )
                }
            } catch {
                if Task.isCancelled { return }
                diagnostics.log("video_present_drop error=\(String(describing: error))")
            }
        }
    }

    private func presentLiveFrames(
        from frameQueue: FrameQueue,
        shouldDropLateFrame: @escaping @Sendable (CMTime) async -> Bool,
        masterClockProvider: @escaping @Sendable () async -> CMTime?,
        preferredLeadSeconds: Double,
        renderHealthLogger: @escaping @Sendable (String, CMTime, Double, Double, Double, Double?) async -> Void
    ) async {
        var pendingFrame: DecodedVideoFrame?

        while !Task.isCancelled {
            if pendingFrame == nil {
                guard let dequeued = await frameQueue.dequeue() else { break }
                pendingFrame = dequeued
            }

            guard let frame = pendingFrame else { continue }

            do {
                if await shouldDropLateFrame(frame.pts) {
                    droppedLiveFrames += 1
                    if droppedLiveFrames == 1 || droppedLiveFrames % 30 == 0 {
                        diagnostics.log("video_live_drop count=\(droppedLiveFrames) latestPTS=\(String(format: "%.3f", frame.pts.seconds))")
                    }
                    pendingFrame = nil
                    continue
                }

                pendingFrame = nil
                try await paceLiveRelativeToAnchor(framePTS: frame.pts)
                try await render(
                    frame: frame,
                    masterClockProvider: masterClockProvider,
                    renderHealthLogger: renderHealthLogger
                )
            } catch {
                if Task.isCancelled { return }
                diagnostics.log("video_present_drop error=\(String(describing: error))")
                pendingFrame = nil
            }
        }
    }

    private func render(
        frame: DecodedVideoFrame,
        masterClockProvider: @escaping @Sendable () async -> CMTime?,
        renderHealthLogger: @escaping @Sendable (String, CMTime, Double, Double, Double, Double?) async -> Void
    ) async throws {
        if !loggedFirstVideoFrame {
            loggedFirstVideoFrame = true
            diagnostics.log("first_video_frame pts=\(frame.pts.seconds)")
        }
        diagnostics.markFirstFrameRendered()
        if videoRenderStartUptime == nil {
            videoRenderStartUptime = ProcessInfo.processInfo.systemUptime
            videoRenderStartPTS = frame.pts
        }
        let renderStart = ProcessInfo.processInfo.systemUptime
        renderedVideoFrameCount += 1
        for output in outputs.values {
            output.render(frame: frame)
        }
        let renderElapsedMs = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
        let queueWaitMs = frame.enqueuedUptime.map { (renderStart - $0) * 1000 } ?? 0
        let audioLeadMs: Double?
        if let masterClock = await masterClockProvider(), masterClock.isValid {
            audioLeadMs = (frame.pts.seconds - masterClock.seconds) * 1000
        } else {
            audioLeadMs = nil
        }
        if renderedVideoFrameCount == 1 || renderedVideoFrameCount % 60 == 0 {
            await renderHealthLogger(
                "video_render_\(renderedVideoFrameCount)",
                frame.pts,
                frame.decodeElapsedMs,
                renderElapsedMs,
                queueWaitMs,
                audioLeadMs
            )
        }
        lastRenderedVideoPTS = frame.pts
        lastRenderedVideoUptime = ProcessInfo.processInfo.systemUptime
    }

    private func paceLiveRelativeToAnchor(framePTS: CMTime) async throws {
        guard framePTS.isValid else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard let anchorPTS = videoTimelineAnchorPTS, let anchorUptime = videoTimelineAnchorUptime else {
            videoTimelineAnchorPTS = framePTS
            videoTimelineAnchorUptime = now
            return
        }

        let mediaOffset = framePTS.seconds - anchorPTS.seconds
        guard mediaOffset > 0.001, mediaOffset < 30 else { return }

        let targetUptime = anchorUptime + mediaOffset
        let sleepSeconds = targetUptime - now
        if sleepSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

    private func pace(
        framePTS: CMTime,
        masterClockProvider: @escaping @Sendable () async -> CMTime?,
        preferredLeadSeconds: Double
    ) async throws {
        guard framePTS.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime

        let targetLead = max(0, preferredLeadSeconds)
        if targetLead > 0 {
            while !Task.isCancelled {
                guard let masterClock = await masterClockProvider(), masterClock.isValid else {
                    // Audio clock not available yet - skip pacing and render immediately
                    // This prevents deadlock when audio hasn't started playing (pre-buffer period)
                    break
                }
                let lead = framePTS.seconds - masterClock.seconds
                let sleepSeconds = lead - targetLead
                if sleepSeconds <= 0.01 {
                    break
                }
                let boundedSleep = min(0.02, sleepSeconds)
                try await Task.sleep(nanoseconds: UInt64(boundedSleep * 1_000_000_000))
            }
            lastRenderedVideoPTS = framePTS
            lastRenderedVideoUptime = ProcessInfo.processInfo.systemUptime
            return
        }

        guard let anchorPTS = videoTimelineAnchorPTS, let anchorUptime = videoTimelineAnchorUptime else {
            videoTimelineAnchorPTS = framePTS
            videoTimelineAnchorUptime = now
            lastRenderedVideoPTS = framePTS
            lastRenderedVideoUptime = now
            return
        }

        if let lastPTS = lastRenderedVideoPTS, let lastUptime = lastRenderedVideoUptime {
            let interval = framePTS.seconds - lastPTS.seconds
            if interval > 0.001, interval < 0.25 {
                let relativeTarget = lastUptime + interval
                let absoluteTarget = anchorUptime + max(0, framePTS.seconds - anchorPTS.seconds)
                let targetUptime = max(relativeTarget, absoluteTarget)
                let sleepSeconds = targetUptime - now
                if sleepSeconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                }
            }
        } else {
            let targetUptime = anchorUptime + max(0, framePTS.seconds - anchorPTS.seconds)
            let sleepSeconds = targetUptime - now
            if sleepSeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }

        lastRenderedVideoPTS = framePTS
        lastRenderedVideoUptime = ProcessInfo.processInfo.systemUptime
    }
}

private enum PlaybackSessionError: Error, Sendable {
    case renderOutputMissing
}

extension PlaybackSessionError: PlaybackCategorizedError {
    var playbackErrorCategory: PlaybackErrorCategory {
        switch self {
        case .renderOutputMissing:
            return .render
        }
    }
}
