import AVKit
import Foundation

public final class PiPControllerBridge: NSObject {
    private let pipBridge: PiPBridge
    private let delegate: PiPPlaybackDelegate
    private var controller: AVPictureInPictureController?

    public init(pipBridge: PiPBridge, delegate: PiPPlaybackDelegate = PiPPlaybackDelegate()) {
        self.pipBridge = pipBridge
        self.delegate = delegate
        super.init()
        configureController()
    }

    public var isPictureInPicturePossible: Bool {
        controller?.isPictureInPicturePossible ?? false
    }

    public var isPictureInPictureActive: Bool {
        controller?.isPictureInPictureActive ?? false
    }

    public func start() {
        controller?.startPictureInPicture()
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    public func invalidate() {
        stop()
        controller?.delegate = nil
        controller = nil
    }

    private func configureController() {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: pipBridge.outputLayer(),
            playbackDelegate: delegate
        )
        controller = AVPictureInPictureController(contentSource: source)
    }
}
