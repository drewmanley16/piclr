import SwiftUI

/// Shared pieces of the Pro teaser experience. Free users open the *real*
/// feature sheet filled with their real data: the free slice renders normally,
/// premium content sits behind `proLocked` blur, and one `ProTeaserUnlockBar`
/// at the bottom opens the paywall for that feature. The pitch is the user's
/// own numbers, not marketing copy.
extension View {
    /// Blur-locks premium content for free users while keeping its true shape:
    /// the real values render underneath, unreadable but obviously *there*.
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
