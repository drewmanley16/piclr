import SwiftUI

/// Shared pieces of the Pro teaser experience. Free users open the *real*
/// feature sheet filled with their real data: the free slice renders normally,
/// premium values sit behind `SealedStat` redaction bars (the value's slot is
/// visibly there, covered), and one `ProTeaserUnlockBar` opens the paywall for
/// that feature. The pitch is the user's own numbers, not marketing copy.
/// Type mirrors the profile's Record card so Pro surfaces don't grow a second
/// voice: `.headline` titles, `.title3`-bold-style numerals, `.caption2` labels.
extension View {
    /// Blur-locks premium content whose *shape* is the tease (charts). For
    /// plain numbers prefer `SealedStat` — a crisp bar over smeared pixels.
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

/// Uppercase micro eyebrow, matching the app's existing ones ("BEST PARTNERS",
/// "WEEK OF JUL 20"). For section markers only — never under a numeral.
struct StatLabel: View {
    let text: String
    var color: Color = Theme.textSecondary

    init(_ text: String, color: Color = Theme.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Card/section heading on Pro surfaces — the same `.headline` voice as the
/// Record and Rivals cards.
struct StatHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
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

/// A locked value's slot: a solid redaction bar covering exactly where the
/// number goes, so the board clearly *has* a value here that the viewer can't
/// read yet. The bar's size never derives from the real value, so nothing
/// leaks. `showsLock: false` is the "awaiting results" variant for values that
/// don't exist yet (an open season) rather than locked ones.
struct SealedStat: View {
    var width: CGFloat = 52
    /// Point size of the numeral this bar stands in for; sets the bar height.
    var size: CGFloat = 16
    var showsLock = true

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Theme.surfaceElevated)
                .frame(width: width, height: max(size * 0.55, 10))
            if showsLock {
                Image(systemName: "lock.fill")
                    .font(.system(size: max(size * 0.5, 9), weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsLock ? "Locked. Unlock with Pro." : "Awaiting results.")
    }
}

/// One numeral + label block on a stat board — the Record card's stat column,
/// extracted: bold number over a quiet caption.
struct StatSegment: View {
    let value: String
    let label: String
    var sealed = false
    var sealedWidth: CGFloat = 52
    var size: CGFloat = 22
    var valueColor: Color = Theme.textPrimary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            if sealed {
                SealedStat(width: sealedWidth, size: size)
            } else {
                Text(value)
                    .font(.system(size: size, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Header row shared by the Pro stat-board cards on the profile: `.headline`
/// title like every other card, PRO badge when locked, chevron affordance.
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
                    Text(title)
                        .font(.headline)
                }
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.accent, in: Capsule())
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
