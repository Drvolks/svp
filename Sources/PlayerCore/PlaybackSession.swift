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
    func decode(packet: DemuxedPacket) async throws -> DecodedAudioFrame?
    func flush() async
}

public actor PlaybackSession: PlayerEngine {
    public let clock: MediaClock
    private let demuxer: any DemuxEngine
    private let videoPipeline: any VideoPipeline
    private let audioPipeline: any AudioPipeline
    private var playTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var videoPacketTask: Task<Void, Never>?
    private var videoPacketContinuation: AsyncStream<DemuxedPacket>.Continuation?
    private var state: PlaybackState = .idle
    private var videoOutputs: [ObjectIdentifier: any VideoOutput] = [:]
    private var audioOutputs: [ObjectIdentifier: any AudioOutput] = [:]
    private let audioSynchronizer = AudioSynchronizerAdapter()
    private var lastAudioPTS: CMTime?
    private var lastPacketUptime: TimeInterval = 0
    private let rebufferThreshold: TimeInterval = 0.8
    private var eventContinuations: [UUID: AsyncStream<PlaybackEvent>.Continuation] = [:]
    private var knownDuration: CMTime?
    private let diagnostics = PlaybackDiagnostics()
    private var packetCount: Int = 0
    private var loggedFirstVideoFrame = false
    private var loggedFirstAudioFrame = false
    private var lastRenderedVideoPTS: CMTime?
    private var lastRenderedVideoUptime: TimeInterval?

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
    }

    public func load(_ source: PlayableSource) async throws {
        _ = source
        stopPlaybackTasks()
        packetCount = 0
        loggedFirstVideoFrame = false
        loggedFirstAudioFrame = false
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
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
        guard playTask == nil else { return }
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
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorForStalls()
        }
        startVideoPacketLoopIfNeeded()
        playTask = Task { [weak self] in
            guard let self else { return }
            await self.consumePackets()
        }
    }

    public func pause() async {
        diagnostics.log("pause_requested")
        stopPlaybackTasks()
        clock.pause()
        setState(.paused)
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handlePause()
        }
    }

    public func seek(to time: CMTime) async throws {
        let resumeAfterSeek = playTask != nil
        diagnostics.log("seek_requested_seconds=\(time.seconds)")
        stopPlaybackTasks()
        clock.seek(to: time)
        setState(resumeAfterSeek ? .buffering : .paused)
        try await demuxer.seek(to: time)
        await videoPipeline.flush()
        await audioPipeline.flush()
        lastAudioPTS = nil
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        lastPacketUptime = ProcessInfo.processInfo.systemUptime
        for output in videoOutputs.values {
            (output as? any VideoOutputLifecycle)?.handleDiscontinuity()
        }
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handleDiscontinuity()
        }
        if resumeAfterSeek {
            await play()
        }
    }

    public func attachVideoOutput(_ output: any VideoOutput) async {
        videoOutputs[ObjectIdentifier(output)] = output
    }

    public func detachVideoOutput(_ output: any VideoOutput) async {
        videoOutputs.removeValue(forKey: ObjectIdentifier(output))
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

    private func consumePackets() async {
        do {
            diagnostics.log("packet_consumer_started")
            let stream = await demuxer.makePacketStream()
            for try await packet in stream {
                if Task.isCancelled { break }
                packetCount += 1
                if packetCount == 1 || packetCount % 100 == 0 {
                    diagnostics.log("packet_received count=\(packetCount) codec=\(packet.formatHint) pts=\(String(describing: packet.pts)) size=\(packet.data.count)")
                }
                lastPacketUptime = ProcessInfo.processInfo.systemUptime
                emitEvent(.progress(position: clock.currentTime(), duration: knownDuration))
                if case .buffering = state {
                    setState(.playing)
                    diagnostics.log("playback_recovered")
                    emitEvent(.recovered)
                }
                switch packet.formatHint {
                case .h264, .hevc:
                    enqueueVideoPacket(packet)
                case .aac, .ac3, .eac3, .opus:
                    if let frame = try await audioPipeline.decode(packet: packet) {
                        if !loggedFirstAudioFrame {
                            loggedFirstAudioFrame = true
                            diagnostics.log("first_audio_frame pts=\(frame.pts.seconds)")
                        }
                        syncAudioMasterClock(with: frame.pts)
                        for output in audioOutputs.values {
                            output.render(frame: frame)
                        }
                    }
                case .unknown:
                    continue
                }
            }
            if Task.isCancelled {
                return
            }
            diagnostics.log("packet_stream_ended")
            setState(.ended)
            emitEvent(.ended)
        } catch {
            let playerError = makePlayerError(from: error)
            let description = describe(playerError)
            diagnostics.incrementDecodeFailure()
            diagnostics.log("playback_error: \(description)")
            setState(.failed(description))
            emitEvent(.error(description))
        }
    }

    private func monitorForStalls() async {
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            let stalled = now - lastPacketUptime > rebufferThreshold
            if stalled, case .playing = state {
                setState(.buffering)
                diagnostics.incrementRebuffer()
                diagnostics.log("playback_stalled")
                emitEvent(.stalled)
            }
            emitEvent(.progress(position: clock.currentTime(), duration: knownDuration))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
        lastRenderedVideoPTS = nil
        lastRenderedVideoUptime = nil
        packetCount = 0
        loggedFirstVideoFrame = false
        loggedFirstAudioFrame = false
        for output in videoOutputs.values {
            (output as? any VideoOutputLifecycle)?.handleDiscontinuity()
        }
        for output in audioOutputs.values {
            (output as? any AudioOutputLifecycle)?.handleDiscontinuity()
        }
        setState(.ready)
    }

    private func paceVideoIfNeeded(framePTS: CMTime) async throws {
        guard framePTS.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime

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

    private func stopPlaybackTasks() {
        playTask?.cancel()
        playTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        videoPacketContinuation?.finish()
        videoPacketContinuation = nil
        videoPacketTask?.cancel()
        videoPacketTask = nil
    }

    private func startVideoPacketLoopIfNeeded() {
        guard videoPacketTask == nil else { return }
        // Do not drop compressed video packets: dropping inter-frames causes visible artifacts.
        let stream = AsyncStream<DemuxedPacket>(bufferingPolicy: .unbounded) { continuation in
            self.videoPacketContinuation = continuation
        }
        videoPacketTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeVideoPackets(stream: stream)
        }
    }

    private func enqueueVideoPacket(_ packet: DemuxedPacket) {
        videoPacketContinuation?.yield(packet)
    }

    private func consumeVideoPackets(stream: AsyncStream<DemuxedPacket>) async {
        do {
            for await packet in stream {
                if Task.isCancelled { return }
                if let frame = try await videoPipeline.decode(packet: packet) {
                    guard frame.pixelBuffer != nil else {
                        throw PlaybackSessionError.renderOutputMissing
                    }
                    try await paceVideoIfNeeded(framePTS: frame.pts)
                    if !loggedFirstVideoFrame {
                        loggedFirstVideoFrame = true
                        diagnostics.log("first_video_frame pts=\(frame.pts.seconds)")
                    }
                    diagnostics.markFirstFrameRendered()
                    for output in videoOutputs.values {
                        output.render(frame: frame)
                    }
                }
            }
        } catch {
            if Task.isCancelled { return }
            let playerError = makePlayerError(from: error)
            let description = describe(playerError)
            diagnostics.incrementDecodeFailure()
            diagnostics.log("video_processing_error: \(description)")
            setState(.failed(description))
            emitEvent(.error(description))
        }
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
