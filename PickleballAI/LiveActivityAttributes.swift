import Foundation
import ActivityKit

/// Shared between the app and the widget extension. Describes the live session
/// shown on the lock screen / Dynamic Island while a session is in progress.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Number of matches logged so far.
        var activityCount: Int
        /// Session title (or a time-of-day default).
        var title: String
        /// Running score of a live game streaming from the watch (US), if any.
        /// Primitive so the widget target needn't compile the shared score model.
        var us: Int?
        /// Running score of a live game streaming from the watch (THEM), if any.
        var them: Int?

        /// True while a watch game is in progress (both scores present).
        var hasLiveGame: Bool { us != nil && them != nil }
    }

    /// When the session started — drives the auto-updating on-screen timer.
    var startedAt: Date
}

extension SessionActivityAttributes {
    /// Deep link the Live Activity opens: resumes the in-progress session in the
    /// app. The scheme is registered under `CFBundleURLTypes` in `project.yml`
    /// and routed by `AppStore.handleInviteURL`.
    static let liveSessionURL = URL(string: "pickleballai://live-session")!
}
