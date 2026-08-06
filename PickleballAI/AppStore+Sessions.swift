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
              var draft = try? JSONDecoder().decode(SessionDraft.self, from: data)
        else { return }
        guard Date().timeIntervalSince(draft.startedAt) < Self.draftMaxAge else {
            deletePersistedDraft()
            return
        }
        // A draft written before practice logging was removed may still hold
        // practice entries. They have no score, so keep the session's matches
        // and drop the rest rather than restoring meaningless 11–9 games.
        draft.activities.removeAll { $0.isLegacyPractice }
        if draft.createID == nil { draft.createID = UUID() }
        activeDraft = draft
    }

    func startLiveSession() {
        if activeDraft == nil { activeDraft = SessionDraft() }
        // The watch app scores independently; keeping the link warm means a
        // game started on the wrist reaches this draft without a cold start.
        WatchConnectivityManager.shared.activate()
    }

    func discardLiveSession() {
        WatchConnectivityManager.shared.sendCommand(.discardSession)
        activeDraft = nil
    }

    /// Posts the live session and clears it on success.
    func postLiveSession() async -> Bool {
        guard !isPostingLiveSession else { return false }
        guard let draft = activeDraft else { return false }
        isPostingLiveSession = true
        defer { isPostingLiveSession = false }
        let ok = await postSession(draft)
        if ok { activeDraft = nil }
        return ok
    }

    /// One-tap log: wraps a single activity in a fresh session and posts it.
    /// `durationMinutes` comes from the editor — a quick log is entered after
    /// play, so there is no elapsed time to measure.
    func quickLog(
        _ activity: DraftActivity,
        durationMinutes: Int = defaultQuickLogDurationMinutes,
        sessionId: UUID = UUID(),
        postToFeed: Bool = true
    ) async -> Bool {
        let duration = max(1, durationMinutes)
        let endedAt = Date()
        var draft = SessionDraft()
        draft.createID = sessionId
        draft.startedAt = endedAt.addingTimeInterval(-TimeInterval(duration * 60))
        draft.endedAt = endedAt
        draft.durationMinutes = duration
        draft.activities = [activity]
        draft.postToFeed = postToFeed
        return await postSession(draft, isQuickLog: true)
    }

    // MARK: - Writes

    /// Default length offered for a one-tap log.
    static let defaultQuickLogDurationMinutes = 60

    /// Ceiling for a duration derived from elapsed time. A live draft survives
    /// a force-quit for up to `draftMaxAge` (24h), so without a cap a session
    /// resumed the next morning would post as a 900-minute workout.
    static let maxDerivedDurationMinutes = 8 * 60

    /// Maps on-device draft activities to the RPC payload shape shared by
    /// `create_own_session` and `update_own_session`. `position` comes from the
    /// array order, and participant ids are carried through — the update RPC
    /// upserts participants by id and deletes the ones missing from the payload.
    static func writeActivities(from activities: [DraftActivity]) -> [SessionWriteActivity] {
        activities.enumerated().map { index, activity in
            let participants =
                activity.partners.map {
                    SessionWriteParticipant(
                        id: $0.id,
                        profileId: $0.profile?.id,
                        guestName: $0.profile == nil ? $0.guestName : nil,
                        role: "partner"
                    )
                }
                + activity.opponents.map {
                    SessionWriteParticipant(
                        id: $0.id,
                        profileId: $0.profile?.id,
                        guestName: $0.profile == nil ? $0.guestName : nil,
                        role: "opponent"
                    )
                }
            return SessionWriteActivity(
                id: activity.id,
                kind: "match",
                position: index,
                notes: activity.notes.isEmpty ? nil : activity.notes,
                teamScore: activity.teamScore,
                opponentScore: activity.opponentScore,
                matchFormat: activity.matchFormat,
                won: activity.wonValue,
                participants: participants
            )
        }
    }

    /// Write a full multi-activity session built on-device, in one transaction
    /// (`create_own_session`). The RPC inserts unposted, writes activities +
    /// tagged participants, and flips `posted` last, so realtime subscribers
    /// only see the completed post and a failure leaves nothing behind.
    func postSession(_ draft: SessionDraft, isQuickLog: Bool = false) async -> Bool {
        guard let uid = currentProfile?.id else {
            errorMessage = "You're signed out. Sign in and try again."
            return false
        }

        // A game still in progress on the watch lives in `liveMatch`, not in
        // `activities` — it only moves across when the watch sends `endGame`.
        // Finishing from the phone mid-game must not throw that score away.
        var activities = draft.activities
        if let liveMatch = draft.liveMatch {
            activities.append(DraftActivity(liveMatch: liveMatch))
        }
        // The editor disables Post while this is empty, but the watch's
        // `finishSession` command reaches postLiveSession() without passing
        // through it, and an activity-less session renders as a bare "Session".
        guard !activities.isEmpty else {
            errorMessage = "Add a match before posting."
            return false
        }

        // Derive "first-ever session" from state we already have: no network call
        // just for analytics. `mySessions` is empty before the user's first post.
        let isFirstSession = mySessions.isEmpty
        let milestonesBefore = Milestone.satisfiedIDs(for: SessionStats(sessions: mySessions, playerID: uid))
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        var uploadedPhotoPath: String?
        do {
            let now = Date()
            let elapsed = Int(now.timeIntervalSince(draft.startedAt) / 60)
            let duration = draft.durationMinutes
                ?? min(max(1, elapsed), Self.maxDerivedDurationMinutes)
            let endedAt = draft.durationMinutes == nil
                ? now
                : draft.startedAt.addingTimeInterval(TimeInterval(duration * 60))
            let sessionId = draft.createID ?? UUID()

            // Upload before the row exists — the storage path is uid-scoped, so
            // it doesn't depend on the session. A failure aborts the post rather
            // than silently publishing a session without its photo.
            var photoPath = ""
            if let photoData = draft.photoData {
                guard let uploaded = await uploadPostPhoto(photoData, sessionId: sessionId, uid: uid) else {
                    // `uploadPostPhoto` reports the specific failure (a storage
                    // error, an encode failure) — don't overwrite it. This only
                    // covers a path that returned nil without saying why, which
                    // would otherwise abort the post in total silence: the user
                    // taps Post, nothing happens, and the session still reads as
                    // unposted with no indication of what went wrong.
                    if errorMessage == nil {
                        errorMessage = "Couldn't upload your photo. Check your connection and try again."
                    }
                    return false
                }
                photoPath = uploaded
                uploadedPhotoPath = uploaded
            }

            let payload = SessionCreatePayload(
                id: sessionId,
                title: draft.title.isEmpty ? Self.timeOfDayTitle(for: draft.startedAt) : draft.title,
                location: draft.location,
                takeaway: draft.takeaway,
                durationMinutes: duration,
                posted: draft.postToFeed,
                startedAt: DateFormatting.iso.string(from: draft.startedAt),
                endedAt: DateFormatting.iso.string(from: endedAt),
                photoPath: photoPath,
                activities: Self.writeActivities(from: activities)
            )
            try await supabase.rpc(
                "create_own_session",
                params: CreateSessionRPCParams(payload: payload)
            ).execute()

            await loadMySessions(userId: uid)
            await loadFeed()
            let properties: [String: Any] = [
                Analytics.Property.activityCount: activities.count,
                Analytics.Property.quickLog: isQuickLog,
                Analytics.Property.hasNote: activities.contains { !$0.notes.isEmpty }
            ]
            Analytics.capture(.sessionLogged, properties)
            if isFirstSession {
                Analytics.captureOnce(.firstSessionLogged, flag: .firstSessionLogged, properties)
            }
            await unlockNewlyCrossedMilestones(previouslySatisfied: milestonesBefore, playerID: uid)
            return true
        } catch {
            // A PostgREST error is a definitive database rejection, so no row
            // can reference the pre-uploaded object. Transport errors are
            // ambiguous: the transaction may have committed before its response
            // was lost, so retain the stable-path upload for an idempotent retry.
            if error is PostgrestError, let uploadedPhotoPath {
                try? await supabase.storage.from("post-photos").remove(paths: [uploadedPhotoPath])
            }
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
            let activities = Self.writeActivities(from: draft.activities)
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
            await loadFeed()
            await loadNotifications(userId: uid)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    /// Diffs milestone state before/after a session post and unlocks (server-side,
    /// idempotently) any newly-crossed thresholds — the celebratory path, which
    /// also fires the "you unlocked X" notification. Best-effort: a failed call
    /// is *not* retried by a later diff (the threshold is satisfied on both sides
    /// by then), so `reconcileMilestoneUnlocks` sweeps up anything lost here on
    /// the next shelf load.
    private func unlockNewlyCrossedMilestones(previouslySatisfied: Set<String>, playerID: UUID) async {
        let after = Milestone.satisfiedIDs(for: SessionStats(sessions: mySessions, playerID: playerID))
        let newlyUnlocked = after.subtracting(previouslySatisfied)
        guard !newlyUnlocked.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: Milestone.catalog.map { ($0.id, $0) })
        for milestoneID in newlyUnlocked {
            guard let milestone = byID[milestoneID] else { continue }
            do {
                try await supabase.rpc("unlock_milestone", params: [
                    "p_milestone_id": milestone.id,
                    "p_title": milestone.title
                ]).execute()
                milestoneUnlocks.insert(milestoneID)
                Analytics.capture(.milestoneUnlocked, [Analytics.Property.milestoneID: milestoneID])
            } catch {
                // Non-fatal: the next session post's diff will retry this milestone.
            }
        }
    }
}
