import SwiftUI

/// Wraps any photo content with simple, consistent zoom + pan used across ALL photo views:
///   • double-click / double-tap → toggle between fit and 2.5×
///   • pinch (trackpad) → smooth zoom, clamped to 1–6×
///   • drag → pan, only while zoomed in
/// Works with a mouse (double-click) or trackpad (pinch), so it's easy for every coach.
struct ZoomablePhoto<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    @State private var zoom: CGFloat            = 1
    @State private var offset: CGSize           = .zero
    @GestureState private var liveZoom: CGFloat = 1
    @GestureState private var liveDrag: CGSize  = .zero

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom * liveZoom, anchor: .center)
                .offset(x: offset.width + liveDrag.width, y: offset.height + liveDrag.height)
                .gesture(
                    MagnificationGesture()
                        .updating($liveZoom) { v, s, _ in s = v }
                        .onEnded { v in
                            zoom = min(6, max(1, zoom * v))
                            if zoom <= 1 { zoom = 1; offset = .zero }
                        }
                )
                // Pan only when zoomed in, so at fit size the drag can't nudge the image.
                .simultaneousGesture(
                    DragGesture()
                        .updating($liveDrag) { v, s, _ in if zoom > 1 { s = v.translation } }
                        .onEnded { v in
                            guard zoom > 1 else { return }
                            offset = CGSize(width:  offset.width  + v.translation.width,
                                            height: offset.height + v.translation.height)
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if zoom > 1 { zoom = 1; offset = .zero } else { zoom = 2.5 }
                    }
                }
                .contentShape(Rectangle())
        }
        .clipped()
    }
}
