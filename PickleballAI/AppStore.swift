import Foundation
import os
import Supabase
import UIKit

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
    @Published private(set) var isInitialFeedLoading = false
    private let feedPageSize = 20
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
    @Published private var optimisticLikeCounts: [UUID: Int] = [:]
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
    @Published private var busyCount = 0
    var isBusy: Bool { busyCount > 0 }
    @Published var errorMessage: String?
    /// Set when the user taps a push notification; RootView presents the target.
    @Published var pendingDeepLink: DeepLink?

    /// The subset of profile columns embedded wherever a lightweight identity
    /// (avatar + name) is all a view needs. Hand-typed in several PostgREST
    /// select strings; kept as one constant so they can't drift apart.
    private static let selectProfileLite = "id,username,display_name,avatar_initials,avatar_url,avatar_path"

    private let selectWithCounts = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(\(AppStore.selectProfileLite))))"
    private let selectFeedPreview = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), preview_comments:comments(*, author:profiles!comments_user_id_fkey(\(AppStore.selectProfileLite))), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(\(AppStore.selectProfileLite))))"

    private var realtimeChannel: RealtimeChannelV2?
    private var realtimeTask: Task<Void, Never>?
    private var notifChannel: RealtimeChannelV2?
    private var notifTask: Task<Void, Never>?
    private var followsChannel: RealtimeChannelV2?
    private var followsInTask: Task<Void, Never>?
    private var followsOutTask: Task<Void, Never>?
    private var commentsChannel: RealtimeChannelV2?
    private var commentsTask: Task<Void, Never>?
    private var invitesChannel: RealtimeChannelV2?
    private var invitesTask: Task<Void, Never>?
    private var inviteRecipientsTask: Task<Void, Never>?
    private var signedInBackgroundTask: Task<Void, Never>?
    private var isFeedRequestInFlight = false
    private var pendingFeedRefresh = false
    private var isDiscoverRequestInFlight = false
    private var pendingDiscoverRefresh = false
    private var initialFeedLoadStartedAt: Date?
    private var acceptedFollowingUserIDs: Set<UUID> = []
    private var sessionRefreshDebounceTask: Task<Void, Never>?
    private var realtimeNeedsFeedRefresh = false
    private var realtimeNeedsMySessionsRefresh = false
    private var realtimeNeedsDiscoverRefresh = false

    private struct CachedMediaURL {
        let value: String
        let validUntil: Date
    }

    private var mediaURLCache: [String: CachedMediaURL] = [:]
    private let signedURLLifetime = 900
    private let signedURLRefreshLeeway: TimeInterval = 60

    /// Default session title from the time of day, used when the user leaves the
    /// title blank (e.g. "Morning Session").
    static func timeOfDayTitle(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12:  return "Morning Session"
        case 12..<17: return "Afternoon Session"
        case 17..<21: return "Evening Session"
        default:      return "Night Session"
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let pushLogger = Logger(subsystem: "com.pickleball.ai", category: "Push")
    private static let feedLogger = Logger(subsystem: "com.pickleball.ai", category: "FeedPerf")

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

    // MARK: - Auth

    func sendPhoneOTP(phone: String) async -> Bool {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.auth.signInWithOTP(phone: phone)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func verifyPhoneOTP(phone: String, token: String) async -> Bool {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.auth.verifyOTP(phone: phone, token: token, type: .sms)
            let session = try await supabase.auth.session
            await handleSignedIn(userId: session.user.id)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func deleteAccount() async -> Bool {
        guard currentProfile != nil else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let response: DeleteAccountResponse = try await supabase.functions.invoke("delete-account")
            guard response.deleted else {
                throw NSError(
                    domain: "PickleballAI.AccountDeletion",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The account could not be deleted."]
                )
            }
            stopRealtime()
            clearSignedInState()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func completeOnboarding(
        displayName: String,
        username: String,
        skillLevel: SkillLevel,
        duprRating: Double?
    ) async -> Bool {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let request = CompleteOnboardingRequest(
                displayName: displayName.trimmed,
                username: username.normalizedUsername,
                avatarInitials: initials(from: displayName),
                skillLevel: skillLevel.rawValue,
                duprRating: skillLevel == .dupr ? duprRating : nil
            )
            let response: CompleteOnboardingResponse = try await supabase.functions
                .invoke(
                    "complete-onboarding",
                    options: FunctionInvokeOptions(body: request)
                )
            currentProfile = response.profile
            authState = .signedIn
            await loadSignedInData(userId: response.profile.id)
            return true
        } catch {
            if isAuthFailure(error) {
                // The session is invalid/expired (e.g. the account was deleted
                // out from under this token). Bail out to the auth screen
                // instead of stranding the user on onboarding.
                await signOut()
                errorMessage = "Your session expired. Please sign in again."
            } else {
                reportError(error)
            }
            return false
        }
    }

    /// True when an error means the session is unauthenticated (HTTP 401/403
    /// from an Edge Function, or a Supabase auth error).
    private func isAuthFailure(_ error: Error) -> Bool {
        if let functionsError = error as? FunctionsError,
           case .httpError(let code, _) = functionsError {
            return code == 401 || code == 403
        }
        return error is AuthError
    }

    func signOut() async {
        stopRealtime()
        await removeDeviceToken()
        try? await supabase.auth.signOut()
        clearSignedInState()
    }

    private func clearSignedInState() {
        signedInBackgroundTask?.cancel()
        signedInBackgroundTask = nil
        isFeedRequestInFlight = false
        pendingFeedRefresh = false
        initialFeedLoadStartedAt = nil
        acceptedFollowingUserIDs = []
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        realtimeNeedsFeedRefresh = false
        realtimeNeedsMySessionsRefresh = false
        realtimeNeedsDiscoverRefresh = false
        isInitialFeedLoading = false
        mediaURLCache.removeAll()
        currentProfile = nil
        feed = []
        discoverFeed = []
        feedReachedEnd = false
        discoverReachedEnd = false
        mySessions = []
        followerCount = 0
        followingCount = 0
        incomingFollowRequests = []
        followers = []
        following = []
        contactMatches = []
        searchResults = []
        requestedFollowIds = []
        gear = []
        incomingRepostRequests = []
        requestedRepostSessionIds = []
        likedSessionIds = []
        notifications = []
        blockedAccounts = []
        deletePersistedDraft() // the live draft belongs to the signed-in user
        authState = .signedOut
    }

    private func handleSignedIn(userId: UUID) async {
        authState = .loading
        switch await loadProfile(userId: userId) {
        case .missing:
            // Valid token but no profile row (e.g. the account was deleted) —
            // the session is orphaned. Clear it and return to the auth screen
            // rather than dropping into an onboarding flow that can't complete.
            await signOut()
            return
        case .failed:
            // Couldn't reach the server; don't destroy a possibly-valid
            // session. Show the auth screen; a good session restores next launch.
            authState = .signedOut
            return
        case .loaded:
            break
        }
        guard let profile = currentProfile else {
            authState = .signedOut
            return
        }
        if profile.hasCompletedOnboarding {
            authState = .signedIn
            await loadSignedInData(userId: userId)
        } else {
            authState = .needsOnboarding
            await loadFollowState(userId: userId)
        }
    }

    private func loadSignedInData(userId: UUID) async {
        // A signed-in session is now confirmed for the local user; resurrect any
        // live draft persisted before a kill (the sign-out path deletes the file,
        // so a leftover file always belongs to this user).
        restorePersistedDraft()
        let startupBeganAt = Date()
        initialFeedLoadStartedAt = startupBeganAt
        isInitialFeedLoading = feed.isEmpty
        startRealtime(userId: userId)
        await loadFeed()
        debugFeedMetric("initial feed pipeline complete", since: startupBeganAt)

        // None of this data is required to draw the Home feed. Let it populate
        // the remaining tabs and badges without extending time-to-feed.
        signedInBackgroundTask?.cancel()
        signedInBackgroundTask = Task { [weak self] in
            guard let self, self.currentProfile?.id == userId else { return }
            async let followState: Void = self.loadFollowState(userId: userId)
            async let followLists: Void = self.loadFollowLists(userId: userId)
            async let mySessions: Void = self.loadMySessions(userId: userId)
            async let gear: Void = self.loadGear(userId: userId)
            async let reposts: Void = self.loadRepostRequests(userId: userId)
            async let notifications: Void = self.loadNotifications(userId: userId)
            async let blocks: Void = self.loadBlockedAccounts()
            async let invites: Void = self.loadActiveInvites(userId: userId)
            _ = await (followState, followLists, mySessions, gear, reposts, notifications, blocks, invites)
            guard !Task.isCancelled, self.currentProfile?.id == userId else { return }
            await self.setUpPush()
        }
    }

    // MARK: - Push notifications

    /// Wires the token callback and registers with APNs. On first sign-in this
    /// prompts for permission; on later launches it silently refreshes the token
    /// if the user already granted it.
    private func setUpPush() async {
        PushService.shared.onToken = { [weak self] token in
            Task { await self?.uploadDeviceToken(token) }
        }
        PushService.shared.onTap = { [weak self] userInfo in
            self?.handlePushTap(userInfo)
        }
        if await PushService.shared.authorizationStatus() == .notDetermined {
            await PushService.shared.requestAuthorizationAndRegister()
        } else {
            await PushService.shared.registerIfAuthorized()
        }
    }

    /// Prompts for permission and registers. Called from the Settings toggle.
    @discardableResult
    func enablePushNotifications() async -> Bool {
        await PushService.shared.requestAuthorizationAndRegister()
    }

    /// Routes a tapped push to its target. The payload carries `type`,
    /// `session_id`, and `actor_id` (set by the send-push edge function).
    private func handlePushTap(_ userInfo: [AnyHashable: Any]) {
        let type = userInfo["type"] as? String
        let sessionId = (userInfo["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let actorId = (userInfo["actor_id"] as? String).flatMap(UUID.init(uuidString:))
        let inviteId = (userInfo["invite_id"] as? String).flatMap(UUID.init(uuidString:))
        switch type {
        case "follow":
            if let actorId { pendingDeepLink = .profile(actorId) }
        case "comment":
            if let sessionId { pendingDeepLink = .comments(sessionId) }
        case "invite_received", "invite_response", "invite_cancelled":
            if let inviteId { pendingDeepLink = .invite(inviteId) }
        default:
            if let sessionId { pendingDeepLink = .session(sessionId) }
        }
    }

    private func uploadDeviceToken(_ token: String) async {
        guard currentProfile != nil else { return }
        do {
            try await supabase
                .rpc("register_device_token", params: ["p_token": token, "p_platform": "ios"])
                .execute()
        } catch {
            // Non-fatal: worst case the device just won't get pushes this run.
            Self.pushLogger.error("token upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes this device's token so it stops receiving pushes (toggle off / sign out).
    func removeDeviceToken() async {
        guard let token = PushService.shared.latestToken else { return }
        try? await supabase
            .from("device_tokens")
            .delete()
            .eq("token", value: token)
            .execute()
    }

    // MARK: - Realtime

    /// Subscribe to `sessions` changes so new posts (yours or people you follow)
    /// surface in the feed live, without a manual refresh.
    private func startRealtime(userId: UUID) {
        stopRealtime()
        let channel = supabase.channel("public:sessions")
        realtimeChannel = channel
        realtimeTask = Task { [weak self] in
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "sessions",
                select: ["id", "user_id", "posted"]
            )
            await channel.subscribe()
            for await change in changes {
                self?.handleSessionChange(change, userId: userId)
                if Task.isCancelled { break }
            }
        }

        // Live badge: reload notifications when a new one arrives for this user.
        let nChannel = supabase.channel("public:notifications:\(userId.uuidString)")
        notifChannel = nChannel
        notifTask = Task { [weak self] in
            let changes = nChannel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "notifications",
                filter: "user_id=eq.\(userId.uuidString)"
            )
            await nChannel.subscribe()
            for await _ in changes {
                await self?.loadNotifications(userId: userId)
                if Task.isCancelled { break }
            }
        }

        // Live follow graph: reload counts/lists when someone follows or
        // requests me (incoming), or accepts my request (outgoing). Two filters
        // on one channel — Realtime allows a single filter per subscription.
        let fChannel = supabase.channel("public:follows:\(userId.uuidString)")
        followsChannel = fChannel
        let incoming = fChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "follows",
            filter: "followee_id=eq.\(userId.uuidString)"
        )
        let outgoing = fChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "follows",
            filter: "follower_id=eq.\(userId.uuidString)"
        )
        followsInTask = Task { [weak self] in
            await fChannel.subscribe()
            for await _ in incoming {
                // Someone followed/requested me → my counts + request banner.
                await self?.reloadFollowGraph(userId: userId, refreshFeed: false)
                if Task.isCancelled { break }
            }
        }
        followsOutTask = Task { [weak self] in
            for await _ in outgoing {
                // A request I sent was accepted → I now follow them, so their
                // sessions belong in my feed.
                await self?.reloadFollowGraph(userId: userId, refreshFeed: true)
                if Task.isCancelled { break }
            }
        }

        // Live invites: reload when an invite or an RSVP to one changes.
        let iChannel = supabase.channel("public:session_invites:\(userId.uuidString)")
        invitesChannel = iChannel
        let inviteChanges = iChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "session_invites"
        )
        let inviteRecipientChanges = iChannel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "invite_recipients"
        )
        invitesTask = Task { [weak self] in
            await iChannel.subscribe()
            for await _ in inviteChanges {
                await self?.loadActiveInvites(userId: userId)
                if Task.isCancelled { break }
            }
        }
        inviteRecipientsTask = Task { [weak self] in
            for await _ in inviteRecipientChanges {
                await self?.loadActiveInvites(userId: userId)
                if Task.isCancelled { break }
            }
        }
    }

    private func handleSessionChange(_ change: AnyAction, userId: UUID) {
        let record: JSONObject
        let isDelete: Bool
        switch change {
        case .insert(let action):
            record = action.record
            isDelete = false
        case .update(let action):
            record = action.record
            isDelete = false
        case .delete(let action):
            record = action.oldRecord
            isDelete = true
        }

        let sessionID = record["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if isDelete, let sessionID {
            feed.removeAll { $0.id == sessionID }
            discoverFeed.removeAll { $0.id == sessionID }
            mySessions.removeAll { $0.id == sessionID }
            return
        }

        guard let authorID = record["user_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            // Older Realtime payloads may omit selected columns. Coalesce one
            // conservative refresh instead of reloading three datasets per event.
            scheduleRealtimeRefresh(feed: true, mySessions: false, discover: !discoverFeed.isEmpty, userId: userId)
            return
        }

        let posted = record["posted"]?.boolValue ?? true
        let alreadyInFeed = sessionID.map { id in feed.contains { $0.id == id } } ?? false
        let alreadyInDiscover = sessionID.map { id in discoverFeed.contains { $0.id == id } } ?? false
        let alreadyInMySessions = sessionID.map { id in mySessions.contains { $0.id == id } } ?? false
        let feedAuthorIsVisible = authorID == userId || acceptedFollowingUserIDs.contains(authorID)
        let refreshFeed = feedAuthorIsVisible && (posted || alreadyInFeed)
        let refreshMine = authorID == userId && (posted || alreadyInMySessions)
        let refreshDiscover = !discoverFeed.isEmpty && authorID != userId && (posted || alreadyInDiscover)
        scheduleRealtimeRefresh(
            feed: refreshFeed,
            mySessions: refreshMine,
            discover: refreshDiscover,
            userId: userId
        )
    }

    private func scheduleRealtimeRefresh(
        feed: Bool,
        mySessions: Bool,
        discover: Bool,
        userId: UUID
    ) {
        guard feed || mySessions || discover else { return }
        realtimeNeedsFeedRefresh = realtimeNeedsFeedRefresh || feed
        realtimeNeedsMySessionsRefresh = realtimeNeedsMySessionsRefresh || mySessions
        realtimeNeedsDiscoverRefresh = realtimeNeedsDiscoverRefresh || discover
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, self.currentProfile?.id == userId else { return }
            let refreshFeed = self.realtimeNeedsFeedRefresh
            let refreshMine = self.realtimeNeedsMySessionsRefresh
            let refreshDiscover = self.realtimeNeedsDiscoverRefresh
            self.realtimeNeedsFeedRefresh = false
            self.realtimeNeedsMySessionsRefresh = false
            self.realtimeNeedsDiscoverRefresh = false
            async let feedLoad: Void = refreshFeed ? self.loadFeed() : ()
            async let mySessionsLoad: Void = refreshMine ? self.loadMySessions(userId: userId) : ()
            async let discoverLoad: Void = refreshDiscover ? self.loadDiscover() : ()
            _ = await (feedLoad, mySessionsLoad, discoverLoad)
        }
    }

    private func reloadFollowGraph(userId: UUID, refreshFeed: Bool) async {
        await loadFollowState(userId: userId)
        await loadFollowLists(userId: userId)
        if refreshFeed { await loadFeed() }
    }

    private func stopRealtime() {
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        realtimeNeedsFeedRefresh = false
        realtimeNeedsMySessionsRefresh = false
        realtimeNeedsDiscoverRefresh = false
        realtimeTask?.cancel()
        realtimeTask = nil
        notifTask?.cancel()
        notifTask = nil
        followsInTask?.cancel()
        followsInTask = nil
        followsOutTask?.cancel()
        followsOutTask = nil
        invitesTask?.cancel()
        invitesTask = nil
        inviteRecipientsTask?.cancel()
        inviteRecipientsTask = nil
        if let channel = invitesChannel {
            invitesChannel = nil
            Task { await channel.unsubscribe() }
        }
        if let channel = realtimeChannel {
            realtimeChannel = nil
            Task { await channel.unsubscribe() }
        }
        if let channel = notifChannel {
            notifChannel = nil
            Task { await channel.unsubscribe() }
        }
        if let channel = followsChannel {
            followsChannel = nil
            Task { await channel.unsubscribe() }
        }
    }

    // MARK: - Comments realtime

    /// Subscribes to new comments on a session, invoking `onInsert` for each so
    /// the view can reload. Keeps Supabase realtime plumbing (channels, filters,
    /// subscribe lifecycle) out of the view layer. Pair with `stopCommentsRealtime()`.
    func startCommentsRealtime(sessionId: UUID, onInsert: @escaping () async -> Void) {
        stopCommentsRealtime()
        let channel = supabase.channel("comments:\(sessionId.uuidString)")
        commentsChannel = channel
        commentsTask = Task {
            let changes = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "comments",
                filter: "session_id=eq.\(sessionId.uuidString)"
            )
            await channel.subscribe()
            for await _ in changes {
                await onInsert()
            }
        }
    }

    func stopCommentsRealtime() {
        commentsTask?.cancel()
        commentsTask = nil
        if let channel = commentsChannel {
            commentsChannel = nil
            Task { await channel.unsubscribe() }
        }
    }

    // MARK: - Reads

    /// Result of trying to load the signed-in user's profile.
    /// `missing` distinguishes "no such profile" (orphaned/deleted account →
    /// sign out) from `failed` (transient/network error → keep the session).
    enum ProfileLoad {
        case loaded
        case missing
        case failed
    }

    @discardableResult
    func loadProfile(userId: UUID) async -> ProfileLoad {
        do {
            // Fetch as an array (not `.single()`) so an empty result is a
            // definitive "no profile" rather than a thrown error.
            let rows: [Profile] = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let profile = rows.first else {
                return .missing
            }
            currentProfile = await hydrateProfile(profile)
            return .loaded
        } catch {
            reportError(error)
            return .failed
        }
    }

    /// Following feed: your posts + posts from people you follow (accepted).
    /// Paginated — pass reset: false to append the next page.
    func loadFeed(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { feedReachedEnd = false } else if feedReachedEnd { return }
        if isFeedRequestInFlight {
            if reset { pendingFeedRefresh = true }
            return
        }

        isFeedRequestInFlight = true
        let requestBeganAt = Date()
        defer {
            isFeedRequestInFlight = false
            if pendingFeedRefresh {
                pendingFeedRefresh = false
                Task { [weak self] in await self?.loadFeed() }
            }
        }

        do {
            let followingIds = try await acceptedFollowingIds(for: uid)
            let visibleIds = [uid] + followingIds
            let idFilter = Self.inFilter(for: visibleIds)
            let from = reset ? 0 : feed.count
            let page: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .eq("posted", value: true)
                .filter("user_id", operator: "in", value: idFilter)
                .order("created_at", ascending: false)
                .order("created_at", ascending: true, referencedTable: "preview_comments")
                .range(from: from, to: from + feedPageSize - 1)
                .limit(3, referencedTable: "preview_comments")
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }

            // Text and activity data can render immediately. Private-media URL
            // signing and liked-state lookup are enhancements, not prerequisites
            // for showing the feed.
            if reset {
                feed = page
            } else {
                let existingIDs = Set(feed.map(\.id))
                feed.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            }
            feedReachedEnd = page.count < feedPageSize
            isInitialFeedLoading = false
            debugFeedMetric("feed query returned \(page.count) rows", since: requestBeganAt)
            if let initialFeedLoadStartedAt {
                debugFeedMetric("cold start to first feed rows", since: initialFeedLoadStartedAt)
                self.initialFeedLoadStartedAt = nil
            }

            async let hydrated: [FeedSession] = hydrateSessions(page)
            async let liked: Set<UUID>? = try? likedSessionIds(for: uid, sessionIds: page.map(\.id))
            let (hydratedPage, likedPage) = await (hydrated, liked)
            guard currentProfile?.id == uid, !Task.isCancelled else { return }

            let hydratedByID = Dictionary(uniqueKeysWithValues: hydratedPage.map { ($0.id, $0) })
            feed = feed.map { hydratedByID[$0.id] ?? $0 }
            if let likedPage {
                likedSessionIds.subtract(page.map(\.id))
                likedSessionIds.formUnion(likedPage)
            }
            debugFeedMetric("feed media hydrated", since: requestBeganAt)
        } catch {
            isInitialFeedLoading = false
            initialFeedLoadStartedAt = nil
            reportError(error)
        }
    }

    /// Discover feed: recent public posts from everyone (excluding your own).
    func loadDiscover(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { discoverReachedEnd = false } else if discoverReachedEnd { return }
        if isDiscoverRequestInFlight {
            if reset { pendingDiscoverRefresh = true }
            return
        }

        isDiscoverRequestInFlight = true
        defer {
            isDiscoverRequestInFlight = false
            if pendingDiscoverRefresh {
                pendingDiscoverRefresh = false
                Task { [weak self] in await self?.loadDiscover() }
            }
        }

        do {
            let from = reset ? 0 : discoverFeed.count
            let page: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .eq("posted", value: true)
                .neq("user_id", value: uid.uuidString)
                .order("created_at", ascending: false)
                .order("created_at", ascending: true, referencedTable: "preview_comments")
                .range(from: from, to: from + feedPageSize - 1)
                .limit(3, referencedTable: "preview_comments")
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            if reset {
                discoverFeed = page
            } else {
                let existingIDs = Set(discoverFeed.map(\.id))
                discoverFeed.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            }
            discoverReachedEnd = page.count < feedPageSize
            async let hydrated: [FeedSession] = hydrateSessions(page)
            async let liked: Set<UUID>? = try? likedSessionIds(for: uid, sessionIds: page.map(\.id))
            let (hydratedPage, likedPage) = await (hydrated, liked)
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            let hydratedByID = Dictionary(uniqueKeysWithValues: hydratedPage.map { ($0.id, $0) })
            discoverFeed = discoverFeed.map { hydratedByID[$0.id] ?? $0 }
            if let likedPage {
                likedSessionIds.subtract(page.map(\.id))
                likedSessionIds.formUnion(likedPage)
            }
        } catch {
            reportError(error)
        }
    }

    private func refreshLikedState(for sessions: [FeedSession], uid: UUID) async {
        guard !sessions.isEmpty else { return }
        if let liked = try? await likedSessionIds(for: uid, sessionIds: sessions.map(\.id)) {
            likedSessionIds.formUnion(liked)
        }
    }

    func loadMySessions(userId: UUID) async {
        do {
            let sessions: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectWithCounts)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            mySessions = await hydrateSessions(sessions)
        } catch {
            reportError(error)
        }
    }

    /// Fetches a single session by id (for opening a post from a notification).
    func loadSession(id: UUID) async -> FeedSession? {
        do {
            let rows: [FeedSession] = try await supabase
                .from("sessions")
                .select(selectFeedPreview)
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value
            let hydrated = await hydrateSessions(rows)
            if let uid = currentProfile?.id { await refreshLikedState(for: hydrated, uid: uid) }
            return hydrated.first
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Refetch one session and swap the fresh copy into every feed array that
    /// holds it. Used after a comment add/delete so the count stays in sync
    /// across Home, Discover, and the profile grid without a full feed reload
    /// (which would collapse pagination back to the first page).
    private func refreshSessionAcrossFeeds(id: UUID) async {
        guard let updated = await loadSession(id: id) else { return }
        feed = feed.map { $0.id == id ? updated : $0 }
        discoverFeed = discoverFeed.map { $0.id == id ? updated : $0 }
        mySessions = mySessions.map { $0.id == id ? updated : $0 }
    }

    func loadGear(userId: UUID) async {
        do {
            let items: [GearItem] = try await supabase
                .from("gear")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            gear = items
        } catch {
            reportError(error)
        }
    }

    /// Loads follow counts, incoming pending requests, and the set of people
    /// this user has already requested/follows (for discovery button state).
    func loadFollowState(userId: UUID) async {
        do {
            let followerTotal = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0
            let followingTotal = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0

            // Outgoing edges (pending or accepted) → discovery "requested" state.
            let outgoing: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("follower_id", value: userId.uuidString)
                .execute()
                .value

            // Incoming pending requests → resolve requester profiles.
            let incoming: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
            let requesters = try await profilesByID(for: incoming.map(\.followerId))
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            followerCount = followerTotal
            followingCount = followingTotal
            requestedFollowIds = Set(outgoing.map(\.followeeId))
            incomingFollowRequests = incoming.map { row in
                FollowRequest(
                    followerId: row.followerId,
                    followeeId: row.followeeId,
                    follower: requesters[row.followerId]
                )
            }
        } catch {
            reportError(error)
        }
    }

    /// Loads the accepted followers/following lists, each annotated with
    /// whether the signed-in user follows that person back.
    func loadFollowLists() async {
        guard let uid = currentProfile?.id else { return }
        await loadFollowLists(userId: uid)
    }

    func loadFollowLists(userId: UUID) async {
        do {
            let followerEdges: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .value
            let followingEdges: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("follower_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .value

            let followerIds = followerEdges.map(\.followerId)
            let followingIds = followingEdges.map(\.followeeId)
            let iFollow = Set(followingIds)
            let byId = try await profilesByID(for: followerIds + followingIds)

            followers = followerIds.map { id in
                FollowListEntry(userId: id, profile: byId[id], isFollowedByMe: iFollow.contains(id))
            }
            following = followingIds.map { id in
                FollowListEntry(userId: id, profile: byId[id], isFollowedByMe: true)
            }
        } catch {
            reportError(error)
        }
    }

    /// Loads another user's followers or following list. Each entry's
    /// `isFollowedByMe` reflects whether the *signed-in* user follows that
    /// person (accepted) — so the follow-back button is relative to me,
    /// Instagram-style. Returns the entries rather than mutating the store's
    /// own published lists.
    func followList(for userId: UUID, kind: FollowListKind) async -> [FollowListEntry] {
        guard let me = currentProfile?.id else { return [] }
        do {
            let column = kind == .followers ? "followee_id" : "follower_id"
            let edges: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq(column, value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .value
            let otherIds = edges.map { kind == .followers ? $0.followerId : $0.followeeId }
            let byId = try await profilesByID(for: otherIds)
            let myFollowing = Set(try await acceptedFollowingIds(for: me))
            return otherIds.map { id in
                FollowListEntry(userId: id, profile: byId[id], isFollowedByMe: myFollowing.contains(id))
            }
        } catch {
            reportError(error)
            return []
        }
    }

    func refresh() async {
        guard let uid = currentProfile?.id else { return }
        await loadFollowState(userId: uid)
        await loadFollowLists(userId: uid)
        await loadFeed()
        await loadMySessions(userId: uid)
        await loadGear(userId: uid)
    }

    // MARK: - Friend discovery

    func matchContacts(phones: [String]) async {
        let uniquePhones = Array(Set(phones)).sorted()
        guard !uniquePhones.isEmpty else {
            contactMatches = []
            return
        }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            var matches: [ContactMatch] = []
            for batch in uniquePhones.chunked(into: 500) {
                let response: MatchContactsResponse = try await supabase.functions
                    .invoke(
                        "match-contacts",
                        options: FunctionInvokeOptions(body: MatchContactsRequest(phones: batch))
                    )
                matches.append(contentsOf: response.matches)
            }
            let ownId = currentProfile?.id
            var seenProfileIds: Set<UUID> = []
            let visibleMatches = matches.filter { match in
                guard match.profile.id != ownId, !seenProfileIds.contains(match.profile.id) else {
                    return false
                }
                seenProfileIds.insert(match.profile.id)
                return true
            }
            var hydrated: [ContactMatch] = []
            for match in visibleMatches {
                hydrated.append(ContactMatch(phone: match.phone, profile: await hydrateProfile(match.profile)))
            }
            contactMatches = hydrated
        } catch {
            reportError(error)
        }
    }

    func searchProfiles(query: String) async {
        let usernameQuery = query.normalizedUsername
        let displayNameQuery = Self.displayNameSearchTerm(from: query)
        var filters: [String] = []
        if usernameQuery.count >= 2 {
            filters.append("username.ilike.*\(usernameQuery)*")
        }
        if displayNameQuery.count >= 2 {
            filters.append("display_name.ilike.*\(displayNameQuery)*")
        }
        guard !filters.isEmpty else {
            searchResults = []
            return
        }
        do {
            let results: [Profile] = try await supabase
                .from("profiles")
                .select()
                .or(filters.joined(separator: ","))
                .limit(10)
                .execute()
                .value
            let ownId = currentProfile?.id
            var hydrated: [Profile] = []
            for profile in results where profile.id != ownId && profile.hasCompletedOnboarding {
                hydrated.append(await hydrateProfile(profile))
            }
            searchResults = hydrated
        } catch {
            reportError(error)
        }
    }

    func searchProfilesAfterTyping(query: String) async {
        guard query.trimmed.count >= 2 else {
            await searchProfiles(query: query)
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        await searchProfiles(query: query)
    }

    /// Sends a follow request: inserts a `pending` edge (me → profile).
    func sendFollowRequest(to profile: Profile) async {
        guard let uid = currentProfile?.id, uid != profile.id else { return }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let new = NewFollow(followerId: uid, followeeId: profile.id, status: "pending")
            try await supabase.from("follows").insert(new).execute()
            requestedFollowIds.insert(profile.id)
            await loadFollowState(userId: uid)
        } catch {
            reportError(error)
        }
    }

    /// Respond to an incoming follow request. Accepting flips the edge to
    /// accepted; declining deletes it so it can be re-requested later.
    func respondToFollowRequest(_ request: FollowRequest, accept: Bool) async {
        guard let uid = currentProfile?.id, request.followeeId == uid else { return }
        do {
            if accept {
                try await supabase
                    .from("follows")
                    .update(["status": "accepted"])
                    .eq("follower_id", value: request.followerId.uuidString)
                    .eq("followee_id", value: uid.uuidString)
                    .execute()
            } else {
                try await supabase
                    .from("follows")
                    .delete()
                    .eq("follower_id", value: request.followerId.uuidString)
                    .eq("followee_id", value: uid.uuidString)
                    .execute()
            }
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
            await loadFeed()
        } catch {
            reportError(error)
        }
    }

    /// Unfollow someone: deletes the signed-in user's outgoing edge (me → them),
    /// whether it was accepted or still pending. Their sessions drop out of the
    /// feed and their profile becomes private again.
    func unfollow(userId: UUID) async {
        guard let uid = currentProfile?.id, uid != userId else { return }
        do {
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: uid.uuidString)
                .eq("followee_id", value: userId.uuidString)
                .execute()
            requestedFollowIds.remove(userId)
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
            await loadFeed()
        } catch {
            reportError(error)
        }
    }

    func cancelFollowRequest(userId: UUID) async {
        await unfollow(userId: userId)
    }

    func removeFollower(userId: UUID) async {
        guard let uid = currentProfile?.id, uid != userId else { return }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase
                .from("follows")
                .delete()
                .eq("follower_id", value: userId.uuidString)
                .eq("followee_id", value: uid.uuidString)
                .execute()
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
        } catch {
            reportError(error)
        }
    }

    // MARK: - User safety

    func loadBlockedAccounts() async {
        guard let uid = currentProfile?.id else {
            blockedAccounts = []
            return
        }
        do {
            let blocks: [BlockedAccount] = try await supabase
                .from("blocks")
                .select("blocked_id,blocked_username,blocked_display_name,blocked_avatar_path,created_at")
                .eq("blocker_id", value: uid.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            blockedAccounts = blocks
        } catch {
            reportError(error)
        }
    }

    @discardableResult
    func blockUser(userId: UUID) async -> Bool {
        guard let uid = currentProfile?.id, uid != userId else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.from("blocks")
                .insert(NewBlock(blockerId: uid, blockedId: userId))
                .execute()

            feed.removeAll { $0.userId == userId }
            discoverFeed.removeAll { $0.userId == userId }
            followers.removeAll { $0.userId == userId }
            following.removeAll { $0.userId == userId }
            incomingFollowRequests.removeAll { $0.followerId == userId }
            contactMatches.removeAll { $0.profile.id == userId }
            searchResults.removeAll { $0.id == userId }
            requestedFollowIds.remove(userId)
            notifications.removeAll { $0.actor?.id == userId }

            await loadBlockedAccounts()
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
            await loadFeed()
            await loadDiscover()
            await loadMySessions(userId: uid)
            await loadRepostRequests(userId: uid)
            await loadNotifications(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func unblockUser(userId: UUID) async {
        guard let uid = currentProfile?.id else { return }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.from("blocks")
                .delete()
                .eq("blocker_id", value: uid.uuidString)
                .eq("blocked_id", value: userId.uuidString)
                .execute()
            await loadBlockedAccounts()
        } catch {
            reportError(error)
        }
    }

    func submitReport(target: ReportTarget, reason: ReportReason, details: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            try await supabase.from("reports")
                .insert(NewReport(
                    reporterId: uid,
                    targetType: target.type,
                    targetId: target.targetId,
                    reason: reason.rawValue,
                    details: trimmed.isEmpty ? nil : trimmed
                ))
                .execute()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    /// Loads another user's public profile. Basic fields + follower/following
    /// counts are always visible; sessions are fetched only when the signed-in
    /// user follows them (accepted). The `sessions` query is additionally
    /// RLS-gated, so it returns nothing even if this check were bypassed.
    func loadPublicProfile(userId: UUID) async -> PublicProfile? {
        guard let me = currentProfile?.id else { return nil }
        do {
            let rows: [Profile] = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let rawProfile = rows.first else { return nil }
            let profile = await hydrateProfile(rawProfile)

            let relationship: FollowRelationship
            if userId == me {
                relationship = .isSelf
            } else {
                let edges: [FollowRow] = try await supabase
                    .from("follows")
                    .select("follower_id, followee_id, status, created_at")
                    .eq("follower_id", value: me.uuidString)
                    .eq("followee_id", value: userId.uuidString)
                    .limit(1)
                    .execute()
                    .value
                switch edges.first?.status {
                case "accepted": relationship = .following
                case "pending": relationship = .requested
                default: relationship = .none
                }
            }

            let followerCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0
            let followingCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0

            var sessions: [FeedSession] = []
            if relationship.canViewContent {
                let rows: [FeedSession] = try await supabase
                    .from("sessions")
                    .select(selectWithCounts)
                    .eq("user_id", value: userId.uuidString)
                    .eq("posted", value: true)
                    .order("created_at", ascending: false)
                    .limit(50)
                    .execute()
                    .value
                sessions = await hydrateSessions(rows)
            }

            return PublicProfile(
                profile: profile,
                relationship: relationship,
                followerCount: followerCount,
                followingCount: followingCount,
                sessions: sessions
            )
        } catch {
            reportError(error)
            return nil
        }
    }

    // MARK: - Writes

    /// Write a full multi-activity session built on-device. Inserts the session
    /// unposted, writes activities + tagged participants, then flips `posted`
    /// last so realtime subscribers only see the completed post.
    /// An in-progress ("live") session that survives leaving the Workout tab.
    /// nil means no session is currently open. Mutations drive the Live Activity.
    @Published var activeDraft: SessionDraft? {
        didSet {
            LiveActivityManager.shared.sync(draft: activeDraft)
            persistActiveDraft()
        }
    }

    // MARK: - Live draft persistence
    // A live session already survives leaving the Workout tab in memory;
    // mirroring it to disk lets it also survive a force-quit / crash /
    // low-memory kill so logged activities aren't lost. All I/O is best-effort:
    // it must never throw or block the UI. The JSON (incl. base64 photoData)
    // is small enough to encode on the main actor.
    private static let draftMaxAge: TimeInterval = 60 * 60 * 24 // 24h

    private var draftFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("LiveSessionDraft.json")
    }

    /// Called from `activeDraft.didSet`: write the current draft, or delete the
    /// file when the session is posted/discarded (`activeDraft == nil`).
    private func persistActiveDraft() {
        guard let url = draftFileURL else { return }
        guard let draft = activeDraft else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? JSONEncoder().encode(draft) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func deletePersistedDraft() {
        guard let url = draftFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Restore a live session persisted before a kill. Assigning normally lets
    /// `didSet` re-sync the Live Activity (which adopts any orphaned one). Drops
    /// drafts older than `draftMaxAge` — a days-old resurrected session is worse
    /// than a lost one. Only restores when nothing is already in progress.
    private func restorePersistedDraft() {
        guard activeDraft == nil,
              let url = draftFileURL,
              let data = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(SessionDraft.self, from: data)
        else { return }
        guard Date().timeIntervalSince(draft.startedAt) < Self.draftMaxAge else {
            deletePersistedDraft()
            return
        }
        activeDraft = draft
    }

    func startLiveSession() {
        if activeDraft == nil { activeDraft = SessionDraft() }
    }

    func discardLiveSession() { activeDraft = nil }

    /// Posts the live session and clears it on success.
    func postLiveSession() async -> Bool {
        guard let draft = activeDraft else { return false }
        let ok = await postSession(draft)
        if ok { activeDraft = nil }
        return ok
    }

    /// One-tap log: wraps a single activity in a fresh session and posts it.
    func quickLog(_ activity: DraftActivity, postToFeed: Bool = true) async -> Bool {
        var draft = SessionDraft()
        draft.startedAt = Date()
        draft.activities = [activity]
        draft.postToFeed = postToFeed
        return await postSession(draft)
    }

    func postSession(_ draft: SessionDraft) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let now = Date()
            let duration = max(1, Int(now.timeIntervalSince(draft.startedAt) / 60))
            let firstFocus = draft.activities.first(where: { $0.kind == .practice && !$0.focus.isEmpty })?.focus

            let session = NewSession(
                userId: uid,
                title: draft.title.isEmpty ? Self.timeOfDayTitle(for: draft.startedAt) : draft.title,
                location: draft.location.isEmpty ? nil : draft.location,
                durationMinutes: duration,
                focus: firstFocus,
                takeaway: nil,
                posted: false,
                startedAt: Self.iso.string(from: draft.startedAt),
                endedAt: Self.iso.string(from: now)
            )
            try await supabase.from("sessions").insert(session).execute()

            for (index, activity) in draft.activities.enumerated() {
                let isMatch = activity.kind == .match
                let newActivity = NewSessionActivity(
                    sessionId: session.id,
                    kind: activity.kind.rawValue,
                    position: index,
                    focus: activity.focus.isEmpty ? nil : activity.focus,
                    reps: activity.reps.isEmpty ? nil : activity.reps,
                    notes: activity.notes.isEmpty ? nil : activity.notes,
                    teamScore: isMatch ? activity.teamScore : nil,
                    opponentScore: isMatch ? activity.opponentScore : nil,
                    won: activity.wonValue
                )
                try await supabase.from("session_activities").insert(newActivity).execute()

                let participants =
                    activity.partners.map { player in
                        NewActivityParticipant(activityId: newActivity.id, sessionId: session.id,
                                               profileId: player.profile?.id, guestName: player.profile == nil ? player.guestName : nil, role: "partner")
                    } +
                    activity.opponents.map { player in
                        NewActivityParticipant(activityId: newActivity.id, sessionId: session.id,
                                               profileId: player.profile?.id, guestName: player.profile == nil ? player.guestName : nil, role: "opponent")
                    }
                if !participants.isEmpty {
                    try await supabase.from("activity_participants").insert(participants).execute()
                }
            }

            if let photoData = draft.photoData,
               let photoPath = await uploadPostPhoto(photoData, sessionId: session.id, uid: uid) {
                try await supabase.from("sessions")
                    .update(["photo_path": photoPath])
                    .eq("id", value: session.id.uuidString)
                    .execute()
            }

            try await supabase.from("sessions")
                .update(["posted": draft.postToFeed])
                .eq("id", value: session.id.uuidString)
                .execute()

            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func updateSession(_ session: FeedSession, draft: SessionDraft) async -> Bool {
        guard let uid = currentProfile?.id, session.userId == uid else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }

        do {
            var photoPath = draft.removePhoto ? nil : draft.existingPhotoPath
            if let photoData = draft.photoData {
                guard let uploaded = await uploadPostPhoto(photoData, sessionId: session.id, uid: uid) else {
                    return false
                }
                photoPath = uploaded
            }

            let endedAt = max(draft.endedAt ?? Date(), draft.startedAt.addingTimeInterval(60))
            let activities = draft.activities.enumerated().map { index, activity in
                let participants =
                    activity.partners.map {
                        SessionUpdateParticipant(
                            id: $0.id,
                            profileId: $0.profile?.id,
                            guestName: $0.profile == nil ? $0.guestName : nil,
                            role: "partner"
                        )
                    }
                    + activity.opponents.map {
                        SessionUpdateParticipant(
                            id: $0.id,
                            profileId: $0.profile?.id,
                            guestName: $0.profile == nil ? $0.guestName : nil,
                            role: "opponent"
                        )
                    }
                let isMatch = activity.kind == .match
                return SessionUpdateActivity(
                    id: activity.id,
                    kind: activity.kind.rawValue,
                    position: index,
                    focus: activity.focus.isEmpty ? nil : activity.focus,
                    reps: activity.reps.isEmpty ? nil : activity.reps,
                    notes: activity.notes.isEmpty ? nil : activity.notes,
                    teamScore: isMatch ? activity.teamScore : nil,
                    opponentScore: isMatch ? activity.opponentScore : nil,
                    won: activity.wonValue,
                    participants: participants
                )
            }
            let payload = SessionUpdatePayload(
                title: draft.title,
                location: draft.location,
                takeaway: draft.takeaway,
                durationMinutes: max(1, Int(endedAt.timeIntervalSince(draft.startedAt) / 60)),
                posted: draft.postToFeed,
                startedAt: Self.iso.string(from: draft.startedAt),
                endedAt: Self.iso.string(from: endedAt),
                photoPath: photoPath ?? "",
                activities: activities
            )
            try await supabase.rpc(
                "update_own_session",
                params: UpdateSessionRPCParams(targetSessionId: session.id, payload: payload)
            ).execute()

            if draft.removePhoto, let oldPath = session.photoPath {
                try? await supabase.storage.from("post-photos").remove(paths: [oldPath])
            }
            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func deleteSession(_ session: FeedSession) async -> Bool {
        guard let uid = currentProfile?.id, session.userId == uid else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.from("sessions")
                .delete()
                .eq("id", value: session.id.uuidString)
                .execute()
            if let path = session.photoPath {
                try? await supabase.storage.from("post-photos").remove(paths: [path])
            }
            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func removeSelfFromSession(_ session: FeedSession) async -> Bool {
        guard let uid = currentProfile?.id, session.userId != uid else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.rpc(
                "remove_self_from_session",
                params: ["target_session_id": session.id.uuidString]
            ).execute()
            requestedRepostSessionIds.remove(session.id)
            await loadFeed()
            await loadNotifications(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    // MARK: - Notifications

    /// Requests that need an action (follow + repost approvals).
    var pendingNotificationCount: Int {
        incomingFollowRequests.count + incomingRepostRequests.count
    }

    var unreadNotificationCount: Int { notifications.filter { !$0.read }.count }

    /// Total count shown on the bell badge: actionable requests + unread activity.
    var badgeCount: Int { pendingNotificationCount + unreadNotificationCount }

    func loadNotifications(userId: UUID) async {
        do {
            let rows: [AppNotification] = try await supabase
                .from("notifications")
                .select("id,type,read,created_at,detail, actor:profiles!notifications_actor_id_fkey(\(Self.selectProfileLite)), session:sessions!notifications_session_id_fkey(id,title), comment:comments!notifications_comment_id_fkey(id,body), invite:session_invites!notifications_invite_id_fkey(id, court:courts(name))")
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            var hydrated: [AppNotification] = []
            for var notification in rows {
                if let actor = notification.actor {
                    notification.actor = await hydrateParticipantProfile(actor)
                }
                hydrated.append(notification)
            }
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            notifications = hydrated
        } catch {
            reportError(error)
        }
    }

    /// Loads and ranks the crew leaderboard: most wins first, then win rate,
    /// then games played. Players with no matches sink to the bottom.
    func loadLeaderboard() async {
        do {
            let rows: [LeaderboardEntry] = try await supabase
                .rpc("crew_leaderboard")
                .execute()
                .value
            leaderboard = rows.sorted {
                if $0.wins != $1.wins { return $0.wins > $1.wins }
                if $0.winRate != $1.winRate { return $0.winRate > $1.winRate }
                return $0.matches > $1.matches
            }
        } catch {
            reportError(error)
        }
    }

    func markNotificationsRead() async {
        guard let uid = currentProfile?.id, unreadNotificationCount > 0 else { return }
        do {
            try await supabase.from("notifications")
                .update(["read": true])
                .eq("user_id", value: uid.uuidString)
                .eq("read", value: false)
                .execute()
            await loadNotifications(userId: uid)
        } catch {
            reportError(error)
        }
    }

    // MARK: - Comments

    func fetchComments(sessionId: UUID) async -> [Comment] {
        do {
            let rows: [Comment] = try await supabase
                .from("comments")
                .select("*, author:profiles!comments_user_id_fkey(\(Self.selectProfileLite))")
                .eq("session_id", value: sessionId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
            var hydrated: [Comment] = []
            for comment in rows {
                hydrated.append(await hydrateComment(comment))
            }
            return hydrated
        } catch {
            reportError(error)
            return []
        }
    }

    @discardableResult
    func addComment(sessionId: UUID, body: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await supabase.from("comments")
                .insert(NewComment(sessionId: sessionId, userId: uid, body: trimmed))
                .execute()
            await refreshSessionAcrossFeeds(id: sessionId)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    @discardableResult
    func deleteComment(_ comment: Comment) async -> Bool {
        do {
            try await supabase.from("comments")
                .delete()
                .eq("id", value: comment.id.uuidString)
                .execute()
            await refreshSessionAcrossFeeds(id: comment.sessionId)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    // MARK: - Reposts

    /// Ask the session's author for permission to repost (copy) it. Only allowed
    /// if you're tagged in the session (enforced by RLS).
    func requestRepost(_ session: FeedSession) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.from("repost_requests")
                .insert(NewRepostRequest(sessionId: session.id, requesterId: uid))
                .execute()
            requestedRepostSessionIds.insert(session.id)
        } catch {
            reportError(error)
        }
    }

    /// Incoming repost requests for sessions the signed-in user authored.
    func loadRepostRequests(userId: UUID) async {
        do {
            let rows: [RepostRequest] = try await supabase
                .from("repost_requests")
                .select("*, requester:profiles!requester_id(\(Self.selectProfileLite)), session:sessions!session_id(id,user_id,title)")
                .eq("status", value: "pending")
                .execute()
                .value
            var hydrated: [RepostRequest] = []
            for var request in rows where request.session?.userId == userId {
                if let requester = request.requester {
                    request.requester = await hydrateParticipantProfile(requester)
                }
                hydrated.append(request)
            }
            incomingRepostRequests = hydrated

            // Track your own outstanding requests so the button reads "Requested".
            let mine: [RepostRequest] = try await supabase
                .from("repost_requests")
                .select("id,session_id,requester_id,status")
                .eq("requester_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .execute()
                .value
            requestedRepostSessionIds = Set(mine.map(\.sessionId))
        } catch {
            reportError(error)
        }
    }

    func approveRepost(_ request: RepostRequest) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.rpc("approve_repost", params: ["request_id": request.id.uuidString]).execute()
            await loadRepostRequests(userId: uid)
            await loadFeed()
        } catch {
            reportError(error)
        }
    }

    func declineRepost(_ request: RepostRequest) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.from("repost_requests")
                .update(["status": "declined"])
                .eq("id", value: request.id.uuidString)
                .execute()
            await loadRepostRequests(userId: uid)
        } catch {
            reportError(error)
        }
    }

    func updateProfile(displayName: String, homeCourt: String, rating: Double?, preferredSide: String, birthday: String?) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let update = ProfileUpdate(
                displayName: displayName,
                homeCourt: homeCourt.isEmpty ? nil : homeCourt,
                rating: rating,
                preferredSide: preferredSide.isEmpty ? nil : preferredSide,
                birthday: birthday
            )
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            // Apply locally instead of re-fetching — saves a round trip and
            // avoids clobbering a concurrent avatar update to the same row.
            currentProfile?.displayName = displayName
            currentProfile?.homeCourt = homeCourt.isEmpty ? nil : homeCourt
            currentProfile?.rating = rating
            currentProfile?.preferredSide = preferredSide.isEmpty ? nil : preferredSide
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func updateMeasures(heightInches: Double?, weightPounds: Double?, shoeSize: Double?) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let update = MeasuresUpdate(
                heightInches: heightInches,
                weightPounds: weightPounds,
                shoeSize: shoeSize
            )
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            await loadProfile(userId: uid)
            return errorMessage == nil
        } catch {
            reportError(error)
            return false
        }
    }

    func uploadProfilePhoto(_ data: Data) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        // Decode + downscale + encode off the main thread so the UI never hangs
        // on a large camera photo. Avatars render in ≤96pt circles, so ~320px
        // (3× retina) is plenty and keeps files tiny (~20–40 KB).
        let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let image = UIImage(data: data) else { return nil }
            return Self.downscaledJPEG(from: image, maxDimension: 320)
        }.value
        guard let jpeg else { return false }
        do {
            // Storage RLS checks the folder equals auth.uid()::text, which
            // Postgres renders lowercase — Swift's uuidString is uppercase, so
            // it must be lowercased or the insert fails the policy.
            let path = "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
            let oldPath = currentProfile?.avatarPath
            try await supabase.storage.from("avatars").upload(
                path,
                data: jpeg,
                // Unique immutable filename → safe to cache for a year.
                options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg")
            )
            try await supabase.from("profiles")
                .update(["avatar_path": path])
                .eq("id", value: uid.uuidString)
                .execute()
            if let oldPath, oldPath != path {
                try? await supabase.storage.from("avatars").remove(paths: [oldPath])
            }
            await loadProfile(userId: uid)
            // Refresh embedded author rows so the new signed avatar appears
            // everywhere without making photo selection wait on every feed.
            Task { [weak self] in
                guard let self else { return }
                await self.loadFeed()
                if !self.discoverFeed.isEmpty { await self.loadDiscover() }
                await self.loadMySessions(userId: uid)
            }
            return errorMessage == nil
        } catch {
            reportError(error)
            return false
        }
    }

    func addGear(category: String, name: String, brand: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let new = NewGear(
                userId: uid,
                category: category,
                name: name,
                brand: brand.isEmpty ? nil : brand
            )
            try await supabase.from("gear").insert(new).execute()
            await loadGear(userId: uid)
            return errorMessage == nil
        } catch {
            reportError(error)
            return false
        }
    }

    func deleteGear(_ item: GearItem) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase
                .from("gear")
                .delete()
                .eq("id", value: item.id.uuidString)
                .execute()
            await loadGear(userId: uid)
        } catch {
            reportError(error)
        }
    }

    func toggleLike(_ session: FeedSession) async {
        guard let uid = currentProfile?.id else { return }
        let wasLiked = likedSessionIds.contains(session.id)
        optimisticLikeCounts[session.id] = max(0, likeCount(for: session) + (wasLiked ? -1 : 1))
        if wasLiked {
            likedSessionIds.remove(session.id)
        } else {
            likedSessionIds.insert(session.id)
        }

        do {
            if wasLiked {
                try await supabase
                    .from("likes")
                    .delete()
                    .eq("user_id", value: uid.uuidString)
                    .eq("session_id", value: session.id.uuidString)
                    .execute()
            } else {
                try await supabase
                    .from("likes")
                    .insert(NewLike(userId: uid, sessionId: session.id))
                    .execute()
            }
        } catch {
            if wasLiked {
                likedSessionIds.insert(session.id)
            } else {
                likedSessionIds.remove(session.id)
            }
            optimisticLikeCounts[session.id] = nil
            reportError(error)
            return
        }
        // Keep the optimistic count as the source of truth rather than reloading
        // only `feed`: `likeCount(for:)` reads this overlay for every array, so
        // copies of the session in `discoverFeed`/`mySessions` stay in sync too
        // (clearing it here would revert those to their stale decoded counts).
    }

    func likeCount(for session: FeedSession) -> Int {
        optimisticLikeCounts[session.id] ?? session.likeCount
    }

    // MARK: - Session invites (RSVP)

    private let selectInvite = "*, host:profiles!session_invites_host_id_fkey(\(AppStore.selectProfileLite)), court:courts(*), recipients:invite_recipients(*, user:profiles!invite_recipients_user_id_fkey(\(AppStore.selectProfileLite)))"

    /// Mutual followers only — the pool of people you're allowed to tag on an
    /// invite (matches the `is_mutual_follow` RLS check on `invite_recipients`).
    var mutualFriends: [FollowListEntry] {
        followers.filter { $0.isFollowedByMe }
    }

    /// Upcoming, non-cancelled invites visible to the signed-in user (hosted by
    /// them or tagged in). RLS already scopes rows to what's visible.
    func loadActiveInvites(userId: UUID) async {
        do {
            let rows: [SessionInvite] = try await supabase
                .from("session_invites")
                .select(selectInvite)
                .is("cancelled_at", value: nil)
                .gte("scheduled_at", value: Self.iso.string(from: Date()))
                .order("scheduled_at", ascending: true)
                .execute()
                .value
            guard currentProfile?.id == userId else { return }
            var hydrated: [SessionInvite] = []
            for var invite in rows {
                if let host = invite.host { invite.host = await hydrateParticipantProfile(host) }
                hydrated.append(invite)
            }
            activeInvites = hydrated
        } catch {
            reportError(error)
        }
    }

    /// Loads one invite for notification/deep-link detail, including cancelled
    /// or elapsed invites that no longer belong in the Upcoming list.
    func loadInvite(inviteId: UUID) async -> SessionInvite? {
        do {
            let rows: [SessionInvite] = try await supabase
                .from("session_invites")
                .select(selectInvite)
                .eq("id", value: inviteId.uuidString)
                .limit(1)
                .execute()
                .value
            guard var invite = rows.first else { return nil }
            if let host = invite.host { invite.host = await hydrateParticipantProfile(host) }
            return invite
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Finds an existing court within ~50m of the given coordinate, or creates
    /// one. Dedupes repeat invites at the same place picked via MapKit search
    /// without needing a separate search-or-create registry UI.
    func findOrCreateCourt(name: String, latitude: Double, longitude: Double) async -> Court? {
        guard let uid = currentProfile?.id else { return nil }
        // ~50m in degrees of latitude; longitude tolerance widened slightly
        // since a degree of longitude shrinks away from the equator.
        let latDelta = 0.00045
        let lonDelta = 0.0006
        do {
            let nearby: [Court] = try await supabase
                .from("courts")
                .select()
                .gte("latitude", value: latitude - latDelta)
                .lte("latitude", value: latitude + latDelta)
                .gte("longitude", value: longitude - lonDelta)
                .lte("longitude", value: longitude + lonDelta)
                .limit(1)
                .execute()
                .value
            if let existing = nearby.first { return existing }

            let created: [Court] = try await supabase
                .from("courts")
                .insert(NewCourt(name: name, latitude: latitude, longitude: longitude, createdBy: uid))
                .select()
                .execute()
                .value
            return created.first
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Creates an invite and tags the given mutual-follower friends (RLS
    /// enforces the mutual-follow requirement per recipient).
    @discardableResult
    func createInvite(courtId: UUID, scheduledAt: Date, note: String?, recipientIds: [UUID]) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created: [SessionInvite] = try await supabase
                .from("session_invites")
                .insert(NewSessionInvite(hostId: uid, courtId: courtId, scheduledAt: scheduledAt, note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote))
                .select()
                .execute()
                .value
            guard let invite = created.first else { return false }
            if !recipientIds.isEmpty {
                try await supabase
                    .from("invite_recipients")
                    .insert(recipientIds.map { NewInviteRecipient(inviteId: invite.id, userId: $0) })
                    .execute()
            }
            await loadActiveInvites(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func respondToInvite(_ invite: SessionInvite, status: RSVPStatus) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase
                .from("invite_recipients")
                .update(InviteRecipientUpdate(status: status.rawValue, respondedAt: Date()))
                .eq("invite_id", value: invite.id.uuidString)
                .eq("user_id", value: uid.uuidString)
                .execute()
            await loadActiveInvites(userId: uid)
        } catch {
            reportError(error)
        }
    }

    /// Soft-cancels an invite. The database enforces host ownership and emits
    /// one cancellation notification for every invited recipient.
    @discardableResult
    func cancelInvite(_ invite: SessionInvite) async -> Bool {
        guard let uid = currentProfile?.id,
              invite.hostId == uid,
              !invite.isCancelled,
              !invite.isPast else { return false }
        do {
            try await supabase
                .from("session_invites")
                .update(InviteCancellationUpdate(cancelledAt: Date()))
                .eq("id", value: invite.id.uuidString)
                .eq("host_id", value: uid.uuidString)
                .is("cancelled_at", value: nil)
                .execute()
            activeInvites.removeAll { $0.id == invite.id }
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    // MARK: - Helpers

    /// People `userId` follows with an accepted edge (for feed visibility).
    private func acceptedFollowingIds(for userId: UUID) async throws -> [UUID] {
        let edges: [FollowRow] = try await supabase
            .from("follows")
            .select("follower_id, followee_id, status, created_at")
            .eq("follower_id", value: userId.uuidString)
            .eq("status", value: "accepted")
            .execute()
            .value
        let ids = Set(edges.map(\.followeeId))
        if currentProfile?.id == userId {
            acceptedFollowingUserIDs = ids
        }
        return Array(ids)
    }

    /// Fetches profiles for the given ids in one query, keyed by id. Ids that
    /// aren't visible (RLS) are simply absent from the result.
    private func profilesByID(for ids: [UUID]) async throws -> [UUID: Profile] {
        let unique = Array(Set(ids)).map(\.uuidString)
        guard !unique.isEmpty else { return [:] }
        let profiles: [Profile] = try await supabase
            .from("profiles")
            .select()
            .in("id", values: unique)
            .execute()
            .value
        var hydrated: [UUID: Profile] = [:]
        for profile in await hydrateProfiles(profiles) {
            hydrated[profile.id] = profile
        }
        return hydrated
    }

    private func likedSessionIds(for userId: UUID, sessionIds: [UUID]) async throws -> Set<UUID> {
        let unique = Array(Set(sessionIds)).map(\.uuidString)
        guard !unique.isEmpty else { return [] }
        let rows: [LikeRow] = try await supabase
            .from("likes")
            .select("session_id")
            .eq("user_id", value: userId.uuidString)
            .in("session_id", values: unique)
            .execute()
            .value
        return Set(rows.map(\.sessionId))
    }

    private static func inFilter(for ids: [UUID]) -> String {
        let values = ids.map { #""\#($0.uuidString)""# }.joined(separator: ",")
        return "(\(values))"
    }

    private static func displayNameSearchTerm(from query: String) -> String {
        let withoutHandle = query.trimmed.replacingOccurrences(of: "@", with: "")
        let allowed = withoutHandle.filter { character in
            character.isLetter
                || character.isNumber
                || character.isWhitespace
                || character == "_"
                || character == "."
                || character == "-"
                || character == "'"
        }
        return allowed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    private func hydrateProfile(_ profile: Profile) async -> Profile {
        await hydrateProfiles([profile]).first ?? profile
    }

    private func hydrateProfiles(_ profiles: [Profile]) async -> [Profile] {
        let paths = Set(profiles.compactMap(\.avatarPath))
        let urls = await signedMediaURLs(bucket: "avatars", paths: paths)
        return profiles.map { profile in
            guard let path = profile.avatarPath else { return profile }
            var hydrated = profile
            hydrated.avatarURL = urls[path]
            return hydrated
        }
    }

    private func hydrateParticipantProfile(_ profile: ParticipantProfile) async -> ParticipantProfile {
        guard let path = profile.avatarPath else { return profile }
        var hydrated = profile
        hydrated.avatarURL = await signedMediaURLs(bucket: "avatars", paths: [path])[path]
        return hydrated
    }

    private func hydrateComment(_ comment: Comment) async -> Comment {
        var hydrated = comment
        if let author = comment.author {
            hydrated.author = await hydrateParticipantProfile(author)
        }
        return hydrated
    }

    private func hydrateSessions(_ sessions: [FeedSession]) async -> [FeedSession] {
        var avatarPaths = Set<String>()
        var photoPaths = Set<String>()
        for session in sessions {
            if let path = session.author.avatarPath { avatarPaths.insert(path) }
            if let path = session.photoPath { photoPaths.insert(path) }
            for comment in session.previewComments ?? [] {
                if let path = comment.author?.avatarPath { avatarPaths.insert(path) }
            }
            for activity in session.activities ?? [] {
                for participant in activity.participants ?? [] {
                    if let path = participant.profile?.avatarPath { avatarPaths.insert(path) }
                }
            }
        }

        let avatarPathsToSign = avatarPaths
        let photoPathsToSign = photoPaths
        async let avatarURLs = signedMediaURLs(bucket: "avatars", paths: avatarPathsToSign)
        async let photoURLs = signedMediaURLs(bucket: "post-photos", paths: photoPathsToSign)
        let (avatars, photos) = await (avatarURLs, photoURLs)

        return sessions.map { session in
            var copy = session
            if let path = copy.author.avatarPath {
                copy.author.avatarURL = avatars[path]
            }
            copy.previewComments = copy.previewComments?.map { comment in
                var hydratedComment = comment
                if var author = hydratedComment.author, let path = author.avatarPath {
                    author.avatarURL = avatars[path]
                    hydratedComment.author = author
                }
                return hydratedComment
            }
            copy.activities = copy.activities?.map { activity in
                var hydratedActivity = activity
                hydratedActivity.participants = hydratedActivity.participants?.map { participant in
                    var hydratedParticipant = participant
                    if var profile = hydratedParticipant.profile, let path = profile.avatarPath {
                        profile.avatarURL = avatars[path]
                        hydratedParticipant.profile = profile
                    }
                    return hydratedParticipant
                }
                return hydratedActivity
            }
            if let path = copy.photoPath {
                copy.photoUrl = photos[path]
            }
            return copy
        }
    }

    private func signedMediaURLs(bucket: String, paths: Set<String>) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }

        let refreshAfter = Date().addingTimeInterval(signedURLRefreshLeeway)
        var resolved: [String: String] = [:]
        var missing: [String] = []
        for path in paths.sorted() {
            let key = "\(bucket):\(path)"
            if let cached = mediaURLCache[key], cached.validUntil > refreshAfter {
                resolved[path] = cached.value
            } else {
                missing.append(path)
            }
        }
        guard !missing.isEmpty else { return resolved }

        let signingBeganAt = Date()
        do {
            let results: [SignedURLResult] = try await supabase.storage
                .from(bucket)
                .createSignedURLs(paths: missing, expiresIn: signedURLLifetime)
            let validUntil = Date().addingTimeInterval(
                TimeInterval(signedURLLifetime) - signedURLRefreshLeeway
            )
            for result in results {
                guard case .success(let path, let url) = result else { continue }
                let value = url.absoluteString
                resolved[path] = value
                mediaURLCache["\(bucket):\(path)"] = CachedMediaURL(
                    value: value,
                    validUntil: validUntil
                )
            }
            debugFeedMetric("signed \(missing.count) \(bucket) URLs in one request", since: signingBeganAt)
        } catch {
            Self.feedLogger.error("\(bucket, privacy: .public) batch signing failed: \(error.localizedDescription, privacy: .public)")
        }
        return resolved
    }

    private func debugFeedMetric(_ label: String, since start: Date) {
        #if DEBUG
        let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
        Self.feedLogger.debug("\(label, privacy: .public): \(milliseconds) ms")
        #endif
    }

    /// Uploads a post photo to the post-photos bucket under the user's
    /// lowercase uid folder and returns its private object path.
    func uploadPostPhoto(_ data: Data, sessionId: UUID, uid: UUID) async -> String? {
        let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let image = UIImage(data: data) else { return nil }
            return Self.downscaledJPEG(from: image, maxDimension: 1024)
        }.value
        guard let jpeg else { return nil }
        do {
            let path = "\(uid.uuidString.lowercased())/\(sessionId.uuidString.lowercased()).jpg"
            try await supabase.storage.from("post-photos").upload(
                path,
                data: jpeg,
                // Post filename is per-session (can be overwritten on edit), so
                // cache for a day rather than a year.
                options: FileOptions(cacheControl: "86400", contentType: "image/jpeg", upsert: true)
            )
            return path
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Downscales an image so its longest side is at most `maxDimension`, then
    /// JPEG-encodes it. Avatars use a small dimension (they render in tiny
    /// circles); post photos use a larger one. `nonisolated static` so callers
    /// can run this CPU-heavy work off the main thread via `Task.detached`.
    nonisolated private static func downscaledJPEG(from image: UIImage, maxDimension: CGFloat, quality: CGFloat = 0.82) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else {
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / longestSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Surface an error to the user — unless it's a cancellation. A cancelled
    /// request (a superseded feed refresh, a task torn down on dismiss) is not a
    /// failure and must never pop an alert. Because `errorMessage` is shared
    /// app-wide, a cancelled background reload used to hijack whatever modal was
    /// on screen (e.g. "Couldn't post session" after a post that actually saved).
    private func reportError(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        errorMessage = friendly(error)
    }

    private func friendly(_ error: Error) -> String {
        if let functionsError = error as? FunctionsError {
            switch functionsError {
            case .httpError(let code, let data):
                if
                    let payload = try? JSONDecoder().decode(EdgeFunctionErrorPayload.self, from: data),
                    !payload.error.isEmpty
                {
                    return payload.error
                }
                if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                    return "Edge Function \(code): \(body)"
                }
                return "Edge Function returned status \(code)."
            case .relayError:
                return functionsError.localizedDescription
            }
        }
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }
}

private struct EdgeFunctionErrorPayload: Decodable {
    let error: String
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
