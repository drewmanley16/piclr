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
    /// track so a free user can see the next rung sitting one step past the
    /// starter badge they own.
    static let tracks: [(title: String, milestones: [Milestone])] = [
        ("Matches", matchMilestones),
        ("Weekly streak", weeklyStreakMilestones),
        ("Win streak", winStreakMilestones),
        ("Rivalries", rivalryMilestones)
    ]

    /// The free starter set: the first rung of each track. Free users can earn
    /// and keep these four, so every player samples every badge type — and the
    /// next rung of each track sits one step away behind Pro.
    static let freeIDs: Set<String> = ["matches_1", "weekly_streak_4", "win_streak_3", "first_rivalry_win"]

    var isFree: Bool { Milestone.freeIDs.contains(id) }

    private static let matchMilestones: [Milestone] = [1, 10, 50, 100, 250].map {
        Milestone(id: "matches_\($0)", title: "\($0) match\($0 == 1 ? "" : "es") played",
                  detail: "Log \($0) match\($0 == 1 ? "" : "es").", icon: "figure.pickleball",
                  rung: "\($0)", rowLabel: "match\($0 == 1 ? "" : "es") played")
    }
    private static let weeklyStreakMilestones: [Milestone] = [4, 10, 26, 52].map {
        Milestone(id: "weekly_streak_\($0)", title: "\($0)-week streak",
                  detail: "Play at least once a week, \($0) weeks running.", icon: "circle.hexagongrid.fill",
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

/// Profile entry point for the Milestones shelf. Everyone taps into the list;
/// free users see the starter badges live and the rest sealed behind Pro.
struct MilestonesCard: View {
    let unlockedCount: Int
    let locked: Bool
    /// Badges already earned but sealed behind Pro (free users only).
    var earnedLockedCount: Int = 0
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                StatBoardHeader(title: "Milestones", locked: locked)
                CourtLineRule()
                HStack(spacing: 0) {
                    StatSegment(value: "\(unlockedCount)", label: "Earned", size: 22,
                                valueColor: unlockedCount > 0 ? Theme.accent : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if earnedLockedCount > 0 {
                        StatSegment(value: "\(earnedLockedCount)", label: "Locked", size: 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    StatSegment(value: "\(Milestone.catalog.count)", label: "Total", size: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

/// The full achievement list, doubling as its own teaser for free users: the
/// starter badges render live, Pro badges show sealed — with an "Earned" chip
/// on ones the player has already crossed but can't claim yet.
struct MilestonesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var loaded = false

    private var locked: Bool { subscriptions.showsLockedFeatures }
    private var earnedLockedCount: Int { store.milestoneUnlocks.subtracting(Milestone.freeIDs).count }

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
                                        unlocked: store.milestoneUnlocks.contains(milestone.id),
                                        sealed: locked && !milestone.isFree
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
            // Pinned, not in the scroll: the list runs long and the unlock
            // moment shouldn't live below the fold.
            .safeAreaInset(edge: .bottom) {
                if locked {
                    ProTeaserUnlockBar(
                        context: .milestones,
                        title: "Unlock all \(Milestone.catalog.count) milestones",
                        caption: earnedLockedCount > 0
                            ? "\(earnedLockedCount) badge\(earnedLockedCount == 1 ? " you've already earned is" : "s you've already earned are") waiting."
                            : nil
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .background(Theme.background)
                }
            }
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await store.loadMilestoneUnlocks()
                loaded = true
            }
            .refreshable { await store.loadMilestoneUnlocks() }
        }
        .trackProTeaser(.milestones, locked: locked)
    }
}

private struct MilestoneRow: View {
    let milestone: Milestone
    let unlocked: Bool
    /// Behind Pro for this (free) viewer. An earned-but-sealed badge shows an
    /// "Earned" chip instead of its checkmark — yours, just locked.
    var sealed = false

    private var showsUnlocked: Bool { unlocked && !sealed }

    var body: some View {
        HStack(spacing: 14) {
            // The threshold is the row's hero: a scoreboard numeral, lit when
            // the badge is yours.
            Text(milestone.rung)
                .font(Theme.scoreboard(18))
                .foregroundStyle(showsUnlocked ? Theme.accent : Theme.textTertiary)
                .frame(width: 44, alignment: .leading)
            Text(milestone.rowLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(showsUnlocked ? Theme.textPrimary : Theme.textSecondary)
            Spacer()
            if showsUnlocked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else if sealed && unlocked {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    Text("EARNED").font(.caption2.weight(.heavy))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Theme.accentSoft, in: Capsule())
            } else if sealed {
                Image(systemName: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 13)
    }
}
