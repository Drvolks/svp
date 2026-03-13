import CoreMedia
import Foundation

public indirect enum SourceKind: Sendable {
    case file(URL)
    case network(URL)
    case liveTS(URL)
    case segmented([URL])
    case split(video: SourceKind, audio: SourceKind)
}

public enum StreamKind: Sendable {
    case video
    case audio
    case subtitle
}

public struct StreamID: Hashable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

public enum CodecID: Sendable {
    case h264
    case hevc
    case av1
    case vp9
    case aac
    case ac3
    case eac3
    case opus
    case unknown
}

public enum ClockKind: Sendable {
    case audio
    case video
    case external
}

public struct StreamDescriptor: Sendable {
    public let id: StreamID
    public let kind: StreamKind
    public let codec: CodecID

    public init(id: StreamID, kind: StreamKind, codec: CodecID) {
        self.id = id
        self.kind = kind
        self.codec = codec
    }
}

public struct MediaSourceDescriptor: Sendable {
    public let kind: SourceKind
    public let isLive: Bool
    public let streams: [StreamDescriptor]
    public let preferredClock: ClockKind

    public init(kind: SourceKind, isLive: Bool, streams: [StreamDescriptor], preferredClock: ClockKind) {
        self.kind = kind
        self.isLive = isLive
        self.streams = streams
        self.preferredClock = preferredClock
    }
}

public struct PlayableSource: Sendable {
    public let descriptor: MediaSourceDescriptor

    public init(descriptor: MediaSourceDescriptor) {
        self.descriptor = descriptor
    }
}

public struct DemuxedPacket: Sendable {
    public let streamID: StreamID
    public let pts: Int64?
    public let dts: Int64?
    public let duration: Int64?
    public let data: Data
    public let codecConfig: Data?
    public let sideData: Data?
    public let sideDataType: Int32?
    public let isKeyframe: Bool
    public let formatHint: CodecID

    public init(
        streamID: StreamID,
        pts: Int64?,
        dts: Int64?,
        duration: Int64?,
        data: Data,
        codecConfig: Data? = nil,
        sideData: Data? = nil,
        sideDataType: Int32? = nil,
        isKeyframe: Bool,
        formatHint: CodecID
    ) {
        self.streamID = streamID
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.data = data
        self.codecConfig = codecConfig
        self.sideData = sideData
        self.sideDataType = sideDataType
        self.isKeyframe = isKeyframe
        self.formatHint = formatHint
    }
}

public struct ColorInfo: Sendable {
    public static let unknown = ColorInfo()
    public init() {}
}

public struct DecodedVideoFrame: @unchecked Sendable {
    public let pts: CMTime
    public let pixelBuffer: CVPixelBuffer?
    public let opaqueDecoderPayload: OpaquePointer?
    public let colorInfo: ColorInfo
    public let decodeElapsedMs: Double
    public let enqueuedUptime: TimeInterval?

    public init(
        pts: CMTime,
        pixelBuffer: CVPixelBuffer?,
        opaqueDecoderPayload: OpaquePointer? = nil,
        colorInfo: ColorInfo = .unknown,
        decodeElapsedMs: Double = 0,
        enqueuedUptime: TimeInterval? = nil
    ) {
        self.pts = pts
        self.pixelBuffer = pixelBuffer
        self.opaqueDecoderPayload = opaqueDecoderPayload
        self.colorInfo = colorInfo
        self.decodeElapsedMs = decodeElapsedMs
        self.enqueuedUptime = enqueuedUptime
    }
}

public struct DecodedAudioFrame: Sendable {
    public let pts: CMTime
    public let sampleRate: Double
    public let channels: Int
    public let data: Data

    public init(pts: CMTime, sampleRate: Double, channels: Int, data: Data) {
        self.pts = pts
        self.sampleRate = sampleRate
        self.channels = channels
        self.data = data
    }
}

public enum PlaybackState: Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

public enum PlaybackEvent: Sendable {
    case stateChanged(PlaybackState)
    case progress(position: CMTime, duration: CMTime?)
    case stalled
    case recovered
    case ended
    case error(String)
}

public enum PlaybackErrorCategory: Sendable {
    case sourceOpen
    case demux
    case decode
    case render
    case audio
    case unknown
}

public protocol PlaybackCategorizedError: Error, Sendable {
    var playbackErrorCategory: PlaybackErrorCategory { get }
}

public enum PlayerError: Error, Sendable {
    case sourceOpen(String)
    case demux(String)
    case decode(String)
    case render(String)
    case audio(String)
    case unknown(String)
}

extension PlayerError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        switch self {
        case .sourceOpen:
            return .sourceOpen
        case .demux:
            return .demux
        case .decode:
            return .decode
        case .render:
            return .render
        case .audio:
            return .audio
        case .unknown:
            return .unknown
        }
    }
}

public protocol VideoOutput: AnyObject, Sendable {
    func render(frame: DecodedVideoFrame)
}

public protocol VideoOutputLifecycle: AnyObject, Sendable {
    func handleDiscontinuity()
}

public protocol AudioOutput: AnyObject, Sendable {
    func render(frame: DecodedAudioFrame)
}

public protocol AudioPlaybackClockProviding: AnyObject, Sendable {
    func currentPlaybackTime() -> CMTime?
}

public protocol AudioOutputSourceConfigurable: AnyObject, Sendable {
    func configure(for descriptor: MediaSourceDescriptor)
}

public protocol AudioOutputLifecycle: AnyObject, Sendable {
    func handlePlay()
    func handlePause()
    func handleDiscontinuity()
}

public protocol PlayerEngine: Actor {
    func load(_ source: PlayableSource) async throws
    func play() async
    func pause() async
    func seek(to time: CMTime) async throws
    func attachVideoOutput(_ output: VideoOutput) async
    func detachVideoOutput(_ output: VideoOutput) async
    func attachAudioOutput(_ output: AudioOutput) async
    func detachAudioOutput(_ output: AudioOutput) async
    func playbackEvents() async -> AsyncStream<PlaybackEvent>
    func currentPosition() async -> CMTime
    func currentDuration() async -> CMTime?
    func playbackMetrics() async -> PlaybackMetrics
}
