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
    /// Mirrors `isInitialFeedLoading` for the Discover tab, which loads lazily
    /// on first switch to it — without this it briefly shows "nothing to
    /// discover yet" before the first page has even been requested.
    @Published var isInitialDiscoverLoading = false
    /// Set when the initial (non-cancelled) following-feed load fails, so the
    /// empty state can show a real error + retry instead of "no posts yet."
    /// Cleared on any successful load. Kept separate from the shared
    /// `errorMessage` so an unrelated background failure elsewhere can't be
    /// misattributed to the feed.
    @Published var feedLoadError: String?
    @Published var discoverLoadError: String?
    let feedPageSize = 20
    @Published var mySessions: [FeedSession] = []
    /// Mirrors `isInitialFeedLoading` for the Workout tab's Recent list, which
    /// loads well after the feed and would otherwise show its "no sessions yet"
    /// empty state to users who simply haven't been fetched yet.
    @Published var isInitialMySessionsLoading = false
    // Directional follow graph (the `follows` table). "Friend" naming is kept
    // on a few discovery-UI hooks for compatibility, but the model is a
    // directed follow: following someone doesn't require them to follow back.
    @Published var followerCount = 0
    @Published var followingCount = 0
    @Published var incomingFollowRequests: [FollowRequest] = []
    @Published var followers: [FollowListEntry] = []
    @Published var following: [FollowListEntry] = []
    @Published var contactMatches: [ContactMatch] = []
    @Published var suggestedAthletes: [SuggestedAthlete] = []
    @Published var isSuggestedAthletesLoading = false
    @Published var searchResults: [Profile] = []
    @Published var requestedFollowIds: Set<UUID> = []
    @Published var gear: [GearItem] = []
    @Published var likedSessionIds: Set<UUID> = []
    @Published var optimisticLikeCounts: [UUID: Int] = [:]
    @Published var likedCommentIds: Set<UUID> = []
    @Published var optimisticCommentLikeCounts: [UUID: Int] = [:]
    @Published var notifications: [AppNotification] = []
    @Published var blockedAccounts: [BlockedAccount] = []
    /// Upcoming invites you're hosting or were tagged in, newest first.
    @Published var activeInvites: [SessionInvite] = []
    /// Crew leaderboard (you + everyone you follow), ranked. Loaded on demand.
    @Published var leaderboard: [LeaderboardEntry] = []
    /// IDs of milestones the signed-in user has unlocked (see `Milestone.catalog`).
    /// Server-authoritative — loaded on demand from `milestone_unlocks`.
    @Published var milestoneUnlocks: Set<String> = []
    /// Count of in-flight user-initiated operations. `isBusy` is *derived* from
    /// this so concurrent operations (e.g. saving profile fields and a photo at
    /// once) don't clobber each other — the UI reads idle only once every one of
    /// them has finished, not when the first to return flips a shared bool.
    @Published var busyCount = 0
    var isBusy: Bool { busyCount > 0 }
    @Published var errorMessage: String?
    /// Set when the user taps a push notification; RootView presents the target.
    @Published var pendingDeepLink: DeepLink?
    /// Set when the user taps the Live Activity; RootView switches to the Play
    /// tab and WorkoutView opens the in-progress session, then clears it. A
    /// fresh id (rather than a bool) so repeat taps always re-trigger.
    @Published var openLiveSessionRequest: UUID?
    /// Set on first sign-in when push permission hasn't been decided yet.
    /// RootView shows a soft explainer sheet before the hard system prompt
    /// fires, instead of surprising a brand-new user with it immediately.
    @Published var showsPushPrimer = false

    /// The subset of profile columns embedded wherever a lightweight identity
    /// (avatar + name) is all a view needs. Hand-typed in several PostgREST
    /// select strings; kept as one constant so they can't drift apart.
    static let selectProfileLite = "id,username,display_name,avatar_initials,avatar_url,avatar_path,is_pro"

    static let selectActivityGraph = "activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(\(selectProfileLite))))"
    static let selectRepostSource = "source:repost_source(id,user_id,title,location,duration_minutes,focus,takeaway,created_at,started_at,ended_at,average_heart_rate_bpm,maximum_heart_rate_bpm,active_calories_kcal,streak_week,photo_path,author:profiles!sessions_user_id_fkey(*),\(selectActivityGraph))"

    let selectWithCounts = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), \(AppStore.selectActivityGraph), \(AppStore.selectRepostSource)"
    let selectFeedPreview = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), preview_comments:comments(*, author:profiles!comments_user_id_fkey(\(AppStore.selectProfileLite))), \(AppStore.selectActivityGraph), \(AppStore.selectRepostSource)"

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
    var commentsRefreshDebounceTask: Task<Void, Never>?
    var commentsRefreshPending = false
    /// Comments whose like write hasn't landed yet. A concurrent reload must not
    /// reconcile these rows or it reverts the optimistic state mid-flight.
    var commentLikeWritesInFlight: Set<UUID> = []
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

    /// Latest transient sensor values from Apple Watch. Kept outside the draft
    /// so raw live samples are never written to disk or uploaded.
    @Published var liveWorkoutMetrics: LiveWorkoutMetrics?
    @Published var watchWorkoutStatus: WatchWorkoutStatus = .idle
    var shouldPostWhenWatchFinishes = false
    var isWaitingForWatchFinalization = false
    /// Guards `postLiveSession()` against concurrent invocation — the phone's
    /// "Finish" button and watch-driven `.finishSession`/`.workoutFinished`
    /// messages can each independently trigger a post in quick succession.
    var isPostingLiveSession = false

    /// An in-progress ("live") session that survives leaving the Workout tab.
    /// nil means no session is currently open. Mutations drive the Live Activity.
    @Published var activeDraft: SessionDraft? {
        didSet {
            if activeDraft == nil {
                liveWorkoutMetrics = nil
                watchWorkoutStatus = .idle
                shouldPostWhenWatchFinishes = false
                isWaitingForWatchFinalization = false
            }
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
