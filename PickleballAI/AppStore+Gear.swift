import Foundation
import Supabase

// MARK: - Gear

extension AppStore {
    /// How much of another player's locker a profile fetch pulls down — enough
    /// to fill the showcase row and the sheet behind it without paging.
    var gearShowcaseLimit: Int { 24 }

    /// One user's locker, newest first. `gear_read` RLS decides what comes
    /// back: your own rows always, someone else's only when they left their
    /// locker visible and you're allowed to see their profile content — so a
    /// hidden locker simply reads as empty.
    func fetchGear(userId: UUID, limit: Int? = nil) async throws -> [GearItem] {
        let query = supabase
            .from("gear")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
        let items: [GearItem] = if let limit {
            try await query.limit(limit).execute().value
        } else {
            try await query.execute().value
        }
        return await media.hydrateGear(items)
    }

    func loadGear(userId: UUID) async {
        do {
            let items = try await fetchGear(userId: userId)
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            gear = items
        } catch {
            reportError(error)
        }
    }

    func addGear(category: String, name: String, brand: String, photo: Data? = nil) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            // The id is ours up front so the photo has a path to land at, but
            // the row has to exist *before* the upload: Storage inserts with a
            // RETURNING clause, and Postgres applies SELECT policies to those,
            // so `gear_photos_read` would evaluate against a gear row that
            // isn't there yet and reject the object.
            let gearId = UUID()
            let new = NewGear(
                id: gearId,
                userId: uid,
                category: category,
                name: name,
                brand: brand.isEmpty ? nil : brand,
                photoPath: nil
            )
            try await supabase.from("gear").insert(new).execute()

            // A photo that fails to upload leaves the item saved without one,
            // which beats losing what they typed.
            var photoPath: String?
            if let photo {
                photoPath = await uploadGearPhoto(photo, gearId: gearId, uid: uid)
                if let photoPath {
                    try await supabase
                        .from("gear")
                        .update(GearPhotoPathUpdate(photoPath: photoPath))
                        .eq("id", value: gearId.uuidString)
                        .execute()
                }
            }
            Analytics.capture(.gearAdded, ["has_photo": photoPath != nil])
            await loadGear(userId: uid)
            return errorMessage == nil
        } catch {
            reportError(error)
            return false
        }
    }

    /// Save edits to an existing item. `photo` carries the intent: `.unchanged`
    /// keeps the stored path, `.replaced` re-uploads to the same path, and
    /// `.removed` nulls the column and cleans up the object.
    func updateGear(
        _ item: GearItem,
        category: String,
        name: String,
        brand: String,
        photo: GearPhotoEdit
    ) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            var photoPath = item.photoPath
            switch photo {
            case .unchanged:
                break
            case .replaced(let data):
                photoPath = await uploadGearPhoto(data, gearId: item.id, uid: uid)
            case .removed:
                photoPath = nil
            }
            let update = GearUpdate(
                category: category,
                name: name,
                brand: brand.isEmpty ? nil : brand,
                photoPath: photoPath
            )
            try await supabase
                .from("gear")
                .update(update)
                .eq("id", value: item.id.uuidString)
                .execute()
            // Only drop the object once the row no longer points at it.
            if case .removed = photo, let stale = item.photoPath {
                await removeGearPhoto(path: stale)
            }
            Analytics.capture(.gearEdited)
            await loadGear(userId: uid)
            return errorMessage == nil
        } catch {
            reportError(error)
            return false
        }
    }

    /// Flip whether the locker shows on your profile. Mirrors the write onto
    /// `currentProfile` so the toggle and the profile showcase update together;
    /// callers revert their own UI when this returns false.
    func setGearVisible(_ visible: Bool) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        do {
            try await supabase
                .from("profiles")
                .update(GearVisibilityUpdate(gearVisible: visible))
                .eq("id", value: uid.uuidString)
                .execute()
            currentProfile?.gearVisible = visible
            Analytics.capture(.gearVisibilityChanged, ["visible": visible])
            return true
        } catch {
            reportError(error)
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
            if let path = item.photoPath {
                await removeGearPhoto(path: path)
            }
            await loadGear(userId: uid)
        } catch {
            reportError(error)
        }
    }
}
