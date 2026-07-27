import Foundation
import Supabase

// MARK: - Squads

extension AppStore {
    /// Loads every squad the signed-in user belongs to, for the "My Squads" list.
    func loadMySquads() async {
        guard let uid = currentProfile?.id else { return }
        isMySquadsLoading = true
        defer {
            if currentProfile?.id == uid {
                isMySquadsLoading = false
            }
        }
        do {
            let rows: [SquadMemberRow] = try await supabase
                .from("squad_members")
                .select("id, squad_id, user_id, role")
                .eq("user_id", value: uid.uuidString)
                .execute()
                .value
            guard !rows.isEmpty else {
                if currentProfile?.id == uid { mySquads = [] }
                return
            }
            let squadIds = Array(Set(rows.map(\.squadId))).map(\.uuidString)
            let squads: [Squad] = try await supabase
                .from("squads")
                .select()
                .in("id", values: squadIds)
                .execute()
                .value
            guard currentProfile?.id == uid, !Task.isCancelled else { return }
            mySquads = squads.sorted { $0.createdAt > $1.createdAt }
        } catch {
            reportError(error)
        }
    }

    /// Creates a squad and seats the caller as owner atomically (server-side).
    @discardableResult
    func createSquad(name: String) async -> Squad? {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            // create_squad returns a single public.squads row (not setof), so
            // PostgREST already responds with one JSON object, not an array.
            let squad: Squad = try await supabase
                .rpc("create_squad", params: ["p_name": name])
                .execute()
                .value
            Analytics.capture(.squadCreated)
            mySquads.insert(squad, at: 0)
            return squad
        } catch {
            reportError(error)
            return nil
        }
    }

    /// Hydrates the roster and leaderboard for one squad (used by `SquadDetailView`).
    func loadSquadDetail(_ squadId: UUID, period: LeaderboardPeriod = .all) async {
        async let rosterTask: Void = loadSquadRoster(squadId)
        async let leaderboardTask: Void = loadSquadLeaderboard(squadId: squadId, period: period)
        _ = await (rosterTask, leaderboardTask)
    }

    func loadSquadRoster(_ squadId: UUID) async {
        do {
            let rows: [SquadMemberRow] = try await supabase
                .from("squad_members")
                .select("id, squad_id, user_id, role")
                .eq("squad_id", value: squadId.uuidString)
                .execute()
                .value
            let byId = try await profilesByID(for: rows.map(\.userId))
            guard activeSquad?.id == squadId, !Task.isCancelled else { return }
            squadRoster = rows
                .map { SquadMember(userId: $0.userId, role: $0.role, profile: byId[$0.userId]) }
                .sorted { $0.isOwner && !$1.isOwner }
        } catch {
            reportError(error)
        }
    }

    func loadSquadLeaderboard(squadId: UUID, period: LeaderboardPeriod) async {
        do {
            let rows: [SquadLeaderboardEntry] = try await supabase
                .rpc("squad_leaderboard", params: ["p_squad_id": squadId.uuidString, "p_period": period.rawValue])
                .execute()
                .value
            guard activeSquad?.id == squadId, !Task.isCancelled else { return }
            squadLeaderboard = rows.sorted {
                if $0.wins != $1.wins { return $0.wins > $1.wins }
                if $0.winRate != $1.winRate { return $0.winRate > $1.winRate }
                return $0.matches > $1.matches
            }
        } catch {
            reportError(error)
        }
    }

    /// Redeems a join code to self-join a squad. Returns nil (with
    /// `errorMessage` set to a friendly string) on an invalid code.
    @discardableResult
    func redeemSquadCode(_ code: String) async -> Squad? {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let squad: Squad = try await supabase
                .rpc("redeem_squad_code", params: ["p_code": code])
                .execute()
                .value
            Analytics.capture(.squadJoinedByCode)
            if !mySquads.contains(where: { $0.id == squad.id }) {
                mySquads.insert(squad, at: 0)
            }
            return squad
        } catch {
            if "\(error)".contains("invalid_code") {
                errorMessage = "That code doesn't match any squad."
            } else {
                reportError(error)
            }
            return nil
        }
    }

    /// Owner-only: invites an existing follower directly into the squad.
    func inviteFollowerToSquad(squadId: UUID, userId: UUID) async {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase
                .rpc("invite_to_squad", params: ["p_squad_id": squadId.uuidString, "p_user_id": userId.uuidString])
                .execute()
            Analytics.capture(.squadInviteSent)
            await loadSquadRoster(squadId)
        } catch {
            reportError(error)
        }
    }

    /// Leaves a squad (deletes the caller's own membership row).
    func leaveSquad(_ squadId: UUID) async {
        guard let uid = currentProfile?.id else { return }
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            try await supabase
                .from("squad_members")
                .delete()
                .eq("squad_id", value: squadId.uuidString)
                .eq("user_id", value: uid.uuidString)
                .execute()
            Analytics.capture(.squadLeft)
            mySquads.removeAll { $0.id == squadId }
            if activeSquad?.id == squadId {
                activeSquad = nil
                squadRoster = []
                squadLeaderboard = []
            }
        } catch {
            reportError(error)
        }
    }

    /// Owner-only: removes another member from the squad.
    func removeSquadMember(squadId: UUID, userId: UUID) async {
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            try await supabase
                .from("squad_members")
                .delete()
                .eq("squad_id", value: squadId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
            await loadSquadRoster(squadId)
        } catch {
            reportError(error)
        }
    }

    /// Owner-only: renames the squad.
    func renameSquad(_ squadId: UUID, name: String) async {
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            try await supabase
                .from("squads")
                .update(["name": name])
                .eq("id", value: squadId.uuidString)
                .execute()
            if let index = mySquads.firstIndex(where: { $0.id == squadId }) {
                mySquads[index] = Squad(
                    id: mySquads[index].id,
                    name: name,
                    ownerId: mySquads[index].ownerId,
                    joinCode: mySquads[index].joinCode,
                    createdAt: mySquads[index].createdAt
                )
            }
            if activeSquad?.id == squadId {
                activeSquad = mySquads.first { $0.id == squadId }
            }
        } catch {
            reportError(error)
        }
    }

    /// Owner-only: deletes the squad entirely (cascades to membership rows).
    func deleteSquad(_ squadId: UUID) async {
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            try await supabase
                .from("squads")
                .delete()
                .eq("id", value: squadId.uuidString)
                .execute()
            Analytics.capture(.squadDeleted)
            mySquads.removeAll { $0.id == squadId }
            if activeSquad?.id == squadId {
                activeSquad = nil
                squadRoster = []
                squadLeaderboard = []
            }
        } catch {
            reportError(error)
        }
    }
}
