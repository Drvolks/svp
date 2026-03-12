import AVFoundation
import AVKit
import CoreMedia
import Input
import PiP
import PlayerCore
import Render
import SVP
import SwiftUI

@MainActor
final class DemoPlayerViewModel: NSObject, ObservableObject {
    @Published var urlText = "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4"
    @Published var statusMessage = "Colle une URL MP4 puis appuie sur Load Video."
    @Published var isLoaded = false
    @Published var isPlaying = false
    @Published var isPiPActive = false
    @Published var isPiPPossible = false
    @Published var isEnded = false
    @Published var isFullscreenPresented = false

    let renderer = MetalRenderer()
    private let pipBridge = PiPBridge()
    private let pipPlaybackDelegate = PiPPlaybackDelegateBridge()

    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var player: Player?
    private var eventsTask: Task<Void, Never>?

    var canUsePiP: Bool {
        pipController != nil && isLoaded
    }

    override init() {
        super.init()
        configureAudioSession()
        pipPlaybackDelegate.updatePausedState(isPaused: true)
        configurePiP()
        pipPlaybackDelegate.setPlayingHandler = { [weak self] playing in
            guard let self else { return }
            Task {
                await self.setPlayback(playing: playing)
            }
        }
        refreshPiPPossible()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playback, .moviePlayback, [.allowAirPlay]),
            (.playback, .moviePlayback, []),
            (.playback, .default, [])
        ]
        for (index, attempt) in attempts.enumerated() {
            do {
                try session.setCategory(attempt.0, mode: attempt.1, options: attempt.2)
                try session.setActive(true)
                #if DEBUG
                print("[SVP][Audio] audio_session active=true attempt=\(index + 1) mode=\(attempt.1.rawValue)")
                #endif
                return
            } catch {
                #if DEBUG
                let nsError = error as NSError
                print("[SVP][Audio] audio_session attempt=\(index + 1) failed code=\(nsError.code) desc=\(error.localizedDescription)")
                #endif
            }
        }
    }

    deinit {
        eventsTask?.cancel()
        pipPossibleObservation?.invalidate()
    }

    func loadVideo() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusMessage = "URL invalide."
            return
        }

        do {
            await teardownCurrentPlayerIfNeeded()

            let source = try makeInputSource(url: url)
            let newPlayer = Player(source: source, preferHardwareDecode: false)
            await newPlayer.attachVideoOutput(renderer)
            await newPlayer.attachVideoOutput(pipBridge)

            let playableSource = PlayableSource(descriptor: source.descriptor)
            try await newPlayer.load(playableSource)

            eventsTask?.cancel()
            eventsTask = Task { [weak self] in
                guard let self else { return }
                let stream = await newPlayer.playbackEvents()
                for await event in stream {
                    self.handlePlaybackEvent(event)
                }
            }

            player = newPlayer
            isLoaded = true
            isPlaying = false
            isEnded = false
            statusMessage = "Vidéo chargée. Appuie sur Play Fullscreen."
        } catch {
            isLoaded = false
            isPlaying = false
            isEnded = false
            statusMessage = "Erreur load/play: \(error)"
        }
    }

    func togglePlayPause() async {
        if isEnded {
            await loadVideo()
            return
        }
        await setPlayback(playing: !isPlaying)
    }

    func playFullscreen() async {
        if !isLoaded || isEnded {
            await loadVideo()
        }
        await setPlayback(playing: true)
        refreshPiPPossible()
        isFullscreenPresented = true
    }

    func dismissFullscreen() {
        isFullscreenPresented = false
    }

    func togglePiP() {
        guard let pipController else {
            statusMessage = "PiP non disponible sur cet appareil."
            logPiP("toggle: controller=nil")
            return
        }
        refreshPiPPossible()
        logPiP("toggle: active=\(pipController.isPictureInPictureActive) possible=\(pipController.isPictureInPicturePossible)")
        if pipController.isPictureInPictureActive {
            logPiP("request stop")
            pipController.stopPictureInPicture()
        } else {
            logPiPLayerState(context: "before-start")
            guard pipBridge.hasEnqueuedFrames() else {
                statusMessage = "PiP pas encore possible (aucune frame rendue)."
                logPiP("request start blocked: no enqueued PiP frame yet")
                return
            }
            pipBridge.primeFromLatestFrame()
            logPiPLayerState(context: "after-prime")
            requestPiPStartWhenPossible(pipController)
        }
    }

    private func makeInputSource(url: URL) throws -> any InputSource {
        if url.isFileURL {
            return FileInputSource(url: url)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        return HTTPInputSource(url: url)
    }

    private func setPlayback(playing: Bool) async {
        guard let player else { return }
        if playing {
            await player.play()
            isPlaying = true
            pipPlaybackDelegate.updatePausedState(isPaused: false)
            isEnded = false
            statusMessage = "Lecture en cours"
        } else {
            await player.pause()
            isPlaying = false
            pipPlaybackDelegate.updatePausedState(isPaused: true)
            statusMessage = "Lecture en pause"
        }
    }

    private func teardownCurrentPlayerIfNeeded() async {
        eventsTask?.cancel()
        eventsTask = nil
        if let player {
            await player.pause()
        }
        self.player = nil
        isPlaying = false
        pipPlaybackDelegate.updatePausedState(isPaused: true)
        isEnded = false
    }

    private func handlePlaybackEvent(_ event: PlaybackEvent) {
        switch event {
        case .stateChanged(let state):
            switch state {
            case .playing:
                isPlaying = true
                pipPlaybackDelegate.updatePausedState(isPaused: false)
                isEnded = false
                refreshPiPPossible()
                if isLoaded {
                    statusMessage = "Lecture en cours"
                }
            case .paused:
                isPlaying = false
                pipPlaybackDelegate.updatePausedState(isPaused: true)
                statusMessage = "Lecture en pause"
            case .buffering:
                statusMessage = "Buffering..."
            case .failed(let message):
                isPlaying = false
                pipPlaybackDelegate.updatePausedState(isPaused: true)
                isEnded = false
                statusMessage = "Playback failed: \(message)"
            case .ended:
                isPlaying = false
                pipPlaybackDelegate.updatePausedState(isPaused: true)
                isEnded = true
                refreshPiPPossible()
                statusMessage = "Lecture terminée"
            default:
                break
            }
        case .error(let message):
            statusMessage = "Erreur: \(message)"
        default:
            break
        }
    }

    private func configurePiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusMessage = "PiP non supporté sur cet appareil."
            pipController = nil
            pipPossibleObservation?.invalidate()
            pipPossibleObservation = nil
            logPiP("configure: unsupported device")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: pipBridge.outputLayer(),
            playbackDelegate: pipPlaybackDelegate
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        pipPlaybackDelegate.bind(controller: controller)
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            let active = controller.isPictureInPictureActive
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPiPPossible = possible
                self.logPiP(
                    "KVO possible=\(possible) active=\(active) " +
                    "frames=\(self.pipBridge.enqueuedFramesCount())"
                )
            }
        }
        refreshPiPPossible()
        logPiPLayerState(context: "configure")
        logPiP("configure: supported=true")
    }

    private func logPiP(_ message: String) {
        #if DEBUG
        print("[SVP][PiP] \(message)")
        #endif
    }

    private func refreshPiPPossible() {
        isPiPPossible = pipController?.isPictureInPicturePossible ?? false
    }

    private func requestPiPStartWhenPossible(_ pipController: AVPictureInPictureController) {
        if pipController.isPictureInPicturePossible {
            logPiP("request start")
            pipController.startPictureInPicture()
            return
        }

        logPiP("request start delayed: possible=false, waiting for stable true")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...10 {
                try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
                guard let controller = self.pipController else { return }
                if controller.isPictureInPicturePossible {
                    self.logPiP("request start after wait attempt=\(attempt)")
                    controller.startPictureInPicture()
                    return
                }
            }
#if targetEnvironment(simulator)
            self.statusMessage = "PiP indisponible sur ce simulateur. Teste sur appareil réel."
#else
            self.statusMessage = "PiP pas encore possible (etat instable). Réessaie."
#endif
            self.logPiP("request start blocked: timed out waiting for possible=true")
        }
    }

    private func logPiPLayerState(context: String) {
        let layer = pipBridge.outputLayer()
        let statusText: String
        switch layer.status {
        case .unknown:
            statusText = "unknown"
        case .rendering:
            statusText = "rendering"
        case .failed:
            statusText = "failed"
        @unknown default:
            statusText = "unknown-default"
        }
        let errorText = layer.error?.localizedDescription ?? "nil"
        logPiP(
            "layer[\(context)] status=\(statusText) ready=\(layer.isReadyForMoreMediaData) " +
            "frames=\(pipBridge.enqueuedFramesCount()) error=\(errorText)"
        )
    }

    func pipOutputLayer() -> AVSampleBufferDisplayLayer {
        pipBridge.outputLayer()
    }

    func logPiPHostAttached() {
        logPiP("host attached")
        logPiPLayerState(context: "host-attached")
    }
}

extension DemoPlayerViewModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        _ = pictureInPictureController
        Task { @MainActor in
            self.logPiP("delegate willStart")
            self.pipBridge.primeFromLatestFrame()
            self.logPiPLayerState(context: "delegate-willStart-prime")
            self.isPiPActive = true
            self.refreshPiPPossible()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        _ = pictureInPictureController
        Task { @MainActor in
            self.logPiP("delegate didStart")
            self.pipBridge.primeFromLatestFrame()
            self.logPiPLayerState(context: "delegate-didStart-prime")
            self.isPiPActive = true
            self.isFullscreenPresented = false
            self.refreshPiPPossible()
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        _ = pictureInPictureController
        Task { @MainActor in
            self.logPiP("delegate willStop")
            self.isPiPActive = false
            self.refreshPiPPossible()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        _ = pictureInPictureController
        Task { @MainActor in
            self.logPiP("delegate didStop")
            self.isPiPActive = false
            self.refreshPiPPossible()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        _ = pictureInPictureController
        Task { @MainActor in
            self.logPiP("delegate failedToStart error=\(error.localizedDescription)")
            self.statusMessage = "PiP start failed: \(error.localizedDescription)"
            self.isPiPActive = false
            self.refreshPiPPossible()
        }
    }
}

private final class PiPPlaybackDelegateBridge: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let lock = NSLock()
    private weak var controller: AVPictureInPictureController?
    private var isPaused = true
    var setPlayingHandler: (@Sendable (Bool) -> Void)?

    func bind(controller: AVPictureInPictureController) {
        self.controller = controller
        invalidatePlaybackState()
    }

    func updatePausedState(isPaused: Bool) {
        lock.withLock {
            self.isPaused = isPaused
        }
        invalidatePlaybackState()
    }

    private func invalidatePlaybackState() {
        guard #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) else { return }
        if Thread.isMainThread {
            invalidatePlaybackStateOnMainThread()
        } else {
            performSelector(onMainThread: #selector(invalidatePlaybackStateOnMainThreadObjC), with: nil, waitUntilDone: false)
        }
    }

    @objc private func invalidatePlaybackStateOnMainThreadObjC() {
        invalidatePlaybackStateOnMainThread()
    }

    private func invalidatePlaybackStateOnMainThread() {
        guard #available(iOS 15.0, tvOS 15.0, macOS 12.0, *) else { return }
        controller?.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        _ = pictureInPictureController
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        _ = pictureInPictureController
        return lock.withLock { isPaused }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        _ = pictureInPictureController
        let handler = setPlayingHandler
        if Thread.isMainThread {
            handler?(playing)
        } else {
            DispatchQueue.main.async {
                handler?(playing)
            }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        _ = pictureInPictureController
        _ = newRenderSize
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        _ = pictureInPictureController
        _ = skipInterval
        completion()
    }
}
