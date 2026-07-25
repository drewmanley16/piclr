import SwiftUI

/// Pro "Insights" surface on the profile — LinkedIn-style tease. Free users see
/// the first insight for real, the rest **blurred**; tapping opens the full
/// breakdown sheet, which carries its own teaser treatment and unlock bar.
/// Pro users see every value. Fed by [[PlayInsights]]; only rendered when
/// `insights.isReady`.
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
            header
            VStack(spacing: 0) {
                ForEach(Array(insights.rows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    // Reveal the first row as the hook; blur the rest for free users.
                    rowView(item, blurred: locked && index > 0)
                }
            }
            if locked { unlockButton }
        }
        .cardStyle()
    }

    private var header: some View {
        HStack {
            Label("Insights", systemImage: "chart.bar.xaxis")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if locked {
                ProLockBadge()
            } else {
                Text("Details")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var unlockButton: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.footnote.weight(.bold))
            Text("Unlock all insights").font(.subheadline.weight(.bold))
        }
        .foregroundStyle(Theme.background)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(Theme.accent, in: Capsule())
        .padding(.top, 2)
    }

    private func rowView(_ row: InsightRow, blurred: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(locked ? row.lockedSubtitle : row.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(row.positive ? Theme.accent : Theme.textPrimary)
                .blur(radius: blurred ? 5 : 0)
                .opacity(blurred ? 0.85 : 1)
                .accessibilityLabel(blurred ? "Locked" : row.value)
        }
        .padding(.vertical, 10)
    }
}
