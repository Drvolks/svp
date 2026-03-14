import Audio
import CoreMedia
import Decode
import Demux
import Input
import OSLog
import PlayerCore
import Render

public actor Player: PlayerEngine {
    private let session: PlaybackSession
    private let log = Logger(subsystem: "com.drvolks.svp", category: "Player")
    private let defaultAudioRenderer: AudioRenderer
    private let sourceKindOverrideForLoad: SourceKind?

    public init(source: any InputSource, preferHardwareDecode: Bool = true) {
        let demux = Self.makeDemuxEngine(for: source)
        let video = DefaultVideoPipeline(preferHardware: preferHardwareDecode)
        let audio = DefaultAudioPipeline()
        self.defaultAudioRenderer = AudioRenderer()
        self.sourceKindOverrideForLoad = nil
        self.session = PlaybackSession(demuxer: demux, videoPipeline: video, audioPipeline: audio)
        let session = self.session
        let defaultAudioRenderer = self.defaultAudioRenderer
        Task {
            await session.attachAudioOutput(defaultAudioRenderer)
        }
    }

    public init(videoSource: any InputSource, audioSource: any InputSource, preferHardwareDecode: Bool = true) {
        let videoKind = videoSource.descriptor.kind
        let audioKind = audioSource.descriptor.kind
        let coalescedKind = Self.sameUnderlyingAsset(videoKind, audioKind)
            ? videoKind
            : nil
        let demux: any DemuxEngine

        log.debug("[SVP][Player] init dual: videoKind=\(String(describing: videoKind)) audioKind=\(String(describing: audioKind)) sameUnderlying=\(coalescedKind != nil)")

        if coalescedKind != nil {
            log.debug("[SVP][Player] using single demux (same underlying)")
            demux = Self.makeDemuxEngine(for: videoSource)
        } else if let videoURL = Self.extractURL(from: videoKind),
                  let audioURL = Self.extractURL(from: audioKind) {
            log.debug("[SVP][Player] using unified FFmpegDemuxAdapter: video=\(videoURL) audio=\(audioURL)")
            demux = FFmpegDemuxAdapter(videoURL: videoURL, audioURL: audioURL)
        } else {
            log.debug("[SVP][Player] using SplitAVInputSource path")
            let compositeSource = SplitAVInputSource(videoSource: videoSource, audioSource: audioSource)
            demux = Self.makeDemuxEngine(for: compositeSource)
        }
        let video = DefaultVideoPipeline(preferHardware: preferHardwareDecode)
        let audio = DefaultAudioPipeline()
        self.defaultAudioRenderer = AudioRenderer()
        self.sourceKindOverrideForLoad = coalescedKind
        self.session = PlaybackSession(demuxer: demux, videoPipeline: video, audioPipeline: audio)
        let session = self.session
        let defaultAudioRenderer = self.defaultAudioRenderer
        Task {
            await session.attachAudioOutput(defaultAudioRenderer)
        }
    }

    private static func extractURL(from kind: SourceKind) -> URL? {
        switch kind {
        case .file(let url):
            return url
        case .network(let url):
            return url
        case .liveTS(let url):
            return url
        case .segmented(let urls):
            return urls.first
        case .split:
            return nil
        }
    }

    public func load(_ source: PlayableSource) async throws {
        if let kindOverride = sourceKindOverrideForLoad,
           case .split = source.descriptor.kind {
            let normalized = PlayableSource(
                descriptor: MediaSourceDescriptor(
                    kind: kindOverride,
                    isLive: source.descriptor.isLive,
                    streams: source.descriptor.streams,
                    preferredClock: source.descriptor.preferredClock
                )
            )
            try await session.load(normalized)
            return
        }
        try await session.load(source)
    }

    public func play() async {
        await session.play()
    }

    public func pause() async {
        await session.pause()
    }

    public func seek(to time: CMTime) async throws {
        try await session.seek(to: time)
    }

    public func attachVideoOutput(_ output: any VideoOutput) async {
        await session.attachVideoOutput(output)
    }

    public func detachVideoOutput(_ output: any VideoOutput) async {
        await session.detachVideoOutput(output)
    }

    public func attachAudioOutput(_ output: any AudioOutput) async {
        await session.attachAudioOutput(output)
    }

    public func detachAudioOutput(_ output: any AudioOutput) async {
        await session.detachAudioOutput(output)
    }

    public func playbackEvents() async -> AsyncStream<PlaybackEvent> {
        await session.playbackEvents()
    }

    public func currentPosition() async -> CMTime {
        await session.currentPosition()
    }

    public func currentDuration() async -> CMTime? {
        await session.currentDuration()
    }

    public func playbackMetrics() async -> PlaybackMetrics {
        await session.playbackMetrics()
    }

    private static func makeDemuxEngine(for source: any InputSource) -> any DemuxEngine {
        if let splitSource = source as? any SplitInputSource {
            let videoDemux = makeDemuxEngine(for: splitSource.videoSource)
            let audioDemux = makeDemuxEngine(for: splitSource.audioSource)
            return SplitAVDemuxEngine(videoDemuxer: videoDemux, audioDemuxer: audioDemux)
        }
        switch source.descriptor.kind {
        case .liveTS:
            return BasicDemuxEngine(source: source)
        case .segmented:
            return BasicDemuxEngine(source: source)
        case .file(let url):
            if isTransportStreamURL(url) {
                return BasicDemuxEngine(source: source)
            }
            return FFmpegDemuxAdapter(url: url)
        case .network(let url):
            if isTransportStreamURL(url) {
                return BasicDemuxEngine(source: source)
            }
            return FFmpegDemuxAdapter(url: url)
        case .split:
            fatalError("Split sources should be handled before switching on descriptor.kind")
        }
    }

    private static func isTransportStreamURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ts" || ext == "m2ts"
    }

    private static func sameUnderlyingAsset(_ lhs: SourceKind, _ rhs: SourceKind) -> Bool {
        switch (lhs, rhs) {
        case let (.file(l), .file(r)):
            return l == r
        case let (.network(l), .network(r)):
            return l == r
        case let (.liveTS(l), .liveTS(r)):
            return l == r
        case let (.segmented(l), .segmented(r)):
            return l == r
        case let (.split(video: lv, audio: la), .split(video: rv, audio: ra)):
            return sameUnderlyingAsset(lv, rv) && sameUnderlyingAsset(la, ra)
        default:
            return false
        }
    }
}
