import RevenueCat
import SwiftUI

@main
struct PickleballAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var subscriptions = SubscriptionStore()

    init() {
        Self.configureRevenueCat()
    }

    /// One-time Purchases SDK setup. Runs before any view (or the
    /// SubscriptionStore auth task) can touch `Purchases.shared` — the SDK
    /// crashes if used unconfigured, so every call site shares this
    /// `monetizationEnabled && isConfigured` gate. Seeding `appUserID` from the
    /// restored session avoids minting a throwaway anonymous RevenueCat user on
    /// each cold start for signed-in users.
    private static func configureRevenueCat() {
        guard FeatureFlags.monetizationEnabled, RevenueCatConfig.isConfigured else { return }
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        var builder = Configuration.builder(withAPIKey: RevenueCatConfig.apiKey)
        if let session = supabase.auth.currentSession {
            builder = builder.with(appUserID: RevenueCatConfig.appUserID(for: session.user.id))
        }
        Purchases.configure(with: builder.build())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(subscriptions)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}
