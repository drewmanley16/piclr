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
        if draft.expectsWatchMetrics == true, draft.workoutMetrics == nil {
            watchWorkoutStatus = .disconnected
        }
    }

    func startLiveSession(trackOnWatch: Bool = true) {
        liveWorkoutMetrics = nil
        if activeDraft == nil { activeDraft = SessionDraft() }
        activeDraft?.expectsWatchMetrics = trackOnWatch
        guard trackOnWatch else {
            watchWorkoutStatus = .idle
            return
        }

        watchWorkoutStatus = .starting
        WatchConnectivityManager.shared.activate()
        AppleWatchWorkoutLauncher.shared.startWorkout { [weak self] result in
            guard let self, self.activeDraft?.expectsWatchMetrics == true else { return }
            switch result {
            case .success:
                // HealthKit accepted the launch request. The Watch will move us
                // to tracking when collection actually begins.
                if self.activeDraft?.watchWorkoutStartedAt == nil {
                    self.watchWorkoutStatus = .starting
                }
                let draftStartedAt = self.activeDraft?.startedAt
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard let self,
                          self.activeDraft?.startedAt == draftStartedAt,
                          self.activeDraft?.expectsWatchMetrics == true,
                          self.activeDraft?.watchWorkoutStartedAt == nil,
                          self.liveWorkoutMetrics == nil else { return }
                    self.watchWorkoutStatus = .failed(
                        "Apple Watch did not confirm tracking. Open the Watch app and check Health permissions."
                    )
                }
            case .failure(let error):
                self.watchWorkoutStatus = .failed(error.localizedDescription)
            }
        }
    }

    func requestLiveWorkoutMetrics() {
        guard activeDraft?.expectsWatchMetrics == true, activeDraft?.workoutMetrics == nil else { return }
        WatchConnectivityManager.shared.activate()
        if activeDraft?.watchWorkoutStartedAt != nil {
            watchWorkoutStatus = WatchConnectivityManager.shared.isReachable
                ? (liveWorkoutMetrics?.heartRateBPM == nil ? .waitingForHeartRate : .tracking)
                : .disconnected
        }
        WatchConnectivityManager.shared.sendCommand(.requestLiveWorkoutMetrics)
    }

    func appDidBecomeActive() {
        guard activeDraft?.expectsWatchMetrics == true, activeDraft?.workoutMetrics == nil else { return }
        requestLiveWorkoutMetrics()
    }

    func discardLiveSession() {
        if activeDraft?.expectsWatchMetrics == true {
            WatchConnectivityManager.shared.sendCommand(.discardWorkout)
        }
        liveWorkoutMetrics = nil
        shouldPostWhenWatchFinishes = false
        activeDraft = nil
    }

    /// Waits briefly for Apple Watch to finalize HealthKit so its aggregate
    /// values are part of the same insert. If tracking never started, posts now.
    func finishAndPostLiveSession() async -> Bool {
        guard activeDraft != nil else { return false }
        guard activeDraft?.expectsWatchMetrics == true else {
            return await postLiveSession()
        }

        shouldPostWhenWatchFinishes = true
        isWaitingForWatchFinalization = true
        defer { isWaitingForWatchFinalization = false }
        watchWorkoutStatus = .finalizing
        WatchConnectivityManager.shared.sendCommand(.requestFinishWorkout)
        for _ in 0..<80 {
            if let metrics = activeDraft?.workoutMetrics {
                guard metrics.averageHeartRateBPM != nil else {
                    watchWorkoutStatus = .failed(
                        "No heart-rate samples were received. Check Apple Watch Health permissions and wrist detection."
                    )
                    errorMessage = "Apple Watch finished without heart-rate data. Retry, or choose Post Without Metrics."
                    return false
                }
                return await postLiveSession()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let metrics = activeDraft?.workoutMetrics, metrics.averageHeartRateBPM != nil {
            return await postLiveSession()
        }
        watchWorkoutStatus = WatchConnectivityManager.shared.isReachable ? .finalizing : .disconnected
        errorMessage = "Apple Watch metrics have not finished syncing. Retry, or choose Post Without Metrics."
        return false
    }

    /// Explicit escape hatch after a failed sync. This is never selected
    /// implicitly: the user must confirm that the post may omit Watch metrics.
    func postLiveSessionWithoutMetrics() async -> Bool {
        guard activeDraft != nil else { return false }
        activeDraft?.expectsWatchMetrics = false
        activeDraft?.workoutMetrics = nil
        shouldPostWhenWatchFinishes = false
        liveWorkoutMetrics = nil
        watchWorkoutStatus = .idle
        return await postLiveSession()
    }

    /// Posts the live session and clears it on success.
    func postLiveSession() async -> Bool {
        guard let draft = activeDraft else { return false }
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
        postToFeed: Bool = true
    ) async -> Bool {
        var draft = SessionDraft()
        draft.startedAt = Date()
        draft.durationMinutes = durationMinutes
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
            let isMatch = activity.kind == .match
            return SessionWriteActivity(
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
    }

    /// Write a full multi-activity session built on-device, in one transaction
    /// (`create_own_session`). The RPC inserts unposted, writes activities +
    /// tagged participants, and flips `posted` last, so realtime subscribers
    /// only see the completed post and a failure leaves nothing behind.
    func postSession(_ draft: SessionDraft, isQuickLog: Bool = false) async -> Bool {
        guard let uid = currentProfile?.id else { return false }

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
            errorMessage = "Add a match or practice before posting."
            return false
        }

        // Derive "first-ever session" from state we already have: no network call
        // just for analytics. `mySessions` is empty before the user's first post.
        let isFirstSession = mySessions.isEmpty
        let milestonesBefore = Milestone.satisfiedIDs(for: SessionStats(sessions: mySessions, playerID: uid))
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let now = Date()
            let elapsed = Int(now.timeIntervalSince(draft.startedAt) / 60)
            let duration = draft.durationMinutes
                ?? min(max(1, elapsed), Self.maxDerivedDurationMinutes)
            let sessionId = UUID()

            // Upload before the row exists — the storage path is uid-scoped, so
            // it doesn't depend on the session. A failure aborts the post rather
            // than silently publishing a session without its photo.
            var photoPath = ""
            if let photoData = draft.photoData {
                guard let uploaded = await uploadPostPhoto(photoData, sessionId: sessionId, uid: uid) else {
                    return false
                }
                photoPath = uploaded
            }

            let payload = SessionCreatePayload(
                id: sessionId,
                title: draft.title.isEmpty ? Self.timeOfDayTitle(for: draft.startedAt) : draft.title,
                location: draft.location,
                takeaway: draft.takeaway,
                durationMinutes: duration,
                posted: draft.postToFeed,
                startedAt: DateFormatting.iso.string(from: draft.startedAt),
                endedAt: DateFormatting.iso.string(from: now),
                photoPath: photoPath,
                averageHeartRateBPM: draft.workoutMetrics?.averageHeartRateBPM,
                maximumHeartRateBPM: draft.workoutMetrics?.maximumHeartRateBPM,
                activeCaloriesKcal: draft.workoutMetrics?.activeCaloriesKcal,
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
                Analytics.Property.quickLog: isQuickLog
            ]
            Analytics.capture(.sessionLogged, properties)
            if isFirstSession {
                Analytics.captureOnce(.firstSessionLogged, flag: .firstSessionLogged, properties)
            }
            await unlockNewlyCrossedMilestones(previouslySatisfied: milestonesBefore, playerID: uid)
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
    /// idempotently) any newly-crossed thresholds. Best-effort — a missed unlock
    /// just means the badge appears next time this diff runs, same trust level
    /// as `updateGoalPrefs`.
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
