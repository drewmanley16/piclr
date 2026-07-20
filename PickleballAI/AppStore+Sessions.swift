import Foundation
import Supabase

// MARK: - Sessions (live draft + writes)

extension AppStore {
    // MARK: - Live draft persistence
    // A live session already survives leaving the Workout tab in memory;
    // mirroring it to disk lets it also survive a force-quit / crash /
    // low-memory kill so logged activities aren't lost. All I/O is best-effort:
    // it must never throw or block the UI. The JSON (incl. base64 photoData)
    // is small enough to encode on the main actor.
    private static let draftMaxAge: TimeInterval = 60 * 60 * 24 // 24h

    private var draftFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("LiveSessionDraft.json")
    }

    /// Called from `activeDraft.didSet`: write the current draft, or delete the
    /// file when the session is posted/discarded (`activeDraft == nil`).
    func persistActiveDraft() {
        guard let url = draftFileURL else { return }
        guard let draft = activeDraft else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? JSONEncoder().encode(draft) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func deletePersistedDraft() {
        guard let url = draftFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Restore a live session persisted before a kill. Assigning normally lets
    /// `didSet` re-sync the Live Activity (which adopts any orphaned one). Drops
    /// drafts older than `draftMaxAge` — a days-old resurrected session is worse
    /// than a lost one. Only restores when nothing is already in progress.
    func restorePersistedDraft() {
        guard activeDraft == nil,
              let url = draftFileURL,
              let data = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(SessionDraft.self, from: data)
        else { return }
        guard Date().timeIntervalSince(draft.startedAt) < Self.draftMaxAge else {
            deletePersistedDraft()
            return
        }
        activeDraft = draft
    }

    func startLiveSession() {
        if activeDraft == nil { activeDraft = SessionDraft() }
    }

    func discardLiveSession() { activeDraft = nil }

    /// Posts the live session and clears it on success.
    func postLiveSession() async -> Bool {
        guard let draft = activeDraft else { return false }
        let ok = await postSession(draft)
        if ok { activeDraft = nil }
        return ok
    }

    /// One-tap log: wraps a single activity in a fresh session and posts it.
    func quickLog(_ activity: DraftActivity, postToFeed: Bool = true) async -> Bool {
        var draft = SessionDraft()
        draft.startedAt = Date()
        draft.activities = [activity]
        draft.postToFeed = postToFeed
        return await postSession(draft, isQuickLog: true)
    }

    // MARK: - Writes

    /// Write a full multi-activity session built on-device. Inserts the session
    /// unposted, writes activities + tagged participants, then flips `posted`
    /// last so realtime subscribers only see the completed post.
    func postSession(_ draft: SessionDraft, isQuickLog: Bool = false) async -> Bool {
        guard let uid = currentProfile?.id else { return false }
        // Derive "first-ever session" from state we already have: no network call
        // just for analytics. `mySessions` is empty before the user's first post.
        let isFirstSession = mySessions.isEmpty
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let now = Date()
            let duration = max(1, Int(now.timeIntervalSince(draft.startedAt) / 60))
            let firstFocus = draft.activities.first(where: { $0.kind == .practice && !$0.focus.isEmpty })?.focus

            let session = NewSession(
                userId: uid,
                title: draft.title.isEmpty ? Self.timeOfDayTitle(for: draft.startedAt) : draft.title,
                location: draft.location.isEmpty ? nil : draft.location,
                durationMinutes: duration,
                focus: firstFocus,
                takeaway: nil,
                posted: false,
                startedAt: DateFormatting.iso.string(from: draft.startedAt),
                endedAt: DateFormatting.iso.string(from: now)
            )
            try await supabase.from("sessions").insert(session).execute()

            for (index, activity) in draft.activities.enumerated() {
                let isMatch = activity.kind == .match
                let newActivity = NewSessionActivity(
                    sessionId: session.id,
                    kind: activity.kind.rawValue,
                    position: index,
                    focus: activity.focus.isEmpty ? nil : activity.focus,
                    reps: activity.reps.isEmpty ? nil : activity.reps,
                    notes: activity.notes.isEmpty ? nil : activity.notes,
                    teamScore: isMatch ? activity.teamScore : nil,
                    opponentScore: isMatch ? activity.opponentScore : nil,
                    won: activity.wonValue
                )
                try await supabase.from("session_activities").insert(newActivity).execute()

                let participants =
                    activity.partners.map { player in
                        NewActivityParticipant(activityId: newActivity.id, sessionId: session.id,
                                               profileId: player.profile?.id, guestName: player.profile == nil ? player.guestName : nil, role: "partner")
                    } +
                    activity.opponents.map { player in
                        NewActivityParticipant(activityId: newActivity.id, sessionId: session.id,
                                               profileId: player.profile?.id, guestName: player.profile == nil ? player.guestName : nil, role: "opponent")
                    }
                if !participants.isEmpty {
                    try await supabase.from("activity_participants").insert(participants).execute()
                }
            }

            if let photoData = draft.photoData,
               let photoPath = await uploadPostPhoto(photoData, sessionId: session.id, uid: uid) {
                try await supabase.from("sessions")
                    .update(["photo_path": photoPath])
                    .eq("id", value: session.id.uuidString)
                    .execute()
            }

            try await supabase.from("sessions")
                .update(["posted": draft.postToFeed])
                .eq("id", value: session.id.uuidString)
                .execute()

            await loadMySessions(userId: uid)
            await loadFeed()
            let properties: [String: Any] = [
                Analytics.Property.activityCount: draft.activities.count,
                Analytics.Property.quickLog: isQuickLog
            ]
            Analytics.capture(.sessionLogged, properties)
            if isFirstSession {
                Analytics.captureOnce(.firstSessionLogged, flag: .firstSessionLogged, properties)
            }
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func updateSession(_ session: FeedSession, draft: SessionDraft) async -> Bool {
        guard let uid = currentProfile?.id, session.userId == uid else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }

        do {
            var photoPath = draft.removePhoto ? nil : draft.existingPhotoPath
            if let photoData = draft.photoData {
                guard let uploaded = await uploadPostPhoto(photoData, sessionId: session.id, uid: uid) else {
                    return false
                }
                photoPath = uploaded
            }

            let endedAt = max(draft.endedAt ?? Date(), draft.startedAt.addingTimeInterval(60))
            let activities = draft.activities.enumerated().map { index, activity in
                let participants =
                    activity.partners.map {
                        SessionUpdateParticipant(
                            id: $0.id,
                            profileId: $0.profile?.id,
                            guestName: $0.profile == nil ? $0.guestName : nil,
                            role: "partner"
                        )
                    }
                    + activity.opponents.map {
                        SessionUpdateParticipant(
                            id: $0.id,
                            profileId: $0.profile?.id,
                            guestName: $0.profile == nil ? $0.guestName : nil,
                            role: "opponent"
                        )
                    }
                let isMatch = activity.kind == .match
                return SessionUpdateActivity(
                    id: activity.id,
                    kind: activity.kind.rawValue,
                    position: index,
                    focus: activity.focus.isEmpty ? nil : activity.focus,
                    reps: activity.reps.isEmpty ? nil : activity.reps,
                    notes: activity.notes.isEmpty ? nil : activity.notes,
                    teamScore: isMatch ? activity.teamScore : nil,
                    opponentScore: isMatch ? activity.opponentScore : nil,
                    won: activity.wonValue,
                    participants: participants
                )
            }
            let payload = SessionUpdatePayload(
                title: draft.title,
                location: draft.location,
                takeaway: draft.takeaway,
                durationMinutes: max(1, Int(endedAt.timeIntervalSince(draft.startedAt) / 60)),
                posted: draft.postToFeed,
                startedAt: DateFormatting.iso.string(from: draft.startedAt),
                endedAt: DateFormatting.iso.string(from: endedAt),
                photoPath: photoPath ?? "",
                activities: activities
            )
            try await supabase.rpc(
                "update_own_session",
                params: UpdateSessionRPCParams(targetSessionId: session.id, payload: payload)
            ).execute()

            if draft.removePhoto, let oldPath = session.photoPath {
                try? await supabase.storage.from("post-photos").remove(paths: [oldPath])
            }
            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func deleteSession(_ session: FeedSession) async -> Bool {
        guard let uid = currentProfile?.id, session.userId == uid else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.from("sessions")
                .delete()
                .eq("id", value: session.id.uuidString)
                .execute()
            if let path = session.photoPath {
                try? await supabase.storage.from("post-photos").remove(paths: [path])
            }
            await loadMySessions(userId: uid)
            await loadFeed()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func removeSelfFromSession(_ session: FeedSession) async -> Bool {
        guard let uid = currentProfile?.id, session.userId != uid else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.rpc(
                "remove_self_from_session",
                params: ["target_session_id": session.id.uuidString]
            ).execute()
            requestedRepostSessionIds.remove(session.id)
            await loadFeed()
            await loadNotifications(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }
}
