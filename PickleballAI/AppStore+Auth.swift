import Foundation
import os
import Supabase

// MARK: - Auth

extension AppStore {
    func sendPhoneOTP(phone: String) async -> Bool {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.auth.signInWithOTP(phone: phone)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func verifyPhoneOTP(phone: String, token: String) async -> Bool {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            try await supabase.auth.verifyOTP(phone: phone, token: token, type: .sms)
            Analytics.capture(.otpVerified)
            let session = try await supabase.auth.session
            await handleSignedIn(userId: session.user.id)
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func deleteAccount() async -> Bool {
        guard currentProfile != nil else { return false }
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let response: DeleteAccountResponse = try await supabase.functions.invoke("delete-account")
            guard response.deleted else {
                throw NSError(
                    domain: "PickleballAI.AccountDeletion",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The account could not be deleted."]
                )
            }
            Analytics.capture(.accountDeleted)
            stopRealtime()
            // Local-only sign-out: clears the (now-dead) keychain session and
            // emits a .signedOut auth event so observers (RevenueCat identity
            // in SubscriptionStore) react — the server user is already gone,
            // so a global sign-out would just fail against the network.
            try? await supabase.auth.signOut(scope: .local)
            clearSignedInState()
            return true
        } catch {
            reportError(error)
            return false
        }
    }

    func completeOnboarding(
        firstName: String,
        lastName: String,
        username: String,
        skillLevel: SkillLevel,
        duprRating: Double?
    ) async -> Bool {
        busyCount += 1
        errorMessage = nil
        defer { busyCount -= 1 }
        do {
            let request = CompleteOnboardingRequest(
                firstName: firstName.trimmed,
                lastName: lastName.trimmed,
                displayName: [firstName.trimmed, lastName.trimmed].joined(separator: " "),
                username: username.normalizedUsername,
                avatarInitials: initials(from: [firstName.trimmed, lastName.trimmed].joined(separator: " ")),
                skillLevel: skillLevel.rawValue,
                duprRating: skillLevel == .dupr ? duprRating : nil
            )
            let response: CompleteOnboardingResponse = try await supabase.functions
                .invoke(
                    "complete-onboarding",
                    options: FunctionInvokeOptions(body: request)
                )
            currentProfile = response.profile
            Analytics.identify(
                userID: response.profile.id.uuidString,
                skillLevel: response.profile.skillLevel,
                hasDuprRating: response.profile.rating != nil
            )
            Analytics.capture(.onboardingCompleted, [
                Analytics.Property.skillLevel: response.profile.skillLevel ?? "unknown"
            ])
            authState = .signedIn
            await loadSignedInData(userId: response.profile.id)
            return true
        } catch {
            if isAuthFailure(error) {
                // The session is invalid/expired (e.g. the account was deleted
                // out from under this token). Bail out to the auth screen
                // instead of stranding the user on onboarding.
                await signOut()
                errorMessage = "Your session expired. Please sign in again."
            } else {
                reportError(error)
            }
            return false
        }
    }

    /// A lightweight, debounced hint for the onboarding form. The unique
    /// database index remains authoritative when onboarding is completed.
    func checkUsernameAvailability(username: String) async -> Bool? {
        guard ProfileIdentityValidator.username(username).isValid else { return nil }
        do {
            let response: UsernameAvailabilityResponse = try await supabase.functions
                .invoke(
                    "complete-onboarding",
                    options: FunctionInvokeOptions(
                        body: UsernameAvailabilityRequest(
                            username: username,
                            checkUsernameOnly: true
                        )
                    )
                )
            return response.available
        } catch {
            return nil
        }
    }

    /// True when an error means the session is unauthenticated (HTTP 401/403
    /// from an Edge Function, or a Supabase auth error).
    private func isAuthFailure(_ error: Error) -> Bool {
        if let functionsError = error as? FunctionsError,
           case .httpError(let code, _) = functionsError {
            return code == 401 || code == 403
        }
        return error is AuthError
    }

    func signOut() async {
        stopRealtime()
        await removeDeviceToken()
        try? await supabase.auth.signOut()
        clearSignedInState()
    }

    private func clearSignedInState() {
        signedInBackgroundTask?.cancel()
        signedInBackgroundTask = nil
        isFeedRequestInFlight = false
        pendingFeedRefresh = false
        initialFeedLoadStartedAt = nil
        acceptedFollowingUserIDs = []
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        realtimeNeedsFeedRefresh = false
        realtimeNeedsMySessionsRefresh = false
        realtimeNeedsDiscoverRefresh = false
        isInitialFeedLoading = false
        media.clearCache()
        currentProfile = nil
        feed = []
        discoverFeed = []
        feedReachedEnd = false
        discoverReachedEnd = false
        mySessions = []
        followerCount = 0
        followingCount = 0
        incomingFollowRequests = []
        followers = []
        following = []
        contactMatches = []
        suggestedAthletes = []
        isSuggestedAthletesLoading = false
        searchResults = []
        requestedFollowIds = []
        gear = []
        likedSessionIds = []
        optimisticLikeCounts = [:]
        likedCommentIds = []
        optimisticCommentLikeCounts = [:]
        notifications = []
        blockedAccounts = []
        deletePersistedDraft() // the live draft belongs to the signed-in user
        Analytics.reset()
        authState = .signedOut
    }

    func handleSignedIn(userId: UUID) async {
        authState = .loading
        switch await loadProfile(userId: userId) {
        case .missing:
            // Valid token but no profile row (e.g. the account was deleted) —
            // the session is orphaned. Clear it and return to the auth screen
            // rather than dropping into an onboarding flow that can't complete.
            await signOut()
            return
        case .failed:
            // Couldn't reach the server; don't destroy a possibly-valid
            // session. Show the auth screen; a good session restores next launch.
            authState = .signedOut
            return
        case .loaded:
            break
        }
        guard let profile = currentProfile else {
            authState = .signedOut
            return
        }
        if profile.hasCompletedOnboarding {
            Analytics.identify(
                userID: profile.id.uuidString,
                skillLevel: profile.skillLevel,
                hasDuprRating: profile.rating != nil
            )
            authState = .signedIn
            await loadSignedInData(userId: userId)
        } else {
            authState = .needsOnboarding
            await loadFollowState(userId: userId)
        }
    }

    private func loadSignedInData(userId: UUID) async {
        // A signed-in session is now confirmed for the local user; resurrect any
        // live draft persisted before a kill (the sign-out path deletes the file,
        // so a leftover file always belongs to this user).
        restorePersistedDraft()
        let startupBeganAt = Date()
        initialFeedLoadStartedAt = startupBeganAt
        isInitialFeedLoading = feed.isEmpty
        startRealtime(userId: userId)
        setUpWatchConnectivity()
        await loadFeed()
        debugFeedMetric("initial feed pipeline complete", since: startupBeganAt)

        // None of this data is required to draw the Home feed. Let it populate
        // the remaining tabs and badges without extending time-to-feed.
        signedInBackgroundTask?.cancel()
        signedInBackgroundTask = Task { [weak self] in
            guard let self, self.currentProfile?.id == userId else { return }
            async let followState: Void = self.loadFollowState(userId: userId)
            async let followLists: Void = self.loadFollowLists(userId: userId)
            async let mySessions: Void = self.loadMySessions(userId: userId)
            async let gear: Void = self.loadGear(userId: userId)
            async let notifications: Void = self.loadNotifications(userId: userId)
            async let blocks: Void = self.loadBlockedAccounts()
            async let invites: Void = self.loadActiveInvites(userId: userId)
            async let suggestions: Void = self.loadSuggestedAthletes()
            _ = await (followState, followLists, mySessions, gear, notifications, blocks, invites, suggestions)
            guard !Task.isCancelled, self.currentProfile?.id == userId else { return }
            await self.setUpPush()
        }
    }

    private func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
    }

    // MARK: - Watch connectivity

    /// Activates the WatchConnectivity link and routes inbound watch messages.
    /// W1 only observes them (logged in the manager); reflecting live scores into
    /// `activeDraft` and posting from the watch land in later phases.
    private func setUpWatchConnectivity() {
        WatchConnectivityManager.shared.onMessage = { [weak self] message in
            self?.handleWatchMessage(message)
        }
        WatchConnectivityManager.shared.onConnectionChange = { [weak self] activated, reachable in
            guard let self, self.activeDraft?.expectsWatchMetrics == true,
                  self.activeDraft?.workoutMetrics == nil else { return }
            if reachable {
                self.requestLiveWorkoutMetrics()
            } else if activated {
                self.watchWorkoutStatus = .disconnected
            }
        }
        WatchConnectivityManager.shared.activate()
    }

    /// Routes messages from the watch into the live session. Score snapshots
    /// stream into `activeDraft.liveMatch` (driving the Live Activity); lifecycle
    /// commands open the session, convert a finished game into a match activity,
    /// or post the whole session.
    private func handleWatchMessage(_ message: WatchSyncMessage) {
        switch message {
        case .score(let score):
            adoptWatchScore(score)

        case .command(.startGame(let score)), .command(.newGame(let score)):
            // A snapshot may have already opened the session; either way, adopt
            // the game the watch just declared authoritative.
            if activeDraft == nil { activeDraft = SessionDraft() }
            activeDraft?.liveMatch = score
            if HealthMetricsSharing.isEnabled {
                activeDraft?.expectsWatchMetrics = true
                if activeDraft?.watchWorkoutStartedAt == nil { watchWorkoutStatus = .starting }
            }

        case .command(.endGame(let score)):
            // Convert the finished game into a match activity (US → team) and
            // clear the live game so the Live Activity stops showing a score.
            if activeDraft == nil { activeDraft = SessionDraft() }
            activeDraft?.activities.append(DraftActivity(liveMatch: score))
            activeDraft?.liveMatch = nil

        case .command(.finishSession):
            if activeDraft?.expectsWatchMetrics == true {
                watchWorkoutStatus = .failed("Apple Watch could not finalize the workout metrics.")
                errorMessage = "Apple Watch metrics could not be finalized. Retry from the phone, or post without metrics."
            } else {
                Task { await postLiveSession() }
            }

        case .command(.workoutStarted(let startedAt)):
            guard activeDraft != nil else { return }
            activeDraft?.watchWorkoutStartedAt = startedAt
            if HealthMetricsSharing.isEnabled {
                activeDraft?.expectsWatchMetrics = true
                watchWorkoutStatus = .waitingForHeartRate
                requestLiveWorkoutMetrics()
            }

        case .command(.workoutStartFailed(let message)):
            guard activeDraft?.expectsWatchMetrics == true else { return }
            watchWorkoutStatus = .failed(message)

        case .command(.liveWorkoutMetrics(let metrics)):
            guard activeDraft?.expectsWatchMetrics == true, HealthMetricsSharing.isEnabled else { return }
            guard liveWorkoutMetrics.map({ metrics.sampledAt >= $0.sampledAt }) ?? true else { return }
            if activeDraft?.watchWorkoutStartedAt == nil {
                activeDraft?.watchWorkoutStartedAt = activeDraft?.startedAt
            }
            liveWorkoutMetrics = metrics
            watchWorkoutStatus = metrics.heartRateBPM == nil ? .waitingForHeartRate : .tracking

        case .command(.requestLiveWorkoutMetrics):
            break

        case .command(.workoutFinished(let metrics, let postSession)):
            guard activeDraft != nil, activeDraft?.workoutMetrics == nil else { return }
            activeDraft?.workoutMetrics = HealthMetricsSharing.isEnabled
                ? metrics
                : WorkoutMetrics(
                    averageHeartRateBPM: nil,
                    maximumHeartRateBPM: nil,
                    activeCaloriesKcal: nil,
                    startedAt: metrics.startedAt,
                    endedAt: metrics.endedAt
                )
            activeDraft?.watchWorkoutStartedAt = nil
            liveWorkoutMetrics = nil
            if HealthMetricsSharing.isEnabled, metrics.averageHeartRateBPM == nil {
                watchWorkoutStatus = .failed(
                    "No heart-rate samples were received. Check Apple Watch Health permissions and wrist detection."
                )
                errorMessage = "Apple Watch finished without heart-rate data. Retry from the phone, or post without metrics."
            } else {
                watchWorkoutStatus = .idle
                if postSession || (shouldPostWhenWatchFinishes && !isWaitingForWatchFinalization) {
                    shouldPostWhenWatchFinishes = false
                    Task { await postLiveSession() }
                }
            }

        case .command(.requestFinishWorkout), .command(.discardWorkout):
            break
        }
    }

    /// Adopts an incoming score only when it's strictly newer than what we hold
    /// (last-writer-wins by `seq`, ties broken by start time), or when it belongs
    /// to a different game. A stale delivery can't clobber a fresher local state.
    private func adoptWatchScore(_ score: LiveMatchScore) {
        if activeDraft == nil { activeDraft = SessionDraft() }
        if let current = activeDraft?.liveMatch, current.id == score.id {
            let newer = score.seq > current.seq
                || (score.seq == current.seq && score.startedAt > current.startedAt)
            guard newer else { return }
        }
        activeDraft?.liveMatch = score
    }

    // MARK: - Push notifications

    /// Wires the token callback and registers with APNs. On first sign-in this
    /// prompts for permission; on later launches it silently refreshes the token
    /// if the user already granted it.
    private func setUpPush() async {
        PushService.shared.onToken = { [weak self] token in
            Task { await self?.uploadDeviceToken(token) }
        }
        PushService.shared.onTap = { [weak self] userInfo in
            self?.handlePushTap(userInfo)
        }
        if await PushService.shared.authorizationStatus() == .notDetermined {
            if await PushService.shared.requestAuthorizationAndRegister() {
                Analytics.capture(.pushNotificationsEnabled)
            }
        } else {
            await PushService.shared.registerIfAuthorized()
        }
    }

    /// Prompts for permission and registers. Called from the Settings toggle.
    @discardableResult
    func enablePushNotifications() async -> Bool {
        let granted = await PushService.shared.requestAuthorizationAndRegister()
        if granted { Analytics.capture(.pushNotificationsEnabled) }
        return granted
    }

    /// Routes a tapped push to its target. The payload carries `type`,
    /// `session_id`, and `actor_id` (set by the send-push edge function).
    private func handlePushTap(_ userInfo: [AnyHashable: Any]) {
        let type = userInfo["type"] as? String
        let sessionId = (userInfo["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let actorId = (userInfo["actor_id"] as? String).flatMap(UUID.init(uuidString:))
        let inviteId = (userInfo["invite_id"] as? String).flatMap(UUID.init(uuidString:))
        switch type {
        case "follow":
            if let actorId { pendingDeepLink = .profile(actorId) }
        case "comment", "comment_reply", "comment_like", "mention":
            if let sessionId { pendingDeepLink = .comments(sessionId) }
        case "invite_received", "invite_response", "invite_cancelled":
            if let inviteId { pendingDeepLink = .invite(inviteId) }
        default:
            if let sessionId { pendingDeepLink = .session(sessionId) }
        }
    }

    private func uploadDeviceToken(_ token: String) async {
        guard currentProfile != nil else { return }
        do {
            try await supabase
                .rpc("register_device_token", params: ["p_token": token, "p_platform": "ios"])
                .execute()
        } catch {
            // Non-fatal: worst case the device just won't get pushes this run.
            Self.pushLogger.error("token upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes this device's token so it stops receiving pushes (toggle off / sign out).
    func removeDeviceToken() async {
        guard let token = PushService.shared.latestToken else { return }
        try? await supabase
            .from("device_tokens")
            .delete()
            .eq("token", value: token)
            .execute()
    }
}
