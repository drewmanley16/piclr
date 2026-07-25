import SwiftUI

/// Shared pieces of the Pro teaser experience, in the app's courtside-scoreboard
/// voice. Free users open the *real* feature sheet filled with their real data:
/// the free slice renders normally, premium values show as `SealedStat` slots
/// (the number's slot exists, the number is waiting), and one
/// `ProTeaserUnlockBar` opens the paywall for that feature. The pitch is the
/// user's own numbers, not marketing copy.
extension View {
    /// Blur-locks premium content whose *shape* is the tease (charts). For plain
    /// numbers prefer `SealedStat` — crisp dashes over smeared pixels.
    @ViewBuilder
    func proLocked(_ locked: Bool = true) -> some View {
        if locked {
            self.blur(radius: 5)
                .opacity(0.85)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Locked. Unlock with Pro.")
        } else {
            self
        }
    }

    /// Capture one `pro_teaser_viewed` per appearance of a locked teaser sheet.
    func trackProTeaser(_ context: PaywallContext, locked: Bool) -> some View {
        onAppear {
            guard locked else { return }
            Analytics.capture(.proTeaserViewed, [Analytics.Property.context: context.id])
        }
    }
}

// MARK: - Stat board kit

/// Micro label under or beside a scoreboard numeral: uppercase, tracked, small.
struct StatLabel: View {
    let text: String
    var color: Color = Theme.textSecondary

    init(_ text: String, color: Color = Theme.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(1.3)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Card/section heading on Pro stat boards ("INSIGHTS", "BY COURT").
struct StatHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.heavy))
            .tracking(1.5)
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Chalk line between board sections. `weight: 2` is the emphasis rule (the
/// baseline before a footer, the net across the weekly board).
struct CourtLineRule: View {
    var weight: CGFloat = 1

    var body: some View {
        Rectangle().fill(Theme.courtLine).frame(height: weight)
    }
}

/// A locked value's slot: fixed placeholder dashes in the scoreboard face, so
/// the board clearly *has* a number here that the viewer can't read yet. The
/// placeholder never derives from the real value, so nothing leaks (not even
/// digit count). `showsLock: false` is the "awaiting results" variant for
/// values that don't exist yet (an open season) rather than locked ones.
struct SealedStat: View {
    var placeholder = "– –"
    var size: CGFloat = 16
    var showsLock = true

    var body: some View {
        HStack(spacing: 5) {
            Text(placeholder)
                .font(Theme.scoreboard(size))
                .foregroundStyle(Theme.textTertiary)
            if showsLock {
                Image(systemName: "lock.fill")
                    .font(.system(size: max(size * 0.5, 8), weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsLock ? "Locked. Unlock with Pro." : "Awaiting results.")
    }
}

/// One numeral + label block on a stat board. Numbers are the heroes: the value
/// sets in the scoreboard face, the label goes small and uppercase beneath it.
struct StatSegment: View {
    let value: String
    let label: String
    var sealed = false
    var placeholder = "– –"
    var size: CGFloat = 24
    var valueColor: Color = Theme.textPrimary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            if sealed {
                SealedStat(placeholder: placeholder, size: size)
            } else {
                Text(value)
                    .font(Theme.scoreboard(size))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            StatLabel(label, color: Theme.textTertiary)
        }
    }
}

/// Header row shared by the Pro stat-board cards on the profile: heading on the
/// left, PRO badge when locked, chevron affordance on the right.
struct StatBoardHeader: View {
    let title: String
    let locked: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatHeading(title)
            Spacer()
            if locked { ProLockBadge() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Unlock bar

/// The single conversion moment on every teaser sheet: optional one-line hook
/// (their own numbers: "3 badges you've earned are waiting."), the unlock
/// button, and the trial terms. Tapping opens the paywall for `context`.
struct ProTeaserUnlockBar: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    let context: PaywallContext
    var title = "Unlock with Pro"
    var caption: String?

    var body: some View {
        VStack(spacing: 10) {
            if let caption {
                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                subscriptions.presentPaywall(context)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open.fill")
                        .font(.footnote.weight(.bold))
                    Text(title.uppercased())
                        .font(.subheadline.weight(.heavy))
                        .tracking(1.1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            Text(trialLine)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var trialLine: String {
        if let days = subscriptions.plans.first?.trialDays {
            return "\(days) days free · Cancel anytime"
        }
        return "Cancel anytime"
    }
}
