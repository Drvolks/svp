import AVFoundation
import SwiftUI
import UIKit

private final class PiPLayerHostUIView: UIView {
    private let pipLayer: AVSampleBufferDisplayLayer

    init(pipLayer: AVSampleBufferDisplayLayer) {
        self.pipLayer = pipLayer
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(pipLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pipLayer.frame = bounds
    }

    func ensureAttached() {
        if pipLayer.superlayer !== layer {
            pipLayer.removeFromSuperlayer()
            layer.addSublayer(pipLayer)
            setNeedsLayout()
        }
    }
}

struct PiPLayerHostView: UIViewRepresentable {
    let pipLayer: AVSampleBufferDisplayLayer
    let onAttached: (() -> Void)?

    func makeUIView(context: Context) -> PiPLayerHostUIView {
        let view = PiPLayerHostUIView(pipLayer: pipLayer)
        view.ensureAttached()
        DispatchQueue.main.async {
            onAttached?()
        }
        return view
    }

    func updateUIView(_ uiView: PiPLayerHostUIView, context: Context) {
        uiView.ensureAttached()
    }
}
