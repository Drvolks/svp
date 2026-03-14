import CoreMedia
import FFmpegBridge
import Foundation
import PlayerCore

public enum FFmpegDemuxError: Error, Sendable {
    case openFailed(reason: String)
    case streamInfoFailed(Int32)
    case readFailed(Int32)
    case seekFailed(Int32)
}

extension FFmpegDemuxError: PlaybackCategorizedError {
    public var playbackErrorCategory: PlaybackErrorCategory {
        .demux
    }
}

public actor FFmpegDemuxAdapter: PlayerCore.DemuxEngine {
    private static let buildStamp = "SVP_LOCAL_2026-03-13T19:45"
    private static let reorderBufferSize = 8
    private let url: URL?
    private let videoURL: URL?
    private let audioURL: URL?
    private let isMultiInput: Bool
    private let handleBox = FFmpegDemuxerHandleBox()
    private var streamInfoByIndex: [Int32: svp_ffmpeg_stream_info_t] = [:]
    private var streamCodecConfigByIndex: [Int32: Data] = [:]
    private var loggedFirstPacket = false
    private var packetStreamGeneration: UInt64 = 0
    // Reordering buffer to handle out-of-order packets from FFmpeg
    private var reorderBuffer: [DemuxedPacket] = []

    public init(url: URL) {
        self.url = url
        self.videoURL = nil
        self.audioURL = nil
        self.isMultiInput = false
    }

    public init(videoURL: URL, audioURL: URL) {
        self.url = nil
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.isMultiInput = true
    }

    public func makePacketStream() -> AsyncThrowingStream<DemuxedPacket, Error> {
        packetStreamGeneration &+= 1
        let generation = packetStreamGeneration
        let bufferSize = Self.reorderBufferSizeStatic
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                // Clear reorder buffer from previous stream
                await self.clearReorderBuffer()
                do {
                    try await self.openIfNeeded()
                    guard await self.isPacketStreamGenerationCurrent(generation) else {
                        continuation.finish()
                        return
                    }
                    await self.log("packet_stream_started")
                    var eofReached = false

                    while !Task.isCancelled {
                        guard await self.isPacketStreamGenerationCurrent(generation) else {
                            continuation.finish()
                            return
                        }

                        // Fill the reorder buffer if not full and haven't reached EOF
                        var bufferCount = await self.getReorderBufferCount()
                        while !eofReached && bufferCount < bufferSize {
                            guard let handle = self.getHandle() else {
                                throw FFmpegDemuxError.openFailed(reason: "demux handle is nil after open")
                            }
                            var rawPacket = svp_ffmpeg_demuxed_packet_t()
                            let status: Int32
                            if self.isMultiInput {
                                status = svp_ffmpeg_multi_demuxer_read_packet(handle, &rawPacket)
                            } else {
                                status = svp_ffmpeg_demuxer_read_packet(handle, &rawPacket)
                            }
                            if status == 0 {
                                await self.log("packet_stream_eof")
                                eofReached = true
                                break
                            }
                            if status < 0 {
                                await self.log("read_packet_failed status=\(status)")
                                throw FFmpegDemuxError.readFailed(status)
                            }
                            let packetSize = rawPacket.size
                            let packetData: Data? = packetSize > 0 && rawPacket.data != nil
                                ? Data(bytes: rawPacket.data!, count: Int(packetSize)) : nil
                            let packetStreamIndex = rawPacket.streamIndex
                            let packetCodecID = rawPacket.codecID
                            let packetPTS = rawPacket.pts
                            let packetDTS = rawPacket.dts
                            let packetDuration = rawPacket.duration
                            let packetHasPTS = rawPacket.hasPTS
                            let packetHasDTS = rawPacket.hasDTS
                            let packetHasDuration = rawPacket.hasDuration
                            let packetIsKeyframe = rawPacket.isKeyframe
                            svp_ffmpeg_demuxed_packet_release(&rawPacket)
                            if let data = packetData, let packet = await self.makePacketFromData(
                                data: data,
                                streamIndex: packetStreamIndex,
                                codecID: packetCodecID,
                                pts: packetPTS,
                                dts: packetDTS,
                                duration: packetDuration,
                                hasPTS: packetHasPTS,
                                hasDTS: packetHasDTS,
                                hasDuration: packetHasDuration,
                                isKeyframe: packetIsKeyframe
                            ) {
                                await self.addToReorderBuffer(packet)
                            }
                            bufferCount = await self.getReorderBufferCount()
                        }

                        // Sort and release packets in PTS order
                        await self.sortReorderBuffer()
                        if let packet = await self.popFromReorderBuffer() {
                            guard await self.isPacketStreamGenerationCurrent(generation) else {
                                continuation.finish()
                                return
                            }
                            await self.logFirstPacketIfNeeded(packet)
                            continuation.yield(packet)
                        } else if eofReached {
                            // Buffer empty and EOF reached, we're done
                            continuation.finish()
                            return
                        } else {
                            // Buffer empty but not EOF, need to read more
                            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func seek(to: CMTime) async throws {
        try await openIfNeeded()
        guard let handle = handleBox.raw else {
            throw FFmpegDemuxError.openFailed(reason: "cannot seek because demux handle is nil")
        }
        let status = svp_ffmpeg_demuxer_seek_seconds(handle, to.seconds)
        guard status >= 0 else {
            throw FFmpegDemuxError.seekFailed(status)
        }
    }

    public func duration() async -> CMTime? {
        do {
            try await openIfNeeded()
            guard let handle = handleBox.raw else { return nil }
            let seconds = svp_ffmpeg_demuxer_duration_seconds(handle)
            guard seconds > 0 else { return nil }
            return CMTime(seconds: seconds, preferredTimescale: 600)
        } catch {
            return nil
        }
    }

    private func openIfNeeded() async throws {
        if handleBox.raw != nil {
            return
        }
        log("build_stamp=\(Self.buildStamp)")
        guard svp_ffmpeg_bridge_has_vendor_backend() == 1 else {
            throw FFmpegDemuxError.openFailed(reason: "vendor ffmpeg backend unavailable")
        }

        let created: UnsafeMutableRawPointer?
        if isMultiInput {
            guard let videoURL = videoURL, let audioURL = audioURL else {
                throw FFmpegDemuxError.openFailed(reason: "multi input missing URLs")
            }
            let videoPath = sourcePath(videoURL)
            let audioPath = sourcePath(audioURL)
            log("open_demux_multi video=\(videoPath) audio=\(audioPath)")
            created = videoPath.withCString { videoCStr in
                audioPath.withCString { audioCStr in
                    svp_ffmpeg_demuxer_create_multi(videoCStr, audioCStr)
                }
            }
            guard let created else {
                throw FFmpegDemuxError.openFailed(reason: "avformat open failed for multi input")
            }
        } else {
            guard let url = url else {
                throw FFmpegDemuxError.openFailed(reason: "single input missing URL")
            }
            let pathString = sourcePath(url)
            log("open_demux source=\(pathString)")
            created = pathString.withCString { svp_ffmpeg_demuxer_create($0) }
            guard let created else {
                throw FFmpegDemuxError.openFailed(
                    reason: "avformat open failed for source=\(pathString)"
                )
            }
        }
        handleBox.raw = created
        handleBox.isMultiInput = isMultiInput
        try loadStreamInfo()
        log("open_demux_ok stream_count=\(streamInfoByIndex.count)")
    }

    private func loadStreamInfo() throws {
        guard let handle = handleBox.raw else {
            throw FFmpegDemuxError.openFailed(reason: "stream info requested with nil handle")
        }
        let count: Int32
        if isMultiInput {
            count = svp_ffmpeg_multi_demuxer_stream_count(handle)
        } else {
            count = svp_ffmpeg_demuxer_stream_count(handle)
        }
        guard count >= 0 else {
            throw FFmpegDemuxError.streamInfoFailed(count)
        }
        var mapped: [Int32: svp_ffmpeg_stream_info_t] = [:]
        var codecConfigs: [Int32: Data] = [:]
        for index in 0..<count {
            var info = svp_ffmpeg_stream_info_t()
            let status: Int32
            if isMultiInput {
                status = svp_ffmpeg_multi_demuxer_stream_info(handle, index, &info)
            } else {
                status = svp_ffmpeg_demuxer_stream_info(handle, index, &info)
            }
            guard status == 0 else {
                throw FFmpegDemuxError.streamInfoFailed(status)
            }
            mapped[index] = info
            var codecConfig = svp_ffmpeg_codec_config_t()
            let configStatus: Int32
            if isMultiInput {
                configStatus = svp_ffmpeg_multi_demuxer_stream_codec_config(handle, index, &codecConfig)
            } else {
                configStatus = svp_ffmpeg_demuxer_stream_codec_config(handle, index, &codecConfig)
            }
            if configStatus > 0, let data = codecConfig.data, codecConfig.size > 0 {
                codecConfigs[index] = Data(bytes: data, count: Int(codecConfig.size))
            }
            svp_ffmpeg_codec_config_release(&codecConfig)
        }
        streamInfoByIndex = mapped
        streamCodecConfigByIndex = codecConfigs
    }

    private func makePacket(from rawPacket: svp_ffmpeg_demuxed_packet_t) -> DemuxedPacket? {
        defer {
            var mutable = rawPacket
            svp_ffmpeg_demuxed_packet_release(&mutable)
        }
        guard rawPacket.size > 0, let dataPtr = rawPacket.data else { return nil }

        let data = Data(bytes: dataPtr, count: Int(rawPacket.size))
        let packetSideData: Data? = {
            guard rawPacket.sideDataSize > 0, let sideDataPtr = rawPacket.sideData else { return nil }
            return Data(bytes: sideDataPtr, count: Int(rawPacket.sideDataSize))
        }()
        let info = streamInfoByIndex[rawPacket.streamIndex]
        let timebaseNum = Int64(info?.timebaseNum ?? 1)
        let timebaseDen = Int64(info?.timebaseDen ?? 90_000)
        let streamCodec = mapCodec(info?.codecID ?? 0)
        let packetCodec = mapCodec(rawPacket.codecID)
        let codec = packetCodec == .unknown ? streamCodec : packetCodec

        let scaledPTS = rawPacket.hasPTS == 1 ? scaleTo90k(rawPacket.pts, num: timebaseNum, den: timebaseDen) : nil
        let scaledDTS = rawPacket.hasDTS == 1 ? scaleTo90k(rawPacket.dts, num: timebaseNum, den: timebaseDen) : nil
        let normalizedPTS = scaledPTS ?? scaledDTS
        let normalizedDTS = scaledDTS ?? scaledPTS

        return DemuxedPacket(
            streamID: StreamID(Int(rawPacket.streamIndex)),
            pts: normalizedPTS,
            dts: normalizedDTS,
            duration: rawPacket.hasDuration == 1 ? scaleTo90k(rawPacket.duration, num: timebaseNum, den: timebaseDen) : nil,
            data: data,
            codecConfig: streamCodecConfigByIndex[rawPacket.streamIndex],
            sideData: packetSideData,
            sideDataType: rawPacket.sideDataType > 0 ? rawPacket.sideDataType : nil,
            isKeyframe: rawPacket.isKeyframe == 1,
            formatHint: codec
        )
    }

    private func makePacketFromData(
        data: Data,
        streamIndex: Int32,
        codecID: Int32,
        pts: Int64,
        dts: Int64,
        duration: Int64,
        hasPTS: Int32,
        hasDTS: Int32,
        hasDuration: Int32,
        isKeyframe: Int32
    ) -> DemuxedPacket? {
        let info = streamInfoByIndex[streamIndex]
        let timebaseNum = Int64(info?.timebaseNum ?? 1)
        let timebaseDen = Int64(info?.timebaseDen ?? 90_000)
        let streamCodec = mapCodec(info?.codecID ?? 0)
        let packetCodec = mapCodec(codecID)
        let codec = packetCodec == .unknown ? streamCodec : packetCodec

        // For multi-input, PTS is already in 90kHz from C code - no scaling needed
        let normalizedPTS: Int64? = hasPTS == 1 ? pts : nil
        let normalizedDTS: Int64? = hasDTS == 1 ? dts : nil

        return DemuxedPacket(
            streamID: StreamID(Int(streamIndex)),
            pts: normalizedPTS,
            dts: normalizedDTS,
            duration: hasDuration == 1 ? duration : nil,
            data: data,
            codecConfig: streamCodecConfigByIndex[streamIndex],
            sideData: nil,
            sideDataType: nil,
            isKeyframe: isKeyframe == 1,
            formatHint: codec
        )
    }

    private func makePacketFromRawData(
        data: UnsafeMutableRawPointer?,
        size: Int32,
        streamIndex: Int32,
        codecID: Int32,
        pts: Int64,
        dts: Int64,
        duration: Int64,
        hasPTS: Int32,
        hasDTS: Int32,
        hasDuration: Int32,
        isKeyframe: Int32
    ) -> DemuxedPacket? {
        guard size > 0, let dataPtr = data else { return nil }

        let packetData = Data(bytes: dataPtr, count: Int(size))
        let info = streamInfoByIndex[streamIndex]
        let timebaseNum = Int64(info?.timebaseNum ?? 1)
        let timebaseDen = Int64(info?.timebaseDen ?? 90_000)
        let streamCodec = mapCodec(info?.codecID ?? 0)
        let packetCodec = mapCodec(codecID)
        let codec = packetCodec == .unknown ? streamCodec : packetCodec

        let scaledPTS = hasPTS == 1 ? scaleTo90k(pts, num: timebaseNum, den: timebaseDen) : nil
        let scaledDTS = hasDTS == 1 ? scaleTo90k(dts, num: timebaseNum, den: timebaseDen) : nil
        let normalizedPTS = scaledPTS ?? scaledDTS
        let normalizedDTS = scaledDTS ?? scaledPTS

        return DemuxedPacket(
            streamID: StreamID(Int(streamIndex)),
            pts: normalizedPTS,
            dts: normalizedDTS,
            duration: hasDuration == 1 ? scaleTo90k(duration, num: timebaseNum, den: timebaseDen) : nil,
            data: packetData,
            codecConfig: streamCodecConfigByIndex[streamIndex],
            sideData: nil,
            sideDataType: nil,
            isKeyframe: isKeyframe == 1,
            formatHint: codec
        )
    }

    private func scaleTo90k(_ value: Int64, num: Int64, den: Int64) -> Int64 {
        guard den != 0 else { return value }
        return (value * num * 90_000) / den
    }

    private func mapCodec(_ codecID: Int32) -> CodecID {
        switch codecID {
        case 1: return .h264
        case 2: return .hevc
        case 3: return .aac
        case 4: return .opus
        case 5: return .ac3
        case 6: return .eac3
        case 7: return .av1
        case 8: return .vp9
        default: return .unknown
        }
    }

    // MARK: - Reorder Buffer Helpers

    private func clearReorderBuffer() {
        reorderBuffer.removeAll()
    }

    private func getReorderBufferCount() -> Int {
        reorderBuffer.count
    }

    private static var reorderBufferSizeStatic: Int {
        Self.reorderBufferSize
    }

    private nonisolated func getHandle() -> UnsafeMutableRawPointer? {
        handleBox.raw
    }

    private func addToReorderBuffer(_ packet: DemuxedPacket) {
        reorderBuffer.append(packet)
    }

    private func sortReorderBuffer() {
        reorderBuffer.sort { a, b in
            let ptsA = a.pts ?? a.dts ?? .max
            let ptsB = b.pts ?? b.dts ?? .max
            return ptsA < ptsB
        }
    }

    private func popFromReorderBuffer() -> DemuxedPacket? {
        guard !reorderBuffer.isEmpty else { return nil }
        return reorderBuffer.removeFirst()
    }

    private func sourcePath(_ url: URL) -> String {
        if url.isFileURL {
            return url.path
        }
        return url.absoluteString
    }

    private func isPacketStreamGenerationCurrent(_ generation: UInt64) -> Bool {
        generation == packetStreamGeneration
    }

    private func logFirstPacketIfNeeded(_ packet: DemuxedPacket) {
        guard !loggedFirstPacket else { return }
        loggedFirstPacket = true
        log("first_packet stream=\(packet.streamID.rawValue) codec=\(packet.formatHint) pts=\(String(describing: packet.pts)) size=\(packet.data.count)")
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[SVP][Demux] \(message)")
        #endif
    }
}

private final class FFmpegDemuxerHandleBox: @unchecked Sendable {
    nonisolated(unsafe) var raw: UnsafeMutableRawPointer?
    var isMultiInput: Bool = false

    deinit {
        if let raw {
            if isMultiInput {
                svp_ffmpeg_multi_demuxer_destroy(raw)
            } else {
                svp_ffmpeg_demuxer_destroy(raw)
            }
        }
    }
}
