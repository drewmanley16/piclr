import Foundation
import ActivityKit
import os

/// Starts/updates/ends the session Live Activity as the in-progress session
/// changes. No-ops on unsupported OSes or when the user disabled Live Activities.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private static let logger = Logger(subsystem: "com.pickleball.ai", category: "LiveActivity")

    private var activity: Activity<SessionActivityAttributes>?
    private var lastState: SessionActivityAttributes.ContentState?
    /// Trailing-edge debounce for `update(...)`: rapid syncs (e.g. per-keystroke
    /// title edits) collapse into one call so we don't spam ActivityKit's limiter.
    private var pendingUpdateTask: Task<Void, Never>?

    /// Reconciles the Live Activity with the current draft: starts one when a
    /// session opens, updates it as activities are added, ends it when cleared.
    func sync(draft: SessionDraft?) {
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // If the app was killed while an activity was live, `self.activity` is nil
        // on relaunch even though the system still shows it. Adopt it before any
        // start()/end() so we never orphan (and double up) live activities.
        adoptOrphanedActivityIfNeeded()

        guard let draft else {
            end()
            return
        }

        let state = SessionActivityAttributes.ContentState(
            activityCount: draft.activities.count,
            title: draft.title.isEmpty ? AppStore.timeOfDayTitle(for: draft.startedAt) : draft.title,
            us: nil,
            them: nil
        )

        if let activity {
            guard state != lastState else { return }
            lastState = state
            scheduleUpdate(activity: activity, state: state)
        } else {
            start(startedAt: draft.startedAt, state: state)
        }
    }

    /// Reattaches to an activity still shown by the system (after a cold launch)
    /// when we've lost our in-memory handle. Seeds `lastState` from its current
    /// content so the next distinct sync is what triggers an update.
    @available(iOS 16.2, *)
    private func adoptOrphanedActivityIfNeeded() {
        guard activity == nil, let orphan = Activity<SessionActivityAttributes>.activities.first else { return }
        activity = orphan
        lastState = orphan.content.state
    }

    /// Debounced update: cancel-and-replace, then apply the latest state after a
    /// short quiet period so a burst of syncs results in a single trailing update.
    @available(iOS 16.2, *)
    private func scheduleUpdate(activity: Activity<SessionActivityAttributes>, state: SessionActivityAttributes.ContentState) {
        pendingUpdateTask?.cancel()
        pendingUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms trailing debounce
            guard !Task.isCancelled else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    @available(iOS 16.2, *)
    private func start(startedAt: Date, state: SessionActivityAttributes.ContentState) {
        let attributes = SessionActivityAttributes(startedAt: startedAt)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            lastState = state
        } catch {
            // Live Activities can be rate-limited or disabled; failing is non-fatal.
            Self.logger.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func end() {
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        let current = activity
        activity = nil
        lastState = nil
        Task {
            await current?.end(nil, dismissalPolicy: .immediate)
            // Belt-and-braces: sweep any other orphaned activities so a lost draft
            // can't leave one lingering on the lock screen forever.
            if #available(iOS 16.2, *) {
                for orphan in Activity<SessionActivityAttributes>.activities {
                    await orphan.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
