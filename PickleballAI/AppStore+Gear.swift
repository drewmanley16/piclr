import Foundation
import Supabase

// MARK: - Gear

extension AppStore {
    func loadGear(userId: UUID) async {
        do {
            let items: [GearItem] = try await supabase
                .from("gear")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
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
            await loadGear(userId: uid)
            return errorMessage == nil
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
