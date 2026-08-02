import SwiftUI

/// Shared defaults keys for the weekly goal + streak-save reminder. The reminder
/// toggle stores intent now; the actual push is delivered server-side later
/// (see the streak_reminders migration / send-push).
enum GoalDefaults {
    static let weeklyGoalKey = "weeklySessionGoal"
    static let streakReminderKey = "streakSaveReminders"
    static let defaultGoal = 3
}

/// Profile card: weekly session goal progress + streak-at-risk nudge. Everyone
/// taps into the sheet; free users see their real progress there with the
/// goal/reminder controls sealed behind Pro.
struct GoalsCard: View {
    let sessionsThisWeek: Int
    let weeklyStreak: Int
    let locked: Bool
    var onOpen: () -> Void = {}

    @AppStorage(GoalDefaults.weeklyGoalKey) private var goal = GoalDefaults.defaultGoal

    private var progress: Double { goal == 0 ? 0 : min(Double(sessionsThisWeek) / Double(goal), 1) }
    private var met: Bool { sessionsThisWeek >= goal }
    private var streakAtRisk: Bool { weeklyStreak > 0 && sessionsThisWeek == 0 }

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                StatBoardHeader(title: "Weekly goal", locked: locked)
                CourtLineRule()

                // Real progress even for free users — their own week is the ad.
                HStack(spacing: 12) {
                    ProgressBar(progress: progress)
                    Text("\(sessionsThisWeek)/\(goal)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(met ? Theme.accent : Theme.textSecondary)
                }

                if streakAtRisk && !locked {
                    Label("Your \(weeklyStreak)-week streak is at risk. Play once to save it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.loss)
                        .lineLimit(2)
                } else if met && !locked {
                    Label("Goal met. Nice week.", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(locked ? "Set a weekly target and protect your streak." : "\(max(goal - sessionsThisWeek, 0)) to go this week.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

/// Slim lime progress bar.
private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceElevated)
                Capsule().fill(Theme.accent)
                    .frame(width: max(6, geo.size.width * progress))
            }
        }
        .frame(height: 10)
    }
}

/// Goal settings, doubling as its own teaser for free users: real weekly
/// progress up top, the target/reminder controls sealed behind Pro below.
struct GoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var subscriptions: SubscriptionStore
    let sessionsThisWeek: Int
    let weeklyStreak: Int

    private var locked: Bool { subscriptions.showsLockedFeatures }

    @AppStorage(GoalDefaults.weeklyGoalKey) private var goal = GoalDefaults.defaultGoal
    @AppStorage(GoalDefaults.streakReminderKey) private var remindersOn = true

    private var progress: Double { goal == 0 ? 0 : min(Double(sessionsThisWeek) / Double(goal), 1) }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        Text("\(sessionsThisWeek) / \(goal)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                        Text("sessions this week")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        ProgressBar(progress: progress)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Sessions per week")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Stepper(value: $goal, in: 1...14) {
                                Text("\(goal)")
                                    .font(.headline.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.accent)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider().overlay(Theme.hairline)
                        Toggle(isOn: $remindersOn) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Streak-save reminders")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Get a nudge when your weekly streak is about to break.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.accent)
                    }
                    .cardStyle()
                    // Locked controls dim like native disabled settings; the
                    // stepper and toggle stay legible so the offer is concrete.
                    .opacity(locked ? 0.45 : 1)
                    .disabled(locked)
                    .accessibilityHint(locked ? "Unlock with Pro to change." : "")

                    if locked {
                        ProTeaserUnlockBar(
                            context: .goals,
                            title: "Unlock goals & reminders",
                            caption: weeklyStreak > 0
                                ? "Protect your \(weeklyStreak)-week streak with save reminders."
                                : "Set a target and get nudged before a streak breaks."
                        )
                    }

                    if weeklyStreak > 0 {
                        HStack(spacing: 14) {
                            Image(systemName: "bolt.fill")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.accent)
                            Text("You're on a \(weeklyStreak)-week streak. Keep it alive.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        .cardStyle()
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .trackProTeaser(.goals, locked: locked)
        .onAppear {
            // Server is the source of truth across devices/reinstalls; local
            // @AppStorage is just a fast cache for the picker/toggle controls.
            if let serverGoal = store.currentProfile?.weeklyGoal { goal = serverGoal }
            if let serverReminders = store.currentProfile?.streakRemindersEnabled { remindersOn = serverReminders }
        }
        .onChange(of: goal) { _, newValue in
            Task { await store.updateGoalPrefs(weeklyGoal: newValue, streakRemindersEnabled: remindersOn) }
        }
        .onChange(of: remindersOn) { _, newValue in
            Haptics.tap()
            Task { await store.updateGoalPrefs(weeklyGoal: goal, streakRemindersEnabled: newValue) }
        }
    }
}
