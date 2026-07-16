import UIKit

/// Central, lightweight haptic feedback. One call site per intent so tactile
/// feedback stays consistent across the app — a win always feels the same as a
/// win, a tap always feels the same as a tap. Cheap to call; generators are
/// created on demand and discarded.
enum Haptics {
    /// A light tap for routine selections (toggling a segment, adding a chip).
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A firmer tap for a committed action (like, follow, add player).
    static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// The payoff: a logged session, a win, onboarding done.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Something failed and the user should feel it.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
