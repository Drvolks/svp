import Render
import SwiftUI

struct PlayerSurfaceView: UIViewRepresentable {
    let renderer: MetalRenderer

    func makeUIView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(frame: .zero, device: nil)
        Task { @MainActor in
            view.attachRenderer(renderer)
        }
        return view
    }

    func updateUIView(_ uiView: MetalVideoView, context: Context) {
        _ = context
        _ = uiView
    }
}
