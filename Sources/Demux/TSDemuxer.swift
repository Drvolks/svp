import CoreMedia
import Foundation
import PlayerCore

public actor TSDemuxer: PlayerCore.DemuxEngine {
    private let packets: AsyncThrowingStream<DemuxedPacket, Error>
    private let normalizer = TimestampNormalizer()

    public init(packets: AsyncThrowingStream<DemuxedPacket, Error>) {
        self.packets = packets
    }

    public func makePacketStream() -> AsyncThrowingStream<DemuxedPacket, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await packet in packets {
                        let normalizedPTS = packet.pts.map { normalizer.normalize($0) }
                        continuation.yield(
                            DemuxedPacket(
                                streamID: packet.streamID,
                                pts: normalizedPTS,
                                dts: packet.dts,
                                duration: packet.duration,
                                data: packet.data,
                                isKeyframe: packet.isKeyframe,
                                formatHint: packet.formatHint
                            )
                        )
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
        _ = to
        normalizer.reset()
    }

    public func duration() async -> CMTime? {
        nil
    }
}
