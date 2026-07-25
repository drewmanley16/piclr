import SwiftUI

/// Pro deep-dive into one head-to-head history, opened from `RivalsSheet`.
/// Free users get intercepted at the tap (`PaywallContext.rivalryInsights`);
/// this view only ever renders for Pro users. Fed entirely by `Rivalry.log`,
/// so no extra network round-trip beyond what `RivalsSheet` already loaded.
struct RivalryInsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rivalry: Rivalry

    var body: some View {
        ProfileNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    recordTiles
                    timelineCard
                    if let opener = openerLine {
                        Text(opener)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(rivalry.person.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProfileAvatar(person: rivalry.person, size: 52, unlinked: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(rivalry.person.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(rivalry.momentumLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(momentumColor)
            }
            Spacer()
        }
    }

    private var momentumColor: Color {
        if rivalry.streak > 0 { return Theme.accent }
        if rivalry.streak < 0 { return Theme.loss }
        return Theme.textSecondary
    }

    private var recordTiles: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatPill(title: "Record", value: rivalry.recordLine, systemImage: "flag.checkered")
                StatPill(title: "Win rate", value: "\(rivalry.winRate)%", systemImage: "chart.line.uptrend.xyaxis")
            }
            HStack(spacing: 12) {
                StatPill(title: "Best streak", value: "\(rivalry.bestStreak)", systemImage: "bolt.fill")
                StatPill(title: "Games", value: "\(rivalry.games)", systemImage: "number")
            }
        }
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent meetings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 6) {
                ForEach(Array(timelineGames.enumerated()), id: \.element.id) { _, game in
                    Circle()
                        .fill(game.won ? Theme.accent : Theme.loss)
                        .frame(width: 14, height: 14)
                }
                Spacer(minLength: 0)
            }
            Text("Oldest → newest, last \(timelineGames.count) of \(rivalry.games)")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .cardStyle()
    }

    /// Oldest-to-newest, capped so the dot row doesn't wrap on a small screen.
    private var timelineGames: [RivalryGame] {
        Array(rivalry.log.reversed().suffix(12))
    }

    private var openerLine: String? {
        guard rivalry.games >= 2 else { return nil }
        return "First met \(rivalry.firstPlayed.formatted(.dateTime.month(.abbreviated).day().year()))."
    }
}
