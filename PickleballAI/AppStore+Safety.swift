import Foundation
import Supabase

// MARK: - User safety

extension AppStore {
    func loadBlockedAccounts() async {
        guard let uid = currentProfile?.id else {
            blockedAccounts = []
            return
        }
        do {
            let blocks: [BlockedAccount] = try await supabase
                .from("blocks")
                .select("blocked_id,blocked_username,blocked_display_name,blocked_avatar_path,created_at")
                .eq("blocker_id", value: uid.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            // Sign the private avatar paths so blocked rows show real faces.
            let paths = Set(blocks.compactMap(\.blockedAvatarPath))
            let urls = await media.signedAvatarURLs(forPaths: paths)
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            blockedAccounts = blocks.map { block in
                var hydrated = block
                if let path = block.blockedAvatarPath { hydrated.avatarURL = urls[path] }
                return hydrated
            }
        } catch {
            reportError(error)
        }
    }

    @discardableResult
    func blockUser(userId: UUID) async -> Bool {
        guard let uid = currentProfile?.id, uid != userId else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.from("blocks")
                .insert(NewBlock(blockerId: uid, blockedId: userId))
                .execute()

            feed.removeAll { $0.userId == userId }
            discoverFeed.removeAll { $0.userId == userId }
            followers.removeAll { $0.userId == userId }
            following.removeAll { $0.userId == userId }
            incomingFollowRequests.removeAll { $0.followerId == userId }
            contactMatches.removeAll { $0.profile.id == userId }
            searchResults.removeAll { $0.id == userId }
            requestedFollowIds.remove(userId)
            notifications.removeAll { $0.actor?.id == userId }

            await loadBlockedAccounts()
            await loadFollowState(userId: uid)
            await loadFollowLists(userId: uid)
            await loadFeed()
            await loadDiscover()
            await loadMySessions(userId: uid)
            await loadRepostRequests(userId: uid)
            await loadNotifications(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func unblockUser(userId: UUID) async {
        guard let uid = currentProfile?.id else { return }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.from("blocks")
                .delete()
                .eq("blocker_id", value: uid.uuidString)
                .eq("blocked_id", value: userId.uuidString)
                .execute()
            await loadBlockedAccounts()
        } catch {
            reportError(error)
        }
    }

    func submitReport(target: ReportTarget, reason: ReportReason, details: String) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            try await supabase.from("reports")
                .insert(NewReport(
                    reporterId: uid,
                    targetType: target.type,
                    targetId: target.targetId,
                    reason: reason.rawValue,
                    details: trimmed.isEmpty ? nil : trimmed
                ))
                .execute()
            return true
        } catch {
            reportError(error)
            return false
        }
    }
}
