import Foundation
import ActivityKit

/// Shared between the app and the widget extension. Describes the live session
/// shown on the lock screen / Dynamic Island while a session is in progress.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Number of matches/practices logged so far.
        var activityCount: Int
        /// Session title (or a time-of-day default).
        var title: String
    }

    /// When the session started — drives the auto-updating on-screen timer.
    var startedAt: Date
}
