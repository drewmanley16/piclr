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
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let selectWithCounts = "*, author:profiles(*), likes(count), comments(count)"

    private var realtimeChannel: RealtimeChannelV2?
    private var realtimeTask: Task<Void, Never>?

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
    private func isAuthFailure(_ error: Error) -> Bool {
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
        startRealtime(userId: userId)
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
    }

    private func refreshFeeds(userId: UUID) async {
        await loadFeed()
        await loadMySessions(userId: userId)
    }

    private func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        if let channel = realtimeChannel {
            realtimeChannel = nil
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
            currentProfile = profile
            return .loaded
        } catch {
            errorMessage = friendly(error)
            return .failed
        }
    }

    func loadFeed() async {
        guard let uid = currentProfile?.id else { return }
        do {
            // Directional: your feed shows your own sessions plus those of the
            // people you follow (accepted).
            let followingIds = try await acceptedFollowingIds(for: uid)
            let visibleIds = [uid] + followingIds
            let idFilter = Self.inFilter(for: visibleIds)
            feed = try await supabase
                .from("sessions")
                .select(selectWithCounts)
                .eq("posted", value: true)
                .filter("user_id", operator: "in", value: idFilter)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadMySessions(userId: UUID) async {
        do {
            mySessions = try await supabase
                .from("sessions")
                .select(selectWithCounts)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = friendly(error)
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
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
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
            contactMatches = matches.filter { match in
                guard match.profile.id != ownId, !seenProfileIds.contains(match.profile.id) else {
                    return false
                }
                seenProfileIds.insert(match.profile.id)
                return true
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func searchProfiles(query: String) async {
        let cleaned = query.normalizedUsername
        guard cleaned.count >= 2 else {
            searchResults = []
            return
        }
        do {
            let results: [Profile] = try await supabase
                .from("profiles")
                .select()
                .ilike("username", pattern: "%\(cleaned)%")
                .limit(10)
                .execute()
                .value
            let ownId = currentProfile?.id
            searchResults = results.filter { $0.id != ownId && $0.hasCompletedOnboarding }
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Sends a follow request: inserts a `pending` edge (me → profile).
    func sendFollowRequest(to profile: Profile) async {
        guard let uid = currentProfile?.id, uid != profile.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
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
        isBusy = true
        defer { isBusy = false }
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

    func updateProfile(displayName: String, homeCourt: String, rating: Double?, preferredSide: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let update = ProfileUpdate(
                displayName: displayName,
                homeCourt: homeCourt.isEmpty ? nil : homeCourt,
                rating: rating,
                preferredSide: preferredSide.isEmpty ? nil : preferredSide
            )
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            await loadProfile(userId: uid)
            return errorMessage == nil
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func updateMeasures(heightInches: Double?, weightPounds: Double?, shoeSize: Double?) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
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
        guard let uid = currentProfile?.id, let image = UIImage(data: data),
              let jpeg = profileJPEG(from: image) else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let path = "\(uid.uuidString)/\(UUID().uuidString).jpg"
            try await supabase.storage.from("avatars").upload(
                path,
                data: jpeg,
                options: FileOptions(contentType: "image/jpeg")
            )
            let publicURL = try supabase.storage.from("avatars").getPublicURL(path: path)
            try await supabase.from("profiles")
                .update(["avatar_url": publicURL.absoluteString])
                .eq("id", value: uid.uuidString)
                .execute()
            await loadProfile(userId: uid)
            return errorMessage == nil
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func addGear(category: String, name: String, brand: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
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
        do {
            try await supabase
                .from("likes")
                .insert(NewLike(userId: uid, sessionId: session.id))
                .execute()
        } catch {
            // Already liked -> treat as unlike.
            _ = try? await supabase
                .from("likes")
                .delete()
                .eq("user_id", value: uid.uuidString)
                .eq("session_id", value: session.id.uuidString)
                .execute()
        }
        await loadFeed()
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
        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    private static func inFilter(for ids: [UUID]) -> String {
        let values = ids.map { #""\#($0.uuidString)""# }.joined(separator: ",")
        return "(\(values))"
    }

    private func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    private func profileJPEG(from image: UIImage) -> Data? {
        let maximumDimension: CGFloat = 1024
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maximumDimension else {
            return image.jpegData(compressionQuality: 0.82)
        }
        let scale = maximumDimension / longestSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.82)
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
