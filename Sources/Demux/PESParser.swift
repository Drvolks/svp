import Foundation

public enum PESParser {
    public static func splitTransportPackets(_ data: Data) -> [Data] {
        let packetSize = 188
        guard data.count >= packetSize else { return [] }
        var packets: [Data] = []
        packets.reserveCapacity(data.count / packetSize)
        var offset = 0
        while offset + packetSize <= data.count {
            packets.append(data.subdata(in: offset..<(offset + packetSize)))
            offset += packetSize
        }
        return packets
    }
}
