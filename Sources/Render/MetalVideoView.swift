import Foundation

#if canImport(MetalKit) && canImport(UIKit)
import MetalKit
import UIKit

public final class MetalVideoView: MTKView {
    public override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        contentMode = .scaleAspectFit
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @MainActor
    public func attachRenderer(_ renderer: MetalRenderer) {
        renderer.bind(view: self)
    }
}

#elseif canImport(MetalKit) && canImport(AppKit)
import AppKit
import MetalKit

public final class MetalVideoView: MTKView {
    public override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        autoresizingMask = [.width, .height]
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @MainActor
    public func attachRenderer(_ renderer: MetalRenderer) {
        renderer.bind(view: self)
    }
}

#elseif canImport(UIKit)
import UIKit
public final class MetalVideoView: UIView {
    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public func attachRenderer(_ renderer: MetalRenderer) {
        _ = renderer
    }
}

#elseif canImport(AppKit)
import AppKit
public final class MetalVideoView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public func attachRenderer(_ renderer: MetalRenderer) {
        _ = renderer
    }
}

#else
public final class MetalVideoView {
    public init() {}
    public func attachRenderer(_ renderer: MetalRenderer) {
        _ = renderer
    }
}
#endif
