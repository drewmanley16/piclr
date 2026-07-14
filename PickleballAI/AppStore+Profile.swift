import Foundation
import Supabase
import UIKit

extension AppStore {
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

    func updateProfile(displayName: String, homeCourt: String, rating: Double?, preferredSide: String, birthday: String?) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let update = ProfileUpdate(
                displayName: displayName,
                homeCourt: homeCourt.isEmpty ? nil : homeCourt,
                rating: rating,
                preferredSide: preferredSide.isEmpty ? nil : preferredSide,
                birthday: birthday
            )
            try await supabase.from("profiles").update(update).eq("id", value: uid.uuidString).execute()
            // Apply locally instead of re-fetching — saves a round trip and
            // avoids clobbering a concurrent avatar update to the same row.
            currentProfile?.displayName = displayName
            currentProfile?.homeCourt = homeCourt.isEmpty ? nil : homeCourt
            currentProfile?.rating = rating
            currentProfile?.preferredSide = preferredSide.isEmpty ? nil : preferredSide
            return true
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
        guard let uid = currentProfile?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        // Decode + downscale + encode off the main thread so the UI never hangs
        // on a large camera photo. Avatars render in ≤96pt circles, so ~320px
        // (3× retina) is plenty and keeps files tiny (~20–40 KB).
        let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let image = UIImage(data: data) else { return nil }
            return Self.downscaledJPEG(from: image, maxDimension: 320)
        }.value
        guard let jpeg else { return false }
        do {
            // Storage RLS checks the folder equals auth.uid()::text, which
            // Postgres renders lowercase — Swift's uuidString is uppercase, so
            // it must be lowercased or the insert fails the policy.
            let path = "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
            try await supabase.storage.from("avatars").upload(
                path,
                data: jpeg,
                // Unique immutable filename → safe to cache for a year.
                options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg")
            )
            let publicURL = try supabase.storage.from("avatars").getPublicURL(path: path)
            try await supabase.from("profiles")
                .update(["avatar_url": publicURL.absoluteString])
                .eq("id", value: uid.uuidString)
                .execute()
            // Apply locally instead of a full re-fetch — saves a round trip.
            currentProfile?.avatarURL = publicURL.absoluteString
            // My own posts in the feed / on my profile still embed the old
            // avatar URL. Refresh that cached data so the new photo shows up
            // everywhere for me. Fire-and-forget so Save stays snappy; other
            // users' cached views update on their next natural reload.
            Task { [weak self] in
                guard let self else { return }
                await self.loadFeed()
                await self.loadMySessions(userId: uid)
            }
            return true
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
                options: FileOptions(cacheControl: "86400", contentType: "image/jpeg")
            )
            return try supabase.storage.from("post-photos").getPublicURL(path: path).absoluteString
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }
}
