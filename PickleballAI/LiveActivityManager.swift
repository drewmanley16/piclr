import Foundation
import ActivityKit

/// Starts/updates/ends the session Live Activity as the in-progress session
/// changes. No-ops on unsupported OSes or when the user disabled Live Activities.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<SessionActivityAttributes>?
    private var lastState: SessionActivityAttributes.ContentState?

    /// Reconciles the Live Activity with the current draft: starts one when a
    /// session opens, updates it as activities are added, ends it when cleared.
    func sync(draft: SessionDraft?) {
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let draft else {
            end()
            return
        }

        let state = SessionActivityAttributes.ContentState(
            activityCount: draft.activities.count,
            title: draft.title.isEmpty ? AppStore.timeOfDayTitle(for: draft.startedAt) : draft.title
        )

        if let activity {
            guard state != lastState else { return }
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            start(startedAt: draft.startedAt, state: state)
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
            print("[LiveActivity] start failed: \(error.localizedDescription)")
        }
    }

    func end() {
        guard let current = activity else { return }
        activity = nil
        lastState = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}
