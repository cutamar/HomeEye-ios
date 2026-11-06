import AVFoundation
import SwiftUI
import UIKit

/// UIView backed by an `AVSampleBufferDisplayLayer`. Touches pass through to SwiftUI.
final class VideoLayerUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }
}

struct VideoView: UIViewRepresentable {
    let view: VideoLayerUIView

    func makeUIView(context: Context) -> VideoLayerUIView { view }

    func updateUIView(_ uiView: VideoLayerUIView, context: Context) {}
}

/// Video with pinch-to-zoom (1…5x), pan while zoomed, double-tap to reset and single tap callback.
struct ZoomableVideo: View {
    let view: VideoLayerUIView
    let aspect: CGFloat
    var onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            VideoView(view: view)
                .aspectRatio(aspect, contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(zoomGesture(container: geo.size))
                .onTapGesture(count: 2) {
                    withAnimation { reset() }
                }
                .onTapGesture { onTap() }
        }
    }

    private func zoomGesture(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .simultaneously(with: DragGesture(minimumDistance: 10))
            .onChanged { value in
                var newScale = scale
                if let magnify = value.first {
                    newScale = min(max(lastScale * magnify.magnification, Self.minScale), Self.maxScale)
                }
                var proposed = lastOffset
                if newScale > 1, let drag = value.second {
                    proposed = CGSize(width: lastOffset.width + drag.translation.width,
                                      height: lastOffset.height + drag.translation.height)
                }
                scale = newScale
                offset = clamp(proposed, scale: newScale, container: container)
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }

    /// Size of the aspect-fit video inside the container, before scaling.
    private func displayedSize(in container: CGSize) -> CGSize {
        guard aspect > 0, container.width > 0, container.height > 0 else { return container }
        if container.width / container.height > aspect {
            return CGSize(width: container.height * aspect, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / aspect)
    }

    private func clamp(_ proposed: CGSize, scale: CGFloat, container: CGSize) -> CGSize {
        let size = displayedSize(in: container)
        let maxX = max(0, (scale - 1) * size.width / 2)
        let maxY = max(0, (scale - 1) * size.height / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
