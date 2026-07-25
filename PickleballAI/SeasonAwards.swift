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
}

/// Profile entry point for season awards. Everyone taps into the history;
/// free users see the latest month live and older seasons sealed behind Pro.
struct SeasonAwardsCard: View {
    let awards: [SeasonAward]
    let locked: Bool
    var onOpen: () -> Void = {}

    private var subtitle: String {
        if awards.isEmpty { return "No awards yet" }
        if locked, let latest = awards.max(by: { $0.seasonKey < $1.seasonKey }) {
            return "You placed top 3 in \(latest.seasonLabel)"
        }
        return "\(awards.count) award\(awards.count == 1 ? "" : "s") earned"
    }

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rosette")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Season awards")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if locked { ProLockBadge() }
                    }
                    Text(subtitle)
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

/// Award history, doubling as its own teaser for free users: the latest month's
/// placement celebrates in full, older seasons sit sealed (month visible, award
/// blurred) — a trophy case accumulating behind glass.
struct SeasonAwardsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore

    private var locked: Bool { subscriptions.showsLockedFeatures }
    /// The most recent month with an award — the free window into the feature.
    private var latestSeasonKey: String? { store.seasonAwards.map(\.seasonKey).max() }
    private var sealedCount: Int {
        store.seasonAwards.filter { $0.seasonKey != latestSeasonKey }.count
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.seasonAwards.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.seasonAwards.enumerated()), id: \.element.id) { index, award in
                                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                                SeasonAwardRow(award: award, sealed: locked && award.seasonKey != latestSeasonKey)
                            }
                        }
                        .cardStyle(padding: 8)
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
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rosette")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("No awards yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Awards are handed out at the start of each month for the month just played.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct SeasonAwardRow: View {
    let award: SeasonAward
    /// Behind Pro for this (free) viewer: the month stays visible, the award
    /// itself (category, rank) blurs behind a lock.
    var sealed = false

    private var rankColor: Color {
        switch award.rank {
        case 1:  return Theme.accent
        case 2:  return Theme.surfaceElevated
        default: return Theme.loss.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: sealed ? "lock.fill" : award.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(sealed ? Theme.textTertiary : (award.rank == 1 ? Theme.background : Theme.textPrimary))
                .frame(width: 36, height: 36)
                .background(sealed ? Theme.surfaceElevated : rankColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(award.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .proLocked(sealed)
                HStack(spacing: 4) {
                    Text("#\(award.rank)")
                        .proLocked(sealed)
                    Text("· \(award.seasonLabel)")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}
