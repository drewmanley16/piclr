import OSLog
import RevenueCat
import Supabase
import SwiftUI

private let logger = Logger(subsystem: "com.pickleball.ai", category: "Subscriptions")

/// One selectable plan on the paywall. Prices are display strings because the
/// source of truth is StoreKit (localized, tax-adjusted): when RevenueCat
/// offerings load, these are rebuilt from the real `StoreProduct`s. The
/// hardcoded values below are a display fallback for when the store can't be
/// reached. `id` is the App Store product identifier.
struct PlanOption: Identifiable, Hashable {
    let id: String
    let title: String
    let priceText: String
    let periodText: String
    /// Small line under the price (trial terms or per-month equivalent).
    let footnote: String
    /// Optional accent badge (e.g. "SAVE 50%").
    let badge: String?
    /// Free-trial length in days, nil if the plan has no trial or the user
    /// isn't eligible for the intro offer (Apple grants it once per user).
    let trialDays: Int?
    /// What the plan renews to after any trial, for the CTA subtitle
    /// (e.g. "$29.99/yr"). Kept separate from the display price so the
    /// billing sentence reads naturally.
    let renewalText: String
}

/// App-wide subscription state and the paywall's brain, backed by RevenueCat.
///
/// - `isPro` follows the "pro" entitlement via `customerInfoStream`.
/// - Identity: a task on `supabase.auth.authStateChanges` mirrors Supabase
///   sign-in/out into `Purchases.logIn/logOut`, so entitlements follow the
///   account (lowercased auth UUID), not the device. AppStore stays unaware
///   of subscriptions entirely.
/// - When the SDK isn't configured (no RevenueCat.plist) the store falls back
///   to the pre-RevenueCat stub behavior in DEBUG so the paywall UX can still
///   be exercised on the simulator; monetization is compiled out of Release.
@MainActor
final class SubscriptionStore: ObservableObject {
    /// The single switch every premium gate reads. Only this class writes it.
    @Published private(set) var isPro = false

    /// Whether the app should surface any paywall / Pro UI. Off in the App Store
    /// build (see `FeatureFlags`), so Pro entry points hide entirely there.
    var monetizationEnabled: Bool { FeatureFlags.monetizationEnabled }

    /// True when a feature should be shown but locked behind the paywall:
    /// monetization is live and the user isn't Pro yet. When monetization is off,
    /// this is false everywhere so gated features simply don't appear.
    var showsLockedFeatures: Bool { monetizationEnabled && !isPro }
    /// True when the user's Pro status should be celebrated (profile badge etc.).
    var showsProStatus: Bool { monetizationEnabled && isPro }
    /// Drives the global paywall sheet. Set via `presentPaywall(_:)`.
    @Published var paywallContext: PaywallContext?
    /// In-flight purchase/restore, for button spinners.
    @Published var isWorking = false
    /// User-facing line for a failed purchase/restore, shown on the paywall.
    /// Cleared when the paywall re-presents or a new attempt starts.
    @Published private(set) var errorText: String?
    /// Which plan the paywall has selected. Annual is the default we want picked.
    @Published var selectedPlanID: String = fallbackAnnual.id
    /// Paywall plan cards. Starts as the hardcoded fallback, replaced with
    /// localized StoreKit data once offerings load.
    @Published private(set) var plans: [PlanOption] = [fallbackAnnual, fallbackMonthly]

    /// `Purchases.shared` is only safe to touch when this is true (the SDK
    /// crashes if used unconfigured) — same gate as `configureRevenueCat()`.
    private let purchasesActive = FeatureFlags.monetizationEnabled && RevenueCatConfig.isConfigured

    /// RevenueCat packages keyed by product id, once offerings load.
    private var packages: [String: Package] = [:]
    private var authTask: Task<Void, Never>?
    private var customerInfoTask: Task<Void, Never>?

    static let fallbackAnnual = PlanOption(
        id: "com.pickleball.ai.pro.annual",
        title: "Annual",
        priceText: "$29.99",
        periodText: "per year",
        footnote: "7-day free trial, then $29.99/yr · $2.50/mo",
        badge: "SAVE 50%",
        trialDays: 7,
        renewalText: "$29.99/yr"
    )
    static let fallbackMonthly = PlanOption(
        id: "com.pickleball.ai.pro.monthly",
        title: "Monthly",
        priceText: "$4.99",
        periodText: "per month",
        footnote: "7-day free trial, then $4.99/mo",
        badge: nil,
        trialDays: 7,
        renewalText: "$4.99/mo"
    )

    init() {
        guard purchasesActive else { return }
        watchCustomerInfo()
        watchAuthState()
        Task { await loadOfferings() }
    }

    deinit {
        authTask?.cancel()
        customerInfoTask?.cancel()
    }

    /// Present the paywall for a given trigger. Calling this from a locked
    /// feature is the whole "tap premium → see plans" flow.
    func presentPaywall(_ context: PaywallContext = .general) {
        guard monetizationEnabled else { return }
        Haptics.tap()
        errorText = nil
        paywallContext = context
        Analytics.capture(.paywallViewed, [Analytics.Property.context: context.id])
    }

    // MARK: Entitlement

    private func watchCustomerInfo() {
        customerInfoTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard let self else { return }
                self.apply(info)
            }
        }
    }

    private func apply(_ info: CustomerInfo) {
        isPro = info.entitlements[RevenueCatConfig.entitlementID]?.isActive == true
        // Keep `is_pro` (super + person property) in lockstep with the entitlement,
        // whatever changed it — purchase, restore, renewal, expiry, another device.
        Analytics.setPro(isPro)
        // Whatever activated Pro (purchase, restore, renewal, another device),
        // a visible paywall is now moot — send the user back where they were.
        if isPro, paywallContext != nil {
            paywallContext = nil
        }
    }

    // MARK: Identity

    /// Mirror Supabase auth into RevenueCat identity. Fires on session restore
    /// (`.initialSession`), fresh OTP sign-in, sign-out, and account deletion —
    /// AppStore needs no knowledge of this store.
    private func watchAuthState() {
        authTask = Task { [weak self] in
            for await (event, session) in supabase.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn:
                    guard let session else { continue }
                    await self.logIn(userId: session.user.id)
                case .signedOut, .userDeleted:
                    await self.logOut()
                default:
                    break
                }
            }
        }
    }

    private func logIn(userId: UUID) async {
        let appUserID = RevenueCatConfig.appUserID(for: userId)
        guard Purchases.shared.appUserID != appUserID else { return }
        do {
            let (info, _) = try await Purchases.shared.logIn(appUserID)
            apply(info)
            // Trial eligibility is per-Apple-account; refresh for the new user.
            await loadOfferings()
        } catch {
            logger.error("logIn failed: \(error)")
        }
    }

    private func logOut() async {
        // logOut throws if the current user is already anonymous.
        guard !Purchases.shared.isAnonymous else { return }
        isPro = false
        do {
            let info = try await Purchases.shared.logOut()
            apply(info)
        } catch {
            logger.error("logOut failed: \(error)")
        }
    }

    // MARK: Offerings

    /// Fetch the current offering and rebuild `plans` from real store products.
    /// On failure the hardcoded fallback plans stay up and `purchaseSelected()`
    /// retries the fetch before giving up.
    private func loadOfferings() async {
        guard purchasesActive else { return }
        do {
            guard let offering = try await Purchases.shared.offerings().current else { return }
            let byProduct = Dictionary(
                offering.availablePackages.map { ($0.storeProduct.productIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
                productIdentifiers: Array(byProduct.keys)
            )

            let annual = byProduct[Self.fallbackAnnual.id]
            let monthly = byProduct[Self.fallbackMonthly.id]
            var built: [PlanOption] = []
            if let annual {
                built.append(planOption(
                    for: annual,
                    title: "Annual",
                    eligibility: eligibility,
                    savingsVersus: monthly?.storeProduct
                ))
            }
            if let monthly {
                built.append(planOption(
                    for: monthly,
                    title: "Monthly",
                    eligibility: eligibility,
                    savingsVersus: nil
                ))
            }
            guard !built.isEmpty else { return }
            packages = byProduct
            plans = built
            if !plans.contains(where: { $0.id == selectedPlanID }) {
                selectedPlanID = plans[0].id
            }
        } catch {
            logger.error("offerings fetch failed: \(error)")
        }
    }

    /// Build a display plan from a live store product: localized prices, real
    /// trial terms (only when this user is still intro-offer eligible), and a
    /// savings badge computed from the actual prices rather than hardcoded.
    private func planOption(
        for package: Package,
        title: String,
        eligibility: [String: IntroEligibility],
        savingsVersus monthly: StoreProduct?
    ) -> PlanOption {
        let product = package.storeProduct
        let price = product.localizedPriceString
        let isAnnual = product.subscriptionPeriod?.unit == .year

        let eligible = eligibility[product.productIdentifier]?.status == .eligible
        let trialDays: Int? = {
            guard eligible,
                  let intro = product.introductoryDiscount,
                  intro.paymentMode == .freeTrial else { return nil }
            return intro.subscriptionPeriod.days
        }()

        let renewalText = "\(price)/\(isAnnual ? "yr" : "mo")"
        var footnote = trialDays.map { "\($0)-day free trial, then \(renewalText)" } ?? renewalText
        if isAnnual, let perMonth = product.localizedPricePerMonth {
            footnote += " · \(perMonth)/mo"
        }

        var badge: String?
        if isAnnual, let monthly, monthly.price > 0 {
            let yearAtMonthly = (monthly.price * 12 as NSDecimalNumber).doubleValue
            let percent = Int(((yearAtMonthly - (product.price as NSDecimalNumber).doubleValue) / yearAtMonthly * 100).rounded())
            if percent > 0 { badge = "SAVE \(percent)%" }
        }

        return PlanOption(
            id: product.productIdentifier,
            title: title,
            priceText: price,
            periodText: isAnnual ? "per year" : "per month",
            footnote: footnote,
            badge: badge,
            trialDays: trialDays,
            renewalText: renewalText
        )
    }

    // MARK: Purchase / restore

    func purchaseSelected() async {
        errorText = nil
        guard purchasesActive else {
            #if DEBUG
            // No RevenueCat.plist on this machine — pretend-purchase so the
            // premium UX can still be walked end to end on the simulator.
            await stubPurchase()
            #else
            // Monetization is on but the SDK never configured (plist missing
            // from the archive). Never pretend-succeed in a shipping build.
            logger.fault("purchase attempted with unconfigured Purchases SDK")
            errorText = "Purchases aren't available right now. Please try again later."
            Haptics.warning()
            #endif
            return
        }
        isWorking = true
        defer { isWorking = false }

        if packages[selectedPlanID] == nil { await loadOfferings() }
        guard let package = packages[selectedPlanID] else {
            errorText = "Can't reach the App Store right now. Check your connection and try again."
            Haptics.warning()
            return
        }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return }
            apply(result.customerInfo)
            let startedTrial = plans.first { $0.id == selectedPlanID }?.trialDays != nil
            Analytics.capture(.purchaseCompleted, [
                Analytics.Property.planID: package.storeProduct.productIdentifier,
                Analytics.Property.trialStarted: startedTrial
            ], setUserProperties: [Analytics.Property.isPro: true])
            Haptics.success()
            paywallContext = nil
        } catch {
            if (error as? RevenueCat.ErrorCode) != .purchaseCancelledError {
                logger.error("purchase failed: \(error)")
                errorText = "The purchase couldn't be completed. Please try again."
                Haptics.warning()
            }
        }
    }

    func restore() async {
        guard purchasesActive else { return }
        errorText = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            if isPro {
                Analytics.capture(.purchaseRestored, setUserProperties: [Analytics.Property.isPro: true])
                Haptics.success()
                paywallContext = nil
            } else {
                errorText = "No purchases to restore for this Apple ID."
                Haptics.warning()
            }
        } catch {
            logger.error("restore failed: \(error)")
            errorText = "Couldn't restore purchases. Please try again."
            Haptics.warning()
        }
    }

    #if DEBUG
    /// Pre-RevenueCat pretend purchase, for DEBUG builds without a
    /// RevenueCat.plist. Compiled out of Release: an unconfigured store there
    /// must fail loudly, not silently hand out Pro.
    private func stubPurchase() async {
        isWorking = true
        defer { isWorking = false }
        try? await Task.sleep(nanoseconds: 700_000_000)
        isPro = true
        Analytics.setPro(true)
        Analytics.capture(.purchaseCompleted, [
            Analytics.Property.planID: selectedPlanID,
            Analytics.Property.trialStarted: plans.first { $0.id == selectedPlanID }?.trialDays != nil
        ], setUserProperties: [Analytics.Property.isPro: true])
        Haptics.success()
        paywallContext = nil
    }

    /// Dev-only: flip Pro without the paywall so gated UI can be exercised.
    /// Note the next customerInfo emission overwrites it when the SDK is live.
    func debugTogglePro() { isPro.toggle() }
    #endif
}

private extension SubscriptionPeriod {
    /// Approximate day count for showing trial length ("7-day free trial").
    var days: Int {
        switch unit {
        case .day:   return value
        case .week:  return value * 7
        case .month: return value * 30
        case .year:  return value * 365
        }
    }
}

/// Why the paywall was shown — lets the headline speak to the exact feature the
/// user just reached for, which converts far better than a generic pitch.
enum PaywallContext: Identifiable, Hashable {
    case general
    case recap
    case rivalryInsights
    case insights
    case unlimitedHistory

    var id: String {
        switch self {
        case .general:          return "general"
        case .recap:            return "recap"
        case .rivalryInsights:  return "rivalry"
        case .insights:         return "insights"
        case .unlimitedHistory: return "history"
        }
    }

    var headline: String {
        switch self {
        case .general:          return "Go further with Pro"
        case .recap:            return "Unlock AI match recaps"
        case .rivalryInsights:  return "See the full rivalry breakdown"
        case .insights:         return "Unlock your play insights"
        case .unlimitedHistory: return "Unlock your full history"
        }
    }
}
