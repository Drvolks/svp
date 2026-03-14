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

        // First attempt
        do {
            return try await decodeFrame(packet)
        } catch let error as VideoDecodeError {
            // Check if it's a recoverable decode error
            if case .decodeFailed(let status) = error, isRecoverableDecodeError(status) {
                #if DEBUG
                print("[SVP] decode: recoverable error \(status), resetting session and retrying")
                #endif
                // Reset session and retry once
                resetDecoderState()
                do {
                    return try await decodeFrame(packet)
                } catch {
                    // Retry also failed - skip this frame to allow video to continue
                    #if DEBUG
                    print("[SVP] decode: retry failed \(status), skipping frame")
                    #endif
                    return nil
                }
            }
            throw error
        }
    }

    private func decodeFrame(_ packet: DemuxedPacket) async throws -> DecodedVideoFrame? {
        captureParameterSets(from: packet.data, codec: packet.formatHint, isCodecConfig: false)
        // Also check codecConfig (extradata) for parameter sets
        #if DEBUG
        print("[SVP] decode: packet.data.count=\(packet.data.count) codecConfig=\(packet.codecConfig?.count ?? 0) hasSPS=\(h264SPS != nil) hasPPS=\(h264PPS != nil)")
        #endif
        if let extradata = packet.codecConfig {
            #if DEBUG
            // Log first few bytes of extradata to debug format
            let bytes = [UInt8](extradata.prefix(20))
            print("[SVP] decode: extradata bytes=\(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
            #endif
            captureParameterSets(from: extradata, codec: packet.formatHint, isCodecConfig: true)
            #if DEBUG
            print("[SVP] decode: after extradata hasSPS=\(h264SPS != nil) hasPPS=\(h264PPS != nil)")
            #endif
        } else {
            #if DEBUG
            print("[SVP] decode: NO codecConfig!")
            #endif
        }
        try ensureSession(codec: packet.formatHint)
        #if DEBUG
        print("[SVP] decode: formatDescription=\(formatDescription != nil) session=\(session != nil)")
        #endif
        guard let session, let formatDescription else {
            throw VideoDecodeError.needMoreData
        }

        // Handle both Annex-B and length-prefixed formats from FFmpeg
        let sampleData = NALUnitCodec.convertToLengthPrefixed(packet.data) ?? packet.data
        #if DEBUG
        let first4 = [UInt8](sampleData.prefix(8))
        let first4Hex = first4.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[SVP] decode: sampleData first8=\(first4Hex) isKeyframe=\(packet.isKeyframe) pts=\(packet.pts ?? -1)")
        #endif
        let pts = CMTime(value: packet.pts ?? 0, timescale: 90_000)
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

    private func captureParameterSets(from data: Data, codec: CodecID, isCodecConfig: Bool) {
        // AVCC/HEVCC format is for codecConfig (extradata from MP4 containers).
        // Packet data is Annex-B or length-prefixed format.
        // This function is called twice: first with packet.data (Annex-B), then with codecConfig (AVCC).
        // We only use AVCC parsing for codecConfig, never for packet.data.


        #if DEBUG
        print("[SVP] captureParameterSets: start codec=\(codec)")
        #endif

        // First, try Annex-B/length-prefixed parsing (works for packet.data)
        let annexBUnits = NALUnitCodec.extractAnnexBNALUnits(data)
        let units: [Data]
        if annexBUnits.isEmpty {
            units = NALUnitCodec.extractLengthPrefixedNALUnits(data) ?? []
        } else {
            units = annexBUnits
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
            #if DEBUG
            print("[SVP] captureParameterSets: found in packet data sps=\(h264SPS?.count ?? hevcSPS?.count ?? 0)")
            #endif
            return
        }

        // AVCC parsing for codecConfig/extradata
        switch codec {
        case .h264:
            if let avccUnits = NALUnitCodec.extractAVCCParameterSets(data), avccUnits.count >= 2 {
                h264SPS = avccUnits[0]
                h264PPS = avccUnits[1]
                #if DEBUG
                let spsBytes = h264SPS?.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ") ?? "nil"
                let ppsBytes = h264PPS?.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ") ?? "nil"
                print("[SVP] captureParameterSets: AVCC parsed sps=\(h264SPS?.count ?? 0) (\(spsBytes)) pps=\(h264PPS?.count ?? 0) (\(ppsBytes))")
                #endif
            }
        case .hevc:
            if let hevccUnits = NALUnitCodec.extractHEVCCParameterSets(data), hevccUnits.count >= 3 {
                hevcVPS = hevccUnits[0]
                hevcSPS = hevccUnits[1]
                hevcPPS = hevccUnits[2]
                #if DEBUG
                print("[SVP] captureParameterSets: HEVCC parsed vps=\(hevcVPS?.count ?? 0) sps=\(hevcSPS?.count ?? 0) pps=\(hevcPPS?.count ?? 0)")
                #endif
            } else if let avccUnits = NALUnitCodec.extractAVCCParameterSets(data), avccUnits.count >= 3 {
                hevcVPS = avccUnits[0]
                hevcSPS = avccUnits[1]
                hevcPPS = avccUnits[2]
                #if DEBUG
                print("[SVP] captureParameterSets: AVCC-HEVC parsed vps=\(hevcVPS?.count ?? 0) sps=\(hevcSPS?.count ?? 0) pps=\(hevcPPS?.count ?? 0)")
                #endif
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
                #if DEBUG
                print("[SVP] ensureSession: needMoreData - sps=\(h264SPS != nil) pps=\(h264PPS != nil)")
                #endif
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
            #if DEBUG
            print("[SVP] VTDecompressionSessionCreate hardware failed (\(sessionStatus)), trying software")
            #endif
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
            #if DEBUG
            print("[SVP] createH264FormatDescription failed: \(status) sps.count=\(sps.count) pps.count=\(pps.count)")
            #endif
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
}

private enum NALUnitCodec {
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
            #if DEBUG
            print("[SVP] extractAVCCParameterSets: data too short (\(data.count) bytes)")
            #endif
            return nil
        }
        let bytes = [UInt8](data)

        #if DEBUG
        print("[SVP] extractAVCCParameterSets: bytes=\(bytes.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " "))")
        #endif

        // Byte 4: NALU length field size = (byte & 0x03) + 1
        var naluLengthSize = Int(bytes[4] & 0x03) + 1
        #if DEBUG
        print("[SVP] extractAVCCParameterSets: byte4=0x\(String(bytes[4], radix: 16)) naluLengthSize=\(naluLengthSize)")
        #endif

        // Use 4-byte NAL lengths to match the packet data format
        naluLengthSize = 4
        #if DEBUG
        print("[SVP] extractAVCCParameterSets: using naluLengthSize=4")
        #endif

        var offset = 5  // After version, profile, compatibility, level, nalLengthSize
        _ = Int(bytes[offset]) // numSPS - we assume 1 SPS for typical streams
        offset += 1

        var parameterSets: [Data] = []

        // Parse SPS
        guard offset + naluLengthSize <= bytes.count else {
            #if DEBUG
            print("[SVP] extractAVCCParameterSets: can't read sps length at offset=\(offset) naluLengthSize=\(naluLengthSize) count=\(bytes.count)")
            #endif
            return nil
        }
        var spsLength = 0
        for i in 0..<naluLengthSize {
            spsLength = (spsLength << 8) | Int(bytes[offset + i])
        }
        #if DEBUG
        print("[SVP] extractAVCCParameterSets: spsLength=\(spsLength) offset=\(offset) naluLengthSize=\(naluLengthSize)")
        #endif
        offset += naluLengthSize
        guard offset + spsLength <= bytes.count else {
            #if DEBUG
            print("[SVP] extractAVCCParameterSets: sps data too long offset=\(offset) spsLength=\(spsLength) count=\(bytes.count)")
            #endif
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

    static func convertToLengthPrefixed(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        
        // Check if it's already length-prefixed (4-byte big endian length)
        // Valid length-prefixed: first 4 bytes are a valid length, not 0x00000001
        if bytes.count >= 4 {
            let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            if length > 0 && length <= bytes.count - 4 {
                // Already length-prefixed format
                #if DEBUG
                print("[SVP] convertToLengthPrefixed: already length-prefixed, length=\(length)")
                #endif
                return data
            }
        }
        
        // Try Annex-B conversion
        let units = extractAnnexBNALUnits(data)
        #if DEBUG
        print("[SVP] convertToLengthPrefixed: Annex-B units.count=\(units.count)")
        #endif
        guard !units.isEmpty else { return nil }

        var output = Data()
        for unit in units where !unit.isEmpty {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        #if DEBUG
        print("[SVP] convertToLengthPrefixed: converted, output first8=\([UInt8](output.prefix(8)).map { String(format: "%02x", $0) }.joined(separator: " "))")
        #endif
        return output.isEmpty ? nil : output
    }

    static func annexBToLengthPrefixed(_ data: Data) -> Data? {
        let units = extractAnnexBNALUnits(data)
        #if DEBUG
        print("[SVP] annexBToLengthPrefixed: input first4=\([UInt8](data.prefix(4)).map { String(format: "%02x", $0) }.joined(separator: " ")) units.count=\(units.count)")
        #endif
        guard !units.isEmpty else { return nil }

        var output = Data()
        for unit in units where !unit.isEmpty {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        #if DEBUG
        print("[SVP] annexBToLengthPrefixed: output first8=\([UInt8](output.prefix(8)).map { String(format: "%02x", $0) }.joined(separator: " "))")
        #endif
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
