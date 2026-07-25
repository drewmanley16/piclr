import SwiftUI

/// Pro "Insights" on the profile, set like a courtside stat sheet: tracked
/// uppercase labels on the left, scoreboard numerals on the right. Free users
/// get the first line for real; the rest render as sealed slots — the number
/// is there, just not readable yet. Tapping anywhere opens the full breakdown
/// sheet, which carries its own teaser treatment and unlock bar. Fed by
/// [[PlayInsights]]; only rendered when `insights.isReady`.
struct InsightsCard: View {
    let insights: PlayInsights
    let locked: Bool
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: { card }
        .buttonStyle(.plain)
        .accessibilityHint("See all insights")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatHeading("Insights")
                Spacer()
                if locked { ProLockBadge() }
            }
            CourtLineRule()
            VStack(spacing: 14) {
                ForEach(Array(insights.rows.enumerated()), id: \.element.id) { index, row in
                    // The first line is the free hook; the rest stay sealed.
                    rowView(row, sealed: locked && index > 0)
                }
            }
            CourtLineRule(weight: 2)
            HStack {
                Text("Full stat sheet")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(Theme.accent)
        }
        .cardStyle()
    }

    private func rowView(_ row: InsightRow, sealed: Bool) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if sealed {
                SealedStat(width: 72, size: 15)
            } else {
                Text(row.value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(row.positive ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}
