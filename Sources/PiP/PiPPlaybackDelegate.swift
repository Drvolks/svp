import AVKit
import CoreMedia
import Foundation

public final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    public override init() {
        super.init()
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        _ = pictureInPictureController
        _ = playing
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        _ = pictureInPictureController
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        _ = pictureInPictureController
        _ = newRenderSize
    }

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        _ = pictureInPictureController
        return false
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        _ = pictureInPictureController
        _ = skipInterval
        completionHandler()
    }
}
