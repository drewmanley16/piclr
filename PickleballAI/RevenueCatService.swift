import Foundation

/// Reads RevenueCat.plist (gitignored). Copy RevenueCat.example.plist ->
/// RevenueCat.plist and fill in the public Apple SDK key (appl_...) from the
/// RevenueCat dashboard. When missing, `isConfigured` is false and the app
/// never touches the Purchases SDK.
enum RevenueCatConfig {
    static let apiKey: String = loaded.key
    static let isConfigured: Bool = loaded.configured

    /// The entitlement identifier configured in the RevenueCat dashboard.
    /// Must match exactly — a typo here silently disables all Pro gating.
    static let entitlementID = "pro"

    /// RevenueCat app-user id for a Supabase auth UUID. Always lowercased:
    /// `UUID.uuidString` is uppercase, but RevenueCat ids are case-sensitive
    /// and the webhook matches them against `auth.users.id`, which Postgres
    /// renders lowercase (same convention as Storage object paths).
    static func appUserID(for uid: UUID) -> String {
        uid.uuidString.lowercased()
    }

    private static let loaded: (key: String, configured: Bool) = {
        guard
            let path = Bundle.main.path(forResource: "RevenueCat", ofType: "plist"),
            let dict = NSDictionary(contentsOfFile: path),
            let key = dict["REVENUECAT_API_KEY"] as? String
        else {
            return ("", false)
        }
        let configured = key.hasPrefix("appl_") && !key.contains("YOUR-KEY")
        return (key, configured)
    }()
}
