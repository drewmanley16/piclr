import SwiftUI

/// Shared defaults keys for the weekly goal + streak-save reminder. The reminder
/// toggle stores intent now; the actual push is delivered server-side later
/// (see the streak_reminders migration / send-push).
enum GoalDefaults {
    static let weeklyGoalKey = "weeklySessionGoal"
    static let streakReminderKey = "streakSaveReminders"
    static let defaultGoal = 3
}

/// Profile card: weekly session goal progress + streak-at-risk nudge. Locked for
/// free users (opens the paywall); Pro users tap in to adjust the goal.
struct GoalsCard: View {
    let sessionsThisWeek: Int
    let weeklyStreak: Int
    let locked: Bool
    var onUnlock: () -> Void = {}
    var onOpen: () -> Void = {}

    @AppStorage(GoalDefaults.weeklyGoalKey) private var goal = GoalDefaults.defaultGoal

    private var progress: Double { goal == 0 ? 0 : min(Double(sessionsThisWeek) / Double(goal), 1) }
    private var met: Bool { sessionsThisWeek >= goal }
    private var streakAtRisk: Bool { weeklyStreak > 0 && sessionsThisWeek == 0 }

    var body: some View {
        Button {
            Haptics.tap()
            if locked { onUnlock() } else { onOpen() }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Weekly goal", systemImage: "target")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if locked {
                        ProLockBadge()
                    } else {
                        Text(met ? "Done" : "\(sessionsThisWeek)/\(goal)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(met ? Theme.accent : Theme.textSecondary)
                    }
                }

                ProgressBar(progress: locked ? 0.45 : progress, blurred: locked)

                if streakAtRisk && !locked {
                    Label("Your \(weeklyStreak)-week streak is at risk — play once to save it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.loss)
                        .lineLimit(2)
                } else if met && !locked {
                    Label("Goal met — nice week.", systemImage: "checkmark.seal.fill")
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

/// Slim lime progress bar; blurred when teased to a free user.
private struct ProgressBar: View {
    let progress: Double
    var blurred = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceElevated)
                Capsule().fill(Theme.accent)
                    .frame(width: max(6, geo.size.width * progress))
            }
        }
        .frame(height: 10)
        .blur(radius: blurred ? 4 : 0)
    }
}

struct GoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let sessionsThisWeek: Int
    let weeklyStreak: Int

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

                    if weeklyStreak > 0 {
                        HStack(spacing: 14) {
                            Image(systemName: "circle.hexagongrid.fill")
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
