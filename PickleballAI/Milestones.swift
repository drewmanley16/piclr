import SwiftUI

/// One achievement a player can unlock by playing more piclr. `Milestone.catalog`
/// is the full fixed set. Unlocked state is tracked server-side
/// (`AppStore.milestoneUnlocks`, backed by `milestone_unlocks`) rather than
/// recomputed live from [[SessionStats]] on every render: win-streak thresholds
/// aren't monotonic (a loss resets `currentStreak`), so a purely live snapshot
/// would appear to "re-lock" a badge the player already earned.
struct Milestone: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String

    static let catalog: [Milestone] = matchMilestones + weeklyStreakMilestones + winStreakMilestones + rivalryMilestones

    private static let matchMilestones: [Milestone] = [1, 10, 50, 100, 250].map {
        Milestone(id: "matches_\($0)", title: "\($0) match\($0 == 1 ? "" : "es") played",
                  detail: "Log \($0) match\($0 == 1 ? "" : "es").", icon: "figure.pickleball")
    }
    private static let weeklyStreakMilestones: [Milestone] = [4, 10, 26, 52].map {
        Milestone(id: "weekly_streak_\($0)", title: "\($0)-week streak",
                  detail: "Play at least once a week, \($0) weeks running.", icon: "circle.hexagongrid.fill")
    }
    private static let winStreakMilestones: [Milestone] = [3, 5, 10].map {
        Milestone(id: "win_streak_\($0)", title: "\($0)-match win streak",
                  detail: "Win \($0) matches in a row.", icon: "flame.fill")
    }
    private static let rivalryMilestones: [Milestone] = [
        Milestone(id: "first_rivalry_win", title: "First rivalry win",
                  detail: "Beat a rival for the first time.", icon: "trophy.fill"),
        Milestone(id: "rivalry_veteran", title: "Rivalry veteran",
                  detail: "Play 10 matches against a single rival.", icon: "person.2.fill")
    ]

    /// Milestone IDs satisfied by these stats right now — a snapshot, not
    /// cumulative history. Diff two snapshots (before/after a session post) to
    /// find newly-crossed thresholds; see `AppStore.detectAndUnlockMilestones`.
    static func satisfiedIDs(for stats: SessionStats) -> Set<String> {
        var ids: Set<String> = []
        for n in [1, 10, 50, 100, 250] where stats.matches >= n { ids.insert("matches_\(n)") }
        for n in [4, 10, 26, 52] where stats.longestWeeklyStreak >= n { ids.insert("weekly_streak_\(n)") }
        for n in [3, 5, 10] where stats.currentStreak >= n { ids.insert("win_streak_\(n)") }
        if stats.rivalries.contains(where: { $0.wins > 0 }) { ids.insert("first_rivalry_win") }
        if (stats.rivalries.map(\.games).max() ?? 0) >= 10 { ids.insert("rivalry_veteran") }
        return ids
    }
}

/// Profile entry point for the Milestones shelf. Locked for free users (opens
/// the paywall); Pro users tap into the full achievement list.
struct MilestonesCard: View {
    let unlockedCount: Int
    let locked: Bool
    var onUnlock: () -> Void = {}
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            if locked { onUnlock() } else { onOpen() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "medal.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Milestones")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if locked { ProLockBadge() }
                    }
                    Text("\(unlockedCount) of \(Milestone.catalog.count) unlocked")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

struct MilestonesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var loaded = false

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(Milestone.catalog.enumerated()), id: \.element.id) { index, milestone in
                        if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                        MilestoneRow(milestone: milestone, unlocked: store.milestoneUnlocks.contains(milestone.id))
                    }
                }
                .cardStyle(padding: 8)
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await store.loadMilestoneUnlocks()
                loaded = true
            }
            .refreshable { await store.loadMilestoneUnlocks() }
        }
    }
}

private struct MilestoneRow: View {
    let milestone: Milestone
    let unlocked: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: milestone.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(unlocked ? Theme.background : Theme.textTertiary)
                .frame(width: 36, height: 36)
                .background(unlocked ? Theme.accent : Theme.surfaceElevated, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(unlocked ? Theme.textPrimary : Theme.textSecondary)
                Text(milestone.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if unlocked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}
