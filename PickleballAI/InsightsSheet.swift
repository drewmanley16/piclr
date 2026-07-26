import SwiftUI

/// The Pro "Insights" breakdown, opened from the profile [[InsightsCard]] and
/// set as a full stat sheet: scoreboard hero up top, split tables beneath. For
/// free users it doubles as its own teaser: every table's labels render, the
/// first value of each split is real, and the rest sit as sealed dash slots
/// above the unlock bar. Recomputes [[PlayInsights]] from the signed-in user's
/// sessions, like `StatsSheet`.
struct InsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var subscriptions: SubscriptionStore
    /// Drives the hero record's roll-up from 0–0 on appear (the sheet's one
    /// orchestrated moment). Starts true under Reduce Motion.
    @State private var heroSettled = false

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
        .onAppear {
            if reduceMotion {
                heroSettled = true
            } else {
                withAnimation(.snappy(duration: 0.8).delay(0.15)) { heroSettled = true }
            }
        }
    }

    private func clutchHero(_ clutch: ClutchStats) -> some View {
        VStack(spacing: 14) {
            StatLabel("Close games · decided by 2 or fewer")
            // The close record stays free: it's the hook the profile card
            // already reveals. Only the deeper cuts seal.
            Text(heroSettled ? clutch.closeRecord : "0–0")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
            HStack(spacing: 0) {
                StatSegment(value: "\(clutch.closeWinRate)%", label: "Close win rate",
                            sealed: locked, sealedWidth: 44, size: 20, alignment: .center)
                    .frame(maxWidth: .infinity)
                heroDivider
                StatSegment(value: clutch.avgMarginLabel, label: "Avg margin",
                            sealed: locked, sealedWidth: 44, size: 20, alignment: .center)
                    .frame(maxWidth: .infinity)
                heroDivider
                StatSegment(value: "\(clutch.decidedMatches)", label: "Matches",
                            sealed: locked, sealedWidth: 32, size: 20, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }

    private var heroDivider: some View {
        Rectangle().fill(Theme.courtLine).frame(width: 1, height: 32)
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
                StatHeading(title)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 {
                            CourtLineRule().padding(.leading, showsAvatar ? 56 : 14)
                        }
                        // The first value of every split is the free hook; the
                        // rest stay sealed for free users.
                        SplitRow(record: record, showsAvatar: showsAvatar, sealed: locked && index > 0)
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
    var sealed = false

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
            if sealed {
                SealedStat(width: 76, size: 15)
            } else {
                HStack(spacing: 10) {
                    Text(record.recordLine)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(record.leading ? Theme.accent : Theme.textPrimary)
                    Text("\(record.winRate)%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
