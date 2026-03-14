import CoreMedia
import Foundation
import PlayerCore

#if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
import CoreImage
import Metal
import MetalKit
#endif

public final class MetalRenderer: NSObject, @unchecked Sendable, VideoOutput {
    private let lock = NSLock()
    private var lastFramePTS: CMTime = .zero
    private var previousSubmittedPTS: CMTime?
    private var recentFrameDurations: [Double] = []
    private var currentPreferredFPS: Int = 60
    private var pendingPreferredFPS: Int?
    private var pendingPreferredFPSHits: Int = 0
    private var fixedPreferredFPS: Int?
    private var lockEstimatedPreferredFPS = false
    private var submittedFrameCount: Int = 0
    private var drawnFrameCount: Int = 0
    private var latestSubmittedPTS: CMTime = .zero
    private var lastSubmitUptime: TimeInterval?
    private var lastSubmitPTSForLog: CMTime?

    #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private lazy var ciContext: CIContext? = {
        guard let device else { return nil }
        return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }()
    private var boundView: MTKView?
    private var latestPixelBuffer: CVPixelBuffer?
    #endif

    public override init() {
        #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = self.device?.makeCommandQueue()
        #endif
        super.init()
    }

    public func render(frame: DecodedVideoFrame) {
        lock.lock()
        if let previousSubmittedPTS, previousSubmittedPTS.isValid, frame.pts.isValid {
            let delta = frame.pts.seconds - previousSubmittedPTS.seconds
            if delta > 0.001, delta < 0.2 {
                recentFrameDurations.append(delta)
                if recentFrameDurations.count > 12 {
                    recentFrameDurations.removeFirst(recentFrameDurations.count - 12)
                }
            }
        }
        previousSubmittedPTS = frame.pts
        lastFramePTS = frame.pts
        latestSubmittedPTS = frame.pts
        submittedFrameCount += 1
        let submittedFrameCount = submittedFrameCount
        let now = ProcessInfo.processInfo.systemUptime
        let submitIntervalMs: Double?
        if let lastSubmitUptime {
            submitIntervalMs = (now - lastSubmitUptime) * 1000
        } else {
            submitIntervalMs = nil
        }
        let submitDeltaPTS: Double?
        if let lastSubmitPTSForLog, lastSubmitPTSForLog.isValid, frame.pts.isValid {
            submitDeltaPTS = (frame.pts - lastSubmitPTSForLog).seconds * 1000
        } else {
            submitDeltaPTS = nil
        }
        self.lastSubmitUptime = now
        self.lastSubmitPTSForLog = frame.pts
        let estimatedFPS = estimatedPreferredFPSLocked()
        let preferredFPS: Int
        if let fixedPreferredFPS {
            preferredFPS = fixedPreferredFPS
        } else {
            preferredFPS = resolvedPreferredFPSLocked(from: estimatedFPS)
            if lockEstimatedPreferredFPS, preferredFPS != currentPreferredFPS {
                fixedPreferredFPS = preferredFPS
            }
        }
        let shouldUpdateFPS = preferredFPS != currentPreferredFPS
        if shouldUpdateFPS {
            currentPreferredFPS = preferredFPS
        }
        #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
        latestPixelBuffer = frame.pixelBuffer
        #endif
        lock.unlock()

        #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
        if shouldUpdateFPS {
            Task { @MainActor [weak self] in
                guard let self, let view = self.boundView else { return }
                view.preferredFramesPerSecond = preferredFPS
                #if DEBUG
                print("[SVP][Render] preferred_fps=\(preferredFPS)")
                #endif
            }
        }
        #endif
    }

    public func currentFrameTime() -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        return lastFramePTS
    }

    public func setFixedPreferredFPS(_ fps: Int?) {
        lock.lock()
        fixedPreferredFPS = fps
        if let fps {
            currentPreferredFPS = fps
            pendingPreferredFPS = nil
            pendingPreferredFPSHits = 0
        }
        lock.unlock()

        #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
        if let fps {
            Task { @MainActor [weak self] in
                guard let view = self?.boundView else { return }
                view.preferredFramesPerSecond = fps
                #if DEBUG
                print("[SVP][Render] preferred_fps=\(fps) fixed=true")
                #endif
            }
        }
        #endif
    }

    public func setLockEstimatedPreferredFPS(_ shouldLock: Bool) {
        self.lock.lock()
        lockEstimatedPreferredFPS = shouldLock
        if !shouldLock {
            fixedPreferredFPS = nil
            pendingPreferredFPS = nil
            pendingPreferredFPSHits = 0
        }
        self.lock.unlock()
    }

    #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
    @MainActor
    public func bind(view: MTKView) {
        lock.lock()
        boundView = view
        lock.unlock()

        view.device = device
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = self
        view.preferredFramesPerSecond = currentPreferredFPS
        view.colorPixelFormat = .bgra8Unorm
    }
    #endif

    private func estimatedPreferredFPSLocked() -> Int {
        guard recentFrameDurations.count >= 6 else { return currentPreferredFPS }
        let sortedDurations = recentFrameDurations.sorted()
        let medianDuration = sortedDurations[sortedDurations.count / 2]
        let fps = 1.0 / medianDuration
        switch fps {
        case 0..<27:
            return 24
        case 27..<36:
            return 30
        case 35..<55:
            return 50
        default:
            return 60
        }
    }

    private func resolvedPreferredFPSLocked(from estimatedFPS: Int) -> Int {
        guard estimatedFPS != currentPreferredFPS else {
            pendingPreferredFPS = nil
            pendingPreferredFPSHits = 0
            return currentPreferredFPS
        }

        if pendingPreferredFPS == estimatedFPS {
            pendingPreferredFPSHits += 1
        } else {
            pendingPreferredFPS = estimatedFPS
            pendingPreferredFPSHits = 1
        }

        guard pendingPreferredFPSHits >= 12 else {
            return currentPreferredFPS
        }

        pendingPreferredFPS = nil
        pendingPreferredFPSHits = 0
        return estimatedFPS
    }
}

#if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
extension MetalRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = size
    }

    public func draw(in view: MTKView) {
        let start = ProcessInfo.processInfo.systemUptime
        guard let drawable = view.currentDrawable,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let ciContext else {
            return
        }

        lock.lock()
        let pixelBuffer = latestPixelBuffer
        let framePTS = lastFramePTS
        let latestSubmittedPTS = latestSubmittedPTS
        let latestSubmittedCount = submittedFrameCount
        drawnFrameCount += 1
        let drawnFrameCount = drawnFrameCount
        lock.unlock()
        guard let pixelBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let scaledImage = image.transformed(by: Self.aspectFitTransform(for: image.extent.size, in: drawableSize))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        ciContext.render(
            scaledImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if drawnFrameCount == 1 || drawnFrameCount % 60 == 0 {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let staleBy = latestSubmittedPTS.isValid && framePTS.isValid ? max(0, latestSubmittedPTS.seconds - framePTS.seconds) : 0
            #if DEBUG
            print(
                "[SVP][Render] draw count=\(drawnFrameCount) pts=\(String(format: "%.3f", framePTS.seconds)) " +
                "ms=\(String(format: "%.2f", elapsedMs)) drawable=\(drawable.texture.width)x\(drawable.texture.height) " +
                "latestSubmitCount=\(latestSubmittedCount) latestSubmitPTS=\(String(format: "%.3f", latestSubmittedPTS.seconds)) staleBy=\(String(format: "%.3f", staleBy))"
            )
            #endif
        }
    }

    private static func aspectFitTransform(for source: CGSize, in target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return .identity
        }
        let scale = min(target.width / source.width, target.height / source.height)
        let scaled = CGSize(width: source.width * scale, height: source.height * scale)
        let tx = (target.width - scaled.width) / 2
        let ty = (target.height - scaled.height) / 2
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }
}
#endif
