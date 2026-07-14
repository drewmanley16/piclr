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
    @Published var notifications: [AppNotification] = []
    @Published var isBusy = false
    @Published var errorMessage: String?

    let selectWithCounts = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(id,username,display_name,avatar_initials,avatar_url)))"
    let selectFeedPreview = "*, author:profiles!sessions_user_id_fkey(*), likes(count), comments(count), preview_comments:comments(*, author:profiles!comments_user_id_fkey(id,username,display_name,avatar_initials,avatar_url)), activities:session_activities(*, participants:activity_participants!activity_participants_activity_id_fkey(*, profile:profiles!activity_participants_profile_id_fkey(id,username,display_name,avatar_initials,avatar_url)))"

    var realtimeChannel: RealtimeChannelV2?
    var realtimeTask: Task<Void, Never>?
    var notifChannel: RealtimeChannelV2?
    var notifTask: Task<Void, Never>?
    var followsChannel: RealtimeChannelV2?
    var followsInTask: Task<Void, Never>?
    var followsOutTask: Task<Void, Never>?

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
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await supabase.auth.signInWithOTP(phone: phone)
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func verifyPhoneOTP(phone: String, token: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
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

    func completeOnboarding(
        displayName: String,
        username: String,
        skillLevel: SkillLevel,
        duprRating: Double?
    ) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
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
    func isAuthFailure(_ error: Error) -> Bool {
        if let functionsError = error as? FunctionsError,
           case .httpError(let code, _) = functionsError {
            return code == 401 || code == 403
        }
        return error is AuthError
    }

    func signOut() async {
        stopRealtime()
        try? await supabase.auth.signOut()
        currentProfile = nil
        feed = []
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
        authState = .signedOut
    }

    func handleSignedIn(userId: UUID) async {
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

    func loadSignedInData(userId: UUID) async {
        await loadFollowState(userId: userId)
        await loadFollowLists(userId: userId)
        await loadFeed()
        await loadMySessions(userId: userId)
        await loadGear(userId: userId)
        await loadRepostRequests(userId: userId)
        await loadNotifications(userId: userId)
        startRealtime(userId: userId)
    }

    // MARK: - Realtime

    /// Subscribe to `sessions` changes so new posts (yours or people you follow)
    /// surface in the feed live, without a manual refresh.
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
            currentProfile = profile
            return .loaded
        } catch {
            errorMessage = friendly(error)
            return .failed
        }
    }

    /// Following feed: your posts + posts from people you follow (accepted).
    /// Paginated — pass reset: false to append the next page.
    /// Discover feed: recent public posts from everyone (excluding your own).
    func refreshLikedState(for sessions: [FeedSession], uid: UUID) async {
        guard !sessions.isEmpty else { return }
        if let liked = try? await likedSessionIds(for: uid, sessionIds: sessions.map(\.id)) {
            likedSessionIds.formUnion(liked)
        }
    }

    /// Loads follow counts, incoming pending requests, and the set of people
    /// this user has already requested/follows (for discovery button state).
    /// Loads the accepted followers/following lists, each annotated with
    /// whether the signed-in user follows that person back.
    /// Loads another user's followers or following list. Each entry's
    /// `isFollowedByMe` reflects whether the *signed-in* user follows that
    /// person (accepted) — so the follow-back button is relative to me,
    /// Instagram-style. Returns the entries rather than mutating the store's
    /// own published lists.
    func refresh() async {
        guard let uid = currentProfile?.id else { return }
        await loadFollowState(userId: uid)
        await loadFollowLists(userId: uid)
        await loadFeed()
        await loadMySessions(userId: uid)
        await loadGear(userId: uid)
    }

    // MARK: - Friend discovery

    /// Sends a follow request: inserts a `pending` edge (me → profile).
    /// Respond to an incoming follow request. Accepting flips the edge to
    /// accepted; declining deletes it so it can be re-requested later.
    /// Unfollow someone: deletes the signed-in user's outgoing edge (me → them),
    /// whether it was accepted or still pending. Their sessions drop out of the
    /// feed and their profile becomes private again.
    /// Loads another user's public profile. Basic fields + follower/following
    /// counts are always visible; sessions are fetched only when the signed-in
    /// user follows them (accepted). The `sessions` query is additionally
    /// RLS-gated, so it returns nothing even if this check were bypassed.
    // MARK: - Writes

    /// Write a full multi-activity session built on-device. Inserts the session
    /// unposted, writes activities + tagged participants, then flips `posted`
    /// last so realtime subscribers only see the completed post.
    // MARK: - Notifications

    /// Requests that need an action (follow + repost approvals).
    var pendingNotificationCount: Int {
        incomingFollowRequests.count + incomingRepostRequests.count
    }

    var unreadNotificationCount: Int { notifications.filter { !$0.read }.count }

    /// Total count shown on the bell badge: actionable requests + unread activity.
    var badgeCount: Int { pendingNotificationCount + unreadNotificationCount }

    // MARK: - Comments

    // MARK: - Reposts

    /// Ask the session's author for permission to repost (copy) it. Only allowed
    /// if you're tagged in the session (enforced by RLS).
    /// Incoming repost requests for sessions the signed-in user authored.
    // MARK: - Helpers

    /// People `userId` follows with an accepted edge (for feed visibility).
    func acceptedFollowingIds(for userId: UUID) async throws -> [UUID] {
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
    func profilesByID(for ids: [UUID]) async throws -> [UUID: Profile] {
        let unique = Array(Set(ids)).map(\.uuidString)
        guard !unique.isEmpty else { return [:] }
        let profiles: [Profile] = try await supabase
            .from("profiles")
            .select()
            .in("id", values: unique)
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func likedSessionIds(for userId: UUID, sessionIds: [UUID]) async throws -> Set<UUID> {
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

    static func inFilter(for ids: [UUID]) -> String {
        let values = ids.map { #""\#($0.uuidString)""# }.joined(separator: ",")
        return "(\(values))"
    }

    static func displayNameSearchTerm(from query: String) -> String {
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

    func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    /// Uploads a post photo to the post-photos bucket under the user's
    /// (lowercase) uid folder and returns its public URL.
    /// Downscales an image so its longest side is at most `maxDimension`, then
    /// JPEG-encodes it. Avatars use a small dimension (they render in tiny
    /// circles); post photos use a larger one. `nonisolated static` so callers
    /// can run this CPU-heavy work off the main thread via `Task.detached`.
    nonisolated static func downscaledJPEG(from image: UIImage, maxDimension: CGFloat, quality: CGFloat = 0.82) -> Data? {
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

    func friendly(_ error: Error) -> String {
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

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
