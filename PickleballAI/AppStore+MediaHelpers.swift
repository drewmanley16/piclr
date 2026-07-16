import Foundation
import os
import Supabase
import UIKit

// MARK: - Media hydration + shared helpers

extension AppStore {
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

    static func inFilter(for ids: [UUID]) -> String {
        let values = ids.map { #""\#($0.uuidString)""# }.joined(separator: ",")
        return "(\(values))"
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
            Self.feedLogger.error("\(bucket, privacy: .public) batch signing failed: \(error.localizedDescription, privacy: .public)")
        }
        return resolved
    }

    func debugFeedMetric(_ label: String, since start: Date) {
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

    /// Surface an error to the user — unless it's a cancellation. A cancelled
    /// request (a superseded feed refresh, a task torn down on dismiss) is not a
    /// failure and must never pop an alert. Because `errorMessage` is shared
    /// app-wide, a cancelled background reload used to hijack whatever modal was
    /// on screen (e.g. "Couldn't post session" after a post that actually saved).
    func reportError(_ error: Error) {
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
