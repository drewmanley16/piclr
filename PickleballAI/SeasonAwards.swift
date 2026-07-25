import SwiftUI

/// A monthly award computed server-side by `compute_season_awards()` (top 3 per
/// category). Awards are global (across all piclr users), unlike the crew
/// leaderboard which is scoped per-viewer's follow graph — a distinct "winner"
/// per viewer wouldn't make sense for a prestige feature.
struct SeasonAward: Identifiable, Decodable, Hashable {
    let id: UUID
    let seasonKey: String
    let category: String
    let rank: Int
    let value: Int

    enum CodingKeys: String, CodingKey {
        case id
        case seasonKey = "season_key"
        case category
        case rank
        case value
    }

    var title: String {
        switch category {
        case "most_wins":         return "Most wins"
        case "most_active":       return "Most active"
        case "rivalry_champion":  return "Rivalry champion"
        default:                  return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var icon: String {
        switch category {
        case "most_wins":        return "trophy.fill"
        case "most_active":      return "figure.pickleball"
        case "rivalry_champion": return "flame.fill"
        default:                 return "medal.fill"
        }
    }

    /// What `value` counts, in the category's own units ("12 wins").
    var valueLabel: String {
        switch category {
        case "most_wins":        return "\(value) win\(value == 1 ? "" : "s")"
        case "most_active":      return "\(value) session\(value == 1 ? "" : "s")"
        case "rivalry_champion": return "\(value) rivalry win\(value == 1 ? "" : "s")"
        default:                 return "\(value)"
        }
    }

    /// "January 2026" from a "2026-01" season key.
    var seasonLabel: String {
        let parts = seasonKey.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return seasonKey }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        guard let date = Calendar.current.date(from: comps) else { return seasonKey }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// "Jul" from a "2026-07" season key, for tight stat-board labels.
    var monthAbbrev: String {
        let parts = seasonKey.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return seasonKey }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        guard let date = Calendar.current.date(from: comps) else { return seasonKey }
        return date.formatted(.dateTime.month(.abbreviated))
    }
}

/// Profile entry point for season awards, set as a mini stat board. Everyone
/// taps into the history; free users see the latest month live and older
/// seasons sealed behind Pro.
struct SeasonAwardsCard: View {
    let awards: [SeasonAward]
    let locked: Bool
    var onOpen: () -> Void = {}

    private var latest: SeasonAward? { awards.max(by: { $0.seasonKey < $1.seasonKey }) }
    private var bestRank: Int? { awards.map(\.rank).min() }

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                StatBoardHeader(title: "Season awards", locked: locked)
                CourtLineRule()
                HStack(spacing: 0) {
                    segments
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var segments: some View {
        if awards.isEmpty {
            // Season in play: the podium is still open — that's the pitch.
            StatSegment(value: Date().formatted(.dateTime.month(.abbreviated)), label: "In play", size: 22,
                        valueColor: Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatSegment(value: "Top 3", label: "To place", size: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if locked, let latest {
            StatSegment(value: "Top 3", label: "In \(latest.monthAbbrev)", size: 22, valueColor: Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatSegment(value: "", label: "All time", sealed: true, sealedWidth: 36, size: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            StatSegment(value: "\(awards.count)", label: awards.count == 1 ? "Award" : "Awards", size: 22,
                        valueColor: Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let bestRank {
                StatSegment(value: "#\(bestRank)", label: "Best finish", size: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Award history as a trophy case: the latest month's placement celebrates in
/// full (its rank settling into place on open — the sheet's one orchestrated
/// moment), older seasons sit sealed for free users with the month visible and
/// the award itself a dash slot. With no awards yet, the current season shows
/// its three open podium slots instead of a bare empty state.
struct SeasonAwardsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    /// Drives the latest award's settle-in. Starts true under Reduce Motion.
    @State private var medalSettled = false

    private var locked: Bool { subscriptions.showsLockedFeatures }
    /// The most recent month with an award — the free window into the feature.
    private var latestSeasonKey: String? { store.seasonAwards.map(\.seasonKey).max() }
    private var sealedCount: Int {
        store.seasonAwards.filter { $0.seasonKey != latestSeasonKey }.count
    }
    /// Awards grouped by month, newest first, ranks best-first within a month.
    private var seasons: [(key: String, awards: [SeasonAward])] {
        Dictionary(grouping: store.seasonAwards, by: \.seasonKey)
            .map { (key: $0.key, awards: $0.value.sorted { $0.rank < $1.rank }) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.seasonAwards.isEmpty {
                        openSeasonBoard
                    } else {
                        ForEach(Array(seasons.enumerated()), id: \.element.key) { index, season in
                            if index == 0 {
                                latestSeason(season)
                            } else {
                                pastSeason(season)
                            }
                        }
                    }
                    if locked {
                        ProTeaserUnlockBar(
                            context: .seasonAwards,
                            title: "Unlock your trophy case",
                            caption: sealedCount > 0
                                ? "\(sealedCount) past award\(sealedCount == 1 ? "" : "s") sealed in your trophy case."
                                : "Pro keeps every season's awards, forever."
                        )
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Season awards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadSeasonAwards() }
            .refreshable { await store.loadSeasonAwards() }
        }
        .trackProTeaser(.seasonAwards, locked: locked)
        .onAppear {
            if reduceMotion {
                medalSettled = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.2)) { medalSettled = true }
            }
        }
    }

    /// The latest month, celebrated in full — free for everyone.
    private func latestSeason(_ season: (key: String, awards: [SeasonAward])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatLabel("\(season.awards[0].seasonLabel) · Latest season")
            VStack(spacing: 0) {
                ForEach(Array(season.awards.enumerated()), id: \.element.id) { index, award in
                    if index > 0 { CourtLineRule().padding(.leading, 74) }
                    HStack(spacing: 16) {
                        Text("#\(award.rank)")
                            .font(.system(size: 30, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(award.rank == 1 ? Theme.accent : Theme.textPrimary)
                            .frame(width: 58, alignment: .leading)
                            .scaleEffect(medalSettled ? 1 : 0.4, anchor: .leading)
                            .opacity(medalSettled ? 1 : 0)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(award.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(award.valueLabel)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 16)
            .cardStyle(padding: 0)
        }
    }

    /// A past month: visible on the shelf, sealed for free users.
    private func pastSeason(_ season: (key: String, awards: [SeasonAward])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatLabel(season.awards[0].seasonLabel)
            VStack(spacing: 0) {
                ForEach(Array(season.awards.enumerated()), id: \.element.id) { index, award in
                    if index > 0 { CourtLineRule().padding(.leading, 58) }
                    SeasonAwardRow(award: award, sealed: locked && season.key != latestSeasonKey)
                }
            }
            .cardStyle(padding: 8)
        }
    }

    /// No awards yet: the current season's podium, slots open. The three
    /// categories render with awaiting-results slots — your name could be there.
    private var openSeasonBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatLabel("\(Date().formatted(.dateTime.month(.wide).year())) · In play")
            VStack(alignment: .leading, spacing: 14) {
                Text("The podium is open.")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                CourtLineRule()
                VStack(spacing: 13) {
                    openSlot("Most wins")
                    openSlot("Most active")
                    openSlot("Rivalry champion")
                }
                Text("Top 3 land here when the month ends.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .cardStyle()
        }
    }

    private func openSlot(_ category: String) -> some View {
        HStack {
            Text(category)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            SealedStat(width: 56, size: 14, showsLock: false)
        }
    }
}

private struct SeasonAwardRow: View {
    let award: SeasonAward
    /// Behind Pro for this (free) viewer: the month header stays visible, the
    /// rank and category render as sealed slots.
    var sealed = false

    var body: some View {
        HStack(spacing: 14) {
            if sealed {
                SealedStat(width: 32, size: 18, showsLock: false)
                    .frame(width: 44, alignment: .leading)
                SealedStat(width: 110, size: 15, showsLock: false)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("#\(award.rank)")
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(award.rank == 1 ? Theme.accent : Theme.textPrimary)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(award.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(award.valueLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .accessibilityElement(children: sealed ? .ignore : .combine)
        .accessibilityLabel(sealed ? "Locked award. Unlock with Pro." : "\(award.title), rank \(award.rank)")
    }
}
