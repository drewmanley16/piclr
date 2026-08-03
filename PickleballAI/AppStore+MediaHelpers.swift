import Foundation
import os
import Supabase
import UIKit

// MARK: - Media upload + shared helpers
// Hydration + the signed-URL cache live in MediaHydrator.swift (`store.media`).

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
        // Not an `Error`, so there's nothing for `reportError` to translate —
        // but returning nil silently would abort the post with no explanation.
        guard let jpeg else {
            errorMessage = "Couldn't prepare that photo. Try a different one."
            return nil
        }
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

    /// Uploads a gear photo to the gear-photos bucket at `<uid>/<gear-id>.jpg`
    /// — the `owner/target.jpg` shape `private.can_read_media` parses to decide
    /// who may read it. Returns the private object path.
    func uploadGearPhoto(_ data: Data, gearId: UUID, uid: UUID) async -> String? {
        let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let image = UIImage(data: data) else { return nil }
            // Renders in a 44pt circle and a modest edit-sheet preview, so this
            // is plenty and keeps lockers cheap to load.
            return Self.downscaledJPEG(from: image, maxDimension: 640)
        }.value
        guard let jpeg else { return nil }
        do {
            let path = "\(uid.uuidString.lowercased())/\(gearId.uuidString.lowercased()).jpg"
            try await supabase.storage.from("gear-photos").upload(
                path,
                data: jpeg,
                // Path is per-item and stable across edits, so a replaced photo
                // reuses it — cache for a day, not a year.
                options: FileOptions(cacheControl: "86400", contentType: "image/jpeg", upsert: true)
            )
            return path
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Best-effort removal of a gear photo object. A failure here leaves an
    /// orphaned file, which is untidy but never blocks the user's edit/delete.
    func removeGearPhoto(path: String) async {
        _ = try? await supabase.storage.from("gear-photos").remove(paths: [path])
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

    /// Translate an error into something safe to put in front of a user.
    ///
    /// Backend errors must never be surfaced verbatim. A PostgREST or Storage
    /// failure carries schema and policy details ("new row violates row-level
    /// security policy", "column sessions_1.focus does not exist") that mean
    /// nothing to a user, look alarming, and describe our internals to anyone
    /// who screenshots them. The technical text goes to the log instead, where
    /// it's still there for debugging.
    ///
    /// The one backend string we do pass through is an edge function's `error`
    /// field: those are written by us, for this purpose.
    private func friendly(_ error: Error) -> String {
        Self.errorLogger.error("\(String(describing: error), privacy: .public)")

        if let functionsError = error as? FunctionsError {
            switch functionsError {
            case .httpError(_, let data):
                if
                    let payload = try? JSONDecoder().decode(EdgeFunctionErrorPayload.self, from: data),
                    !payload.error.isEmpty
                {
                    return payload.error
                }
                return Self.genericFailureMessage
            case .relayError:
                return Self.genericFailureMessage
            }
        }
        // Auth messages ("Invalid login credentials", "Token has expired") are
        // written for end users and are the whole point of the sign-in screen.
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "That took too long. Try again."
            default:
                return Self.genericFailureMessage
            }
        }
        return Self.genericFailureMessage
    }

    static let genericFailureMessage = "Something went wrong. Please try again."
}

private struct EdgeFunctionErrorPayload: Decodable {
    let error: String
}
