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
        lastFramePTS = frame.pts
        #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
        latestPixelBuffer = frame.pixelBuffer
        #endif
        lock.unlock()

        #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
        Task { @MainActor [weak self] in
            guard let view = self?.boundView else { return }
            #if canImport(UIKit)
            view.setNeedsDisplay()
            #elseif canImport(AppKit)
            view.setNeedsDisplay(view.bounds)
            #endif
        }
        #endif
    }

    public func currentFrameTime() -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        return lastFramePTS
    }

    #if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
    @MainActor
    public func bind(view: MTKView) {
        lock.lock()
        boundView = view
        lock.unlock()

        view.device = device
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = self
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        #if canImport(UIKit)
        view.setNeedsDisplay()
        #elseif canImport(AppKit)
        view.setNeedsDisplay(view.bounds)
        #endif
    }
    #endif
}

#if canImport(Metal) && canImport(MetalKit) && canImport(CoreImage)
extension MetalRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = size
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let ciContext else {
            return
        }

        lock.lock()
        let pixelBuffer = latestPixelBuffer
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
