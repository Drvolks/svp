import CoreMedia
import CoreVideo
import FFmpegBridge
import Foundation
import OSLog
import PlayerCore

public actor FFmpegVideoDecoder: VideoDecoder {
    private static let defaultInvalidPacketDropLimit = 8
    private static let av1InvalidPacketDropLimit = 32
    private static let newExtradataSideDataType: Int32 = 1

    private let handleBox = FFmpegDecoderHandleBox()
    private var activeCodec: CodecID?
    private var activeCodecConfig: Data?
    private var droppedInvalidPacketCount = 0
    private var consecutiveInvalidPacketDrops = 0

    private let log = Logger(subsystem: "com.drvolks.svp", category: "FFmpegDecode")

    public init() {}

    public func decode(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        guard packet.formatHint == .h264
            || packet.formatHint == .hevc
            || packet.formatHint == .av1
            || packet.formatHint == .vp9 else {
            throw VideoDecodeError.unsupportedCodec(packet.formatHint)
        }
        guard let pts = packet.pts else {
            throw VideoDecodeError.needMoreData
        }
        guard svp_ffmpeg_bridge_has_vendor_backend() == 1 else {
            throw VideoDecodeError.backendUnavailable
        }

        let decoderConfig = updatedCodecConfig(for: packet)
        try ensureDecoder(codec: packet.formatHint, codecConfig: decoderConfig)
        guard let decoderHandle = handleBox.raw else {
            throw VideoDecodeError.backendUnavailable
        }

        let bytestream = BitstreamConverter.toAnnexBIfNeeded(packet.data, codec: packet.formatHint)
        let dts = packet.dts ?? pts
        let packetSideDataType: Int32
        let packetSideData: Data?
        if packet.sideDataType == Self.newExtradataSideDataType {
            packetSideDataType = 0
            packetSideData = nil
        } else {
            packetSideDataType = packet.sideDataType ?? 0
            packetSideData = packet.sideData
        }

        var rawFrame = svp_ffmpeg_decoded_frame_t()
        let status: Int32
        if let sideData = packetSideData, !sideData.isEmpty {
            status = bytestream.withUnsafeBytes { bytes in
                sideData.withUnsafeBytes { sideBytes in
                    svp_ffmpeg_video_decoder_decode(
                        decoderHandle,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(bytestream.count),
                        pts,
                        dts,
                        packetSideDataType,
                        sideBytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(sideData.count),
                        &rawFrame
                    )
                }
            }
        } else {
            status = bytestream.withUnsafeBytes { bytes in
                svp_ffmpeg_video_decoder_decode(
                    decoderHandle,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(bytestream.count),
                    pts,
                    dts,
                    0,
                    nil,
                    0,
                    &rawFrame
                )
            }
        }
        defer { svp_ffmpeg_decoded_frame_release(&rawFrame) }

        if status == 0 {
            // A packet accepted by the decoder, even if it produced no frame yet,
            // breaks an "invalid packet" streak.
            consecutiveInvalidPacketDrops = 0
            return nil
        }
        if status < 0 {
            if shouldIgnoreDecodeError(status) {
                droppedInvalidPacketCount += 1
                consecutiveInvalidPacketDrops += 1
                if droppedInvalidPacketCount == 1 || droppedInvalidPacketCount % 25 == 0 {
                    log.debug("[SVP][Decode] drop_invalid_packet codec=\(String(describing: packet.formatHint)) status=\(status) count=\(self.droppedInvalidPacketCount)")
                }
                if consecutiveInvalidPacketDrops >= maxInvalidPacketDropsBeforeFailure(for: packet.formatHint) {
                    // Persistent invalid packets usually indicate we started mid-GOP
                    // or decoder state drifted. Escalate so PlaybackSession can
                    // enter keyframe resync mode and flush stale decode state.
                    consecutiveInvalidPacketDrops = 0
                    throw VideoDecodeError.decodeFailed(OSStatus(status))
                }
                return nil
            }
            if shouldRecreateDecoder(for: status) {
                resetDecoderHandle()
            }
            consecutiveInvalidPacketDrops = 0
            throw VideoDecodeError.decodeFailed(OSStatus(status))
        }

        consecutiveInvalidPacketDrops = 0

        let pixelBuffer = try makePixelBuffer(from: rawFrame)
        let framePTS = CMTime(value: rawFrame.pts90k, timescale: 90_000)
        return DecodedVideoFrame(pts: framePTS, pixelBuffer: pixelBuffer)
    }

    private func updatedCodecConfig(for packet: DemuxedPacket) -> Data? {
        guard packet.sideDataType == Self.newExtradataSideDataType,
              let sideData = packet.sideData,
              !sideData.isEmpty else {
            return packet.codecConfig
        }

        if activeCodecConfig != sideData {
            let previousSize = activeCodecConfig?.count ?? 0
            let msg =
                "[SVP][Decode] new_extradata codec=\(String(describing: packet.formatHint)) " +
                "pts=\(String(describing: packet.pts)) size=\(sideData.count) previousSize=\(previousSize)"
            log.debug("\(msg)")
            consecutiveInvalidPacketDrops = 0
            droppedInvalidPacketCount = 0
        }
        return sideData
    }

    public func flush() async {
        guard let decoderHandle = handleBox.raw else { return }
        _ = svp_ffmpeg_video_decoder_flush(decoderHandle)
    }

    private func resetDecoderHandle() {
        if let decoderHandle = handleBox.raw {
            svp_ffmpeg_video_decoder_destroy(decoderHandle)
            handleBox.raw = nil
        }
    }

    private func shouldRecreateDecoder(for status: Int32) -> Bool {
        // INVALIDDATA is often recoverable with subsequent packets/keyframes.
        // Recreating decoder state on every invalid packet causes visible
        // playback stalls for network streams.
        if status == -22 { // AVERROR(EINVAL)
            return true
        }
        return false
    }

    private func shouldIgnoreDecodeError(_ status: Int32) -> Bool {
        // AVERROR_INVALIDDATA (FFERRTAG('I','N','D','A')): treat as a dropped/corrupt packet.
        // Escalating this to playback-level resync causes slideshow behavior on split VOD.
        return status == -1094995529
    }

    private func maxInvalidPacketDropsBeforeFailure(for codec: CodecID) -> Int {
        switch codec {
        case .av1:
            // Split YouTube AV1 regularly trips short INVALIDDATA bursts even while
            // continuing to decode fine on nearby packets. Let software decode ride
            // through brief turbulence before forcing a full resync.
            return Self.av1InvalidPacketDropLimit
        default:
            return Self.defaultInvalidPacketDropLimit
        }
    }

    private func ensureDecoder(codec: CodecID, codecConfig: Data?) throws {
        if activeCodec != codec || activeCodecConfig != codecConfig {
            if let decoderHandle = handleBox.raw {
                svp_ffmpeg_video_decoder_destroy(decoderHandle)
                handleBox.raw = nil
            }
            self.activeCodec = codec
            self.activeCodecConfig = codecConfig
        }
        if handleBox.raw != nil {
            return
        }
        let created: UnsafeMutableRawPointer?
        if let codecConfig, !codecConfig.isEmpty {
            created = codecConfig.withUnsafeBytes { bytes in
                svp_ffmpeg_video_decoder_create_with_extradata(
                    codecID(codec),
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(codecConfig.count)
                )
            }
        } else {
            created = svp_ffmpeg_video_decoder_create(codecID(codec))
        }
        guard let created else {
            throw VideoDecodeError.backendUnavailable
        }
        handleBox.raw = created
    }

    private func codecID(_ codec: CodecID) -> Int32 {
        switch codec {
        case .h264: return 1
        case .hevc: return 2
        case .av1: return 7
        case .vp9: return 8
        default: return 0
        }
    }

    private func makePixelBuffer(from frame: svp_ffmpeg_decoded_frame_t) throws -> CVPixelBuffer {
        guard frame.width > 0, frame.height > 0 else {
            throw VideoDecodeError.decodeFailed(-1)
        }
        guard let srcY = frame.planeY, let srcUV = frame.planeUV else {
            throw VideoDecodeError.decodeFailed(-2)
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: Int(frame.width),
            kCVPixelBufferHeightKey: Int(frame.height),
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(frame.width),
            Int(frame.height),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw VideoDecodeError.decodeFailed(createStatus)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let dstY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let dstUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw VideoDecodeError.decodeFailed(-3)
        }

        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let srcYStride = Int(frame.linesizeY)
        let srcUVStride = Int(frame.linesizeUV)

        // Clear the buffer first to avoid "burning" artifacts from stale data
        memset(dstY, 0, dstYStride * Int(frame.height))
        memset(dstUV, 0, dstUVStride * Int((frame.height + 1) / 2))

        copyPlane(
            source: srcY,
            sourceStride: srcYStride,
            destination: dstY,
            destinationStride: dstYStride,
            rowBytes: min(srcYStride, dstYStride),
            rows: Int(frame.height)
        )
        copyPlane(
            source: srcUV,
            sourceStride: srcUVStride,
            destination: dstUV,
            destinationStride: dstUVStride,
            rowBytes: min(srcUVStride, dstUVStride),
            rows: Int((frame.height + 1) / 2)
        )

        return pixelBuffer
    }

    private func copyPlane(
        source: UnsafeMutablePointer<UInt8>,
        sourceStride: Int,
        destination: UnsafeMutableRawPointer,
        destinationStride: Int,
        rowBytes: Int,
        rows: Int
    ) {
        for row in 0..<rows {
            let src = source.advanced(by: row * sourceStride)
            let dst = destination.advanced(by: row * destinationStride)
            memcpy(dst, src, rowBytes)
        }
    }
}

private final class FFmpegDecoderHandleBox: @unchecked Sendable {
    var raw: UnsafeMutableRawPointer?

    deinit {
        if let raw {
            svp_ffmpeg_video_decoder_destroy(raw)
        }
    }
}

private enum BitstreamConverter {
    static func toAnnexBIfNeeded(_ data: Data, codec: CodecID) -> Data {
        guard codec == .h264 || codec == .hevc else { return data }
        if NALScanner.containsAnnexBStartCode(data) {
            return data
        }
        if let converted = lengthPrefixedToAnnexB(data, nalLengthBytes: 4) {
            return converted
        }
        if let converted = lengthPrefixedToAnnexB(data, nalLengthBytes: 2) {
            return converted
        }
        if let converted = lengthPrefixedToAnnexB(data, nalLengthBytes: 1) {
            return converted
        }
        return data
    }

    private static func lengthPrefixedToAnnexB(_ data: Data, nalLengthBytes: Int) -> Data? {
        guard data.count > nalLengthBytes else { return nil }
        let bytes = [UInt8](data)
        var offset = 0
        var out = Data()
        var convertedUnits = 0

        while offset + nalLengthBytes <= bytes.count {
            var nalLength = 0
            for i in 0..<nalLengthBytes {
                nalLength = (nalLength << 8) | Int(bytes[offset + i])
            }
            offset += nalLengthBytes
            guard nalLength > 0, offset + nalLength <= bytes.count else {
                return nil
            }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
            convertedUnits += 1
        }

        guard offset == bytes.count, convertedUnits > 0 else { return nil }
        return out
    }
}

private enum NALScanner {
    static func containsAnnexBStartCode(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                return true
            }
            if i + 4 < bytes.count,
               bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                return true
            }
            i += 1
        }
        return false
    }
}
