import SwiftUI

/// One selectable plan on the paywall. Prices are display strings here because
/// the source of truth for real prices is StoreKit (localized, tax-adjusted) —
/// when purchases go live these get populated from `Product`s instead of the
/// hardcoded previews below. `id` is the App Store product identifier.
struct PlanOption: Identifiable, Hashable {
    let id: String
    let title: String
    let priceText: String
    let periodText: String
    /// Small line under the price (trial terms or per-month equivalent).
    let footnote: String
    /// Optional accent badge (e.g. "SAVE 50%").
    let badge: String?
    /// Free-trial length in days, nil if the plan has no trial.
    let trialDays: Int?
    /// What the plan renews to after any trial, for the CTA subtitle
    /// (e.g. "$29.99/yr"). Kept separate from the display price so the
    /// billing sentence reads naturally.
    let renewalText: String
}

/// App-wide subscription state and the paywall's brain. Today it's a stub:
/// `isPro` is false and "purchasing" just flips a local flag so we can build and
/// screenshot the whole premium UX before wiring StoreKit/RevenueCat. When real
/// purchases land, only this class changes — every `isPro` gate and the paywall
/// UI stay exactly as they are.
@MainActor
final class SubscriptionStore: ObservableObject {
    /// The single switch every premium gate reads.
    @Published var isPro = false
    /// Drives the global paywall sheet. Set via `presentPaywall(_:)`.
    @Published var paywallContext: PaywallContext?
    /// In-flight purchase/restore, for button spinners.
    @Published var isWorking = false
    /// Which plan the paywall has selected. Annual is the default we want picked.
    @Published var selectedPlanID: String = annual.id

    static let annual = PlanOption(
        id: "com.pickleball.ai.pro.annual",
        title: "Annual",
        priceText: "$29.99",
        periodText: "per year",
        footnote: "7-day free trial, then $29.99/yr · $2.50/mo",
        badge: "SAVE 50%",
        trialDays: 7,
        renewalText: "$29.99/yr"
    )
    static let monthly = PlanOption(
        id: "com.pickleball.ai.pro.monthly",
        title: "Monthly",
        priceText: "$4.99",
        periodText: "per month",
        footnote: "7-day free trial, then $4.99/mo",
        badge: nil,
        trialDays: 7,
        renewalText: "$4.99/mo"
    )
    var plans: [PlanOption] { [Self.annual, Self.monthly] }

    /// Present the paywall for a given trigger. Calling this from a locked
    /// feature is the whole "tap premium → see plans" flow.
    func presentPaywall(_ context: PaywallContext = .general) {
        Haptics.tap()
        paywallContext = context
    }

    /// STUB purchase. Real version: buy the StoreKit product, verify the
    /// transaction, sync entitlement to Supabase, then flip `isPro`.
    func purchaseSelected() async {
        isWorking = true
        defer { isWorking = false }
        try? await Task.sleep(nanoseconds: 700_000_000)   // pretend to hit the App Store
        isPro = true
        Haptics.success()
        paywallContext = nil
    }

    /// STUB restore. Real version: `AppStore.sync()` / RevenueCat restore.
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        try? await Task.sleep(nanoseconds: 500_000_000)
        isWorking = false
    }

    #if DEBUG
    /// Dev-only: flip Pro without the paywall so gated UI can be exercised.
    func debugTogglePro() { isPro.toggle() }
    #endif
}

/// Why the paywall was shown — lets the headline speak to the exact feature the
/// user just reached for, which converts far better than a generic pitch.
enum PaywallContext: Identifiable, Hashable {
    case general
    case recap
    case rivalryInsights
    case unlimitedHistory

    var id: String {
        switch self {
        case .general:          return "general"
        case .recap:            return "recap"
        case .rivalryInsights:  return "rivalry"
        case .unlimitedHistory: return "history"
        }
    }

    var headline: String {
        switch self {
        case .general:          return "Go further with Pro"
        case .recap:            return "Unlock AI match recaps"
        case .rivalryInsights:  return "See the full rivalry breakdown"
        case .unlimitedHistory: return "Unlock your full history"
        }
    }
}
