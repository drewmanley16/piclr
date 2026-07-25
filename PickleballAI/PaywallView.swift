import SwiftUI

/// The paywall. Context-aware headline, a short list of what Pro unlocks, two
/// selectable plan cards (annual pre-selected with a trial), one CTA, and the
/// required restore / terms / privacy footer. Presented globally from
/// `SubscriptionStore.paywallContext`.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sub: SubscriptionStore
    let context: PaywallContext

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                featureList
                planPicker
                cta
                footer
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 68, height: 68)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack(spacing: 6) {
                Text("piclr")
                    .font(.title2.weight(.heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("PRO")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
            }

            Text(context.headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 28)
    }

    /// The feature the user was reaching for when the paywall opened, if the
    /// context maps to one. It leads the list, highlighted.
    private var leadFeature: ProFeature? {
        ProFeature.catalog.first { $0.contextID == context.id }
    }

    /// Lead feature first, then the strongest of the rest, capped at five rows
    /// so the pitch stays scannable.
    private var features: [ProFeature] {
        guard let lead = leadFeature else { return Array(ProFeature.catalog.prefix(5)) }
        return [lead] + ProFeature.catalog.filter { $0.title != lead.title }.prefix(4)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(features.enumerated()), id: \.element.title) { index, feature in
                ProFeatureRow(
                    icon: feature.icon,
                    title: feature.title,
                    detail: feature.detail,
                    highlighted: index == 0 && leadFeature != nil
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 10)
    }

    private var planPicker: some View {
        VStack(spacing: 12) {
            ForEach(sub.plans) { plan in
                PlanCard(plan: plan, isSelected: sub.selectedPlanID == plan.id) {
                    Haptics.tap()
                    Analytics.capture(.paywallPlanSelected, [Analytics.Property.planID: plan.id])
                    withAnimation(.snappy(duration: 0.2)) { sub.selectedPlanID = plan.id }
                }
            }
        }
    }

    private var cta: some View {
        VStack(spacing: 10) {
            if let errorText = sub.errorText {
                Text(errorText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.loss)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await sub.purchaseSelected() }
            } label: {
                ZStack {
                    Text(ctaTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.background)
                        .opacity(sub.isWorking ? 0 : 1)
                    if sub.isWorking { ProgressView().tint(Theme.background) }
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(sub.isWorking)

            Text(ctaSubtitle)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var selectedPlan: PlanOption {
        sub.plans.first { $0.id == sub.selectedPlanID } ?? SubscriptionStore.fallbackAnnual
    }
    private var ctaTitle: String {
        selectedPlan.trialDays != nil ? "Start free trial" : "Continue"
    }
    private var ctaSubtitle: String {
        if let days = selectedPlan.trialDays {
            return "\(days) days free, then \(selectedPlan.renewalText). Cancel anytime."
        }
        return "\(selectedPlan.renewalText). Cancel anytime."
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                Task { await sub.restore() }
            } label: {
                Text("Restore purchases")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            HStack(spacing: 16) {
                Link("Terms", destination: URL(string: "https://pickleball.ai/terms")!)
                Text("·").foregroundStyle(Theme.textTertiary)
                Link("Privacy", destination: URL(string: "https://pickleball.ai/privacy")!)
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 4)
    }
}

/// One row of the paywall's "what you get" list. `contextID` ties a feature to
/// the `PaywallContext` that reaches for it, so the paywall can lead with the
/// exact thing the user just tapped. Catalog order doubles as the default list:
/// the first five rows are the general-context pitch.
private struct ProFeature {
    /// Matching `PaywallContext.id`, or nil for features with no entry point.
    let contextID: String?
    let icon: String
    let title: String
    let detail: String

    static let catalog: [ProFeature] = [
        ProFeature(contextID: "insights", icon: "chart.bar.xaxis", title: "Play insights",
                   detail: "Clutch record, best court, best partner, and more."),
        ProFeature(contextID: "rivalry", icon: "flame.fill", title: "Rivalry insights",
                   detail: "Full head-to-head trends and who's heating up."),
        ProFeature(contextID: "weekly_wrap", icon: "sparkles", title: "Weekly wrap",
                   detail: "Your record, streak, and hottest rival, recapped and shareable every week."),
        ProFeature(contextID: "milestones", icon: "medal.fill", title: "All 14 milestones",
                   detail: "Claim every badge you earn, from first match to a 52-week streak."),
        ProFeature(contextID: "history", icon: "infinity", title: "Unlimited history",
                   detail: "Every session and stat, all the way back."),
        ProFeature(contextID: "season_awards", icon: "rosette", title: "Season awards",
                   detail: "Monthly podium finishes, kept in your trophy case forever."),
        ProFeature(contextID: "goals", icon: "target", title: "Goals and streak saves",
                   detail: "Set a weekly target and get nudged before your streak breaks."),
        ProFeature(contextID: "leaderboard", icon: "trophy.fill", title: "Leaderboard filters",
                   detail: "Slice the crew leaderboard by wins, activity, and month."),
        ProFeature(contextID: nil, icon: "square.and.arrow.up", title: "Shareable cards",
                   detail: "Premium recap cards built to post to the group chat.")
    ]
}

private struct ProFeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    var highlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(highlighted ? Theme.background : Theme.accent)
                .frame(width: 30, height: 30)
                .background(highlighted ? Theme.accent : Theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if highlighted { Spacer(minLength: 0) }
        }
        .padding(10)
        .background(
            highlighted ? Theme.accentSoft : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct PlanCard: View {
    let plan: PlanOption
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if let badge = plan.badge {
                            Text(badge)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Theme.background)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    Text(plan.footnote)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(plan.priceText)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(plan.periodText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)
            .background(
                isSelected ? Theme.accentSoft : Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Filled "PRO" pill marking a subscribed user (profile header). Distinct from
/// `ProLockBadge`, which marks locked features for non-subscribers.
struct ProStatusBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent, in: Capsule())
    }
}

/// Small "PRO" pill to mark locked features in-line. Drop next to any premium
/// entry point; tapping the row it lives on should call `presentPaywall`.
struct ProLockBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
            Text("PRO").font(.caption2.weight(.heavy))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.accentSoft, in: Capsule())
    }
}
