import Audio
import CoreMedia
import Decode
import Demux
import Input
import PlayerCore
import Render

public actor Player: PlayerEngine {
    private let session: PlaybackSession
    private let defaultAudioRenderer: AudioRenderer

    public init(source: any InputSource, preferHardwareDecode: Bool = true) {
        let demux = Self.makeDemuxEngine(for: source)
        let video = DefaultVideoPipeline(preferHardware: preferHardwareDecode)
        let audio = DefaultAudioPipeline()
        self.defaultAudioRenderer = AudioRenderer()
        self.session = PlaybackSession(demuxer: demux, videoPipeline: video, audioPipeline: audio)
        let session = self.session
        let defaultAudioRenderer = self.defaultAudioRenderer
        Task {
            await session.attachAudioOutput(defaultAudioRenderer)
        }
    }

    public func load(_ source: PlayableSource) async throws {
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
        }
    }

    private static func isTransportStreamURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ts" || ext == "m2ts"
    }
}
