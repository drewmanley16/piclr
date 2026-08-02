import Foundation
import Supabase

// MARK: - Weight log

/// The weight log is **private data**: `weight_entries` and `weight_settings`
/// are owner-only under RLS, nothing here is embedded in a feed/profile select,
/// and no other user's weight is ever fetched.
extension AppStore {
    /// Ceiling on how many weigh-ins are held in memory. A daily logger fills
    /// two years inside this, and the chart's longest range is 1Y.
    var weightLogLimit: Int { 800 }

    func loadWeightLog(userId: UUID) async {
        defer {
            if currentProfile?.id == userId { isInitialWeightLoading = false }
        }
        do {
            // Independent tables, so both round trips overlap.
            async let entryRows: [WeightEntry] = supabase
                .from("weight_entries")
                .select("id, recorded_on, weight_pounds")
                .eq("user_id", value: userId.uuidString)
                .order("recorded_on", ascending: false)
                .limit(weightLogLimit)
                .execute()
                .value
            async let settingRows: [WeightSettingsRow] = supabase
                .from("weight_settings")
                .select("unit, goal_pounds")
                .eq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value

            let (entries, settings) = try await (entryRows, settingRows)
            guard currentProfile?.id == userId, !Task.isCancelled else { return }
            weightEntries = entries
            // Absent row = untouched defaults; don't clobber a unit the user
            // just picked while this load was in flight.
            if let row = settings.first {
                weightUnit = row.unit
                weightGoalPounds = row.goalPounds
            }
        } catch {
            reportError(error)
        }
    }

    /// Records or corrects a weigh-in. One entry per calendar day: logging the
    /// same day twice updates that day through the `(user_id, recorded_on)`
    /// unique index rather than stacking two points on the chart.
    @discardableResult
    func logWeight(pounds: Double, on day: Date) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        guard pounds > 0, pounds <= 1500, pounds.isFinite else {
            errorMessage = "That doesn't look like a valid weight."
            return false
        }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let entry = WeightEntryUpsert(
                userId: uid,
                recordedOn: WeightEntry.string(from: day),
                // Stored at the precision the UI shows, so a round trip never
                // turns 168.4 into 168.39999999999998.
                weightPounds: (pounds * 10).rounded() / 10
            )
            try await supabase
                .from("weight_entries")
                .upsert(entry, onConflict: "user_id,recorded_on")
                .execute()
            Analytics.capture(.weightLogged)
            await loadWeightLog(userId: uid)
            return errorMessage == nil
        } catch {
            reportError(error)
            return false
        }
    }

    func deleteWeightEntry(_ entry: WeightEntry) async {
        guard let uid = currentProfile?.id else { return }
        // Drop it locally first — the row is already gone from the user's point
        // of view, and the reload below is authoritative either way.
        weightEntries.removeAll { $0.id == entry.id }
        do {
            try await supabase
                .from("weight_entries")
                .delete()
                .eq("id", value: entry.id.uuidString)
                .execute()
            await loadWeightLog(userId: uid)
        } catch {
            reportError(error)
            await loadWeightLog(userId: uid)
        }
    }

    /// Unit is a display preference; applied immediately so the toggle feels
    /// instant, then persisted so it follows the user to a new device.
    func setWeightUnit(_ unit: WeightUnit) async {
        guard weightUnit != unit else { return }
        weightUnit = unit
        await saveWeightSettings()
    }

    /// `nil` clears the goal (and with it the chart's target line).
    func setWeightGoal(pounds: Double?) async {
        weightGoalPounds = pounds
        await saveWeightSettings()
    }

    private func saveWeightSettings() async {
        guard let uid = currentProfile?.id else { return }
        do {
            let settings = WeightSettingsUpsert(
                userId: uid,
                unit: weightUnit.rawValue,
                goalPounds: weightGoalPounds.map { ($0 * 10).rounded() / 10 }
            )
            try await supabase
                .from("weight_settings")
                .upsert(settings, onConflict: "user_id")
                .execute()
        } catch {
            reportError(error)
        }
    }
}
