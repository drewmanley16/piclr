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
        if let limit {
            return try await query.limit(limit).execute().value
        }
        return try await query.execute().value
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

    func addGear(category: String, name: String, brand: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let new = NewGear(
                userId: uid,
                category: category,
                name: name,
                brand: brand.isEmpty ? nil : brand
            )
            try await supabase.from("gear").insert(new).execute()
            Analytics.capture(.gearAdded)
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
            await loadGear(userId: uid)
        } catch {
            reportError(error)
        }
    }
}
