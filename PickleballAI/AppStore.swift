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
    @Published var friendCount = 0
    @Published var pendingFriendRequestCount = 0
    @Published var incomingFriendRequests: [FriendRequest] = []
    @Published var contactMatches: [ContactMatch] = []
    @Published var searchResults: [Profile] = []
    @Published var requestedFriendIds: Set<UUID> = []
    @Published var gear: [GearItem] = []
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let selectWithCounts = "*, author:profiles(*), likes(count), comments(count)"
    private let requestSelect = """
    *,
    requester:profiles!friend_requests_requester_id_fkey(*),
    addressee:profiles!friend_requests_addressee_id_fkey(*)
    """

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
            errorMessage = friendly(error)
            return false
        }
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        currentProfile = nil
        feed = []
        mySessions = []
        friendCount = 0
        pendingFriendRequestCount = 0
        incomingFriendRequests = []
        contactMatches = []
        searchResults = []
        requestedFriendIds = []
        gear = []
        authState = .signedOut
    }

    private func handleSignedIn(userId: UUID) async {
        authState = .loading
        let didLoadProfile = await loadProfile(userId: userId)
        guard didLoadProfile, let profile = currentProfile else {
            authState = .needsOnboarding
            return
        }
        if profile.hasCompletedOnboarding {
            authState = .signedIn
            await loadSignedInData(userId: userId)
        } else {
            authState = .needsOnboarding
            await loadFriendState(userId: userId)
        }
    }

    private func loadSignedInData(userId: UUID) async {
        await loadFriendState(userId: userId)
        await loadFeed()
        await loadMySessions(userId: userId)
        await loadGear(userId: userId)
    }

    // MARK: - Reads

    @discardableResult
    func loadProfile(userId: UUID) async -> Bool {
        do {
            let profile: Profile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            currentProfile = profile
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    func loadFeed() async {
        guard let uid = currentProfile?.id else { return }
        do {
            let friendIds = try await acceptedFriendIds(for: uid)
            let visibleIds = [uid] + friendIds
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

    func loadFriendState(userId: UUID) async {
        do {
            let accepted: [FriendRequest] = try await supabase
                .from("friend_requests")
                .select()
                .eq("status", value: "accepted")
                .execute()
                .value
            let pending: [FriendRequest] = try await supabase
                .from("friend_requests")
                .select(requestSelect)
                .eq("status", value: "pending")
                .execute()
                .value

            friendCount = Set(accepted.map { $0.otherUserId(for: userId) }).count
            incomingFriendRequests = pending.filter { $0.addresseeId == userId }
            pendingFriendRequestCount = incomingFriendRequests.count
            requestedFriendIds = Set(
                pending
                    .filter { $0.requesterId == userId }
                    .map(\.addresseeId)
            )
        } catch {
            errorMessage = friendly(error)
        }
    }

    func refresh() async {
        guard let uid = currentProfile?.id else { return }
        await loadFriendState(userId: uid)
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

    func sendFriendRequest(to profile: Profile) async {
        guard let uid = currentProfile?.id, uid != profile.id else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let new = NewFriendRequest(
                requesterId: uid,
                addresseeId: profile.id,
                status: "pending"
            )
            try await supabase.from("friend_requests").insert(new).execute()
            requestedFriendIds.insert(profile.id)
            await loadFriendState(userId: uid)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func respond(to request: FriendRequest, status: String) async {
        guard let uid = currentProfile?.id, request.addresseeId == uid else { return }
        do {
            try await supabase
                .from("friend_requests")
                .update(["status": status])
                .eq("id", value: request.id.uuidString)
                .execute()
            await loadFriendState(userId: uid)
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

    private func acceptedFriendIds(for userId: UUID) async throws -> [UUID] {
        let accepted: [FriendRequest] = try await supabase
            .from("friend_requests")
            .select()
            .eq("status", value: "accepted")
            .execute()
            .value
        return Array(Set(accepted.map { $0.otherUserId(for: userId) }))
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
