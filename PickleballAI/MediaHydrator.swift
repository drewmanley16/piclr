import Foundation
import os
import Supabase

// MARK: - Media hydration

/// Owns the signed-URL cache and the `hydrate*` helpers that turn Storage object
/// paths into renderable URLs on read models. Extracted from `AppStore` so
/// hydration is one shared dependency (`store.media.hydrateSessions(...)`) rather
/// than call-after-every-fetch discipline scattered across the store's extensions.
///
/// Two buckets, two strategies:
/// - **avatars** is PUBLIC. Its URLs are *derived* synchronously from the object
///   path (`getPublicURL`) — no network round-trip, no signing, no cache needed.
///   `avatar_path` is the single source of truth; the stored `avatar_url` column
///   is kept truthful for older builds but the app never depends on it.
/// - **post-photos** is PRIVATE. Its URLs are short-lived signed URLs from a
///   batch signing request, memoized in `mediaURLCache`.
///
/// Deliberately holds no reference back to `AppStore`: signing failures are
/// best-effort (logged, then the path resolves to `nil`), never surfaced as a
/// user-facing error — matching the pre-extraction behavior.
@MainActor
final class MediaHydrator {
    private struct CachedMediaURL {
        let value: String
        let validUntil: Date
    }

    private var mediaURLCache: [String: CachedMediaURL] = [:]
    private let signedURLLifetime = 900
    private let signedURLRefreshLeeway: TimeInterval = 60

    /// Drop every cached signed URL. Called on sign-out so a subsequent account's
    /// reads never resolve against the previous user's cache.
    func clearCache() {
        mediaURLCache.removeAll()
    }

    func hydrateProfile(_ profile: Profile) async -> Profile {
        await hydrateProfiles([profile]).first ?? profile
    }

    func hydrateProfiles(_ profiles: [Profile]) async -> [Profile] {
        return profiles.map { profile in
            guard let path = profile.avatarPath else { return profile }
            var hydrated = profile
            hydrated.avatarURL = Self.publicAvatarURL(for: path)
            return hydrated
        }
    }

    func hydrateParticipantProfile(_ profile: ParticipantProfile) async -> ParticipantProfile {
        guard let path = profile.avatarPath else { return profile }
        var hydrated = profile
        hydrated.avatarURL = Self.publicAvatarURL(for: path)
        return hydrated
    }

    /// Map a batch of bare avatar Storage paths to their derived public URLs
    /// (path → URL). Used by models that carry only a path (e.g. blocked
    /// accounts). No network — the avatars bucket is public.
    func signedAvatarURLs(forPaths paths: Set<String>) async -> [String: String] {
        Self.publicAvatarURLs(for: paths)
    }

    func hydrateComment(_ comment: Comment) async -> Comment {
        var hydrated = comment
        if let author = comment.author {
            hydrated.author = await hydrateParticipantProfile(author)
        }
        return hydrated
    }

    func hydrateSessions(_ sessions: [FeedSession]) async -> [FeedSession] {
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

        // Avatars are public → derived synchronously. Only post photos (private)
        // need the signing round-trip.
        let avatars = Self.publicAvatarURLs(for: avatarPaths)
        let photos = await signedMediaURLs(bucket: "post-photos", paths: photoPaths)

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

    /// Derive the public URL for an avatar Storage path. The avatars bucket is
    /// public, so this is a synchronous string build (no signing, no network).
    /// Returns `nil` only if the SDK can't form a URL (malformed config), which
    /// matches the prior best-effort behavior of resolving to `nil`.
    static func publicAvatarURL(for path: String) -> String? {
        (try? supabase.storage.from("avatars").getPublicURL(path: path))?.absoluteString
    }

    /// Batch variant of `publicAvatarURL(for:)` (path → URL), skipping any path
    /// that fails to resolve.
    static func publicAvatarURLs(for paths: Set<String>) -> [String: String] {
        var resolved: [String: String] = [:]
        for path in paths {
            if let url = publicAvatarURL(for: path) { resolved[path] = url }
        }
        return resolved
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
            AppStore.feedLogger.error("\(bucket, privacy: .public) batch signing failed: \(error.localizedDescription, privacy: .public)")
        }
        return resolved
    }

    private func debugFeedMetric(_ label: String, since start: Date) {
        #if DEBUG
        let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
        AppStore.feedLogger.debug("\(label, privacy: .public): \(milliseconds) ms")
        #endif
    }
}
