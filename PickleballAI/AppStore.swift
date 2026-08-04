import Foundation
import Observation
import os
import Supabase

// AppStore's method bodies live in same-module extension files
// (AppStore+Auth.swift, AppStore+Feed.swift, …). This file keeps the class
// declaration, every piece of stored state, and top-level lifecycle.

// Observation is per-property: a view only re-renders when a property it
// actually read in `body` changes. That only holds if state SwiftUI never
// renders stays out of the graph — every stored `var` below that no view reads
// is marked `@ObservationIgnored`. Keep that up when adding state.

@MainActor
@Observable
final class AppStore {
    enum AuthState: Equatable {
        case unconfigured
        case loading
        case signedOut
        case needsOnboarding
        case signedIn
    }

    var authState: AuthState = .loading
    var currentProfile: Profile?
    var feed: [FeedSession] = []
    var discoverFeed: [FeedSession] = []
    var feedReachedEnd = false
    var discoverReachedEnd = false
    var isInitialFeedLoading = false
    /// Mirrors `isInitialFeedLoading` for the Discover tab, which loads lazily
    /// on first switch to it — without this it briefly shows "nothing to
    /// discover yet" before the first page has even been requested.
    var isInitialDiscoverLoading = false
    /// Set when the initial (non-cancelled) following-feed load fails, so the
    /// empty state can show a real error + retry instead of "no posts yet."
    /// Cleared on any successful load. Kept separate from the shared
    /// `errorMessage` so an unrelated background failure elsewhere can't be
    /// misattributed to the feed.
    var feedLoadError: String?
    var discoverLoadError: String?
    let feedPageSize = 20
    var mySessions: [FeedSession] = []
    /// Mirrors `isInitialFeedLoading` for the Workout tab's Recent list, which
    /// loads well after the feed and would otherwise show its "no sessions yet"
    /// empty state to users who simply haven't been fetched yet.
    var isInitialMySessionsLoading = false
    // Directional follow graph (the `follows` table). "Friend" naming is kept
    // on a few discovery-UI hooks for compatibility, but the model is a
    // directed follow: following someone doesn't require them to follow back.
    var followerCount = 0
    var followingCount = 0
    var incomingFollowRequests: [FollowRequest] = []
    var followers: [FollowListEntry] = []
    var following: [FollowListEntry] = []
    var contactMatches: [ContactMatch] = []
    var suggestedAthletes: [SuggestedAthlete] = []
    var isSuggestedAthletesLoading = false
    var searchResults: [Profile] = []
    var requestedFollowIds: Set<UUID> = []
    var gear: [GearItem] = []
    /// The signed-in user's private weight log, newest first. Owner-only under
    /// RLS — no other user's entries are ever loaded (see AppStore+Weight).
    var weightEntries: [WeightEntry] = []
    /// Display unit for every weight surface. Pounds stay canonical on the wire.
    var weightUnit: WeightUnit = .pounds
    var weightGoalPounds: Double?
    /// Mirrors `isInitialMySessionsLoading` for the weight sheet, which can be
    /// opened before the background fan-out has reached the log.
    var isInitialWeightLoading = false
    var likedSessionIds: Set<UUID> = []
    var optimisticLikeCounts: [UUID: Int] = [:]
    var likedCommentIds: Set<UUID> = []
    var optimisticCommentLikeCounts: [UUID: Int] = [:]
    var notifications: [AppNotification] = []
    var blockedAccounts: [BlockedAccount] = []
    /// Upcoming invites you're hosting or were tagged in, newest first.
    var activeInvites: [SessionInvite] = []
    /// Crew leaderboard (you + everyone you follow), ranked. Loaded on demand.
    var leaderboard: [LeaderboardEntry] = []
    /// IDs of milestones the signed-in user has unlocked (see `Milestone.catalog`).
    /// Server-authoritative — loaded on demand from `milestone_unlocks`.
    var milestoneUnlocks: Set<String> = []
    /// Count of in-flight user-initiated operations. `isBusy` is *derived* from
    /// this so concurrent operations (e.g. saving profile fields and a photo at
    /// once) don't clobber each other — the UI reads idle only once every one of
    /// them has finished, not when the first to return flips a shared bool.
    var busyCount = 0
    var isBusy: Bool { busyCount > 0 }
    var errorMessage: String?
    /// Set when the user taps a push notification; RootView presents the target.
    var pendingDeepLink: DeepLink?
    /// Set when the user taps the Live Activity; RootView switches to the Play
    /// tab and WorkoutView opens the in-progress session, then clears it. A
    /// fresh id (rather than a bool) so repeat taps always re-trigger.
    var openLiveSessionRequest: UUID?
    /// Set on first sign-in when push permission hasn't been decided yet.
    /// RootView shows a soft explainer sheet before the hard system prompt
    /// fires, instead of surprising a brand-new user with it immediately.
    var showsPushPrimer = false

    /// The subset of profile columns embedded wherever a lightweight identity
    /// (avatar + name) is all a view needs. Hand-typed in several PostgREST
    /// select strings; kept as one constant so they can't drift apart.
    static let selectProfileLite = "id,username,display_name,avatar_initials,avatar_url,avatar_path,is_pro"

    static let selectActivityGraph = "activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(\(selectProfileLite))))"
    static let selectRepostSource = "source:repost_source(id,user_id,title,location,duration_minutes,takeaway,created_at,started_at,ended_at,average_heart_rate_bpm,maximum_heart_rate_bpm,active_calories_kcal,streak_week,photo_path,author:profiles!sessions_user_id_fkey(*),\(selectActivityGraph))"

    let selectWithCounts = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), \(AppStore.selectActivityGraph), \(AppStore.selectRepostSource)"
    let selectFeedPreview = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), preview_comments:comments(*, author:profiles!comments_user_id_fkey(\(AppStore.selectProfileLite))), \(AppStore.selectActivityGraph), \(AppStore.selectRepostSource)"

    // Realtime channel + listener-task lifecycles (see AppStore+Realtime.swift).
    let sessionsRealtime = RealtimeSubscription()
    let notificationsRealtime = RealtimeSubscription()
    let followsRealtime = RealtimeSubscription()
    let invitesRealtime = RealtimeSubscription()
    let commentsRealtime = RealtimeSubscription()
    // Request-coalescing and debounce bookkeeping. No view reads these and they
    // flip several times per feed load, so they stay out of the observation
    // graph — see the note at the top of the file.
    @ObservationIgnored var signedInBackgroundTask: Task<Void, Never>?
    @ObservationIgnored var isFeedRequestInFlight = false
    @ObservationIgnored var pendingFeedRefresh = false
    /// Server-row offsets stay separate from visible-card counts while legacy
    /// practice-only sessions are filtered client-side before the phase-2 purge.
    @ObservationIgnored var feedNextOffset = 0
    @ObservationIgnored var isDiscoverRequestInFlight = false
    @ObservationIgnored var pendingDiscoverRefresh = false
    @ObservationIgnored var discoverNextOffset = 0
    @ObservationIgnored var initialFeedLoadStartedAt: Date?
    @ObservationIgnored var acceptedFollowingUserIDs: Set<UUID> = []
    @ObservationIgnored var sessionRefreshDebounceTask: Task<Void, Never>?
    @ObservationIgnored var commentsRefreshDebounceTask: Task<Void, Never>?
    @ObservationIgnored var commentsRefreshPending = false
    /// Comments whose like write hasn't landed yet. A concurrent reload must not
    /// reconcile these rows or it reverts the optimistic state mid-flight.
    @ObservationIgnored var commentLikeWritesInFlight: Set<UUID> = []
    @ObservationIgnored var realtimeNeedsFeedRefresh = false
    @ObservationIgnored var realtimeNeedsMySessionsRefresh = false
    @ObservationIgnored var realtimeNeedsDiscoverRefresh = false

    /// Signed-URL cache + `hydrate*` helpers for avatars and post photos.
    let media = MediaHydrator()

    static let pushLogger = Logger(subsystem: "com.pickleball.ai", category: "Push")
    static let feedLogger = Logger(subsystem: "com.pickleball.ai", category: "FeedPerf")
    static let errorLogger = Logger(subsystem: "com.pickleball.ai", category: "Errors")

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
    var liveWorkoutMetrics: LiveWorkoutMetrics?
    var watchWorkoutStatus: WatchWorkoutStatus = .idle
    @ObservationIgnored var shouldPostWhenWatchFinishes = false
    /// Observed so the editor can keep Post live while the finalization window
    /// runs — waiting is the user's choice, and they must be able to take it back.
    var isWaitingForWatchFinalization = false
    /// Set by `stopWaitingForWatchAndPost()` to break the finalization poll early
    /// so the abort posts, rather than racing the loop to it.
    @ObservationIgnored var abortWatchFinalization = false
    /// Guards `postLiveSession()` against concurrent invocation — the phone's
    /// "Finish" button and watch-driven `.finishSession`/`.workoutFinished`
    /// messages can each independently trigger a post in quick succession.
    @ObservationIgnored var isPostingLiveSession = false

    /// An in-progress ("live") session that survives leaving the Workout tab.
    /// nil means no session is currently open. Mutations drive the Live Activity.
    var activeDraft: SessionDraft? {
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
