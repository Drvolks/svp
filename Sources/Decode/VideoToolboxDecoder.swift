import CoreMedia
import CoreVideo
import Foundation
import PlayerCore
import VideoToolbox

public actor VideoToolboxDecoder: VideoDecoder {
    private var activeCodec: CodecID?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?

    public init() {}

    public func decode(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        guard packet.formatHint == .h264 || packet.formatHint == .hevc else {
            throw VideoDecodeError.unsupportedCodec(packet.formatHint)
        }
        guard let ptsValue = packet.pts else {
            throw VideoDecodeError.needMoreData
        }

        if activeCodec != packet.formatHint {
            resetDecoderState()
            activeCodec = packet.formatHint
        }

        captureParameterSets(from: packet.data, codec: packet.formatHint)
        try ensureSession(codec: packet.formatHint)
        guard let session, let formatDescription else {
            throw VideoDecodeError.needMoreData
        }

        let sampleData = NALUnitCodec.annexBToLengthPrefixed(packet.data) ?? packet.data
        let pts = CMTime(value: ptsValue, timescale: 90_000)
        let dts = packet.dts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid
        let duration = packet.duration.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid
        let sampleBuffer = try makeSampleBuffer(
            sampleData: sampleData,
            formatDescription: formatDescription,
            pts: pts,
            dts: dts,
            duration: duration
        )

        return try await withCheckedThrowingContinuation { continuation in
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: VTDecodeFrameFlags._EnableAsynchronousDecompression,
                infoFlagsOut: &infoFlags
            ) { status, _, imageBuffer, presentationTimeStamp, _ in
                if status != noErr {
                    continuation.resume(throwing: VideoDecodeError.decodeFailed(status))
                    return
                }
                guard let imageBuffer else {
                    continuation.resume(throwing: VideoDecodeError.outputUnavailable)
                    return
                }
                continuation.resume(
                    returning: DecodedVideoFrame(
                        pts: presentationTimeStamp,
                        pixelBuffer: imageBuffer
                    )
                )
            }
            if status != noErr {
                continuation.resume(throwing: VideoDecodeError.decodeFailed(status))
            }
        }
    }

    public func flush() async {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        resetDecoderState()
    }

    private func resetDecoderState() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        h264SPS = nil
        h264PPS = nil
        hevcVPS = nil
        hevcSPS = nil
        hevcPPS = nil
    }

    private func captureParameterSets(from data: Data, codec: CodecID) {
        let annexBUnits = NALUnitCodec.extractAnnexBNALUnits(data)
        let units: [Data]
        if annexBUnits.isEmpty {
            units = NALUnitCodec.extractLengthPrefixedNALUnits(data) ?? []
        } else {
            units = annexBUnits
        }

        switch codec {
        case .h264:
            for unit in units {
                let type = unit.first.map { $0 & 0x1F } ?? 0
                if type == 7 {
                    h264SPS = unit
                } else if type == 8 {
                    h264PPS = unit
                }
            }
        case .hevc:
            for unit in units {
                let type = unit.first.map { ($0 >> 1) & 0x3F } ?? 0
                if type == 32 {
                    hevcVPS = unit
                } else if type == 33 {
                    hevcSPS = unit
                } else if type == 34 {
                    hevcPPS = unit
                }
            }
        default:
            break
        }
    }

    private func ensureSession(codec: CodecID) throws {
        if session != nil {
            return
        }

        let newFormatDescription: CMVideoFormatDescription
        switch codec {
        case .h264:
            guard let sps = h264SPS, let pps = h264PPS else {
                throw VideoDecodeError.needMoreData
            }
            newFormatDescription = try createH264FormatDescription(sps: sps, pps: pps)
        case .hevc:
            guard let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS else {
                throw VideoDecodeError.needMoreData
            }
            newFormatDescription = try createHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
        default:
            throw VideoDecodeError.unsupportedCodec(codec)
        }

        let pixelBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttributes,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )
        guard status == noErr, let sessionOut else {
            throw VideoDecodeError.sessionCreationFailed(status)
        }

        formatDescription = newFormatDescription
        session = sessionOut
    }

    private func makeSampleBuffer(
        sampleData: Data,
        formatDescription: CMVideoFormatDescription,
        pts: CMTime,
        dts: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createBlockStatus == noErr, let blockBuffer else {
            throw VideoDecodeError.sampleBufferCreationFailed(createBlockStatus)
        }

        let replaceStatus = sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard replaceStatus == noErr else {
            throw VideoDecodeError.sampleBufferCreationFailed(replaceStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleData.count
        let createSampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createSampleStatus == noErr, let sampleBuffer else {
            throw VideoDecodeError.sampleBufferCreationFailed(createSampleStatus)
        }
        return sampleBuffer
    }

    private func createH264FormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard status == noErr, let formatDescription else {
            throw VideoDecodeError.sessionCreationFailed(status)
        }
        return formatDescription
    }

    private func createHEVCFormatDescription(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    var pointers: [UnsafePointer<UInt8>] = [
                        vpsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    var sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
        guard status == noErr, let formatDescription else {
            throw VideoDecodeError.sessionCreationFailed(status)
        }
        return formatDescription
    }
}

private enum NALUnitCodec {
    static func extractAnnexBNALUnits(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var units: [Data] = []
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                starts.append(i)
                i += 3
                continue
            }
            if i + 4 < bytes.count,
               bytes[i] == 0,
               bytes[i + 1] == 0,
               bytes[i + 2] == 0,
               bytes[i + 3] == 1 {
                starts.append(i)
                i += 4
                continue
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }

        for index in 0..<starts.count {
            let startCodeLength: Int
            let start = starts[index]
            if bytes[start] == 0 && bytes[start + 1] == 0 && bytes[start + 2] == 1 {
                startCodeLength = 3
            } else {
                startCodeLength = 4
            }
            let payloadStart = start + startCodeLength
            let payloadEnd = (index + 1 < starts.count) ? starts[index + 1] : bytes.count
            guard payloadStart < payloadEnd else { continue }
            units.append(Data(bytes[payloadStart..<payloadEnd]))
        }
        return units
    }

    static func annexBToLengthPrefixed(_ data: Data) -> Data? {
        let units = extractAnnexBNALUnits(data)
        guard !units.isEmpty else { return nil }

        var output = Data()
        for unit in units where !unit.isEmpty {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output.isEmpty ? nil : output
    }

    static func extractLengthPrefixedNALUnits(_ data: Data) -> [Data]? {
        guard data.count > 4 else { return nil }
        if let units = extractLengthPrefixedNALUnits(data, lengthFieldBytes: 4) {
            return units
        }
        if let units = extractLengthPrefixedNALUnits(data, lengthFieldBytes: 2) {
            return units
        }
        if let units = extractLengthPrefixedNALUnits(data, lengthFieldBytes: 1) {
            return units
        }
        return nil
    }

    private static func extractLengthPrefixedNALUnits(_ data: Data, lengthFieldBytes: Int) -> [Data]? {
        let bytes = [UInt8](data)
        var offset = 0
        var units: [Data] = []

        while offset + lengthFieldBytes <= bytes.count {
            var nalLength = 0
            for i in 0..<lengthFieldBytes {
                nalLength = (nalLength << 8) | Int(bytes[offset + i])
            }
            offset += lengthFieldBytes
            guard nalLength > 0, offset + nalLength <= bytes.count else {
                return nil
            }
            units.append(Data(bytes[offset..<(offset + nalLength)]))
            offset += nalLength
        }

        guard offset == bytes.count, !units.isEmpty else { return nil }
        return units
    }
}
