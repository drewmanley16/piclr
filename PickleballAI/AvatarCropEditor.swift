import SwiftUI
import UIKit

// MARK: - Avatar crop editor

/// Full-screen editor shown right after the user picks a profile photo.
/// Lets them pinch-zoom and drag the photo inside a square crop window
/// (Instagram-style — no rotation), then hands back the cropped square
/// `UIImage` for `AppStore.uploadProfilePhoto`, which owns the one
/// downscale-and-JPEG-encode step.
///
/// How it works, in one paragraph: the photo is laid out `scaledToFill` in a
/// square, then two plain SwiftUI effects are stacked on top — `scaleEffect`
/// (zoom) and `offset` (pan) — and the result is clipped to the square.
/// Committed values live in `@State`; in-flight gesture deltas live in
/// `@GestureState` (which SwiftUI resets to identity the moment fingers
/// lift), and the display always shows `committed ⊕ delta`. "Save" renders
/// the *exact same view* through `ImageRenderer`, so the exported crop is
/// pixel-for-pixel what the user saw — there is no separate CoreGraphics
/// math to drift out of sync.
///
/// Pan containment: the *displayed* offset is passed through `clampedPan`
/// every frame (committed value ⊕ in-flight delta), so the photo hard-stops
/// at the point where it would stop covering the crop square — the circle
/// can never show background.
struct AvatarCropEditor: View {
    let image: UIImage
    var onCancel: () -> Void
    /// Called with the square cropped image.
    var onDone: (UIImage) -> Void

    // Committed transform — updated once, when each gesture ends.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    // In-flight gesture deltas. `@GestureState` auto-resets to these initial
    // (identity) values when the gesture ends, which is also what drives the
    // grid: any non-identity delta means fingers are moving on screen.
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gesturePan: CGSize = .zero

    private let zoomRange: ClosedRange<CGFloat> = 1...6

    /// True while any pinch/drag is actively updating — controls the
    /// gridline overlay.
    private var isInteracting: Bool {
        gestureZoom != 1 || gesturePan != .zero
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // One size drives both the on-screen canvas and the final
                // render, so the committed pan offset (measured in points)
                // means the same thing in both.
                let cropSize = min(geo.size.width - 48, 340)

                VStack(spacing: 0) {
                    Spacer()

                    cropCanvas(size: cropSize)
                        .overlay(dimmedSurround)
                        .overlay(gridOverlay)
                        .overlay(
                            Circle().strokeBorder(Theme.courtLine, lineWidth: 1)
                        )

                    Text("Pinch to zoom • Drag to move")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 24)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Whole-surface hit area: gestures work even when fingers
                // start outside the crop square. The bar buttons live in the
                // navigation bar, above this view, so they never contend
                // with the drag.
                .contentShape(Rectangle())
                .gesture(transformGesture(cropSize: cropSize))
                .toolbar { toolbarContent(cropSize: cropSize) }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Adjust Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
    }

    // MARK: - Canvas (shared by display and export)

    /// The transformed, clipped square. This exact view is what the user
    /// manipulates on screen *and* what `renderCroppedJPEG` exports. Display
    /// chrome (dim layer, grid, circle stroke) is overlaid *outside* this
    /// builder so none of it leaks into the exported image.
    private func cropCanvas(size: CGFloat) -> some View {
        let liveZoom = zoom * gestureZoom
        // Clamp the offset at display time, every frame — dragging past the
        // edge simply stops the photo there (no overshoot, no snap-back),
        // and pinching out at an edge keeps the photo pinned to it.
        let livePan = clampedPan(
            CGSize(
                width: pan.width + gesturePan.width,
                height: pan.height + gesturePan.height
            ),
            zoom: liveZoom,
            cropSize: size
        )
        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(liveZoom)
            .offset(x: livePan.width, y: livePan.height)
            .frame(width: size, height: size)
            .clipped()
            .background(Theme.background)
    }

    /// Darkens the square's corners outside the inscribed circle, previewing
    /// the avatar's final circular shape (the corners still upload — every
    /// avatar in the app is displayed clipped to a circle).
    private var dimmedSurround: some View {
        CircleCutout()
            .fill(Theme.background.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
    }

    /// Rule-of-thirds guide: two vertical + two horizontal lines whose
    /// intersections form the center square. Visible only while fingers are
    /// actively transforming the photo.
    private var gridOverlay: some View {
        ThirdsGrid()
            .stroke(Theme.textSecondary, lineWidth: 1)
            .opacity(isInteracting ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isInteracting)
            .allowsHitTesting(false)
    }

    // MARK: - Gestures

    /// Pinch and drag run simultaneously, each writing its delta into
    /// `@GestureState` and folding into the committed value on end.
    /// `cropSize` is needed to clamp the committed pan.
    private func transformGesture(cropSize: CGFloat) -> some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .updating($gestureZoom) { value, state, _ in
                    state = value.magnification
                }
                .onEnded { value in
                    // The spring only matters when the pinch overshot the
                    // zoom limits (zoom rubber-bands; pan doesn't).
                    withAnimation(.spring(duration: 0.3)) {
                        zoom = (zoom * value.magnification)
                            .clamped(to: zoomRange)
                        // Zooming out shrinks the legal pan range — keep
                        // the committed offset inside it.
                        pan = clampedPan(pan, zoom: zoom, cropSize: cropSize)
                    }
                },
            DragGesture()
                .updating($gesturePan) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    // No animation: the display already showed the clamped
                    // position, so committing it is visually a no-op.
                    pan = clampedPan(
                        CGSize(
                            width: pan.width + value.translation.width,
                            height: pan.height + value.translation.height
                        ),
                        zoom: zoom,
                        cropSize: cropSize
                    )
                }
        )
    }

    /// Clamps a pan offset so the photo's footprint always fully covers the
    /// crop square — the photo can never be dragged off screen. At minimum
    /// zoom the fill-fitted photo exactly covers the square along its short
    /// side, so that axis clamps to zero.
    private func clampedPan(_ proposed: CGSize, zoom: CGFloat, cropSize: CGFloat) -> CGSize {
        // Dimensions the photo occupies when `scaledToFill`-fitted into the
        // square (short side == cropSize), before zoom.
        let aspect = image.size.width / max(image.size.height, 1)
        let baseWidth = aspect > 1 ? cropSize * aspect : cropSize
        let baseHeight = aspect > 1 ? cropSize : cropSize / aspect
        let maxX = max(0, (baseWidth * zoom - cropSize) / 2)
        let maxY = max(0, (baseHeight * zoom - cropSize) / 2)
        return CGSize(
            width: proposed.width.clamped(to: -maxX...maxX),
            height: proposed.height.clamped(to: -maxY...maxY)
        )
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private func toolbarContent(cropSize: CGFloat) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                Haptics.tap()
                onCancel()
            } label: {
                Text("Cancel")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Haptics.tap()
                if let cropped = renderCroppedImage(cropSize: cropSize) {
                    onDone(cropped)
                } else {
                    // Rendering essentially can't fail for a valid UIImage,
                    // but never strand the user in the editor if it does.
                    onCancel()
                }
            } label: {
                Text("Save")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Export

    /// Renders the same `cropCanvas` the user was looking at into a UIImage.
    /// Gesture deltas are guaranteed to be identity here (fingers are off the
    /// screen when Save is tappable), so only committed values apply. No JPEG
    /// encode happens here — `uploadProfilePhoto` owns the single
    /// downscale-and-encode so quality/size constants live in one place.
    private func renderCroppedImage(cropSize: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: cropCanvas(size: cropSize))
        // The upload pipeline downscales to 320px, so 2× the ~340pt crop
        // square is already more resolution than survives.
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Overlay shapes

/// A rectangle with its inscribed circle punched out (via even-odd fill) —
/// the dim layer that previews the circular avatar shape.
private struct CircleCutout: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Rectangle().path(in: rect)
        path.addPath(Circle().path(in: rect))
        return path
    }
}

/// Two vertical + two horizontal lines at the ⅓ and ⅔ marks — four lines
/// total, forming a square in the center cell.
private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
