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
    /// The threshold set in scoreboard numerals at the head of the row ("50",
    /// "1st") — the track header carries the units.
    let rung: String
    /// The rest of the row's phrase after the rung numeral ("matches played"),
    /// so the row reads as one line without repeating the number. `title`
    /// stays the standalone name used in unlock notifications.
    let rowLabel: String

    static let catalog: [Milestone] = tracks.flatMap(\.milestones)

    /// The four progression tracks, in display order. Each sheet section is one
    /// track, so the next rung always sits one step past the last one earned.
    static let tracks: [(title: String, milestones: [Milestone])] = [
        ("Matches", matchMilestones),
        ("Weekly streak", weeklyStreakMilestones),
        ("Win streak", winStreakMilestones),
        ("Rivalries", rivalryMilestones)
    ]

    private static let matchMilestones: [Milestone] = [1, 10, 50, 100, 250].map {
        Milestone(id: "matches_\($0)", title: "\($0) match\($0 == 1 ? "" : "es") played",
                  detail: "Log \($0) match\($0 == 1 ? "" : "es").", icon: "figure.pickleball",
                  rung: "\($0)", rowLabel: "match\($0 == 1 ? "" : "es") played")
    }
    private static let weeklyStreakMilestones: [Milestone] = [4, 10, 26, 52].map {
        Milestone(id: "weekly_streak_\($0)", title: "\($0)-week streak",
                  detail: "Play at least once a week, \($0) weeks running.", icon: "bolt.fill",
                  rung: "\($0)", rowLabel: "weeks in a row")
    }
    private static let winStreakMilestones: [Milestone] = [3, 5, 10].map {
        Milestone(id: "win_streak_\($0)", title: "\($0)-match win streak",
                  detail: "Win \($0) matches in a row.", icon: "flame.fill",
                  rung: "\($0)", rowLabel: "wins in a row")
    }
    private static let rivalryMilestones: [Milestone] = [
        Milestone(id: "first_rivalry_win", title: "First rivalry win",
                  detail: "Beat a rival for the first time.", icon: "trophy.fill",
                  rung: "1st", rowLabel: "rivalry win"),
        Milestone(id: "rivalry_veteran", title: "Rivalry veteran",
                  detail: "Play 10 matches against a single rival.", icon: "person.2.fill",
                  rung: "10", rowLabel: "matches vs one rival")
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

/// Profile entry point for the Milestones shelf. Free for everyone — the card
/// is a progress readout, not a teaser.
struct MilestonesCard: View {
    let unlockedCount: Int
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                StatBoardHeader(title: "Milestones")
                CourtLineRule()
                HStack(spacing: 0) {
                    StatSegment(value: "\(unlockedCount)", label: "Earned", size: 22,
                                valueColor: unlockedCount > 0 ? Theme.accent : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatSegment(value: "\(Milestone.catalog.count)", label: "Total", size: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

/// The full achievement list, one section per track. Every badge is earnable by
/// every player — a row is either yours or the next thing to chase.
struct MilestonesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Milestone.tracks, id: \.title) { track in
                        VStack(alignment: .leading, spacing: 10) {
                            StatHeading(track.title)
                            VStack(spacing: 0) {
                                ForEach(Array(track.milestones.enumerated()), id: \.element.id) { index, milestone in
                                    if index > 0 { CourtLineRule().padding(.leading, 66) }
                                    MilestoneRow(
                                        milestone: milestone,
                                        unlocked: store.milestoneUnlocks.contains(milestone.id)
                                    )
                                }
                            }
                            .cardStyle(padding: 8)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadMilestoneUnlocks() }
            .refreshable { await store.loadMilestoneUnlocks() }
        }
    }
}

private struct MilestoneRow: View {
    let milestone: Milestone
    let unlocked: Bool

    var body: some View {
        HStack(spacing: 14) {
            // The threshold is the row's hero: a scoreboard numeral, lit when
            // the badge is yours.
            Text(milestone.rung)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(unlocked ? Theme.accent : Theme.textTertiary)
                .frame(width: 44, alignment: .leading)
            Text(milestone.rowLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(unlocked ? Theme.textPrimary : Theme.textSecondary)
            Spacer()
            if unlocked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 13)
    }
}
