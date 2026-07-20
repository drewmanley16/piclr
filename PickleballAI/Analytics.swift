import Foundation
import PostHog

/// The single source of truth for the product-analytics taxonomy. Every event
/// name and property key lives here — call sites go through `Analytics`, never
/// through raw `PostHogSDK.shared.capture("…")` string literals.
///
/// Event names are snake_case and past-tense. All calls are safe no-ops when the
/// SDK wasn't set up (e.g. a unit context), so instrumentation never crashes the
/// app.
enum Analytics {
    // MARK: - Setup

    // The PostHog project token is a *public* client key designed to ship in the
    // app binary (see the PostHog iOS integration guide), so it lives in source
    // like the RevenueCat public SDK key rather than a gitignored plist.
    private static let apiKey = "phc_oHcNioDwztq7bd4vx8WcHxD5u2dK2ctFhXDKoetvCyTG"
    private static let host = "https://us.i.posthog.com"

    /// One-time SDK bootstrap. Call once, as early as possible in app launch.
    static func start() {
        let config = PostHogConfig(apiKey: apiKey, host: host)
        #if DEBUG
        // Mirror the RevenueCat DEBUG logging convention: surface captured events
        // in the console so instrumentation can be verified on the simulator.
        config.debug = true
        #endif
        PostHogSDK.shared.setup(config)
    }

    // MARK: - Events

    /// The full app event vocabulary. Adding an event = adding a case here.
    enum Event: String {
        // Activation funnel
        case signupStarted = "signup_started"
        case otpVerified = "otp_verified"
        case onboardingCompleted = "onboarding_completed"
        case firstSessionLogged = "first_session_logged"
        case sessionLogged = "session_logged"

        // Retention / social
        case firstRivalSeen = "first_rival_seen"
        case sessionLiked = "session_liked"
        case commentPosted = "comment_posted"
        case followSent = "follow_sent"
        case followAccepted = "follow_accepted"
        case repostRequested = "repost_requested"
        case repostApproved = "repost_approved"
        case gearAdded = "gear_added"
        /// Reserved: fired by the invite-sharing flow (Agent 1) with a `source`
        /// property. Declared here so the name has a single home; don't duplicate.
        case inviteLinkShared = "invite_link_shared"

        // Account lifecycle
        case accountDeleted = "account_deleted"
        case pushNotificationsEnabled = "push_notifications_enabled"

        // Monetization funnel
        case paywallViewed = "paywall_viewed"
        case paywallPlanSelected = "paywall_plan_selected"
        case purchaseCompleted = "purchase_completed"
        case purchaseRestored = "purchase_restored"
    }

    // MARK: - Property keys

    /// Event- and person-property keys. Centralized so a rename happens once.
    enum Property {
        static let skillLevel = "skill_level"
        static let hasDuprRating = "has_dupr_rating"
        static let isPro = "is_pro"
        static let source = "source"
        static let context = "context"
        static let planID = "plan_id"
        static let trialStarted = "trial_started"
        static let quickLog = "quick_log"
        static let activityCount = "activity_count"
    }

    // MARK: - Capture

    static func capture(_ event: Event, _ properties: [String: Any]? = nil) {
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    /// Capture an event that also sets person properties (e.g. the purchase that
    /// flips `is_pro`), so the property lands on the identified person.
    static func capture(
        _ event: Event,
        _ properties: [String: Any]? = nil,
        setUserProperties: [String: Any]
    ) {
        PostHogSDK.shared.capture(
            event.rawValue,
            properties: properties,
            userProperties: setUserProperties
        )
    }

    /// Fire an event at most once per identified user per device. `reset()`
    /// clears the flags so a different user on the same device can fire again.
    static func captureOnce(_ event: Event, flag: OnceFlag, _ properties: [String: Any]? = nil) {
        guard !UserDefaults.standard.bool(forKey: flag.key) else { return }
        UserDefaults.standard.set(true, forKey: flag.key)
        capture(event, properties)
    }

    /// "First X" milestones guarded by a persisted flag. Raw keys are exposed so
    /// a SwiftUI `@AppStorage` can share the same guard as `captureOnce`.
    enum OnceFlag: CaseIterable {
        case firstSessionLogged
        case firstRivalSeen

        var key: String {
            switch self {
            case .firstSessionLogged: return "analytics.firstSessionLogged"
            case .firstRivalSeen:     return "analytics.firstRivalSeen"
            }
        }
    }

    // MARK: - Identity

    /// Attach a signed-in user's stable person properties for funnel
    /// segmentation. `is_pro` is owned separately by `SubscriptionStore` (it
    /// can't be read from here without crossing that boundary).
    static func identify(userID: String, skillLevel: String?, hasDuprRating: Bool) {
        var properties: [String: Any] = [Property.hasDuprRating: hasDuprRating]
        if let skillLevel { properties[Property.skillLevel] = skillLevel }
        PostHogSDK.shared.identify(userID, userProperties: properties)
    }

    /// Reflect the current Pro entitlement everywhere: as a super property (so it
    /// tags every future event) and as a person property on the current person
    /// (so funnels can segment by it). Called by `SubscriptionStore` whenever the
    /// entitlement changes.
    static func setPro(_ isPro: Bool) {
        PostHogSDK.shared.register([Property.isPro: isPro])
        PostHogSDK.shared.identify(
            PostHogSDK.shared.getDistinctId(),
            userProperties: [Property.isPro: isPro]
        )
    }

    /// Clear identity + super properties + "first X" guards on sign-out/delete.
    static func reset() {
        PostHogSDK.shared.reset()
        for flag in OnceFlag.allCases {
            UserDefaults.standard.removeObject(forKey: flag.key)
        }
    }
}
