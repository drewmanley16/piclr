import Foundation

/// Build-time feature gates.
enum FeatureFlags {
    /// Whether any payment / paywall UI is shown at all.
    ///
    /// OFF in Release builds — which is what TestFlight and the App Store ship —
    /// so the store review build contains no subscription or purchase surface
    /// while the products and Paid Apps agreement aren't live yet. ON in local
    /// Debug builds so the paywall can keep being developed on the simulator.
    ///
    /// When monetization is ready to go public, flip this to an unconditional
    /// `true` (one line) and the paywall, Pro banner, and gated features light up.
    #if DEBUG
    static let monetizationEnabled = true
    #else
    static let monetizationEnabled = false
    #endif
}
