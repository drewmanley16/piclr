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
            stopRealtime()
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
        searchResults = []
        requestedFollowIds = []
        gear = []
        incomingRepostRequests = []
        requestedRepostSessionIds = []
        likedSessionIds = []
        notifications = []
        blockedAccounts = []
        deletePersistedDraft() // the live draft belongs to the signed-in user
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
            async let reposts: Void = self.loadRepostRequests(userId: userId)
            async let notifications: Void = self.loadNotifications(userId: userId)
            async let blocks: Void = self.loadBlockedAccounts()
            async let invites: Void = self.loadActiveInvites(userId: userId)
            _ = await (followState, followLists, mySessions, gear, reposts, notifications, blocks, invites)
            guard !Task.isCancelled, self.currentProfile?.id == userId else { return }
            await self.setUpPush()
        }
    }

    private func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "PB" : String(letters).uppercased()
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
            await PushService.shared.requestAuthorizationAndRegister()
        } else {
            await PushService.shared.registerIfAuthorized()
        }
    }

    /// Prompts for permission and registers. Called from the Settings toggle.
    @discardableResult
    func enablePushNotifications() async -> Bool {
        await PushService.shared.requestAuthorizationAndRegister()
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
        case "comment":
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
