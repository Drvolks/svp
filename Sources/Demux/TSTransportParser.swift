import Foundation
import PlayerCore

final class TSTransportParser: @unchecked Sendable {
    private let packetSize = 188
    private var remainder = Data()

    private var pmtPID: UInt16?
    private var codecsByPID: [UInt16: CodecID] = [:]
    private var continuityByPID: [UInt16: UInt8] = [:]

    private var pesPayloadByPID: [UInt16: Data] = [:]
    private var pesTimingByPID: [UInt16: (pts: Int64?, dts: Int64?)] = [:]
    private var lastPTSByPID: [UInt16: Int64] = [:]
    private var lastPCR: Int64?
    private let pcrNormalizer = PCRNormalizer()

    private let normalizer = TimestampNormalizer()

    func consume(_ chunk: Data) -> [DemuxedPacket] {
        guard !chunk.isEmpty else { return [] }
        remainder.append(chunk)

        var outputs: [DemuxedPacket] = []
        var offset = 0
        while offset + packetSize <= remainder.count {
            if remainder[offset] != 0x47 {
                if let sync = findNextSync(startingAt: offset + 1) {
                    offset = sync
                } else {
                    break
                }
            }
            let packet = remainder.subdata(in: offset..<(offset + packetSize))
            outputs.append(contentsOf: parsePacket(packet))
            offset += packetSize
        }
        if offset > 0 {
            remainder.removeSubrange(0..<offset)
        }
        return outputs
    }

    func finalize() -> [DemuxedPacket] {
        var packets: [DemuxedPacket] = []
        for pid in pesPayloadByPID.keys.sorted() {
            if let packet = flushPES(for: pid) {
                packets.append(packet)
            }
        }
        pesPayloadByPID.removeAll()
        pesTimingByPID.removeAll()
        return packets
    }

    private func findNextSync(startingAt: Int) -> Int? {
        guard startingAt < remainder.count else { return nil }
        for i in startingAt..<remainder.count where remainder[i] == 0x47 {
            return i
        }
        return nil
    }

    private func parsePacket(_ packet: Data) -> [DemuxedPacket] {
        guard packet.count == packetSize else { return [] }
        guard packet[0] == 0x47 else { return [] }

        let payloadUnitStart = (packet[1] & 0x40) != 0
        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let adaptationFieldControl = (packet[3] >> 4) & 0x03
        let continuityCounter = packet[3] & 0x0F

        var index = 4
        var outputs: [DemuxedPacket] = []

        if adaptationFieldControl == 0x02 || adaptationFieldControl == 0x03 {
            guard index < packet.count else { return [] }
            let adaptationLength = Int(packet[index])
            index += 1
            if adaptationLength > 0, index + adaptationLength <= packet.count {
                let flags = packet[index]
                if (flags & 0x10) != 0, adaptationLength >= 7 {
                    let rawPCR = parsePCR(packet, at: index + 1)
                    lastPCR = pcrNormalizer.normalize(rawPCR)
                }
            }
            index += adaptationLength
        }

        let hasPayload = adaptationFieldControl == 0x01 || adaptationFieldControl == 0x03
        guard hasPayload, index < packet.count else { return [] }

        if let previous = continuityByPID[pid] {
            let expected = (previous + 1) & 0x0F
            if continuityCounter != expected, !payloadUnitStart {
                pesPayloadByPID.removeValue(forKey: pid)
                pesTimingByPID.removeValue(forKey: pid)
            }
        }
        continuityByPID[pid] = continuityCounter

        let payload = packet.subdata(in: index..<packet.count)
        if pid == 0 {
            parsePAT(payload, payloadUnitStart: payloadUnitStart)
            return []
        }

        if let pmtPID, pid == pmtPID {
            parsePMT(payload, payloadUnitStart: payloadUnitStart)
            return []
        }

        guard codecsByPID[pid] != nil else { return [] }

        if payloadUnitStart {
            if let previous = flushPES(for: pid) {
                outputs.append(previous)
            }

            let parsed = parsePES(payload)
            pesTimingByPID[pid] = (pts: parsed.pts, dts: parsed.dts)
            pesPayloadByPID[pid] = parsed.payload
            return outputs
        }

        var current = pesPayloadByPID[pid] ?? Data()
        current.append(payload)
        pesPayloadByPID[pid] = current
        return outputs
    }

    private func parsePAT(_ payload: Data, payloadUnitStart: Bool) {
        guard payloadUnitStart, !payload.isEmpty else { return }
        let pointer = Int(payload[0])
        let sectionStart = 1 + pointer
        guard sectionStart + 8 <= payload.count else { return }

        let section = payload.subdata(in: sectionStart..<payload.count)
        guard section.count >= 8, section[0] == 0x00 else { return }

        let sectionLength = Int((UInt16(section[1] & 0x0F) << 8) | UInt16(section[2]))
        let totalLength = 3 + sectionLength
        guard totalLength <= section.count, totalLength >= 12 else { return }

        let endWithoutCRC = totalLength - 4
        var index = 8
        while index + 4 <= endWithoutCRC {
            let programNumber = (UInt16(section[index]) << 8) | UInt16(section[index + 1])
            let mappedPID = (UInt16(section[index + 2] & 0x1F) << 8) | UInt16(section[index + 3])
            if programNumber != 0 {
                pmtPID = mappedPID
                return
            }
            index += 4
        }
    }

    private func parsePMT(_ payload: Data, payloadUnitStart: Bool) {
        guard payloadUnitStart, !payload.isEmpty else { return }
        let pointer = Int(payload[0])
        let sectionStart = 1 + pointer
        guard sectionStart + 12 <= payload.count else { return }

        let section = payload.subdata(in: sectionStart..<payload.count)
        guard section.count >= 12, section[0] == 0x02 else { return }

        let sectionLength = Int((UInt16(section[1] & 0x0F) << 8) | UInt16(section[2]))
        let totalLength = 3 + sectionLength
        guard totalLength <= section.count, totalLength >= 16 else { return }

        let programInfoLength = Int((UInt16(section[10] & 0x0F) << 8) | UInt16(section[11]))
        var index = 12 + programInfoLength
        let endWithoutCRC = totalLength - 4

        while index + 5 <= endWithoutCRC {
            let streamType = section[index]
            let elementaryPID = (UInt16(section[index + 1] & 0x1F) << 8) | UInt16(section[index + 2])
            let esInfoLength = Int((UInt16(section[index + 3] & 0x0F) << 8) | UInt16(section[index + 4]))

            codecsByPID[elementaryPID] = mapCodec(streamType: streamType)
            index += 5 + esInfoLength
        }
    }

    private func parsePES(_ payload: Data) -> (pts: Int64?, dts: Int64?, payload: Data) {
        guard payload.count >= 9 else { return (nil, nil, payload) }
        guard payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x01 else {
            return (nil, nil, payload)
        }

        let ptsDtsFlags = (payload[7] >> 6) & 0x03
        let headerLength = Int(payload[8])
        let payloadStart = 9 + headerLength

        var pts: Int64?
        var dts: Int64?

        if ptsDtsFlags == 0x02, payload.count >= 14 {
            pts = parseTimestamp(payload, at: 9)
        } else if ptsDtsFlags == 0x03, payload.count >= 19 {
            pts = parseTimestamp(payload, at: 9)
            dts = parseTimestamp(payload, at: 14)
        }

        guard payloadStart <= payload.count else {
            return (pts, dts, Data())
        }
        return (pts, dts, payload.subdata(in: payloadStart..<payload.count))
    }

    private func parseTimestamp(_ data: Data, at index: Int) -> Int64 {
        guard index + 5 <= data.count else { return 0 }
        let b0 = Int64(data[index + 0])
        let b1 = Int64(data[index + 1])
        let b2 = Int64(data[index + 2])
        let b3 = Int64(data[index + 3])
        let b4 = Int64(data[index + 4])

        let p0 = (b0 >> 1) & 0x07
        let p1 = b1
        let p2 = (b2 >> 1) & 0x7F
        let p3 = b3
        let p4 = (b4 >> 1) & 0x7F

        return (p0 << 30) | (p1 << 22) | (p2 << 15) | (p3 << 7) | p4
    }

    private func parsePCR(_ data: Data, at index: Int) -> Int64 {
        guard index + 6 <= data.count else { return 0 }
        let b0 = UInt64(data[index + 0])
        let b1 = UInt64(data[index + 1])
        let b2 = UInt64(data[index + 2])
        let b3 = UInt64(data[index + 3])
        let b4 = UInt64(data[index + 4])
        let b5 = UInt64(data[index + 5])

        let base = (b0 << 25) | (b1 << 17) | (b2 << 9) | (b3 << 1) | (b4 >> 7)
        let ext = ((b4 & 0x01) << 8) | b5
        return Int64(base * 300 + ext)
    }

    private func flushPES(for pid: UInt16) -> DemuxedPacket? {
        guard let payload = pesPayloadByPID.removeValue(forKey: pid), !payload.isEmpty else {
            pesTimingByPID.removeValue(forKey: pid)
            return nil
        }

        let codec = codecsByPID[pid] ?? .unknown
        let timing = pesTimingByPID.removeValue(forKey: pid)
        let normalizedPTS = timing?.pts.map { normalizer.normalize($0) }
        let normalizedDTS = timing?.dts.map { normalizer.normalize($0) }

        var duration: Int64?
        if let pts = normalizedPTS {
            if let previous = lastPTSByPID[pid], pts >= previous {
                duration = pts - previous
            } else if let pcr = lastPCR {
                duration = pcr > 0 ? pcr : nil
            }
            lastPTSByPID[pid] = pts
        }

        return DemuxedPacket(
            streamID: StreamID(Int(pid)),
            pts: normalizedPTS,
            dts: normalizedDTS,
            duration: duration,
            data: payload,
            isKeyframe: isKeyframe(payload: payload, codec: codec),
            formatHint: codec
        )
    }

    private func mapCodec(streamType: UInt8) -> CodecID {
        switch streamType {
        case 0x1B: return .h264
        case 0x24: return .hevc
        case 0x0F, 0x11: return .aac
        case 0x81: return .ac3
        case 0x87: return .eac3
        default: return .unknown
        }
    }

    private func isKeyframe(payload: Data, codec: CodecID) -> Bool {
        switch codec {
        case .h264:
            return containsH264IDR(payload)
        case .hevc:
            return containsHEVCIDR(payload)
        default:
            return false
        }
    }

    private func containsH264IDR(_ data: Data) -> Bool {
        for nalType in annexBNALTypes(in: data) where nalType == 5 {
            return true
        }
        return false
    }

    private func containsHEVCIDR(_ data: Data) -> Bool {
        for nalType in annexBNALTypes(in: data) where (19...21).contains(nalType) {
            return true
        }
        return false
    }

    private func annexBNALTypes(in data: Data) -> [UInt8] {
        guard data.count >= 5 else { return [] }
        var types: [UInt8] = []
        var i = 0
        while i + 4 < data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                let nal = data[i + 3]
                types.append(nal & 0x1F)
                i += 4
                continue
            }
            if i + 5 < data.count, data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                let nal = data[i + 4]
                // H.264 type uses low 5 bits; HEVC type is bits 1...6.
                let h264Type = nal & 0x1F
                let hevcType = (nal >> 1) & 0x3F
                types.append(h264Type)
                types.append(hevcType)
                i += 5
                continue
            }
            i += 1
        }
        return types
    }
}

private final class PCRNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private let wrap = Int64(1) << 42
    private var first: Int64?
    private var lastRaw: Int64?
    private var rolloverOffset: Int64 = 0

    func normalize(_ raw: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        if first == nil {
            first = raw
            lastRaw = raw
            return 0
        }
        if let lastRaw, raw < lastRaw, (lastRaw - raw) > (wrap / 2) {
            rolloverOffset += wrap
        }
        self.lastRaw = raw
        return (raw + rolloverOffset) - (first ?? 0)
    }
}
