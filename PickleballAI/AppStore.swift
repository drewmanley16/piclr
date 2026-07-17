import Foundation
import os
import Supabase

// AppStore's method bodies live in same-module extension files
// (AppStore+Auth.swift, AppStore+Feed.swift, …). This file keeps the class
// declaration, every piece of stored state, and top-level lifecycle.

@MainActor
final class AppStore: ObservableObject {
    enum AuthState: Equatable {
        case unconfigured
        case loading
        case signedOut
        case needsOnboarding
        case signedIn
    }

    @Published var authState: AuthState = .loading
    @Published var currentProfile: Profile?
    @Published var feed: [FeedSession] = []
    @Published var discoverFeed: [FeedSession] = []
    @Published var feedReachedEnd = false
    @Published var discoverReachedEnd = false
    @Published var isInitialFeedLoading = false
    let feedPageSize = 20
    @Published var mySessions: [FeedSession] = []
    // Directional follow graph (the `follows` table). "Friend" naming is kept
    // on a few discovery-UI hooks for compatibility, but the model is a
    // directed follow: following someone doesn't require them to follow back.
    @Published var followerCount = 0
    @Published var followingCount = 0
    @Published var incomingFollowRequests: [FollowRequest] = []
    @Published var followers: [FollowListEntry] = []
    @Published var following: [FollowListEntry] = []
    @Published var contactMatches: [ContactMatch] = []
    @Published var searchResults: [Profile] = []
    @Published var requestedFollowIds: Set<UUID> = []
    @Published var gear: [GearItem] = []
    @Published var incomingRepostRequests: [RepostRequest] = []
    @Published var requestedRepostSessionIds: Set<UUID> = []
    @Published var likedSessionIds: Set<UUID> = []
    @Published var optimisticLikeCounts: [UUID: Int] = [:]
    @Published var notifications: [AppNotification] = []
    @Published var blockedAccounts: [BlockedAccount] = []
    /// Upcoming invites you're hosting or were tagged in, newest first.
    @Published var activeInvites: [SessionInvite] = []
    /// Crew leaderboard (you + everyone you follow), ranked. Loaded on demand.
    @Published var leaderboard: [LeaderboardEntry] = []
    /// Count of in-flight user-initiated operations. `isBusy` is *derived* from
    /// this so concurrent operations (e.g. saving profile fields and a photo at
    /// once) don't clobber each other — the UI reads idle only once every one of
    /// them has finished, not when the first to return flips a shared bool.
    @Published var busyCount = 0
    var isBusy: Bool { busyCount > 0 }
    @Published var errorMessage: String?
    /// Set when the user taps a push notification; RootView presents the target.
    @Published var pendingDeepLink: DeepLink?

    /// The subset of profile columns embedded wherever a lightweight identity
    /// (avatar + name) is all a view needs. Hand-typed in several PostgREST
    /// select strings; kept as one constant so they can't drift apart.
    static let selectProfileLite = "id,username,display_name,avatar_initials,avatar_url,avatar_path"

    let selectWithCounts = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(\(AppStore.selectProfileLite))))"
    let selectFeedPreview = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), preview_comments:comments(*, author:profiles!comments_user_id_fkey(\(AppStore.selectProfileLite))), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(\(AppStore.selectProfileLite))))"

    // Realtime channel + listener-task lifecycles (see AppStore+Realtime.swift).
    let sessionsRealtime = RealtimeSubscription()
    let notificationsRealtime = RealtimeSubscription()
    let followsRealtime = RealtimeSubscription()
    let invitesRealtime = RealtimeSubscription()
    let commentsRealtime = RealtimeSubscription()
    var signedInBackgroundTask: Task<Void, Never>?
    var isFeedRequestInFlight = false
    var pendingFeedRefresh = false
    var isDiscoverRequestInFlight = false
    var pendingDiscoverRefresh = false
    var initialFeedLoadStartedAt: Date?
    var acceptedFollowingUserIDs: Set<UUID> = []
    var sessionRefreshDebounceTask: Task<Void, Never>?
    var realtimeNeedsFeedRefresh = false
    var realtimeNeedsMySessionsRefresh = false
    var realtimeNeedsDiscoverRefresh = false

    /// Signed-URL cache + `hydrate*` helpers for avatars and post photos.
    let media = MediaHydrator()

    static let pushLogger = Logger(subsystem: "com.pickleball.ai", category: "Push")
    static let feedLogger = Logger(subsystem: "com.pickleball.ai", category: "FeedPerf")

    // MARK: - Lifecycle

    func start() async {
        guard SupabaseConfig.isConfigured else {
            authState = .unconfigured
            return
        }
        if let session = try? await supabase.auth.session {
            await handleSignedIn(userId: session.user.id)
        } else {
            authState = .signedOut
        }
    }

    // MARK: - Live session

    /// An in-progress ("live") session that survives leaving the Workout tab.
    /// nil means no session is currently open. Mutations drive the Live Activity.
    @Published var activeDraft: SessionDraft? {
        didSet {
            LiveActivityManager.shared.sync(draft: activeDraft)
            persistActiveDraft()
        }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedUsername: String {
        trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }
}
