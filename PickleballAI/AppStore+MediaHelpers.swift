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
    ///
    /// Anything we can't map to copy of our own gets the generic message plus a
    /// reference code — see `internalFailure(_:)`.
    private func friendly(_ error: Error) -> String {
        if let expected = Self.expectedMessage(for: error) {
            Self.errorLogger.error("\(String(describing: error), privacy: .public)")
            return expected
        }
        return internalFailure(error)
    }

    /// Copy we've written ourselves for failures the user can actually act on.
    /// Returns nil for everything else, which is the signal that the error is
    /// ours to diagnose rather than theirs to fix.
    private static func expectedMessage(for error: Error) -> String? {
        if let functionsError = error as? FunctionsError {
            guard case .httpError(_, let data) = functionsError else { return nil }
            guard
                let payload = try? JSONDecoder().decode(EdgeFunctionErrorPayload.self, from: data),
                !payload.error.isEmpty
            else { return nil }
            return payload.error
        }

        // Auth errors are matched on `errorCode`, never on `message`. GoTrue
        // mixes copy written for end users ("Invalid login credentials") with
        // provider text written for us — an SMS failure arrives as the raw
        // Twilio complaint, vendor name and support URL included, and App
        // Review once read one of those off our own sign-in screen.
        if let authError = error as? AuthError {
            switch authError.errorCode {
            case .invalidCredentials, .otpExpired:
                return "That code is expired or incorrect. Request a new one."
            case .overSMSSendRateLimit, .overRequestRateLimit:
                return "Too many attempts. Try again in a few minutes."
            case .validationFailed:
                return "Check the number and try again."
            case .phoneExists:
                return "That number is already signed up. Request a code to sign in."
            default:
                return nil
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "That took too long. Try again."
            default:
                return nil
            }
        }

        return nil
    }

    /// The generic message, tagged with a short reference code.
    ///
    /// The code is the whole point: it's on screen, in the log line, and on the
    /// `error_shown` analytics event, so a user reporting "it said something
    /// went wrong, ref A1B2C3D4" is enough to find the actual failure in
    /// PostHog — including Supabase's `sb-request-id`, which their auth and API
    /// logs are keyed by. The user gets a code that means nothing on its own;
    /// we get everything.
    private func internalFailure(_ error: Error) -> String {
        let reference = String(UUID().uuidString.prefix(8))
        let requestID = Self.requestID(from: error)
        let diagnostics = Self.diagnostics(for: error)
        let detail = String(describing: error)

        Self.errorLogger.error("""
            ref \(reference, privacy: .public) \
            [\(diagnostics.domain, privacy: .public)/\(diagnostics.code ?? "-", privacy: .public)] \
            request \(requestID ?? "-", privacy: .public): \(detail, privacy: .public)
            """)

        Analytics.captureError(
            reference: reference,
            domain: diagnostics.domain,
            code: diagnostics.code,
            detail: detail,
            requestID: requestID
        )

        return "\(Self.genericFailureMessage) (ref \(reference))"
    }

    /// Supabase stamps `sb-request-id` on every response and logs the same value
    /// server-side, so carrying it into telemetry turns a user-reported failure
    /// into a single log lookup. Only auth errors expose the response object;
    /// everything else reports nil rather than guessing.
    private static func requestID(from error: Error) -> String? {
        guard case .api(_, _, _, let response)? = error as? AuthError else { return nil }
        return response.value(forHTTPHeaderField: "sb-request-id")
    }

    private static func diagnostics(for error: Error) -> (domain: String, code: String?) {
        if let authError = error as? AuthError {
            return ("auth", authError.errorCode.rawValue)
        }
        if let functionsError = error as? FunctionsError {
            guard case .httpError(let code, _) = functionsError else { return ("functions", "relay") }
            return ("functions", String(code))
        }
        if let urlError = error as? URLError {
            return ("network", String(urlError.code.rawValue))
        }
        return (String(describing: type(of: error)), nil)
    }

    static let genericFailureMessage = "Something went wrong. Please try again."
}

private struct EdgeFunctionErrorPayload: Decodable {
    let error: String
}
