import Foundation
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
    /// Count of in-flight user-initiated operations. `isBusy` is *derived* from
    /// this so concurrent operations (e.g. saving profile fields and a photo at
    /// once) don't clobber each other — the UI reads idle only once every one of
    /// them has finished, not when the first to return flips a shared bool.
    @Published private var busyCount = 0
    var isBusy: Bool { busyCount > 0 }
    @Published var errorMessage: String?

    private let selectWithCounts = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(id,username,display_name,avatar_initials,avatar_url,avatar_path)))"
    private let selectFeedPreview = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), preview_comments:comments(*, author:profiles!comments_user_id_fkey(id,username,display_name,avatar_initials,avatar_url,avatar_path)), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(id,username,display_name,avatar_initials,avatar_url,avatar_path)))"

    private var realtimeChannel: RealtimeChannelV2?
    private var realtimeTask: Task<Void, Never>?
    private var notifChannel: RealtimeChannelV2?
    private var notifTask: Task<Void, Never>?
    private var followsChannel: RealtimeChannelV2?
    private var followsInTask: Task<Void, Never>?
    private var followsOutTask: Task<Void, Never>?
    private var commentsChannel: RealtimeChannelV2?
    private var commentsTask: Task<Void, Never>?

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
                errorMessage = friendly(error)
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
        await loadFollowState(userId: userId)
        await loadFollowLists(userId: userId)
        await loadFeed()
        await loadMySessions(userId: userId)
        await loadGear(userId: userId)
        await loadRepostRequests(userId: userId)
        await loadNotifications(userId: userId)
        await loadBlockedAccounts()
        startRealtime(userId: userId)
        await setUpPush()
    }

    // MARK: - Push notifications

    /// Wires the token callback and registers with APNs. On first sign-in this
    /// prompts for permission; on later launches it silently refreshes the token
    /// if the user already granted it.
    private func setUpPush() async {
        PushService.shared.onToken = { [weak self] token in
            Task { await self?.uploadDeviceToken(token) }
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

    private func uploadDeviceToken(_ token: String) async {
        guard currentProfile != nil else { return }
        do {
            try await supabase
                .rpc("register_device_token", params: ["p_token": token, "p_platform": "ios"])
                .execute()
        } catch {
            // Non-fatal: worst case the device just won't get pushes this run.
            print("[Push] token upload failed: \(error.localizedDescription)")
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
            let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "sessions")
            await channel.subscribe()
            for await _ in changes {
                await self?.refreshFeeds(userId: userId)
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
    }

    private func refreshFeeds(userId: UUID) async {
        await loadFeed()
        await loadMySessions(userId: userId)
        if !discoverFeed.isEmpty { await loadDiscover() }
    }

    private func reloadFollowGraph(userId: UUID, refreshFeed: Bool) async {
        await loadFollowState(userId: userId)
        await loadFollowLists(userId: userId)
        if refreshFeed { await loadFeed() }
    }

    private func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        notifTask?.cancel()
        notifTask = nil
        followsInTask?.cancel()
        followsInTask = nil
        followsOutTask?.cancel()
        followsOutTask = nil
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
            errorMessage = friendly(error)
            return .failed
        }
    }

    /// Following feed: your posts + posts from people you follow (accepted).
    /// Paginated — pass reset: false to append the next page.
    func loadFeed(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { feedReachedEnd = false } else if feedReachedEnd { return }
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
            let hydratedPage = await hydrateSessions(page)
            feed = reset ? hydratedPage : feed + hydratedPage
            feedReachedEnd = page.count < feedPageSize
            await refreshLikedState(for: page, uid: uid)
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Discover feed: recent public posts from everyone (excluding your own).
    func loadDiscover(reset: Bool = true) async {
        guard let uid = currentProfile?.id else { return }
        if reset { discoverReachedEnd = false } else if discoverReachedEnd { return }
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
            let hydratedPage = await hydrateSessions(page)
            discoverFeed = reset ? hydratedPage : discoverFeed + hydratedPage
            discoverReachedEnd = page.count < feedPageSize
            await refreshLikedState(for: page, uid: uid)
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
            return nil
        }
    }

    func loadGear(userId: UUID) async {
        do {
            gear = try await supabase
                .from("gear")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Loads follow counts, incoming pending requests, and the set of people
    /// this user has already requested/follows (for discovery button state).
    func loadFollowState(userId: UUID) async {
        do {
            followerCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "accepted")
                .execute()
                .count ?? 0
            followingCount = try await supabase
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
            requestedFollowIds = Set(outgoing.map(\.followeeId))

            // Incoming pending requests → resolve requester profiles.
            let incoming: [FollowRow] = try await supabase
                .from("follows")
                .select("follower_id, followee_id, status, created_at")
                .eq("followee_id", value: userId.uuidString)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
            let followers = try await profilesByID(for: incoming.map(\.followerId))
            incomingFollowRequests = incoming.map { row in
                FollowRequest(
                    followerId: row.followerId,
                    followeeId: row.followeeId,
                    follower: followers[row.followerId]
                )
            }
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
        }
    }

    // MARK: - User safety

    func loadBlockedAccounts() async {
        guard let uid = currentProfile?.id else {
            blockedAccounts = []
            return
        }
        do {
            blockedAccounts = try await supabase
                .from("blocks")
                .select("blocked_id,blocked_username,blocked_display_name,blocked_avatar_path,created_at")
                .eq("blocker_id", value: uid.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
            return nil
        }
    }

    // MARK: - Writes

    func logSession(
        title: String,
        location: String,
        durationMinutes: Int,
        focus: String,
        takeaway: String,
        postToFeed: Bool
    ) async {
        guard let uid = currentProfile?.id else { return }
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            let new = NewSession(
                userId: uid,
                title: title.isEmpty ? nil : title,
                location: location.isEmpty ? nil : location,
                durationMinutes: durationMinutes,
                focus: focus,
                takeaway: takeaway.isEmpty ? nil : takeaway,
                posted: postToFeed
            )
            try await supabase.from("sessions").insert(new).execute()
            await loadMySessions(userId: uid)
            await loadFeed()
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Write a full multi-activity session built on-device. Inserts the session
    /// unposted, writes activities + tagged participants, then flips `posted`
    /// last so realtime subscribers only see the completed post.
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
                title: draft.title.isEmpty ? nil : draft.title,
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
                    won: isMatch ? activity.won : nil
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
            errorMessage = friendly(error)
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
                    won: isMatch ? activity.won : nil,
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
                .select("id,type,read,created_at, actor:profiles!notifications_actor_id_fkey(id,username,display_name,avatar_initials,avatar_url,avatar_path), session:sessions!notifications_session_id_fkey(id,title), comment:comments!notifications_comment_id_fkey(id,body)")
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
            notifications = hydrated
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
        }
    }

    // MARK: - Comments

    func fetchComments(sessionId: UUID) async -> [Comment] {
        do {
            let rows: [Comment] = try await supabase
                .from("comments")
                .select("*, author:profiles!comments_user_id_fkey(id,username,display_name,avatar_initials,avatar_url,avatar_path)")
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
            errorMessage = friendly(error)
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
            await loadFeed()
            return true
        } catch {
            errorMessage = friendly(error)
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
            await loadFeed()
            return true
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
        }
    }

    /// Incoming repost requests for sessions the signed-in user authored.
    func loadRepostRequests(userId: UUID) async {
        do {
            let rows: [RepostRequest] = try await supabase
                .from("repost_requests")
                .select("*, requester:profiles!requester_id(id,username,display_name,avatar_initials,avatar_url,avatar_path), session:sessions!session_id(id,user_id,title)")
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
            errorMessage = friendly(error)
        }
    }

    func approveRepost(_ request: RepostRequest) async {
        guard let uid = currentProfile?.id else { return }
        do {
            try await supabase.rpc("approve_repost", params: ["request_id": request.id.uuidString]).execute()
            await loadRepostRequests(userId: uid)
            await loadFeed()
        } catch {
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
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
            errorMessage = friendly(error)
            return
        }
        await loadFeed()
        optimisticLikeCounts[session.id] = nil
    }

    func likeCount(for session: FeedSession) -> Int {
        optimisticLikeCounts[session.id] ?? session.likeCount
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
        return Array(Set(edges.map(\.followeeId)))
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
        for profile in profiles {
            hydrated[profile.id] = await hydrateProfile(profile)
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
        guard let path = profile.avatarPath else { return profile }
        var hydrated = profile
        if let url = try? await supabase.storage.from("avatars")
            .createSignedURL(path: path, expiresIn: 900) {
            hydrated.avatarURL = url.absoluteString
        } else {
            hydrated.avatarURL = nil
        }
        return hydrated
    }

    private func hydrateParticipantProfile(_ profile: ParticipantProfile) async -> ParticipantProfile {
        guard let path = profile.avatarPath else { return profile }
        var hydrated = profile
        if let url = try? await supabase.storage.from("avatars")
            .createSignedURL(path: path, expiresIn: 900) {
            hydrated.avatarURL = url.absoluteString
        } else {
            hydrated.avatarURL = nil
        }
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
        var hydrated: [FeedSession] = []
        hydrated.reserveCapacity(sessions.count)
        for session in sessions {
            var copy = session
            copy.author = await hydrateProfile(session.author)
            if let comments = session.previewComments {
                var hydratedComments: [Comment] = []
                for comment in comments {
                    hydratedComments.append(await hydrateComment(comment))
                }
                copy.previewComments = hydratedComments
            }
            if let activities = session.activities {
                var hydratedActivities: [SessionActivity] = []
                for var activity in activities {
                    if let participants = activity.participants {
                        var hydratedParticipants: [ActivityParticipant] = []
                        for var participant in participants {
                            if let profile = participant.profile {
                                participant.profile = await hydrateParticipantProfile(profile)
                            }
                            hydratedParticipants.append(participant)
                        }
                        activity.participants = hydratedParticipants
                    }
                    hydratedActivities.append(activity)
                }
                copy.activities = hydratedActivities
            }
            if let path = session.photoPath,
               let url = try? await supabase.storage.from("post-photos")
                .createSignedURL(path: path, expiresIn: 900) {
                copy.photoUrl = url.absoluteString
            } else if session.photoPath != nil {
                copy.photoUrl = nil
            }
            hydrated.append(copy)
        }
        return hydrated
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
            errorMessage = friendly(error)
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
