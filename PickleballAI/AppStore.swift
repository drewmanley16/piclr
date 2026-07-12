import Foundation
import Supabase

@MainActor
final class AppStore: ObservableObject {
    enum AuthState: Equatable {
        case unconfigured
        case loading
        case signedOut
        case signedIn
    }

    @Published var authState: AuthState = .loading
    @Published var currentProfile: Profile?
    @Published var feed: [FeedSession] = []
    @Published var mySessions: [FeedSession] = []
    @Published var followerCount = 0
    @Published var followingCount = 0
    @Published var gear: [GearItem] = []
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let selectWithCounts = "*, author:profiles(*), likes(count), comments(count)"

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

    func signIn(email: String, password: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try await supabase.auth.signIn(email: email, password: password)
            await handleSignedIn(userId: session.user.id)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signUp(email: String, password: String, username: String, displayName: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            // The profile row is created server-side by the on_auth_user_created
            // trigger, using this metadata.
            let response = try await supabase.auth.signUp(
                email: email,
                password: password,
                data: [
                    "username": .string(username),
                    "display_name": .string(displayName),
                    "avatar_initials": .string(initials(from: displayName))
                ]
            )
            if let session = response.session {
                await handleSignedIn(userId: session.user.id)
            } else {
                // Email confirmation is enabled: no session yet.
                errorMessage = "Check your email to confirm your account, then sign in."
                authState = .signedOut
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        currentProfile = nil
        feed = []
        mySessions = []
        followerCount = 0
        followingCount = 0
        authState = .signedOut
    }

    private func handleSignedIn(userId: UUID) async {
        authState = .signedIn
        await loadProfile(userId: userId)
        await loadFeed()
        await loadMySessions(userId: userId)
        await loadGear(userId: userId)
    }

    // MARK: - Reads

    func loadProfile(userId: UUID) async {
        do {
            let profile: Profile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            currentProfile = profile

            followerCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("following_id", value: userId.uuidString)
                .execute()
                .count ?? 0
            followingCount = try await supabase
                .from("follows")
                .select("*", head: true, count: .exact)
                .eq("follower_id", value: userId.uuidString)
                .execute()
                .count ?? 0
        } catch {
            errorMessage = friendly(error)
        }
    }

    func loadFeed() async {
        do {
            feed = try await supabase
                .from("sessions")
                .select(selectWithCounts)
                .eq("posted", value: true)
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

    func refresh() async {
        guard let uid = currentProfile?.id else { return }
        await loadFeed()
        await loadMySessions(userId: uid)
        await loadGear(userId: uid)
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

    func updateProfile(displayName: String, homeCourt: String, rating: Double?, paddle: String, preferredSide: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let update = ProfileUpdate(
                displayName: displayName,
                homeCourt: homeCourt.isEmpty ? nil : homeCourt,
                rating: rating,
                paddle: paddle.isEmpty ? nil : paddle,
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

    private func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    private func friendly(_ error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        return error.localizedDescription
    }
}
