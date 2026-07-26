import Foundation

/// Build-time feature gates.
enum FeatureFlags {
    /// Master kill switch for **all** paid features — the paywall, Pro badges,
    /// Insights, unlimited history, rivalry insights, and every other gated
    /// surface. They all read this through `monetizationEnabled` below, so this
    /// one flag turns the entire subscription surface on or off.
    ///
    /// Keep it `false` until subscriptions are fully set up: App Store Connect
    /// products approved, the Paid Apps agreement active, and RevenueCat
    /// offerings live. While it's `false`, **no paid feature ships in a
    /// TestFlight or App Store build.** Flip it to `true` (one line) to launch.
    static let subscriptionsEnabled = true

    /// Whether any payment / paywall UI is shown at all. Every Pro gate reads
    /// this (directly, or via `SubscriptionStore.showsLockedFeatures` /
    /// `showsProStatus`).
    ///
    /// - **Release** (TestFlight / App Store): on only when `subscriptionsEnabled`
    ///   is `true`, so nothing paid reaches testers or users before launch.
    /// - **Debug**: always on, so the paywall and gated features can keep being
    ///   developed on the simulator regardless of the master switch.
    static var monetizationEnabled: Bool {
        #if DEBUG
        return true
        #else
        return subscriptionsEnabled
        #endif
    }
}
