import Foundation
import Nuke
import UIKit

/// Remote-image infrastructure: pipeline configuration and request construction.
///
/// This deliberately lives outside `DesignSystem.swift` — that file is the app's
/// visual vocabulary (`Theme`, `cardStyle()`, `IdentityRow`), not a place for
/// caching and networking policy. `RemoteImage` stays there as the view; every
/// decision about *how* bytes become a bitmap is made here.
enum ImageLoading {
    /// Installs the shared pipeline. Call once from the app entry point, before
    /// any view renders — `ImagePipeline.shared` is read lazily by every
    /// `LazyImage`, so a later swap would leave early loads on the default.
    static func configure() {
        // `withDataCache` gives an on-disk cache of *decoded* images and disables
        // URLCache, so cold launches don't re-download avatars regardless of what
        // cache headers Supabase Storage sends. The default in-memory ImageCache
        // (which sizes itself against available RAM) sits in front of it.
        var config = ImagePipeline.Configuration.withDataCache(
            name: "ai.pickleball.images",
            sizeLimit: 256 * 1024 * 1024
        )
        // `.automatic` skips the disk cache for any request carrying processors —
        // which is every request we make. `.storeAll` keeps the downsampled
        // result, so a re-appearing avatar costs neither a download nor a resize.
        config.dataCachePolicy = .storeAll
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    /// Target size for a full-bleed feed photo, whose width is `.infinity` at the
    /// call site and so can't be read from the layout without a greedy
    /// `GeometryReader`. The app is iPhone-only and portrait-locked, so screen
    /// width is a stable upper bound; over-fetching a few points is free because
    /// the processor crops to fill anyway.
    @MainActor
    static func feedPhotoSize(height: CGFloat) -> CGSize {
        CGSize(width: UIScreen.main.bounds.width, height: height)
    }

    /// Builds a request that downsamples to the size the image will actually be
    /// drawn at. This is the point of the whole exercise: a 2000px avatar decoded
    /// at full resolution into a 44pt circle costs orders of magnitude more work
    /// and memory than the visible result needs, and that cost lands on the main
    /// thread at draw time — mid-swipe.
    ///
    /// `.aspectFill` + `crop` matches the `.scaledToFill()` + `.clipped()` the
    /// call sites apply, so the processed bitmap is exactly what gets shown.
    /// Sizes are in points; Nuke scales by the screen's scale factor internally.
    static func request(url: URL, targetSize: CGSize?) -> ImageRequest {
        guard let targetSize, targetSize.width > 0, targetSize.height > 0 else {
            return ImageRequest(url: url)
        }
        return ImageRequest(
            url: url,
            processors: [.resize(size: targetSize, contentMode: .aspectFill, crop: true)]
        )
    }
}
