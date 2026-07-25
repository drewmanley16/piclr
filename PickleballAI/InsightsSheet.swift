import SwiftUI

/// The Pro "Insights" breakdown, opened from the profile [[InsightsCard]].
/// Shows the full tables the card only teases: clutch/margin hero, and
/// per-court, per-time, per-partner, and first-game splits. For free users it
/// doubles as its own teaser: every table's labels render, the first value of
/// each split is real, and the rest blur behind the unlock bar. Recomputes
/// [[PlayInsights]] from the signed-in user's sessions, like `StatsSheet`.
struct InsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var subscriptions: SubscriptionStore

    private var locked: Bool { subscriptions.showsLockedFeatures }

    private var insights: PlayInsights {
        PlayInsights(sessions: store.mySessions, playerID: store.currentProfile?.id)
    }

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    let i = insights
                    if i.clutch.hasData { clutchHero(i.clutch) }
                    SplitSection(title: "By court", records: i.courts, locked: locked)
                    SplitSection(title: "By time of day", records: i.timeOfDay, locked: locked)
                    SplitSection(title: "By partner", records: i.partners, showsAvatar: true, locked: locked)
                    if i.firstGames.games > 0 {
                        SplitSection(
                            title: "Session form",
                            caption: "How you start vs. once you've settled in",
                            records: [i.firstGames, i.laterGames].filter { $0.games > 0 },
                            locked: locked
                        )
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            // Pinned, not in the scroll: the splits run long and the unlock
            // moment shouldn't live below the fold.
            .safeAreaInset(edge: .bottom) {
                if locked {
                    ProTeaserUnlockBar(
                        context: .insights,
                        title: "Unlock all insights",
                        caption: "Your clutch record, best court, and best partner are in."
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .background(Theme.background)
                }
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .trackProTeaser(.insights, locked: locked)
    }

    private func clutchHero(_ clutch: ClutchStats) -> some View {
        VStack(spacing: 16) {
            // The close record stays free: it's the hook the profile card
            // already reveals. Only the deeper cuts blur.
            Text(clutch.closeRecord)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text("IN CLOSE GAMES (≤2 POINTS)")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                HeroStat(value: "\(clutch.closeWinRate)%", label: "Close win rate")
                Divider().frame(height: 28).overlay(Theme.hairline)
                HeroStat(value: clutch.avgMarginLabel, label: "Avg margin")
                Divider().frame(height: 28).overlay(Theme.hairline)
                HeroStat(value: "\(clutch.decidedMatches)", label: "Matches")
            }
            .proLocked(locked)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }
}

private struct HeroStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SplitSection: View {
    let title: String
    var caption: String?
    let records: [SplitRecord]
    var showsAvatar = false
    var locked = false

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, showsAvatar ? 56 : 14) }
                        // The first value of every split is the free hook; the
                        // rest blur for free users.
                        SplitRow(record: record, showsAvatar: showsAvatar, blurred: locked && index > 0)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
    }
}

private struct SplitRow: View {
    let record: SplitRecord
    var showsAvatar = false
    var blurred = false

    var body: some View {
        HStack(spacing: 12) {
            if showsAvatar, let person = record.person {
                ProfileAvatar(person: person, size: 34, unlinked: true)
            }
            Text(record.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                Text(record.recordLine)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(record.leading ? Theme.accent : Theme.textPrimary)
                Text("\(record.winRate)%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .proLocked(blurred)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
