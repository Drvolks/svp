import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @ObservedObject var viewModel: DemoPlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            TextField("https://...", text: $viewModel.urlText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Load Video") {
                    Task { await viewModel.loadVideo() }
                }
                .buttonStyle(.borderedProminent)

                Button("Play Fullscreen") {
                    Task { await viewModel.playFullscreen() }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isLoaded)
            }

            Text(viewModel.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .padding()
        .overlay {
            PiPLayerHostView(pipLayer: viewModel.pipOutputLayer(), onAttached: nil)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .fullScreenCover(isPresented: $viewModel.isFullscreenPresented) {
            FullscreenPlayerView(viewModel: viewModel)
        }
    }
}

private struct FullscreenPlayerView: View {
    @ObservedObject var viewModel: DemoPlayerViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurfaceView(renderer: viewModel.renderer)
                .ignoresSafeArea()
            PiPLayerHostView(pipLayer: viewModel.pipOutputLayer(), onAttached: {
                viewModel.logPiPHostAttached()
            })
            .frame(width: 2, height: 2)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Button {
                viewModel.dismissFullscreen()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(16)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12) {
                Button {
                    viewModel.togglePiP()
                } label: {
                    Image(systemName: viewModel.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(viewModel.isPiPPossible ? 0.95 : 0.45))
                }

                Button {
                    Task { await viewModel.togglePlayPause() }
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(16)
        }
    }
}

#Preview {
    ContentView(viewModel: DemoPlayerViewModel())
}

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

private struct PiPLayerHostView: UIViewRepresentable {
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
