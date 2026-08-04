import SwiftUI

/// One rung on a progression track — a threshold the player crosses by playing.
///
/// Unlocked state is tracked server-side (`AppStore.milestoneUnlocks`, backed by
/// `milestone_unlocks`) rather than recomputed live from [[SessionStats]] on
/// every render: win-streak thresholds aren't monotonic (a loss resets
/// `currentStreak`), so a purely live snapshot would appear to "re-lock" a badge
/// the player already earned.
struct Milestone: Identifiable, Hashable {
    let id: String
    /// Standalone name — used in the unlock notification and on the profile card.
    let title: String
    /// What it takes. Read out to VoiceOver on a rung the player hasn't reached.
    let detail: String
    /// The numeral printed under the rail node ("50", "1st").
    let rung: String
    /// The bar this rung sits at, measured in its lane's metric.
    let threshold: Int
}

/// A single metric the player advances along, plus the rungs sitting on it.
/// Most tracks are one lane; Rivalries has two, because "rivals beaten" and
/// "matches against one rival" are different numbers that can't share a rail.
struct MilestoneLane: Identifiable {
    /// Caption beside the lane's current value, count-aware ("1 match played").
    let unit: (Int) -> String
    /// Noun for the distance-to-go line ("36 more **matches**").
    let step: (Int) -> String
    /// Where the player sits on this lane right now.
    let value: (SessionStats) -> Int
    let milestones: [Milestone]

    var id: String { milestones.first?.id ?? "" }
}

/// One card in the sheet: a themed group of lanes.
struct MilestoneTrack: Identifiable {
    let title: String
    let icon: String
    let lanes: [MilestoneLane]

    var id: String { title }
    var milestones: [Milestone] { lanes.flatMap(\.milestones) }
}

// MARK: - Catalog

extension Milestone {
    /// The progression tracks, in display order.
    static let tracks: [MilestoneTrack] = [
        MilestoneTrack(title: "Matches", icon: "figure.pickleball", lanes: [
            MilestoneLane(
                unit: { "\($0 == 1 ? "match" : "matches") played" },
                step: { $0 == 1 ? "match" : "matches" },
                value: { $0.matches },
                milestones: [1, 10, 50, 100, 250].map {
                    Milestone(id: "matches_\($0)",
                              title: "\($0) match\($0 == 1 ? "" : "es") played",
                              detail: "Log \($0) match\($0 == 1 ? "" : "es").",
                              rung: "\($0)", threshold: $0)
                })
        ]),
        MilestoneTrack(title: "Weekly streak", icon: "bolt.fill", lanes: [
            MilestoneLane(
                unit: { $0 == 1 ? "week in a row" : "weeks in a row" },
                step: { $0 == 1 ? "week" : "weeks" },
                value: { $0.longestWeeklyStreak },
                milestones: [4, 10, 26, 52].map {
                    Milestone(id: "weekly_streak_\($0)",
                              title: "\($0)-week streak",
                              detail: "Play at least once a week, \($0) weeks running.",
                              rung: "\($0)", threshold: $0)
                })
        ]),
        MilestoneTrack(title: "Win streak", icon: "flame.fill", lanes: [
            MilestoneLane(
                unit: { $0 == 1 ? "win in a row" : "wins in a row" },
                step: { $0 == 1 ? "win" : "wins" },
                value: { $0.currentStreak },
                milestones: [3, 5, 10].map {
                    Milestone(id: "win_streak_\($0)",
                              title: "\($0)-match win streak",
                              detail: "Win \($0) matches in a row.",
                              rung: "\($0)", threshold: $0)
                })
        ]),
        MilestoneTrack(title: "Rivalries", icon: "trophy.fill", lanes: [
            MilestoneLane(
                unit: { $0 == 1 ? "rival beaten" : "rivals beaten" },
                step: { $0 == 1 ? "win over a rival" : "wins over rivals" },
                value: { $0.rivalries.filter { $0.wins > 0 }.count },
                milestones: [Milestone(id: "first_rivalry_win", title: "First rivalry win",
                                       detail: "Beat a rival for the first time.",
                                       rung: "1st", threshold: 1)]),
            MilestoneLane(
                unit: { $0 == 1 ? "match vs one rival" : "matches vs one rival" },
                step: { $0 == 1 ? "matchup" : "matchups" },
                value: { $0.rivalries.map(\.games).max() ?? 0 },
                milestones: [Milestone(id: "rivalry_veteran", title: "Rivalry veteran",
                                       detail: "Play 10 matches against a single rival.",
                                       rung: "10", threshold: 10)])
        ])
    ]

    static let catalog: [Milestone] = tracks.flatMap(\.milestones)

    /// Milestone IDs satisfied by these stats right now — a snapshot, not
    /// cumulative history. Diff two snapshots (before/after a session post) to
    /// find newly-crossed thresholds; see `AppStore.unlockNewlyCrossedMilestones`.
    static func satisfiedIDs(for stats: SessionStats) -> Set<String> {
        var ids: Set<String> = []
        for lane in tracks.flatMap(\.lanes) {
            let value = lane.value(stats)
            for milestone in lane.milestones where value >= milestone.threshold {
                ids.insert(milestone.id)
            }
        }
        return ids
    }

    /// What the shelf shows as earned: what the server has recorded, plus what
    /// the player's stats already satisfy. The union keeps the UI honest in the
    /// window before `reconcileMilestoneUnlocks` writes a freshly-crossed rung.
    static func earnedIDs(for stats: SessionStats, unlocked: Set<String>) -> Set<String> {
        satisfiedIDs(for: stats).union(unlocked).intersection(Set(catalog.map(\.id)))
    }

    /// The rung the player is closest to crossing — the profile card's hook.
    /// `nil` once every milestone is earned.
    static func closest(for stats: SessionStats, unlocked: Set<String>) -> MilestoneProgress? {
        var best: MilestoneProgress?
        for lane in tracks.flatMap(\.lanes) {
            let value = lane.value(stats)
            guard let next = lane.nextRung(value: value, unlocked: unlocked) else { continue }
            let fraction = min(1, Double(value) / Double(next.threshold))
            if fraction > (best?.fraction ?? -1) {
                best = MilestoneProgress(milestone: next, value: value, fraction: fraction,
                                         unit: lane.unit(next.threshold))
            }
        }
        return best
    }
}

/// How far along the player is toward one specific rung.
struct MilestoneProgress {
    let milestone: Milestone
    let value: Int
    let fraction: Double
    /// Plural unit noun for the target ("matches played").
    let unit: String
}

// MARK: - Rail math

extension MilestoneLane {
    func isEarned(_ milestone: Milestone, value: Int, unlocked: Set<String>) -> Bool {
        unlocked.contains(milestone.id) || value >= milestone.threshold
    }

    /// The next rung to chase — the first the player neither owns nor satisfies.
    func nextRung(value: Int, unlocked: Set<String>) -> Milestone? {
        milestones.first { !isEarned($0, value: value, unlocked: unlocked) }
    }

    /// How much of the rail segment leading into node `index` is painted, 0–1.
    /// Every node has one, including the first — without a leading stub a player
    /// three quarters of the way to the opening rung would stare at an empty
    /// rail.
    func segmentFill(upTo index: Int, value: Int, unlocked: Set<String>) -> Double {
        guard let first = milestones.first else { return 0 }
        guard index > 0 else {
            if isEarned(first, value: value, unlocked: unlocked) { return 1 }
            return clamp(Double(value) / Double(first.threshold))
        }
        return clamp(position(value: value, unlocked: unlocked) - Double(index - 1))
    }

    /// Where the player sits in rung-index space (0 = first node). Interpolates
    /// between rungs so a rail reads as "most of the way to 50", not a step
    /// function.
    ///
    /// Never retreats below the furthest *earned* node: `currentStreak` drops to
    /// zero on a loss, and a rail that drained back to the start would read as
    /// losing badges the player still owns.
    private func position(value: Int, unlocked: Set<String>) -> Double {
        guard let last = milestones.last, milestones.count > 1 else { return 0 }
        let live: Double
        if value >= last.threshold {
            live = Double(milestones.count - 1)
        } else if let index = milestones.lastIndex(where: { value >= $0.threshold }) {
            let lower = Double(milestones[index].threshold)
            let upper = Double(milestones[index + 1].threshold)
            live = Double(index) + (Double(value) - lower) / (upper - lower)
        } else {
            live = 0  // short of the first rung; the distance-to-go line carries it
        }
        let earned = Double(milestones.lastIndex { unlocked.contains($0.id) } ?? 0)
        return max(live, earned)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

// MARK: - Profile card

/// Profile entry point for the shelf. Leads with the rung the player is closest
/// to crossing — a reason to tap in, where a bare earned/total count was just a
/// scoreboard.
struct MilestonesCard: View {
    let earnedCount: Int
    /// The closest unearned rung, or `nil` once the shelf is complete.
    let nextUp: MilestoneProgress?
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                StatBoardHeader(title: "Milestones")
                CourtLineRule()
                if let nextUp {
                    nextUpBlock(nextUp)
                } else {
                    completeBlock
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func nextUpBlock(_ next: MilestoneProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EyebrowLabel("NEXT UP")
            Text(next.milestone.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            RailBar(fraction: next.fraction)
            HStack {
                Text("\(next.value) of \(next.milestone.threshold)")
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(earnedCount) of \(Milestone.catalog.count) earned")
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.caption.weight(.bold))
            .monospacedDigit()
        }
    }

    private var completeBlock: some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(Theme.accent)
            Text("All \(Milestone.catalog.count) milestones earned")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Sheet

/// The full shelf: one card per track, each a rail the player can see themselves
/// standing on. Free for everyone.
struct MilestonesSheet: View {
    let stats: SessionStats

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var loaded = false

    private var unlocked: Set<String> { store.milestoneUnlocks }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if loaded || !unlocked.isEmpty {
                        ForEach(Milestone.tracks) { track in
                            MilestoneTrackCard(track: track, stats: stats, unlocked: unlocked)
                        }
                    } else {
                        // The catalog is fixed, so there's no empty state to
                        // show — only the unlocked set is in flight. Skeletons
                        // beat rendering every rung as locked and letting them
                        // pop to earned a beat later.
                        ForEach(Milestone.tracks) { _ in SkeletonList(rows: 3) }
                    }
                }
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

private struct MilestoneTrackCard: View {
    let track: MilestoneTrack
    let stats: SessionStats
    let unlocked: Set<String>

    private var earnedCount: Int {
        track.lanes.reduce(0) { total, lane in
            let value = lane.value(stats)
            return total + lane.milestones.filter { lane.isEarned($0, value: value, unlocked: unlocked) }.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ForEach(Array(track.lanes.enumerated()), id: \.element.id) { index, lane in
                if index > 0 { CourtLineRule() }
                MilestoneLaneView(lane: lane, value: lane.value(stats), unlocked: unlocked)
            }
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: track.icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accentSoft, in: Circle())
            StatHeading(track.title)
            Spacer()
            Text("\(earnedCount) of \(track.milestones.count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One metric: where the player stands, the rail of rungs, and the gap to the
/// next one.
private struct MilestoneLaneView: View {
    let lane: MilestoneLane
    let value: Int
    let unlocked: Set<String>

    private var next: Milestone? { lane.nextRung(value: value, unlocked: unlocked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(value)")
                    .font(Theme.scoreboard(30))
                    .foregroundStyle(value > 0 ? Theme.accent : Theme.textTertiary)
                Text(lane.unit(value))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)

            MilestoneRail(lane: lane, value: value, unlocked: unlocked)

            if let next {
                let remaining = next.threshold - value
                Text("\(remaining) more \(lane.step(remaining)) to unlock \(next.rung)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                    Text(lane.milestones.count == 1 ? "Earned" : "Every rung earned")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// The progression rail: a node per rung, lime up to where the player has
/// reached and dim beyond. Rungs are spaced evenly rather than proportionally —
/// 1 → 250 on a true number line would smudge the first three into one.
private struct MilestoneRail: View {
    let lane: MilestoneLane
    let value: Int
    let unlocked: Set<String>

    private let nodeSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(lane.milestones.enumerated()), id: \.element.id) { index, milestone in
                RailBar(fraction: lane.segmentFill(upTo: index, value: value, unlocked: unlocked))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                    .padding(.top, nodeSize / 2 - 1.5)
                nodeColumn(milestone)
            }
        }
    }

    private func nodeColumn(_ milestone: Milestone) -> some View {
        let earned = lane.isEarned(milestone, value: value, unlocked: unlocked)
        let isNext = next?.id == milestone.id
        return VStack(spacing: 8) {
            node(earned: earned, isNext: isNext)
            Text(milestone.rung)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(earned ? Theme.textPrimary : Theme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(earned
                            ? "\(milestone.title), earned"
                            : "\(milestone.title), not yet earned. \(milestone.detail)")
    }

    private var next: Milestone? { lane.nextRung(value: value, unlocked: unlocked) }

    /// Three states told by shape as well as color, so the rail still reads
    /// without color vision: filled with a check (earned), ringed with a dot
    /// (next up), bare (out of reach).
    private func node(earned: Bool, isNext: Bool) -> some View {
        ZStack {
            Circle().fill(earned ? Theme.accent : Theme.surfaceElevated)
            if isNext {
                Circle().strokeBorder(Theme.accent, lineWidth: 2)
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
            }
            if earned {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.background)
            }
        }
        .frame(width: nodeSize, height: nodeSize)
    }
}

// MARK: - Shared bits

/// Flat progress bar: chalk-line track, lime fill.
private struct RailBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.courtLine)
                Capsule().fill(Theme.accent)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Small all-caps kicker above a card's lead line.
private struct EyebrowLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}
