import CoreMedia
import CoreVideo
import Foundation
import PlayerCore
import VideoToolbox
import OSLog

public actor VideoToolboxDecoder: VideoDecoder {
    private var activeCodec: CodecID?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var requiresKeyframeResync = false

    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?

    private let log = Logger(subsystem: "com.drvolks.svp", category: "Video")
    private static let staticLog = Logger(subsystem: "com.drvolks.svp", category: "Video")

    public init() {}

    public func decode(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        log.info(">>> VideoToolboxDecoder.decode CALLED for codec=\(String(describing: packet.formatHint)) <<<")
        log.debug("[SVP] VideoToolboxDecoder.decode: START packet.pts=\(packet.pts ?? -1) formatHint=\(String(describing: packet.formatHint)) data.count=\(packet.data.count)\n")
        guard packet.pts != nil else {
            log.debug("[SVP] VideoToolboxDecoder.decode: no pts")
            throw VideoDecodeError.needMoreData
        }

        if activeCodec != packet.formatHint {
            log.debug("[SVP] VideoToolboxDecoder.decode: codec changed, resetting")
            resetDecoderState()
            activeCodec = packet.formatHint
            requiresKeyframeResync = false
        }

        if requiresKeyframeResync {
            guard packet.isKeyframe else {
                log.debug("[SVP] decode: waiting for keyframe resync, dropping inter frame pts=\(packet.pts ?? -1)")
                throw VideoDecodeError.needsKeyframe
            }
            log.debug("[SVP] decode: resyncing decoder on keyframe pts=\(packet.pts ?? -1)")
            resetDecoderState()
            requiresKeyframeResync = false
        }

        do {
            return try await decodeFrame(packet)
        } catch let error as VideoDecodeError {
            if case .decodeFailed(let status) = error, isRecoverableDecodeError(status) {
                if !packet.isKeyframe {
                    log.debug("[SVP] decode: recoverable error \(status) on inter frame, forcing keyframe resync")
                    requiresKeyframeResync = true
                    resetDecoderState()
                    throw VideoDecodeError.needsKeyframe
                }

                log.debug("[SVP] decode: recoverable error \(status) on keyframe, resetting session and retrying once")
                resetDecoderState()
                do {
                    return try await decodeFrame(packet)
                } catch let retryError as VideoDecodeError {
                    if case .decodeFailed(let retryStatus) = retryError {
                        log.debug("[SVP] decode: keyframe retry failed \(retryStatus), waiting for next keyframe")
                    } else {
                        log.debug("[SVP] decode: keyframe retry failed with \(String(describing: retryError)), waiting for next keyframe")
                    }
                    requiresKeyframeResync = true
                    resetDecoderState()
                    throw VideoDecodeError.needsKeyframe
                } catch {
                    log.debug("[SVP] decode: keyframe retry failed with unexpected error=\(String(describing: error)), waiting for next keyframe")
                    requiresKeyframeResync = true
                    resetDecoderState()
                    throw VideoDecodeError.needsKeyframe
                }
            }
            throw error
        }
    }

    private func decodeFrame(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        switch packet.formatHint {
        case .h264, .hevc:
            captureParameterSets(from: packet.data, codec: packet.formatHint, isCodecConfig: false)
            log.debug("[SVP] decode: packet.data.count=\(packet.data.count) codecConfig=\(packet.codecConfig?.count ?? 0) hasSPS=\(self.h264SPS != nil) hasPPS=\(self.h264PPS != nil)")
            if let extradata = packet.codecConfig {
                let bytes = [UInt8](extradata.prefix(20))
                log.debug("[SVP] decode: extradata bytes=\(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
                captureParameterSets(from: extradata, codec: packet.formatHint, isCodecConfig: true)
                log.debug("[SVP] decode: after extradata hasSPS=\(self.h264SPS != nil) hasPPS=\(self.h264PPS != nil)")
            } else {
                log.debug("[SVP] decode: NO codecConfig!")
            }
        case .av1, .vp9:
            break
        default:
            log.debug("[SVP] VideoToolboxDecoder.decode: unsupported codec: \(String(describing: packet.formatHint))")
            throw VideoDecodeError.unsupportedCodec(packet.formatHint)
        }

        try ensureSession(
            codec: packet.formatHint,
            codedWidth: packet.codedWidth,
            codedHeight: packet.codedHeight
        )
        log.debug("[SVP] decode: formatDescription=\(self.formatDescription != nil) session=\(self.session != nil)")
        guard let session, let formatDescription else {
            throw VideoDecodeError.needMoreData
        }

        let sampleData: Data
        switch packet.formatHint {
        case .h264, .hevc:
            sampleData = NALUnitCodec.convertToLengthPrefixed(packet.data) ?? packet.data
        case .av1, .vp9:
            sampleData = packet.data
        default:
            throw VideoDecodeError.unsupportedCodec(packet.formatHint)
        }
        let first4 = [UInt8](sampleData.prefix(8))
        let first4Hex = first4.map { String(format: "%02x", $0) }.joined(separator: " ")
        log.debug("[SVP] decode: sampleData first8=\(first4Hex) isKeyframe=\(packet.isKeyframe) pts=\(packet.pts ?? -1)")
        let pts = CMTime(value: packet.pts ?? 0, timescale: 90_000)
        let dts = packet.dts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid
        let duration = packet.duration.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid
        let sampleBuffer = try makeSampleBuffer(
            sampleData: sampleData,
            formatDescription: formatDescription,
            pts: pts,
            dts: dts,
            duration: duration,
            isKeyframe: packet.isKeyframe
        )

        return try await withCheckedThrowingContinuation { continuation in
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                // Keep VT internally pipelined; the defensive pixel-buffer copy
                // and strict keyframe resync handle the corruption case.
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
                let ownedPixelBuffer: CVPixelBuffer
                do {
                    ownedPixelBuffer = try Self.copyPixelBuffer(imageBuffer)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    returning: DecodedVideoFrame(
                        pts: presentationTimeStamp,
                        pixelBuffer: ownedPixelBuffer
                    )
                )
            }
            if status != noErr {
                continuation.resume(throwing: VideoDecodeError.decodeFailed(status))
            }
        }
    }

    private func isRecoverableDecodeError(_ status: OSStatus) -> Bool {
        // kVTInvalidPictureErr = -8969
        // kVTDecoderFailedErr = -12348
        // kVTVideoDecoderMalfunctionErr = -15570
        return status == -8969 || status == -12348 || status == -15570
    }

    public func flush() async {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        requiresKeyframeResync = false
        resetDecoderState()
    }

    private func resetDecoderState() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
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

    private func captureParameterSets(from data: Data, codec: CodecID, isCodecConfig: Bool) {
        // AVCC/HEVCC format is for codecConfig (extradata from MP4 containers).
        // Packet data is Annex-B or length-prefixed format.
        // This function is called twice: first with packet.data (Annex-B), then with codecConfig (AVCC).
        // We only use AVCC parsing for codecConfig, never for packet.data.


        log.debug("[SVP] captureParameterSets: start codec=\(String(describing: codec)) isConfig=\(isCodecConfig)")

        // First, try Annex-B/length-prefixed parsing
        let annexBUnits = NALUnitCodec.extractAnnexBNALUnits(data)
        let units: [Data]
        if annexBUnits.isEmpty {
            units = NALUnitCodec.extractLengthPrefixedNALUnits(data) ?? []
        } else {
            units = annexBUnits
            if isCodecConfig {
                log.debug("[SVP] captureParameterSets: found Annex-B in codecConfig!")
            }
        }

        var foundInPacketData = false
        switch codec {
        case .h264:
            for unit in units {
                let type = unit.first.map { $0 & 0x1F } ?? 0
                if type == 7 {  // SPS
                    h264SPS = unit
                } else if type == 8 {  // PPS
                    h264PPS = unit
                }
            }
            foundInPacketData = h264SPS != nil && h264PPS != nil
        case .hevc:
            for unit in units {
                let type = unit.first.map { ($0 >> 1) & 0x3F } ?? 0
                if type == 32 {  // VPS
                    hevcVPS = unit
                } else if type == 33 {  // SPS
                    hevcSPS = unit
                } else if type == 34 {  // PPS
                    hevcPPS = unit
                }
            }
            foundInPacketData = (hevcVPS != nil && hevcSPS != nil && hevcPPS != nil) ||
                (hevcSPS != nil && hevcPPS != nil)
        default:
            break
        }

        // If we found SPS/PPS in packet data, we're done
        if foundInPacketData {
            log.debug("[SVP] captureParameterSets: found in packet data sps=\(self.h264SPS?.count ?? self.hevcSPS?.count ?? 0)")
            return
        }

        // For codecConfig/extradata, skip AVCC parsing entirely and use raw NAL unit extraction
        // This handles both Annex-B and malformed AVCC extended format
        guard isCodecConfig else { return }

        // Skip AVCC parsing for codecConfig - just use the raw NAL units we already extracted
        // If units is empty, try extracting from data directly (in case it'sAnnex-B/length-prefixed)
        log.debug("[SVP] captureParameterSets: codecConfig using raw NAL units count=\(units.count)")
        switch codec {
        case .h264:
            for unit in units {
                let type = unit.first.map { $0 & 0x1F } ?? 0
                if type == 7 { h264SPS = unit }
                else if type == 8 { h264PPS = unit }
            }
            if h264SPS != nil && h264PPS != nil {
                log.debug("[SVP] captureParameterSets: raw sps=\(self.h264SPS?.count ?? 0) pps=\(self.h264PPS?.count ?? 0)")
            }
        case .hevc:
            for unit in units {
                let type = unit.first.map { ($0 >> 1) & 0x3F } ?? 0
                if type == 32 { hevcVPS = unit }
                else if type == 33 { hevcSPS = unit }
                else if type == 34 { hevcPPS = unit }
            }
            if (hevcVPS != nil && hevcSPS != nil) || (hevcSPS != nil && hevcPPS != nil) {
                log.debug("[SVP] captureParameterSets: raw vps=\(self.hevcVPS?.count ?? 0) sps=\(self.hevcSPS?.count ?? 0) pps=\(self.hevcPPS?.count ?? 0)")
            }
        default:
            break
        }
        return
    }

    private func ensureSession(codec: CodecID, codedWidth: Int32?, codedHeight: Int32?) throws {
        if session != nil {
            return
        }

        let newFormatDescription: CMVideoFormatDescription
        switch codec {
        case .h264:
            guard let sps = h264SPS, let pps = h264PPS else {
                log.debug("[SVP] ensureSession: needMoreData - sps=\(self.h264SPS != nil) pps=\(self.h264PPS != nil)")
                throw VideoDecodeError.needMoreData
            }
            newFormatDescription = try createH264FormatDescription(sps: sps, pps: pps)
        case .hevc:
            guard let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS else {
                throw VideoDecodeError.needMoreData
            }
            newFormatDescription = try createHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
        case .av1, .vp9:
            guard let codedWidth, let codedHeight, codedWidth > 0, codedHeight > 0 else {
                log.debug("[SVP] ensureSession: missing coded size for codec=\(String(describing: codec))")
                throw VideoDecodeError.unsupportedCodec(codec)
            }
            newFormatDescription = try createGenericFormatDescription(
                codec: codec,
                width: codedWidth,
                height: codedHeight
            )
        default:
            throw VideoDecodeError.unsupportedCodec(codec)
        }

        let pixelBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        // Force hardware acceleration
        let decoderSpecification: CFDictionary = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ] as CFDictionary

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: pixelBufferAttributes,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )
        var sessionStatus = status

        // Try hardware acceleration first
        if sessionStatus != noErr {
            log.debug("[SVP] VTDecompressionSessionCreate hardware failed (\(sessionStatus)), trying software")
            // Fall back to software decoding
            sessionStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: newFormatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: pixelBufferAttributes,
                outputCallback: nil,
                decompressionSessionOut: &sessionOut
            )
        }

        guard sessionStatus == noErr, let sessionOut else {
            throw VideoDecodeError.sessionCreationFailed(sessionStatus)
        }

        formatDescription = newFormatDescription
        session = sessionOut
    }

    private func makeSampleBuffer(
        sampleData: Data,
        formatDescription: CMVideoFormatDescription,
        pts: CMTime,
        dts: CMTime,
        duration: CMTime,
        isKeyframe: Bool
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

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dictionaries = attachments as NSArray
            if let sampleAttachments = dictionaries.firstObject as? NSMutableDictionary {
                if isKeyframe {
                    sampleAttachments.removeObject(forKey: kCMSampleAttachmentKey_NotSync)
                } else {
                    sampleAttachments[kCMSampleAttachmentKey_NotSync] = kCFBooleanTrue
                }
            }
        }

        return sampleBuffer
    }

    private func createH264FormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        // For AVCC format (from codecConfig), SPS/PPS already include NAL type header
        // For Annex-B format, they also include NAL type header
        // CMVideoFormatDescriptionCreateFromH264ParameterSets expects the full NAL units including type
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
            log.debug("[SVP] createH264FormatDescription failed: \(status) sps.count=\(sps.count) pps.count=\(pps.count)")
            throw VideoDecodeError.sessionCreationFailed(status)
        }
        return formatDescription
    }

    private func createHEVCFormatDescription(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        // CMVideoFormatDescriptionCreateFromHEVCParameterSets expects full NAL units including type
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

    private func createGenericFormatDescription(
        codec: CodecID,
        width: Int32,
        height: Int32
    ) throws -> CMVideoFormatDescription {
        guard let codecType = videoCodecType(for: codec) else {
            throw VideoDecodeError.unsupportedCodec(codec)
        }
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw VideoDecodeError.sessionCreationFailed(status)
        }
        return formatDescription
    }

    private func videoCodecType(for codec: CodecID) -> CMVideoCodecType? {
        switch codec {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .av1:
            return kCMVideoCodecType_AV1
        case .vp9:
            return kCMVideoCodecType_VP9
        default:
            return nil
        }
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let planeCount = CVPixelBufferGetPlaneCount(source)

        var destination: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw VideoDecodeError.outputUnavailable
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    throw VideoDecodeError.outputUnavailable
                }
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let rowBytes = min(srcBytesPerRow, dstBytesPerRow)

                memset(dstBase, 0, dstBytesPerRow * planeHeight)
                for row in 0..<planeHeight {
                    let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                    let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                    memcpy(dstRow, srcRow, rowBytes)
                }
            }
        } else {
            guard let srcBase = CVPixelBufferGetBaseAddress(source),
                  let dstBase = CVPixelBufferGetBaseAddress(destination) else {
                throw VideoDecodeError.outputUnavailable
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let rowBytes = min(srcBytesPerRow, dstBytesPerRow)

            memset(dstBase, 0, dstBytesPerRow * height)
            for row in 0..<height {
                let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dstRow, srcRow, rowBytes)
            }
        }

        return destination
    }
}

private enum NALUnitCodec {
    private static let log = Logger(subsystem: "com.drvolks.svp", category: "NALUnitCodec")

    /// Extracts parameter sets from AVCC/HEVCC format (extradata from MP4 containers)
    /// AVCC format:
    /// - 1 byte: version
    /// - 1 byte: profile
    /// - 1 byte: compatibility
    /// - 1 byte: level
    /// - 1 byte: 0xFF (6 bits reserved + 2 bits NALU length size - 1)
    /// - 1 byte: 0xE1 (3 bits reserved + 5 bits number of SPS)
    /// - Then for each SPS: 2 bytes length + N bytes SPS
    /// - Then 1 byte number of PPS
    /// - Then for each PPS: 2 bytes length + N bytes PPS
    static func extractAVCCParameterSets(_ data: Data) -> [Data]? {
        guard data.count >= 7 else {
            log.debug("[SVP] extractAVCCParameterSets: data too short (\(data.count) bytes)")
            return nil
        }
        let bytes = [UInt8](data)

        log.debug("[SVP] extractAVCCParameterSets: bytes=\(bytes.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Byte 4: NALU length field size = (byte & 0x03) + 1
        var naluLengthSize = Int(bytes[4] & 0x03) + 1
        log.debug("[SVP] extractAVCCParameterSets: byte4=0x\(String(bytes[4], radix: 16)) naluLengthSize=\(naluLengthSize)")

        // Use 4-byte NAL lengths to match the packet data format
        naluLengthSize = 4
        log.debug("[SVP] extractAVCCParameterSets: using naluLengthSize=4")

        var offset = 5  // After version, profile, compatibility, level, nalLengthSize

        // Read number of SPS
        let numSPS = Int(bytes[offset])
        offset += 1
        log.debug("[SVP] extractAVCCParameterSets: numSPS=\(numSPS) offset=\(offset) byte5=0x\(String(bytes[5], radix: 16))")

        var parameterSets: [Data] = []

        // Parse SPS
        guard offset + naluLengthSize <= bytes.count else {
            log.debug("[SVP] extractAVCCParameterSets: can't read sps length at offset=\(offset) naluLengthSize=\(naluLengthSize) count=\(bytes.count)")
            return nil
        }
        var spsLength = 0
        for i in 0..<naluLengthSize {
            spsLength = (spsLength << 8) | Int(bytes[offset + i])
        }
        log.debug("[SVP] extractAVCCParameterSets: spsLength=\(spsLength) offset=\(offset) naluLengthSize=\(naluLengthSize)")
        offset += naluLengthSize
        guard offset + spsLength <= bytes.count else {
            log.debug("[SVP] extractAVCCParameterSets: sps data too long offset=\(offset) spsLength=\(spsLength) count=\(bytes.count)")
            return nil
        }
        let sps = Data(bytes[offset..<(offset + spsLength)])
        offset += spsLength

        // Parse PPS
        guard offset < bytes.count else { return nil }
        let numPPS = Int(bytes[offset])
        offset += 1

        for _ in 0..<numPPS {
            guard offset + naluLengthSize <= bytes.count else { return nil }
            var ppsLength = 0
            for i in 0..<naluLengthSize {
                ppsLength = (ppsLength << 8) | Int(bytes[offset + i])
            }
            offset += naluLengthSize
            guard offset + ppsLength <= bytes.count else { return nil }
            let pps = Data(bytes[offset..<(offset + ppsLength)])
            parameterSets.append(pps)
            offset += ppsLength
        }

        // Prepend SPS as first element
        return [sps] + parameterSets
    }

    /// Extracts parameter sets from HEVCC format (extradata for HEVC in MP4)
    static func extractHEVCCParameterSets(_ data: Data) -> [Data]? {
        guard data.count >= 23 else { return nil }
        let bytes = [UInt8](data)

        // HEVCC format:
        // 1 byte: configurationVersion (1)
        // 1 byte: general_profile_space (2 bits) + general_tier_flag (1 bit) + general_profile_idc (5 bits)
        // 4 bytes: general_profile_compatibility_flags
        // 4 bytes: general_constraint_indicator_flags
        // 1 byte: general_level_idc
        // 4 bytes: min_spatial_segmentation_idc (12 bits reserved + 4 bits)
        // 1 byte: parallelismType
        // 1 byte: chromaFormat
        // 1 byte: bitDepthLumaMinus8
        // 1 byte: bitDepthChromaMinus8
        // 2 bytes: avgFrameRate
        // 1 byte: constantFrameRate + numTemporalLayers + lengthSizeMinusOne (2 bits each)
        // 1 byte: numOfArrays
        // For each array: 1 byte (nalUnitType) + 2 bytes (numNalus) + for each nalu: 2 bytes (length) + nalu data

        let lengthSizeMinusOne = bytes[21] & 0x03
        let naluLengthSize = Int(lengthSizeMinusOne) + 1

        var offset = 22  // After the header fields
        guard offset < bytes.count else { return nil }
        let numArrays = Int(bytes[offset])
        offset += 1

        var parameterSets: [Data] = []

        for _ in 0..<numArrays {
            guard offset + 3 <= bytes.count else { return nil }
            let nalUnitType = bytes[offset] & 0x3F
            offset += 1

            let numNalus = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2

            for _ in 0..<numNalus {
                guard offset + naluLengthSize <= bytes.count else { return nil }
                var nalLength = 0
                for i in 0..<naluLengthSize {
                    nalLength = (nalLength << 8) | Int(bytes[offset + i])
                }
                offset += naluLengthSize
                guard offset + nalLength <= bytes.count else { return nil }
                let nalData = Data(bytes[offset..<(offset + nalLength)])

                // VPS=32, SPS=33, PPS=34
                switch nalUnitType {
                case 32:
                    parameterSets.insert(nalData, at: 0)  // VPS first
                case 33:
                    // Insert after VPS if exists, otherwise at position 1
                    if parameterSets.isEmpty || (parameterSets.count == 1 && isHEVCParameterSet(parameterSets[0], type: 32)) {
                        parameterSets.append(nalData)  // SPS second
                    } else {
                        parameterSets.insert(nalData, at: parameterSets.count >= 1 ? 1 : 0)
                    }
                case 34:
                    parameterSets.append(nalData)  // PPS last
                default:
                    break
                }
                offset += nalLength
            }
        }

        return parameterSets.isEmpty ? nil : parameterSets
    }

    private static func isHEVCParameterSet(_ data: Data, type: Int) -> Bool {
        guard !data.isEmpty else { return false }
        let typeByte = (data[0] >> 1) & 0x3F
        return Int(typeByte) == type
    }

    static func extractAnnexBNALUnits(_ data: Data) -> [Data] {
        log.debug("[SVP] extractAnnexBNALUnits: data.count=\(data.count) firstBytes=\([UInt8](data.prefix(8)).map { String(format: "%02x", $0) }.joined(separator: " "))")
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
        log.debug("[SVP] extractAnnexBNALUnits: found=\(units.count) starts=\(starts)")
        return units
    }

    static func convertToLengthPrefixed(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        
        // Check if it's already length-prefixed (4-byte big endian length)
        // Valid length-prefixed: first 4 bytes are a valid length, not 0x00000001
        if bytes.count >= 4 {
            let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            if length > 0 && length <= bytes.count - 4 {
                // Already length-prefixed format
                log.debug("[SVP] convertToLengthPrefixed: already length-prefixed, length=\(length)")
                return data
            }
        }
        
        // Try Annex-B conversion
        let units = extractAnnexBNALUnits(data)
        log.debug("[SVP] convertToLengthPrefixed: Annex-B units.count=\(units.count)")
        guard !units.isEmpty else { return nil }

        var output = Data()
        for unit in units where !unit.isEmpty {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        log.debug("[SVP] convertToLengthPrefixed: converted, output first8=\([UInt8](output.prefix(8)).map { String(format: "%02x", $0) }.joined(separator: " "))")
        return output.isEmpty ? nil : output
    }

    static func annexBToLengthPrefixed(_ data: Data) -> Data? {
        let units = extractAnnexBNALUnits(data)
        log.debug("[SVP] annexBToLengthPrefixed: input first4=\([UInt8](data.prefix(4)).map { String(format: "%02x", $0) }.joined(separator: " ")) units.count=\(units.count)")
        guard !units.isEmpty else { return nil }

        var output = Data()
        for unit in units where !unit.isEmpty {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        log.debug("[SVP] annexBToLengthPrefixed: output first8=\([UInt8](output.prefix(8)).map { String(format: "%02x", $0) }.joined(separator: " "))")
        return output.isEmpty ? nil : output
    }

    static func extractLengthPrefixedNALUnits(_ data: Data) -> [Data]? {
        guard data.count > 4 else { return nil }
        // Check for extended AVCC format (byte[4] = 0xFF)
        if data[4] == 0xFF {
            // Extended format - try to extract NAL units directly by scanning for NAL type bytes
            return extractDirectNALUnits(data)
        }
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

    /// Fallback extractor for extended AVCC format - scans for NAL start codes in the data
    private static func extractDirectNALUnits(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { return nil }

        // Skip AVCC header (at least 5 bytes)
        // Byte 0: version
        // Byte 1: profile
        // Byte 2: compatibility
        // Byte 3: level
        // Byte 4: NALU length size (0xFF = extended)

        // For extended format, the structure is different:
        // Byte 5: number of SPS (or length bytes for SPS)
        // Try offset 6 as start of SPS length (2 bytes) based on observed data

        var units: [Data] = []
        var offset = 6 // Try starting here based on the 44-byte config pattern

        // Try to read SPS length (2 bytes big endian)
        guard offset + 2 <= bytes.count else { return nil }
        let spsLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2

        // Extract SPS
        if spsLength > 0 && offset + spsLength <= bytes.count {
            let sps = Data(bytes[offset..<(offset + spsLength)])
            // Verify it's actually an SPS (type = 7)
            if let firstByte = sps.first, (firstByte & 0x1F) == 7 {
                units.append(sps)
            }
            offset += spsLength
        }

        // Try to read PPS count and extract
        guard offset < bytes.count else { return units.isEmpty ? nil : units }
        let ppsCount = Int(bytes[offset])
        offset += 1

        for _ in 0..<ppsCount {
            guard offset + 2 <= bytes.count else { break }
            let ppsLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2

            if ppsLength > 0 && offset + ppsLength <= bytes.count {
                let pps = Data(bytes[offset..<(offset + ppsLength)])
                // Verify it's actually a PPS (type = 8)
                if let firstByte = pps.first, (firstByte & 0x1F) == 8 {
                    units.append(pps)
                }
                offset += ppsLength
            }
        }

        return units.isEmpty ? nil : units
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
