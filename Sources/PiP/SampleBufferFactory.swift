import AVFoundation
import CoreMedia
import Foundation
import PlayerCore

public struct SampleBufferFactory: Sendable {
    public init() {}

    public func makeSampleBuffer(
        from frame: DecodedVideoFrame,
        presentationTimeStamp: CMTime? = nil,
        duration: CMTime = CMTime(value: 3_000, timescale: 90_000),
        displayImmediately: Bool = false
    ) -> CMSampleBuffer? {
        guard let pixelBuffer = frame.pixelBuffer else { return nil }
        var format: CMVideoFormatDescription?
        let createFormatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )
        guard createFormatStatus == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp ?? frame.pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createBufferStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createBufferStatus == noErr, let sampleBuffer else { return nil }

        if displayImmediately {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }
}
