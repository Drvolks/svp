import CoreMedia
import Foundation
import Input
import OSLog
import PlayerCore

public actor SplitAVDemuxEngine: PlayerCore.DemuxEngine {
    private let videoDemuxer: any DemuxEngine
    private let audioDemuxer: any DemuxEngine
    private let videoStreamIDOffset = 1_000
    private let audioStreamIDOffset = 2_000
    private var mergeGeneration: UInt64 = 0

    private let log = Logger(subsystem: "com.drvolks.svp", category: "SplitDemux")

    public init(videoDemuxer: any DemuxEngine, audioDemuxer: any DemuxEngine) {
        self.videoDemuxer = videoDemuxer
        self.audioDemuxer = audioDemuxer
    }

    public func makePacketStream() -> AsyncThrowingStream<DemuxedPacket, Error> {
        mergeGeneration &+= 1
        let generation = mergeGeneration
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var commonBaseline: Int64?
                var pendingVideoPTS: Int64?
                var pendingAudioPTS: Int64?
                var lastVideoNormalizedPTS: Int64?
                var lastAudioNormalizedPTS: Int64?
                var forwardedVideoPackets = 0
                var forwardedAudioPackets = 0

                func logFirstPTS() {
                    // Logging disabled - baseline is logged in establishCommonBaseline
                }

                func establishCommonBaseline(_ packet: DemuxedPacket, isVideo: Bool) {
                    // Once baseline is established, never change it
                    guard commonBaseline == nil else { return }

                    let packetPTS = packet.pts ?? packet.dts ?? 0

                    if isVideo {
                        pendingVideoPTS = packetPTS
                    } else {
                        pendingAudioPTS = packetPTS
                    }

                    // Wait until we have packets from both streams before establishing baseline
                    guard let videoPTS = pendingVideoPTS, let audioPTS = pendingAudioPTS else {
                        return
                    }

                    // Use the minimum as baseline (earliest packet in timeline)
                    commonBaseline = min(videoPTS, audioPTS)
                    let b_sec = Double(commonBaseline!) / 90000.0
                    log.debug("[SVP][SplitDemux] baseline=\(String(format: "%.3f", b_sec)) video=\(Double(videoPTS)/90000.0) audio=\(Double(audioPTS)/90000.0)")
                }

                func isVideoPacket(_ packet: DemuxedPacket) -> Bool {
                    switch packet.formatHint {
                    case .h264, .hevc, .av1, .vp9:
                        return true
                    default:
                        return false
                    }
                }

                func isAudioPacket(_ packet: DemuxedPacket) -> Bool {
                    switch packet.formatHint {
                    case .aac, .ac3, .eac3, .opus:
                        return true
                    default:
                        return false
                    }
                }

                func normalize(_ packet: DemuxedPacket, isVideo: Bool, streamIDOffset: Int) -> DemuxedPacket {
                    establishCommonBaseline(packet, isVideo: isVideo)
                    let baseline = commonBaseline ?? packet.pts ?? packet.dts ?? 0
                    let normalizedPTS = packet.pts.map { max(0, $0 - baseline) }
                    let normalizedDTS = packet.dts.map { max(0, $0 - baseline) }
                    if forwardedVideoPackets == 1 || forwardedAudioPackets == 1 {
                        log.debug("[SVP][SplitDemux] normalize origPts=\(String(describing: packet.pts)) normalized=\(String(describing: normalizedPTS)) baseline=\(baseline)")
                    }
                    return DemuxedPacket(
                        streamID: StreamID(packet.streamID.rawValue + streamIDOffset),
                        pts: normalizedPTS,
                        dts: normalizedDTS,
                        duration: packet.duration,
                        data: packet.data,
                        codecConfig: packet.codecConfig,
                        sideData: packet.sideData,
                        sideDataType: packet.sideDataType,
                        isKeyframe: packet.isKeyframe,
                        formatHint: packet.formatHint
                    )
                }

                func normalizeWithFallback(
                    _ packet: DemuxedPacket,
                    isVideo: Bool,
                    lastPTS: inout Int64?,
                    streamIDOffset: Int,
                    defaultStep90k: Int64
                ) -> DemuxedPacket {
                    let normalized = normalize(packet, isVideo: isVideo, streamIDOffset: streamIDOffset)
                    var pts = normalized.pts
                    var dts = normalized.dts

                    if pts == nil && dts == nil {
                        let step = max(1, normalized.duration ?? defaultStep90k)
                        if let lastPTS {
                            pts = lastPTS + step
                            dts = pts
                        } else {
                            pts = 0
                            dts = 0
                        }
                    } else if pts == nil {
                        pts = dts
                    } else if dts == nil {
                        dts = pts
                    }

                    if let pts {
                        lastPTS = pts
                    } else if let dts {
                        lastPTS = dts
                    }

                    return DemuxedPacket(
                        streamID: normalized.streamID,
                        pts: pts,
                        dts: dts,
                        duration: normalized.duration,
                        data: normalized.data,
                        codecConfig: normalized.codecConfig,
                        sideData: normalized.sideData,
                        sideDataType: normalized.sideDataType,
                        isKeyframe: normalized.isKeyframe,
                        formatHint: normalized.formatHint
                    )
                }

                func packetTimestamp(_ packet: DemuxedPacket) -> Int64 {
                    packet.pts ?? packet.dts ?? .max
                }

                func nextFilteredVideo(
                    _ iterator: inout AsyncThrowingStream<DemuxedPacket, Error>.AsyncIterator
                ) async throws -> DemuxedPacket? {
                    while true {
                        guard await self.isMergeGenerationCurrent(generation) else {
                            return nil
                        }
                        guard let packet = try await iterator.next() else {
                            if await self.isMergeGenerationCurrent(generation) {
                                log.debug("[SVP][SplitDemux] video_eof forwarded=\(forwardedVideoPackets)")
                            }
                            return nil
                        }
                        guard isVideoPacket(packet) else { continue }
                        let normalized = normalizeWithFallback(
                            packet,
                            isVideo: true,
                            lastPTS: &lastVideoNormalizedPTS,
                            streamIDOffset: videoStreamIDOffset,
                            defaultStep90k: 3_003
                        )
                        forwardedVideoPackets += 1
                        if forwardedVideoPackets == 1 || forwardedVideoPackets % 300 == 0 {
                            log.debug("[SVP][SplitDemux] video_forward count=\(forwardedVideoPackets) pts=\(String(describing: normalized.pts))")
                        }
                        if forwardedVideoPackets == 1 {
                            logFirstPTS()
                        }
                        return normalized
                    }
                }

                func nextFilteredAudio(
                    _ iterator: inout AsyncThrowingStream<DemuxedPacket, Error>.AsyncIterator
                ) async throws -> DemuxedPacket? {
                    while true {
                        guard await self.isMergeGenerationCurrent(generation) else {
                            return nil
                        }
                        guard let packet = try await iterator.next() else {
                            if await self.isMergeGenerationCurrent(generation) {
                                log.debug("[SVP][SplitDemux] audio_eof forwarded=\(forwardedAudioPackets)")
                            }
                            return nil
                        }
                        guard isAudioPacket(packet) else { continue }
                        let normalized = normalizeWithFallback(
                            packet,
                            isVideo: false,
                            lastPTS: &lastAudioNormalizedPTS,
                            streamIDOffset: audioStreamIDOffset,
                            defaultStep90k: 2_088
                        )
                        forwardedAudioPackets += 1
                        if forwardedAudioPackets == 1 || forwardedAudioPackets % 300 == 0 {
                            log.debug("[SVP][SplitDemux] audio_forward count=\(forwardedAudioPackets) pts=\(String(describing: normalized.pts))")
                        }
                        if forwardedAudioPackets == 1 {
                            logFirstPTS()
                        }
                        return normalized
                    }
                }

                do {
                    guard await self.isMergeGenerationCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    let videoStream = await videoDemuxer.makePacketStream()
                    let audioStream = await audioDemuxer.makePacketStream()
                    var videoIterator = videoStream.makeAsyncIterator()
                    var audioIterator = audioStream.makeAsyncIterator()
                    var nextVideo = try await nextFilteredVideo(&videoIterator)
                    var nextAudio = try await nextFilteredAudio(&audioIterator)

                    while !Task.isCancelled {
                        guard await self.isMergeGenerationCurrent(generation) else {
                            continuation.finish()
                            return
                        }
                        switch (nextVideo, nextAudio) {
                        case let (video?, audio?):
                            if packetTimestamp(video) <= packetTimestamp(audio) {
                                continuation.yield(video)
                                nextVideo = try await nextFilteredVideo(&videoIterator)
                            } else {
                                continuation.yield(audio)
                                nextAudio = try await nextFilteredAudio(&audioIterator)
                            }
                        case let (video?, nil):
                            continuation.yield(video)
                            nextVideo = try await nextFilteredVideo(&videoIterator)
                        case let (nil, audio?):
                            continuation.yield(audio)
                            nextAudio = try await nextFilteredAudio(&audioIterator)
                        case (nil, nil):
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    if await self.isMergeGenerationCurrent(generation) {
                        log.debug("[SVP][SplitDemux] merge_error \(error)")
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func isMergeGenerationCurrent(_ generation: UInt64) -> Bool {
        generation == mergeGeneration
    }

    public func seek(to: CMTime) async throws {
        try await videoDemuxer.seek(to: to)
        try await audioDemuxer.seek(to: to)
    }

    public func duration() async -> CMTime? {
        let videoDuration = await videoDemuxer.duration()
        let audioDuration = await audioDemuxer.duration()

        switch (videoDuration, audioDuration) {
        case let (lhs?, rhs?):
            return lhs.seconds >= rhs.seconds ? lhs : rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }
}
