import CoreMedia
import FFmpegBridge
import Foundation
import PlayerCore

public actor FFmpegAudioDecoder: AudioDecoder {
    private let handleBox = FFmpegAudioDecoderHandleBox()
    private var activeCodec: CodecID?

    public init() {}

    public func decode(_ packet: DemuxedPacket) async throws -> [DecodedAudioFrame] {
        guard packet.formatHint == .aac || packet.formatHint == .opus || packet.formatHint == .ac3 || packet.formatHint == .eac3 else {
            throw AudioDecodeError.unsupportedCodec(packet.formatHint)
        }
        guard let pts = packet.pts else { throw AudioDecodeError.needMoreData }
        guard svp_ffmpeg_bridge_has_vendor_backend() == 1 else {
            throw AudioDecodeError.backendUnavailable
        }

        try ensureDecoder(codec: packet.formatHint)
        guard let handle = handleBox.raw else {
            throw AudioDecodeError.backendUnavailable
        }

        var decodedFrames: [DecodedAudioFrame] = []
        var frame = svp_ffmpeg_decoded_audio_frame_t()
        let initialStatus = packet.data.withUnsafeBytes { bytes in
            svp_ffmpeg_audio_decoder_decode(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                Int32(packet.data.count),
                pts,
                &frame
            )
        }
        do {
            try appendDecodedFrame(from: &frame, status: initialStatus, into: &decodedFrames)
        } catch AudioDecodeError.needMoreData {
            return decodedFrames
        }

        while true {
            var drained = svp_ffmpeg_decoded_audio_frame_t()
            let drainStatus = svp_ffmpeg_audio_decoder_drain(handle, &drained)
            do {
                try appendDecodedFrame(from: &drained, status: drainStatus, into: &decodedFrames)
            } catch AudioDecodeError.needMoreData {
                break
            }
            if drainStatus == 0 {
                break
            }
        }

        return decodedFrames
    }

    public func flush() async {
        guard let handle = handleBox.raw else { return }
        _ = svp_ffmpeg_audio_decoder_flush(handle)
    }

    private func ensureDecoder(codec: CodecID) throws {
        if activeCodec != codec {
            if let handle = handleBox.raw {
                svp_ffmpeg_audio_decoder_destroy(handle)
                handleBox.raw = nil
            }
            activeCodec = codec
        }
        if handleBox.raw != nil {
            return
        }
        let created = svp_ffmpeg_audio_decoder_create(codecID(codec))
        guard let created else {
            throw AudioDecodeError.backendUnavailable
        }
        handleBox.raw = created
    }

    private func codecID(_ codec: CodecID) -> Int32 {
        switch codec {
        case .aac: return 3
        case .opus: return 4
        case .ac3: return 5
        case .eac3: return 6
        default: return 0
        }
    }

    private func appendDecodedFrame(
        from frame: inout svp_ffmpeg_decoded_audio_frame_t,
        status: Int32,
        into output: inout [DecodedAudioFrame]
    ) throws {
        defer { svp_ffmpeg_decoded_audio_frame_release(&frame) }

        if status == 0 {
            throw AudioDecodeError.needMoreData
        }
        if status < 0 {
            throw AudioDecodeError.decodeFailed(OSStatus(status))
        }
        guard frame.size > 0, let dataPtr = frame.data else { return }

        let data = Data(bytes: dataPtr, count: Int(frame.size))
        output.append(
            DecodedAudioFrame(
                pts: CMTime(value: frame.pts90k, timescale: 90_000),
                sampleRate: Double(frame.sampleRate),
                channels: Int(frame.channels),
                data: data
            )
        )
    }
}

private final class FFmpegAudioDecoderHandleBox: @unchecked Sendable {
    var raw: UnsafeMutableRawPointer?

    deinit {
        if let raw {
            svp_ffmpeg_audio_decoder_destroy(raw)
        }
    }
}
