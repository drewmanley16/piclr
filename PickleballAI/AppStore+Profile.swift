import Foundation
import Supabase
import UIKit

// MARK: - Profile

extension AppStore {
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
            currentProfile = await media.hydrateProfile(profile)
            return .loaded
        } catch {
            reportError(error)
            return .failed
        }
    }

    func updateProfile(firstName: String, lastName: String, homeCourt: String, rating: Double?, preferredSide: String, birthday: String?) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        let cleanFirstName = ProfileIdentityValidator.normalizedName(firstName)
        let cleanLastName = ProfileIdentityValidator.normalizedName(lastName)
        let validations = [
            ProfileIdentityValidator.firstName(cleanFirstName),
            ProfileIdentityValidator.lastName(cleanLastName),
            ProfileIdentityValidator.combinedName(firstName: cleanFirstName, lastName: cleanLastName),
        ]
        if let message = validations.compactMap(\.errorMessage).first {
            errorMessage = message
            return false
        }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let displayName = [cleanFirstName, cleanLastName].joined(separator: " ")
            let update = ProfileUpdate(
                firstName: cleanFirstName,
                lastName: cleanLastName,
                displayName: displayName,
                homeCourt: homeCourt.isEmpty ? nil : homeCourt,
                rating: rating,
                preferredSide: preferredSide.isEmpty ? nil : preferredSide,
                birthday: birthday
            )
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            // Apply locally instead of re-fetching — saves a round trip and
            // avoids clobbering a concurrent avatar update to the same row.
            currentProfile?.firstName = cleanFirstName
            currentProfile?.lastName = cleanLastName
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

    /// Syncs the Goals card's weekly target + streak-save reminder toggle so
    /// `notify_streak_reminders()` can actually honor it server-side (was
    /// local-only `@AppStorage` before). Fire-and-forget from the UI's
    /// perspective — see `GoalsSheet`.
    func updateGoalPrefs(weeklyGoal: Int, streakRemindersEnabled: Bool) async {
        guard let uid = currentProfile?.id else { return }
        do {
            let update = GoalPrefsUpdate(weeklyGoal: weeklyGoal, streakRemindersEnabled: streakRemindersEnabled)
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            currentProfile?.weeklyGoal = weeklyGoal
            currentProfile?.streakRemindersEnabled = streakRemindersEnabled
        } catch {
            reportError(error)
        }
    }

    /// Toggles the private-account setting. Private accounts require an
    /// accepted follow to view sessions/comments/likes (`can_view_session`
    /// RLS); profile header, follower/following counts stay public either way.
    @discardableResult
    func updatePrivacy(isPrivate: Bool) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        do {
            let update = PrivacyUpdate(isPrivate: isPrivate)
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            currentProfile?.isPrivate = isPrivate
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

    func uploadProfilePhoto(_ image: UIImage) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        // Downscale + encode off the main thread so the UI never hangs on a
        // large photo. Avatars render in ≤96pt circles, so ~320px (3× retina)
        // is plenty and keeps files tiny (~20–40 KB). This is the ONE encode
        // in the avatar pipeline — callers (crop editor) hand over UIImages.
        let jpeg = await Task.detached(priority: .userInitiated) {
            Self.downscaledJPEG(from: image, maxDimension: 320)
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
            // `avatar_path` is the source of truth; the app derives avatar URLs
            // from it. Keep the stored `avatar_url` column truthful too so older
            // installed builds (which read the column directly) don't 404 on the
            // just-deleted old object.
            let publicURL = MediaHydrator.publicAvatarURL(for: path)
            var update = ["avatar_path": path]
            if let publicURL {
                update["avatar_url"] = publicURL
            }
            try await supabase.from("profiles")
                .update(update)
                .eq("id", value: uid.uuidString)
                .execute()
            if let oldPath, oldPath != path {
                try? await supabase.storage.from("avatars").remove(paths: [oldPath])
            }
            // Apply locally instead of re-fetching — a re-fetch could race the
            // concurrent profile-text save in `saveProfile` and clobber its
            // locally-applied fields with the pre-update row.
            currentProfile?.avatarPath = path
            currentProfile?.avatarURL = publicURL
            refreshAvatarSurfaces(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    /// Clears the profile photo: nulls both avatar columns (the avatar falls
    /// back to initials everywhere), then deletes the storage object.
    func removeProfilePhoto() async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let oldPath = currentProfile?.avatarPath
            // Explicit AnyJSON.null — a plain [String: String?] would drop the
            // keys instead of writing NULL.
            try await supabase.from("profiles")
                .update(["avatar_path": AnyJSON.null, "avatar_url": AnyJSON.null])
                .eq("id", value: uid.uuidString)
                .execute()
            // Delete the object only after the row no longer references it, so
            // a failure between the two steps never leaves a dangling URL.
            if let oldPath {
                try? await supabase.storage.from("avatars").remove(paths: [oldPath])
            }
            // Apply locally instead of re-fetching — a re-fetch could race the
            // concurrent profile-text save in `saveProfile` and clobber its
            // locally-applied fields with the pre-update row.
            currentProfile?.avatarPath = nil
            currentProfile?.avatarURL = nil
            refreshAvatarSurfaces(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    /// Refreshes every surface that embeds author avatars after the profile
    /// photo changes (upload or removal), without making the caller wait. The
    /// loads hit independent endpoints, so they run concurrently.
    private func refreshAvatarSurfaces(userId: UUID) {
        Task { [weak self] in
            guard let self else { return }
            async let feed: Void = self.loadFeed()
            async let sessions: Void = self.loadMySessions(userId: userId)
            if !self.discoverFeed.isEmpty {
                async let discover: Void = self.loadDiscover()
                _ = await (feed, sessions, discover)
            } else {
                _ = await (feed, sessions)
            }
        }
    }

    /// Loads another user's public profile. Basic fields, follower/following
    /// counts, and posted sessions are visible to anyone — following only
    /// affects the following feed, not profile visibility. The `sessions`
    /// query is additionally RLS-gated to `posted = true` rows.
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
            let profile = await media.hydrateProfile(rawProfile)

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

            // Via RPC (not a direct `follows` select) so a private target's
            // tightened follows_read policy doesn't zero these out — counts
            // stay visible even when the follower/following list is hidden.
            let counts: [FollowCounts] = try await supabase
                .rpc("follow_counts", params: ["target_id": userId.uuidString])
                .execute()
                .value
            let followerCount = counts.first?.followerCount ?? 0
            let followingCount = counts.first?.followingCount ?? 0

            let sessionLimit = 50
            var sessionOffset = 0
            var rawPageCount = 0
            var sessionRows: [FeedSession] = []
            repeat {
                let rawPage: [FeedSession] = try await supabase
                    .from("sessions")
                    .select(selectWithCounts)
                    .is("comments.deleted_at", value: nil)
                    .eq("user_id", value: userId.uuidString)
                    .eq("posted", value: true)
                    .order("created_at", ascending: false)
                    .range(from: sessionOffset, to: sessionOffset + sessionLimit - 1)
                    .execute()
                    .value
                rawPageCount = rawPage.count
                sessionOffset += rawPageCount
                sessionRows.append(contentsOf: rawPage.filter(\.hasMatchContent))
                // The profile promises up to 50 visible sessions, not 50 raw
                // rows that may include practice-only shells.
            } while sessionRows.count < sessionLimit
                && rawPageCount == sessionLimit
                && !Task.isCancelled
            let sessions = await media.hydrateSessions(Array(sessionRows.prefix(sessionLimit)))

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
                hydrated.append(ContactMatch(phone: match.phone, profile: await media.hydrateProfile(match.profile)))
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
                hydrated.append(await media.hydrateProfile(profile))
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
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
