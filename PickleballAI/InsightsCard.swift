import SwiftUI

/// Pro "Insights" surface on the profile: clutch record, point margin, best
/// court, best time. Locked-but-visible — free users see the real rows with the
/// values redacted and tap through to the paywall; Pro users see the numbers.
/// Fed by [[PlayInsights]]; only rendered when `insights.isReady`.
struct InsightsCard: View {
    let insights: PlayInsights
    let locked: Bool
    var onUnlock: () -> Void = {}

    var body: some View {
        if locked {
            Button {
                Haptics.tap()
                onUnlock()
            } label: { card }
            .buttonStyle(.plain)
            .accessibilityHint("Unlock the full breakdown with Pro")
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Insights", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if locked { ProLockBadge() }
            }

            VStack(spacing: 0) {
                ForEach(Array(insights.rows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    rowView(item)
                }
            }

            if locked {
                HStack(spacing: 6) {
                    Text("Unlock every split")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            }
        }
        .cardStyle()
    }

    private func rowView(_ row: InsightRow) -> some View {
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

            if locked {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 52, height: 18)
                    .overlay(
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    )
                    .accessibilityLabel("Locked")
            } else {
                Text(row.value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(row.positive ? Theme.accent : Theme.textPrimary)
            }
        }
        .padding(.vertical, 10)
    }
}
