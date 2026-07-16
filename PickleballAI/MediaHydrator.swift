import Foundation
import os
import Supabase

// MARK: - Media hydration

/// Owns the signed-URL cache and the `hydrate*` helpers that turn private
/// Storage object paths (avatars, post photos) into short-lived signed URLs on
/// read models. Extracted from `AppStore` so hydration is one shared dependency
/// (`store.media.hydrateSessions(...)`) rather than call-after-every-fetch
/// discipline scattered across the store's extensions.
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
        let paths = Set(profiles.compactMap(\.avatarPath))
        let urls = await signedMediaURLs(bucket: "avatars", paths: paths)
        return profiles.map { profile in
            guard let path = profile.avatarPath else { return profile }
            var hydrated = profile
            hydrated.avatarURL = urls[path]
            return hydrated
        }
    }

    func hydrateParticipantProfile(_ profile: ParticipantProfile) async -> ParticipantProfile {
        guard let path = profile.avatarPath else { return profile }
        var hydrated = profile
        hydrated.avatarURL = await signedMediaURLs(bucket: "avatars", paths: [path])[path]
        return hydrated
    }

    /// Sign a batch of bare avatar Storage paths into short-lived URLs (path →
    /// URL), reusing the shared signed-URL cache and one signing request. Used by
    /// models that carry only a path (e.g. blocked accounts).
    func signedAvatarURLs(forPaths paths: Set<String>) async -> [String: String] {
        await signedMediaURLs(bucket: "avatars", paths: paths)
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
